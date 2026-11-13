#!/usr/bin/env bash
# devlead-session.sh — manages the DevLead opt-in marker.
#
# DevLead is an opt-in mode, NOT an always-on daemon (DEVLEAD.md §2, decision 7).
# The hooks (post-edit.sh, gate-check.sh) are registered globally but stay INERT
# unless the current repo is in the session list. /arranquemos turns it on for the
# day; /cerremos turns it off.
#
# Usage:
#   devlead-session.sh on     → mark the current repo as DevLead-active (dedup)
#   devlead-session.sh off    → unmark the current repo
#   devlead-session.sh check  → exit 0 if active here, exit 1 if not
#
# State lives in ~/.devlead/session-repos, one entry per line in the format
# `path<TAB>epoch` (UTC seconds from `date -u +%s`). Entries expire on their
# own: `check` treats an entry older than the TTL (default 16h, override via
# DEVLEAD_SESSION_TTL_HOURS) as inert WITHOUT deleting it — `off` stays the
# only explicit-removal path. Legacy bare lines (no timestamp, from before
# this format existed) are always inert but stay matchable/removable by `on`
# and `off` via field-based (not whole-line) matching.
# `on`/`off` serialize their read-rewrite-replace critical section with an
# flock on a dedicated lockfile so concurrent invocations never lose an
# update; any write failure (permissions, disk) is reported on stderr with a
# nonzero exit instead of a false success banner; and a repo path containing
# a TAB or NEWLINE byte is rejected outright (nothing written) since either
# would corrupt the registry format or inject a spoofed entry.
# It is local machine state — never committed, never a source of truth on the "qué".
#
# Pre-rename machines may still have ~/.devlead/active-repos on disk (this
# script used to be devlead-active.sh). `_migrate_registry` moves that file
# to the new path exactly once, under the same lock used for on/off writes;
# `check` falls back to reading it read-only when only the old file exists,
# so hooks never silently go inert on an unmigrated machine.

set -uo pipefail

SESSION_FILE="$HOME/.devlead/session-repos"
LEGACY_SESSION_FILE="$HOME/.devlead/active-repos"  # pre-rename path; referenced
# only here, in check's read-only fallback, and in bootstrap's prune (REQ-1).
_TTL_DEFAULT_HOURS=16

# Resolve the repo root (or $PWD if not in a git repo) so the marker is stable
# regardless of which subdirectory the hook fires from.
_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# _resolve_ttl_hours — prints the effective TTL in hours. Never fails, never
# disables the gate: an invalid override falls back to the pinned default and
# warns on stderr, it never bypasses evaluation.
_resolve_ttl_hours() {
  local _h="${DEVLEAD_SESSION_TTL_HOURS:-$_TTL_DEFAULT_HOURS}"
  if ! [[ "$_h" =~ ^[1-9][0-9]*$ ]]; then
    echo "devlead-session: DEVLEAD_SESSION_TTL_HOURS='$_h' is not a positive integer — using ${_TTL_DEFAULT_HOURS}h instead" >&2
    _h="$_TTL_DEFAULT_HOURS"
  fi
  printf '%s' "$_h"
}

# _drop_root — stdin -> stdout, drops every line whose path field (text
# before the first tab, or the whole line for a legacy bare entry) matches
# $_root. Reads whole lines and re-emits them byte-for-byte so foreign lines
# survive untouched — no awk -v (backslash processing), no grep -x
# (whole-line matching can't separate the path field from a trailing ts).
_drop_root() {
  local _line
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "${_line%%$'\t'*}" == "$_root" ]] && continue
    printf '%s\n' "$_line"
  done
}

# _validate_root — fails closed (stderr + exit 1, nothing written) if $_root
# contains a TAB or NEWLINE byte. A TAB would land inside the path field and
# corrupt the tab-delimited format (breaks dedup/freshness matching); a
# NEWLINE would let a crafted repo path inject an extra, attacker-controlled
# line into the registry. Called by on/off before any write; `check` is
# read-only and does not need it.
_validate_root() {
  if [[ "$_root" == *$'\t'* || "$_root" == *$'\n'* ]]; then
    echo "devlead-session: repo path contains a TAB or NEWLINE byte — refusing to write (would corrupt the registry or inject a spoofed entry)" >&2
    exit 1
  fi
}

# _acquire_lock — opens fd 9 on "${SESSION_FILE}.lock" (a dedicated lockfile,
# never the registry file itself — the rewrite path replaces the registry's
# inode via `mv`, so locking that file directly would not serialize anything)
# and takes an exclusive flock, waiting up to a few seconds. Exits 1 with a
# stderr message on any failure — opening the lockfile or acquiring the lock
# — so on/off never proceed with an unlocked read-rewrite-replace. `check`
# stays read-only and lock-free; it never calls this.
_acquire_lock() {
  local _lock="${SESSION_FILE}.lock"
  exec 9>"$_lock" || { echo "devlead-session: cannot open lock file $_lock" >&2; exit 1; }
  if ! flock -w 5 9; then
    echo "devlead-session: could not acquire lock on $_lock within 5s" >&2
    exit 1
  fi
}

# _migrate_registry — called under the on/off flock, before any write to
# SESSION_FILE. Handles the three possible pre-rename layouts:
#   both exist  → refuse to merge or choose; abort loudly, nothing written
#   old only    → mv old->new exactly once, notify on stderr
#   else        → no-op (already migrated, or fresh install)
_migrate_registry() {
  if [[ -f "$LEGACY_SESSION_FILE" && -f "$SESSION_FILE" ]]; then
    echo "devlead-session: both $LEGACY_SESSION_FILE and $SESSION_FILE exist — refusing to merge or choose. Keep the entries you want in $SESSION_FILE, delete $LEGACY_SESSION_FILE, then re-run." >&2
    exit 1
  fi
  [[ -f "$LEGACY_SESSION_FILE" ]] || return 0
  mv "$LEGACY_SESSION_FILE" "$SESSION_FILE" || { echo "devlead-session: failed to migrate $LEGACY_SESSION_FILE -> $SESSION_FILE" >&2; exit 1; }
  echo "devlead-session: migrated $LEGACY_SESSION_FILE -> $SESSION_FILE (session registry renamed)" >&2
}

_cmd="${1:-check}"
_root="$(_repo_root)"

case "$_cmd" in
  on)
    _validate_root
    mkdir -p "$(dirname "$SESSION_FILE")" || { echo "devlead-session: cannot create $(dirname "$SESSION_FILE")" >&2; exit 1; }
    _acquire_lock
    _migrate_registry
    touch "$SESSION_FILE" || { echo "devlead-session: cannot write $SESSION_FILE" >&2; exit 1; }
    _tmp="$(mktemp "${SESSION_FILE}.XXXXXX")" || { echo "devlead-session: mktemp failed for $SESSION_FILE" >&2; exit 1; }
    if ! { _drop_root < "$SESSION_FILE"; printf '%s\t%s\n' "$_root" "$(date -u +%s)"; } > "$_tmp"; then
      echo "devlead-session: failed writing $_tmp" >&2
      rm -f "$_tmp"
      exit 1
    fi
    if ! mv "$_tmp" "$SESSION_FILE"; then
      echo "devlead-session: failed to replace $SESSION_FILE" >&2
      rm -f "$_tmp"
      exit 1
    fi
    echo "DevLead activo en: $_root"
    ;;
  off)
    _validate_root
    if [[ -f "$SESSION_FILE" || -f "$LEGACY_SESSION_FILE" ]]; then
      _acquire_lock
      _migrate_registry
      if [[ -f "$SESSION_FILE" ]]; then
        _tmp="$(mktemp "${SESSION_FILE}.XXXXXX")" || { echo "devlead-session: mktemp failed for $SESSION_FILE" >&2; exit 1; }
        if ! _drop_root < "$SESSION_FILE" > "$_tmp"; then
          echo "devlead-session: failed writing $_tmp" >&2
          rm -f "$_tmp"
          exit 1
        fi
        if ! mv "$_tmp" "$SESSION_FILE"; then
          echo "devlead-session: failed to replace $SESSION_FILE" >&2
          rm -f "$_tmp"
          exit 1
        fi
      fi
    fi
    echo "DevLead inactivo en: $_root"
    ;;
  check)
    # Accepted TOCTOU: these two -f probes are not atomic with an on/off
    # migration running concurrently under _acquire_lock. On a legacy-only
    # machine, a migration mv landing exactly between the two probes can
    # make both `-f` tests miss (SESSION_FILE not there yet when probed,
    # LEGACY_SESSION_FILE already gone by the time we fall back to it) — this
    # can happen at most once per machine, the first time on/off and check
    # race each other post-rename. Direction is fail-closed: the lost race
    # yields INERT for this one call, never a false ACTIVE, and the very
    # next invocation reads SESSION_FILE correctly since the mv already
    # landed. This is accepted by design — check stays deliberately
    # lock-free (it runs on every hook invocation; taking the flock here
    # would add real contention for a one-turn, self-healing blip). Do not
    # "fix" this into reading stale data or taking the lock.
    _read="$SESSION_FILE"
    [[ -f "$_read" ]] || _read="$LEGACY_SESSION_FILE"
    [[ -f "$_read" ]] || exit 1
    _max=$(( $(_resolve_ttl_hours) * 3600 ))
    _now="$(date -u +%s)"
    while IFS=$'\t' read -r _p _ts || [[ -n "$_p" ]]; do
      [[ "$_p" == "$_root" ]] || continue
      # ^[1-9][0-9]*$ (not ^[0-9]+$): a leading-zero value like "09" would
      # pass a plain digit regex but then blow up the arithmetic below —
      # bash's $(( )) treats a leading-0 numeral as octal, and "09" is not
      # valid octal, which aborts the script instead of yielding INERT.
      [[ "$_ts" =~ ^[1-9][0-9]*$ ]] || continue
      _age=$(( _now - _ts ))
      (( _age < 0 )) && continue
      (( _age >= _max )) && continue
      exit 0
    done < "$_read"
    exit 1
    ;;
  *)
    echo "uso: devlead-session.sh {on|off|check}" >&2
    exit 2
    ;;
esac
