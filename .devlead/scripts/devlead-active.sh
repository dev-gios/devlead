#!/usr/bin/env bash
# devlead-active.sh — manages the DevLead opt-in marker.
#
# DevLead is an opt-in mode, NOT an always-on daemon (DEVLEAD.md §2, decision 7).
# The hooks (post-edit.sh, gate-check.sh) are registered globally but stay INERT
# unless the current repo is in the active list. /arranquemos turns it on for the
# day; /cerremos turns it off.
#
# Usage:
#   devlead-active.sh on     → mark the current repo as DevLead-active (dedup)
#   devlead-active.sh off    → unmark the current repo
#   devlead-active.sh check  → exit 0 if active here, exit 1 if not
#
# State lives in ~/.devlead/active-repos (one absolute repo root per line).
# It is local machine state — never committed, never a source of truth on the "qué".

set -uo pipefail

ACTIVE_FILE="$HOME/.devlead/active-repos"

# Resolve the repo root (or $PWD if not in a git repo) so the marker is stable
# regardless of which subdirectory the hook fires from.
_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

_cmd="${1:-check}"
_root="$(_repo_root)"

case "$_cmd" in
  on)
    mkdir -p "$(dirname "$ACTIVE_FILE")"
    touch "$ACTIVE_FILE"
    if ! grep -qxF "$_root" "$ACTIVE_FILE" 2>/dev/null; then
      echo "$_root" >> "$ACTIVE_FILE"
    fi
    echo "DevLead activo en: $_root"
    ;;
  off)
    if [[ -f "$ACTIVE_FILE" ]]; then
      _tmp="$(mktemp)"
      grep -vxF "$_root" "$ACTIVE_FILE" > "$_tmp" 2>/dev/null || true
      mv "$_tmp" "$ACTIVE_FILE"
    fi
    echo "DevLead inactivo en: $_root"
    ;;
  check)
    [[ -f "$ACTIVE_FILE" ]] || exit 1
    grep -qxF "$_root" "$ACTIVE_FILE" 2>/dev/null || exit 1
    exit 0
    ;;
  *)
    echo "uso: devlead-active.sh {on|off|check}" >&2
    exit 2
    ;;
esac
