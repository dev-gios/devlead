#!/usr/bin/env bash
# bootstrap-lib.sh — sourced-only function library: "prepare my machine" primitives
# shared by install.sh (first install) and envelope.sh init (repeatable re-derive).
#
# NOT executed directly — no dispatch here. `source` it and call the functions.
#
# ADR — why this file NEVER runs `set -e` / `set -u` / `set -o pipefail`:
# This file is SOURCED into the caller's shell, not run as a subprocess. Any
# `set` here would silently change the CALLER's shell options for the rest of
# its script — install.sh runs `set -euo pipefail` and envelope.sh runs
# `set -uo pipefail`; each caller keeps its own mode. Setting anything here
# would leak across that boundary. Internal degradation is therefore handled
# explicitly (`|| true` + stderr warnings), never via inherited `set -e`.
#
# ADR — the return-0 contract:
# ALL THREE bootstrap_* functions below ALWAYS `return 0`, regardless of
# whether individual steps inside them failed. A single failing `ln -sf` /
# `chmod` / `mkdir` must never abort install.sh's `set -euo pipefail` run —
# that fragility is exactly what extracting this lib avoids. Degradation is
# reported on stderr; callers that care read stderr, not the exit code.

# ---------------------------------------------------------------------------
# _bootstrap_default_repo_dir — resolves the DevLead SOURCE checkout root
# (e.g. ~/Work/devlead) by following this file's OWN symlink chain. This is
# now a FALLBACK ONLY (see the ADR above `_bootstrap_source_repo` below) —
# it is correct exclusively on a pre-migration first run, where this file is
# still reached via its installed symlink ~/.devlead/scripts/bootstrap-lib.sh.
# Once this file itself becomes a published COPY (post-migration steady
# state), `readlink -f` on itself resolves to itself — no symlink chain to
# follow — and walking `dirname` three times up from a copy under
# ~/.devlead/scripts/ lands on ~/.devlead, NOT the repo root. Callers MUST
# NOT invoke this directly for repo resolution in steady state; go through
# `_bootstrap_source_repo` instead, which gates this fallback on the
# still-a-symlink check.
#
# `cd "$(dirname "$BASH_SOURCE")"` does NOT resolve symlinks on its own —
# only `readlink -f` on ${BASH_SOURCE[0]} follows the ENTIRE symlink chain
# back to the real committed file, which is why it is used here.
#
# This file lives at <repo_root>/.devlead/scripts/bootstrap-lib.sh — three
# path components below repo root once the filename itself is dropped
# (bootstrap-lib.sh -> scripts -> .devlead -> repo_root). One `readlink -f`
# fully resolves the real file path (symlinks and all); three `dirname` hops
# on that already-resolved path then walk up to repo root — no further symlink
# resolution is needed past that single readlink -f call.
# ---------------------------------------------------------------------------
_bootstrap_default_repo_dir() {
  local _real
  _real="$(readlink -f "${BASH_SOURCE[0]}")"
  dirname "$(dirname "$(dirname "$_real")")"
}

# ---------------------------------------------------------------------------
# _bootstrap_source_repo [explicit_repo_dir] — resolves the DevLead SOURCE
# checkout root. Prints the resolved absolute path on stdout and returns 0,
# or prints nothing and returns 1 when no tier resolves.
#
# ADR — SOURCE_REPO is the PRIMARY resolution mechanism (supersedes the
# readlink-f-sole ADR from #1915): once live scripts/CLI/hooks/commands and
# systemd units are published as real COPIES (not symlinks), a copy's own
# `readlink -f` resolves to itself, not back to the repo checkout — self-
# resolution is fundamentally incompatible with the copy model in steady
# state. `~/.devlead/SOURCE_REPO` is a one-line anchor file recording the
# absolute source checkout path; it is written early by `devlead upgrade`/
# `devlead init` (before any copy happens, so a mid-run failure never leaves
# published copies without a recorded anchor) and self-heals on every run.
#
# Three-tier resolution order (first match wins):
#   1. explicit arg — the caller already knows its own repo path (install.sh
#      derives $REPO_DIR at its own top and passes it straight through).
#   2. `~/.devlead/SOURCE_REPO` — the durable anchor, once it exists.
#   3. `_bootstrap_default_repo_dir` self-resolve — FALLBACK ONLY, and only
#      correct while this very file (bootstrap-lib.sh) is STILL a symlink,
#      i.e. the pre-migration first run before any copy has been published.
#      Once this file is itself a copy, tier 3 cannot recover the repo path
#      (see the ADR on `_bootstrap_default_repo_dir` above) — with no arg
#      and no SOURCE_REPO anchor recorded, resolution fails honestly (return
#      1) rather than guessing a wrong path.
# ---------------------------------------------------------------------------
_bootstrap_source_repo() {
  local _arg="${1:-}"
  if [[ -n "$_arg" ]]; then
    printf '%s\n' "$_arg"
    return 0
  fi

  local _anchor="$HOME/.devlead/SOURCE_REPO"
  if [[ -f "$_anchor" ]]; then
    local _recorded
    _recorded="$(<"$_anchor")"
    if [[ -n "$_recorded" ]]; then
      printf '%s\n' "$_recorded"
      return 0
    fi
  fi

  if [[ -L "${BASH_SOURCE[0]}" ]]; then
    _bootstrap_default_repo_dir
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# _bootstrap_copy_one src dst mode — atomic per-file publish primitive.
#
# Behavior:
#   - Resolves the real source path via `readlink -f` (defensive: correct
#     even if `src` itself is reached through a symlink).
#   - Migration: if `dst` is currently a symlink (leftover pre-copy-model
#     install), remove it FIRST. Without this, the content-skip check below
#     (`[[ -f "$_dst" ]] && cmp -s "$_real_src" "$_dst"`) would follow the
#     pre-existing symlink and trivially "match" the very repo file it
#     points at, so `dst` would silently remain a symlink forever (a silent
#     non-migration) instead of becoming a pinned copy — the symlink must be
#     gone before any copy/compare happens.
#   - Content-skip: if `dst` already exists as a real file with byte-
#     identical content to the resolved source, this is a cheap no-op — the
#     copy/rename is skipped, but for mode="x" targets the executable bit is
#     still re-asserted (chmod +x is idempotent) so a destination that lost
#     its executable bit through some external means self-heals even when
#     content is unchanged.
#   - Otherwise: copy source to a same-directory temp file `dst.tmp.$$`,
#     chmod +x the temp file first when mode="x", then `mv -f` the temp file
#     onto `dst`. `mv` on the same filesystem (both under $HOME) is an atomic
#     rename — the live path is NEVER observed half-written, which matters
#     because a 07:00 sweep timer could execute it mid-copy otherwise.
#   - Returns non-zero on any REAL copy failure (temp write or rename), so
#     callers that need honest per-file failure accounting (`devlead
#     upgrade`, added in a later phase) can detect and report it. Bootstrap
#     wrappers (`bootstrap_symlinks`/`bootstrap_systemd`) still swallow this
#     per the return-0 contract ADR above — this function's non-zero return
#     is for callers that opt in to honest failure reporting.
# ---------------------------------------------------------------------------
_bootstrap_copy_one() {
  local _src="$1" _dst="$2" _mode="${3:-}"

  local _real_src
  _real_src="$(readlink -f "$_src" 2>/dev/null)"
  [[ -z "$_real_src" ]] && _real_src="$_src"

  if [[ -L "$_dst" ]]; then
    rm -f "$_dst" 2>/dev/null || {
      echo "bootstrap: WARNING: failed to remove stale symlink $_dst" >&2
      return 1
    }
  fi

  if [[ -f "$_dst" ]] && cmp -s "$_real_src" "$_dst" 2>/dev/null; then
    if [[ "$_mode" == "x" ]] && ! chmod +x "$_dst" 2>/dev/null; then
      echo "bootstrap: WARNING: failed to chmod +x $_dst" >&2
      return 1
    fi
    return 0
  fi

  local _tmp="$_dst.tmp.$$"
  if ! cp "$_real_src" "$_tmp" 2>/dev/null; then
    echo "bootstrap: WARNING: failed to copy $_real_src -> $_tmp" >&2
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi

  if [[ "$_mode" == "x" ]] && ! chmod +x "$_tmp" 2>/dev/null; then
    echo "bootstrap: WARNING: failed to chmod +x $_tmp" >&2
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi

  if ! mv -f "$_tmp" "$_dst" 2>/dev/null; then
    echo "bootstrap: WARNING: failed to move $_tmp -> $_dst" >&2
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# bootstrap_symlinks [repo_dir]
# Idempotent publish (copy, not symlink) of: scripts (including this very
# file, bootstrap-lib.sh — it is sourced as a plain sibling by the installed
# copy of envelope.sh, so it must live alongside it, not be special-cased as
# a standing symlink anchor), CLI, hooks, and Claude commands. Auto-migrates
# any leftover symlink from the pre-copy-model install (see
# `_bootstrap_copy_one`). NEVER touches ~/.claude/settings.json (that merge
# stays install.sh's sole responsibility).
#
# Sets the global array BOOTSTRAP_SYMLINKS_FAILED to the list of destination
# paths that failed to publish this run (empty array = full success), for a
# later caller (`devlead upgrade`) that needs honest per-file failure
# reporting. This function itself ALWAYS returns 0 — see the return-0
# contract ADR above; failures are reported via stderr warnings and the
# BOOTSTRAP_SYMLINKS_FAILED array, never via the return code.
# ---------------------------------------------------------------------------
bootstrap_symlinks() {
  local repo_dir="${1:-}"
  BOOTSTRAP_SYMLINKS_FAILED=()

  if [[ -z "$repo_dir" ]]; then
    repo_dir="$(_bootstrap_source_repo)" || repo_dir=""
  fi
  if [[ -z "$repo_dir" ]]; then
    echo "bootstrap: WARNING: could not resolve source repo (no arg, no ~/.devlead/SOURCE_REPO, and bootstrap-lib.sh is not a symlink) — skipping publish" >&2
    return 0
  fi

  local devlead_dir="$HOME/.devlead"
  local local_bin="$HOME/.local/bin"
  local claude_commands="$HOME/.claude/commands"

  mkdir -p "$devlead_dir/scripts" "$devlead_dir/hooks" "$local_bin" "$claude_commands" 2>/dev/null \
    || echo "bootstrap: WARNING: failed to mkdir one of the publish target dirs" >&2

  # (src|dst|chmod) table. chmod="x" -> chmod +x the DESTINATION copy (see
  # _bootstrap_copy_one) instead of the shared symlink target of the old
  # model; bootstrap-lib.sh and markdown commands are sourced/read-only, so
  # they get no chmod.
  local -a _pairs=(
    "$repo_dir/.devlead/scripts/bootstrap-lib.sh|$devlead_dir/scripts/bootstrap-lib.sh|"
    "$repo_dir/.devlead/scripts/state.sh|$devlead_dir/scripts/state.sh|x"
    "$repo_dir/.devlead/scripts/branch.sh|$devlead_dir/scripts/branch.sh|x"
    "$repo_dir/.devlead/scripts/ref-resolver.sh|$devlead_dir/scripts/ref-resolver.sh|x"
    "$repo_dir/.devlead/scripts/forbidden-check.sh|$devlead_dir/scripts/forbidden-check.sh|x"
    "$repo_dir/.devlead/scripts/devlead-active.sh|$devlead_dir/scripts/devlead-active.sh|x"
    "$repo_dir/.devlead/scripts/envelope.sh|$devlead_dir/scripts/envelope.sh|x"
    "$repo_dir/.devlead/scripts/envelope-auth.sh|$devlead_dir/scripts/envelope-auth.sh|x"
    "$repo_dir/.devlead/scripts/sweep.sh|$devlead_dir/scripts/sweep.sh|x"
    "$repo_dir/.devlead/scripts/run-state.sh|$devlead_dir/scripts/run-state.sh|x"
    "$repo_dir/.devlead/scripts/sweep-loop.sh|$devlead_dir/scripts/sweep-loop.sh|x"
    "$repo_dir/.devlead/bin/devlead|$local_bin/devlead|x"
    "$repo_dir/.claude/hooks/post-edit.sh|$devlead_dir/hooks/post-edit.sh|x"
    "$repo_dir/.claude/hooks/gate-check.sh|$devlead_dir/hooks/gate-check.sh|x"
    "$repo_dir/.claude/commands/arranquemos.md|$claude_commands/arranquemos.md|"
    "$repo_dir/.claude/commands/cerremos.md|$claude_commands/cerremos.md|"
    "$repo_dir/.claude/commands/batch.md|$claude_commands/batch.md|"
    "$repo_dir/.claude/commands/sweep-execute.md|$claude_commands/sweep-execute.md|"
  )

  local _entry _src _dst _mode
  for _entry in "${_pairs[@]}"; do
    IFS='|' read -r _src _dst _mode <<< "$_entry"
    if ! _bootstrap_copy_one "$_src" "$_dst" "$_mode"; then
      echo "bootstrap: WARNING: failed to publish $_dst from $_src" >&2
      BOOTSTRAP_SYMLINKS_FAILED+=("$_dst")
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# bootstrap_systemd [repo_dir]
# Idempotent publish (copy, not symlink) of the sweep .service/.timer units
# into ~/.config/systemd/user/. Auto-migrates any leftover symlink from the
# pre-copy-model install. NEVER enables the timer — enable+start is the sole
# responsibility of the explicit opt-in question (envelope.sh _do_optin).
#
# Captures a `cksum` of each destination unit BEFORE and AFTER publishing it,
# and sets the global BOOTSTRAP_SYSTEMD_RELOAD_NEEDED to 1 if any unit's
# on-disk content actually changed this run, 0 otherwise. A later caller
# (`devlead upgrade`) reads this signal to decide whether `systemctl --user
# daemon-reload` is warranted — publishing byte-identical content (the
# common case) must NOT trigger a reload. This function ALWAYS returns 0.
#
# Sets the global array BOOTSTRAP_SYSTEMD_FAILED to the list of destination
# paths that failed to publish this run (empty array = full success), for a
# later caller (`devlead upgrade`) that needs honest per-file failure
# reporting — mirrors BOOTSTRAP_SYMLINKS_FAILED in `bootstrap_symlinks` above.
# This function itself ALWAYS returns 0 — see the return-0 contract ADR
# above; failures are reported via stderr warnings and the
# BOOTSTRAP_SYSTEMD_FAILED array, never via the return code.
# ---------------------------------------------------------------------------
bootstrap_systemd() {
  local repo_dir="${1:-}"
  # shellcheck disable=SC2034 # consumed externally by devlead upgrade (later phase)
  BOOTSTRAP_SYSTEMD_RELOAD_NEEDED=0
  BOOTSTRAP_SYSTEMD_FAILED=()

  if [[ -z "$repo_dir" ]]; then
    repo_dir="$(_bootstrap_source_repo)" || repo_dir=""
  fi
  if [[ -z "$repo_dir" ]]; then
    echo "bootstrap: WARNING: could not resolve source repo (no arg, no ~/.devlead/SOURCE_REPO, and bootstrap-lib.sh is not a symlink) — skipping systemd unit publish" >&2
    return 0
  fi

  local systemd_dir="$HOME/.config/systemd/user"
  mkdir -p "$systemd_dir" 2>/dev/null \
    || echo "bootstrap: WARNING: failed to mkdir $systemd_dir" >&2

  local -a _pairs=(
    "$repo_dir/.devlead/systemd/devlead-sweep.service|$systemd_dir/devlead-sweep.service"
    "$repo_dir/.devlead/systemd/devlead-sweep.timer|$systemd_dir/devlead-sweep.timer"
    "$repo_dir/.devlead/systemd/devlead-loop.service|$systemd_dir/devlead-loop.service"
    "$repo_dir/.devlead/systemd/devlead-loop.timer|$systemd_dir/devlead-loop.timer"
  )

  local _entry _src _dst _before _after
  for _entry in "${_pairs[@]}"; do
    IFS='|' read -r _src _dst <<< "$_entry"

    _before=""
    [[ -f "$_dst" ]] && _before="$(cksum "$_dst" 2>/dev/null)"

    if ! _bootstrap_copy_one "$_src" "$_dst" ""; then
      echo "bootstrap: WARNING: failed to publish $_dst from $_src" >&2
      BOOTSTRAP_SYSTEMD_FAILED+=("$_dst")
      continue
    fi

    _after=""
    [[ -f "$_dst" ]] && _after="$(cksum "$_dst" 2>/dev/null)"
    if [[ "$_before" != "$_after" ]]; then
      # shellcheck disable=SC2034 # consumed externally by devlead upgrade (later phase)
      BOOTSTRAP_SYSTEMD_RELOAD_NEEDED=1
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# bootstrap_token_seed
# Mirrors sweep.sh's _ensure_auth gate: seed ~/.devlead/gh-token ONLY if it is
# missing, empty, or not chmod 600. Never overwrites an already-valid file
# (content/mtime preserved). Degrades honestly (stderr warning, no partial
# write) when `gh` is missing or unauthenticated. ALWAYS returns 0 —
# degradation is not failure.
# ---------------------------------------------------------------------------
bootstrap_token_seed() {
  local token_file="$HOME/.devlead/gh-token"
  mkdir -p "$(dirname "$token_file")" 2>/dev/null \
    || echo "bootstrap: WARNING: failed to mkdir $(dirname "$token_file")" >&2

  if [[ -f "$token_file" ]]; then
    local _perm
    _perm="$(stat -c '%a' "$token_file" 2>/dev/null || echo "")"
    if [[ -s "$token_file" ]]; then
      if [[ "$_perm" == "600" ]]; then
        return 0
      fi
      # Permission-only repair: existing content is valid, only the mode
      # drifted. This does NOT require `gh` — repairing perms on content we
      # already have is independent of seeding NEW content, which does need
      # `gh` (see the fall-through below, reached only when missing/empty).
      chmod 600 "$token_file" 2>/dev/null \
        || echo "bootstrap: WARNING: failed to chmod 600 $token_file" >&2
      return 0
    fi
  fi

  if ! command -v gh &>/dev/null; then
    echo "bootstrap: WARNING: gh not authenticated — token not seeded" >&2
    return 0
  fi

  local _tok
  _tok="$(gh auth token 2>/dev/null || true)"
  if [[ -z "$_tok" ]]; then
    echo "bootstrap: WARNING: gh not authenticated — token not seeded" >&2
    return 0
  fi

  # umask 077 inside a subshell closes the world/group-readable window that
  # existed between file creation and the chmod 600 below — the file is born
  # with restrictive perms instead of the default umask (typically 644) for
  # the brief interval before chmod ran. Subshell keeps the umask change from
  # leaking into the caller's shell (this file is sourced, never executed).
  # rm -f first: if token_file already exists (stale/interrupted run, manual
  # touch), the '>' redirection would truncate that existing inode instead of
  # creating a new one, and umask has no effect on an existing inode's perms —
  # reopening the same race for pre-existing files. Removing it first forces
  # '>' to always create a fresh inode under the tightened umask.
  rm -f "$token_file" 2>/dev/null
  if ( umask 077 && printf '%s' "$_tok" > "$token_file" ); then
    chmod 600 "$token_file" 2>/dev/null \
      || echo "bootstrap: WARNING: failed to chmod 600 $token_file" >&2
  else
    echo "bootstrap: WARNING: failed to write $token_file" >&2
  fi

  return 0
}
