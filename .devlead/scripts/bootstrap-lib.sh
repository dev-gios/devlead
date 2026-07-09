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
# (e.g. ~/Work/devlead), used by callers that don't already know their own
# repo path (envelope.sh init). install.sh instead passes its own $REPO_DIR
# explicitly (it already derived it at its own top) — that is the PRIMARY
# path; this self-resolution is the FALLBACK, and both converge on the same
# absolute path in steady state.
#
# ADR — readlink -f is the SOLE symlink-resolution mechanism (locked decision):
# `cd "$(dirname "$BASH_SOURCE")"` does NOT resolve symlinks — if this file is
# reached via its installed symlink ~/.devlead/scripts/bootstrap-lib.sh, a
# `cd`-based dirname would land in ~/.devlead, not the real checkout. Only
# `readlink -f` on ${BASH_SOURCE[0]} follows the ENTIRE symlink chain back to
# the real committed file, which is why it is used here exclusively.
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
# bootstrap_symlinks [repo_dir]
# Idempotent create-or-fix symlinks: scripts, CLI, hooks, Claude commands.
# `ln -sf` is correct-or-recreated by construction — it never fails on an
# already-correct link, and self-heals a broken/stale one. NEVER touches
# ~/.claude/settings.json (that merge stays install.sh's sole responsibility).
# ALWAYS returns 0 — see return-0 contract ADR above.
# ---------------------------------------------------------------------------
bootstrap_symlinks() {
  local repo_dir="${1:-}"
  [[ -z "$repo_dir" ]] && repo_dir="$(_bootstrap_default_repo_dir)"

  local devlead_dir="$HOME/.devlead"
  local local_bin="$HOME/.local/bin"
  local claude_commands="$HOME/.claude/commands"

  mkdir -p "$devlead_dir/scripts" "$devlead_dir/hooks" "$local_bin" "$claude_commands" 2>/dev/null \
    || echo "bootstrap: WARNING: failed to mkdir one of the symlink target dirs" >&2

  # (src|dst|chmod) table. chmod="x" -> chmod +x the SOURCE (matches
  # install.sh's prior per-script chmod); markdown commands get no chmod.
  local -a _pairs=(
    "$repo_dir/.devlead/scripts/state.sh|$devlead_dir/scripts/state.sh|x"
    "$repo_dir/.devlead/scripts/branch.sh|$devlead_dir/scripts/branch.sh|x"
    "$repo_dir/.devlead/scripts/ref-resolver.sh|$devlead_dir/scripts/ref-resolver.sh|x"
    "$repo_dir/.devlead/scripts/forbidden-check.sh|$devlead_dir/scripts/forbidden-check.sh|x"
    "$repo_dir/.devlead/scripts/devlead-active.sh|$devlead_dir/scripts/devlead-active.sh|x"
    "$repo_dir/.devlead/scripts/envelope.sh|$devlead_dir/scripts/envelope.sh|x"
    "$repo_dir/.devlead/scripts/sweep.sh|$devlead_dir/scripts/sweep.sh|x"
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
    if ln -sf "$_src" "$_dst" 2>/dev/null; then
      if [[ "$_mode" == "x" ]]; then
        chmod +x "$_src" 2>/dev/null \
          || echo "bootstrap: WARNING: failed to chmod +x $_src" >&2
      fi
    else
      echo "bootstrap: WARNING: failed to symlink $_dst -> $_src" >&2
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# bootstrap_systemd [repo_dir]
# Idempotent symlink of the sweep .service/.timer units into
# ~/.config/systemd/user/. NEVER enables the timer — enable+start is the sole
# responsibility of the explicit opt-in question (envelope.sh _do_optin).
# ALWAYS returns 0.
# ---------------------------------------------------------------------------
bootstrap_systemd() {
  local repo_dir="${1:-}"
  [[ -z "$repo_dir" ]] && repo_dir="$(_bootstrap_default_repo_dir)"

  local systemd_dir="$HOME/.config/systemd/user"
  mkdir -p "$systemd_dir" 2>/dev/null \
    || echo "bootstrap: WARNING: failed to mkdir $systemd_dir" >&2

  local -a _pairs=(
    "$repo_dir/.devlead/systemd/devlead-sweep.service|$systemd_dir/devlead-sweep.service"
    "$repo_dir/.devlead/systemd/devlead-sweep.timer|$systemd_dir/devlead-sweep.timer"
  )

  local _entry _src _dst
  for _entry in "${_pairs[@]}"; do
    IFS='|' read -r _src _dst <<< "$_entry"
    ln -sf "$_src" "$_dst" 2>/dev/null \
      || echo "bootstrap: WARNING: failed to symlink $_dst -> $_src" >&2
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
