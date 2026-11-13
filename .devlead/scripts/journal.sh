#!/usr/bin/env bash
# journal.sh — the per-repo journal, kept as a history instead of one page.
#
# Usage:
#   journal.sh path            print the path of the current entry
#   journal.sh save            replace the current entry with stdin, archiving
#                              the previous one first
#   journal.sh history [N]     print the last N archived entries (default 5)
#
# Why this exists: /cerremos used to overwrite the journal every day, so the
# *why* of anything older than yesterday was gone. The current entry stays
# where /arranquemos has always read it; what changes is that closing a day
# moves the previous entry into <key>.history.md instead of destroying it.
#
# The journal holds the *why* only. It is never a source for technical state
# (that is state.sh, A2) and nothing in the pipeline reads it for authority.
#
# Exit codes: 0 ok · 1 misuse, empty entry, or a write that failed (in which
# case the current entry is left exactly as it was).
#
# Environment:
#   DEVLEAD_JOURNAL_DIR   directory holding the journals (default:
#                         ~/.devlead/journals). Tests point it at a sandbox.

set -uo pipefail

JOURNAL_DIR="${DEVLEAD_JOURNAL_DIR:-$HOME/.devlead/journals}"
ENTRY_HEADER='# DevLead Journal — '

_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Same key the commands have always derived, so existing journals keep working.
_key="${_root//\//_}"
CURRENT="$JOURNAL_DIR/${_key}.md"
HISTORY="$JOURNAL_DIR/${_key}.history.md"

_save() {
  local entry tmp
  entry="$(cat)"
  if [[ -z "${entry//[[:space:]]/}" ]]; then
    echo "journal: empty entry on stdin — nothing saved" >&2
    return 1
  fi
  if ! mkdir -p "$JOURNAL_DIR" 2>/dev/null; then
    echo "journal: cannot create $JOURNAL_DIR" >&2
    return 1
  fi
  # Archive first: if anything below fails, the previous entry exists in at
  # least one of the two files.
  if [[ -s "$CURRENT" ]] && grep -q '[^[:space:]]' "$CURRENT"; then
    if ! cat "$CURRENT" >> "$HISTORY" 2>/dev/null || ! printf '\n' >> "$HISTORY" 2>/dev/null; then
      echo "journal: cannot archive the previous entry to $HISTORY — nothing saved" >&2
      return 1
    fi
  fi
  if ! tmp="$(mktemp "$JOURNAL_DIR/.journal.XXXXXX")"; then
    echo "journal: cannot create a temp file in $JOURNAL_DIR — nothing saved" >&2
    return 1
  fi
  if ! printf '%s\n' "$entry" > "$tmp" || ! mv -f "$tmp" "$CURRENT"; then
    rm -f "$tmp"
    echo "journal: cannot write $CURRENT" >&2
    return 1
  fi
  echo "STATUS: saved"
  echo "PATH: $CURRENT"
}

_history() {
  local n="${1:-5}"
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "journal: history takes a positive number of entries" >&2
    return 1
  fi
  if [[ ! -s "$HISTORY" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  local total
  total="$(grep -c "^$ENTRY_HEADER" "$HISTORY")"
  echo "STATUS: ok"
  echo "ENTRIES: $total"
  # An entry runs from its header line to the next header.
  awk -v hdr="$ENTRY_HEADER" -v from="$(( total - n ))" '
    index($0, hdr) == 1 { seen++ }
    seen > from && seen > 0 { print }
  ' "$HISTORY"
}

case "${1:-}" in
  path)    echo "$CURRENT" ;;
  save)    _save ;;
  history) shift; _history "$@" ;;
  *)
    echo "Usage: journal.sh path | save (entry on stdin) | history [N]" >&2
    exit 1 ;;
esac
