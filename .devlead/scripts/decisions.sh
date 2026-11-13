#!/usr/bin/env bash
# decisions.sh — what DevLead decided on its own, and what the user said about it.
#
# Usage:
#   decisions.sh record <task> <what> <why>   one decision taken without asking
#   decisions.sh list [--new]                 the log; --new: not shown to the user yet
#   decisions.sh shown                        mark everything new as shown
#   decisions.sh correct <id> <what the user wanted instead>
#   decisions.sh corrections                  corrections not yet turned into profile entries
#   decisions.sh digested                     mark those corrections as processed
#
# DevLead starts and carries out work without asking (GOVERNANCE.md §A1). The
# other half of that deal is that nothing it decides for the user stays
# unsaid: every choice of task, of approach, or of how to read an unclear spec
# is recorded here with its reason, shown to the user, and open to correction.
# A correction is the best signal there is about how the user decides, so it
# is what feeds the profile (profile.sh) next.
#
# This is a record. It grants nothing and blocks nothing: the doors, the
# envelope, the gates and guard.sh never read it.
#
# Kept per repository: a decision about one project is not shown in another.
#
# State (local only):
#   ~/.devlead/decisions/<repo-key>/log.tsv
#       <id> TAB <when> TAB <new|shown> TAB <task> TAB <what> TAB <why> TAB <correction> TAB <-|pending|digested>
#   ~/.devlead/decisions/<repo-key>/repo     the repository path the key stands for
#
# Environment:
#   DEVLEAD_DECISIONS_DIR    state root (default ~/.devlead/decisions)
#   DEVLEAD_DECISIONS_NOW    timestamp, "YYYY-MM-DD HH:MM" (tests)
#   DEVLEAD_DECISIONS_MAX_ROWS  rows kept per repository (default 500)
#
# Exit codes: 0 ok · 1 misuse, an unknown id, or a local write that failed.

# shellcheck disable=SC2016 # awk programs are single-quoted on purpose
set -uo pipefail

DECISIONS_ROOT="${DEVLEAD_DECISIONS_DIR:-$HOME/.devlead/decisions}"
NOW="${DEVLEAD_DECISIONS_NOW:-$(date '+%F %H:%M')}"
FIELD_MAX_CHARS=300
LIST_ROWS=40               # how many of the latest decisions a plain `list` prints
LOG_MAX_ROWS="${DEVLEAD_DECISIONS_MAX_ROWS:-500}"

_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$_root" ]]; then
  echo "STATUS: not-a-repo"
  exit 0
fi
# Same key the other per-repository state uses: a hash, so no two paths collide.
_key="$(printf '%s' "$_root" | sha256sum | cut -c1-20)"
STATE_DIR="$DECISIONS_ROOT/$_key"
LOG="$STATE_DIR/log.tsv"

# _flat <text> — one line, no tabs, bounded.
_flat() {
  local t
  t="$(printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  printf '%s' "${t:0:$FIELD_MAX_CHARS}"
}

_ensure_state() {
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "decisions: cannot create $STATE_DIR" >&2
    return 1
  fi
  [[ -f "$STATE_DIR/repo" ]] || printf '%s\n' "$_root" > "$STATE_DIR/repo" 2>/dev/null
  touch "$LOG" 2>/dev/null || { echo "decisions: cannot write $LOG" >&2; return 1; }
}

# _rewrite <awk program> [awk -v assignments...]
_rewrite() {
  local prog="$1" tmp
  shift
  local -a vars=()
  local v
  for v in "$@"; do vars+=(-v "$v"); done
  tmp="$(mktemp "$STATE_DIR/.decisions.XXXXXX")" || { echo "decisions: cannot create a temp file" >&2; return 1; }
  if ! awk -F'\t' -v OFS='\t' ${vars[@]+"${vars[@]}"} "$prog" "$LOG" > "$tmp" || ! mv -f "$tmp" "$LOG"; then
    rm -f "$tmp"
    echo "decisions: cannot rewrite $LOG" >&2
    return 1
  fi
}

_record() {
  local task what why
  task="$(_flat "${1:-}")"; what="$(_flat "${2:-}")"; why="$(_flat "${3:-}")"
  if [[ -z "$task" || -z "$what" || -z "$why" ]]; then
    echo "Usage: decisions.sh record <task> <what> <why>   (a decision without its reason is not recorded)" >&2
    return 1
  fi
  _ensure_state || return 1
  local n id
  n="$(awk -F'\t' '{ sub(/^d/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 1 }' "$LOG")"
  id="d$n"
  printf '%s\t%s\tnew\t%s\t%s\t%s\t\t-\n' "$id" "$NOW" "$task" "$what" "$why" >> "$LOG" \
    || { echo "decisions: cannot write $LOG" >&2; return 1; }
  # Bounded: the oldest rows fall off, but never one the user has not seen or
  # a correction the profile has not read.
  local total
  total="$(wc -l < "$LOG")"
  if [[ "$total" -gt "$LOG_MAX_ROWS" ]]; then
    _rewrite 'NR > total - max || $3 == "new" || $8 == "pending"' "total=$total" "max=$LOG_MAX_ROWS" || true
  fi
  echo "STATUS: recorded"
  echo "ID: $id"
}

_print_rows() {
  awk -F'\t' '{
    printf "[%s] %s · %s\n    decided: %s\n    because: %s\n", $1, $2, $4, $5, $6
    if ($7 != "") printf "    you said: %s\n", $7
  }'
}

_list() {
  _ensure_state || return 1
  local rows
  case "${1:-}" in
    --new) rows="$(awk -F'\t' '$3 == "new"' "$LOG")" ;;
    "")    rows="$(tail -n "$LIST_ROWS" "$LOG")" ;;
    *)     echo "Usage: decisions.sh list [--new]" >&2; return 1 ;;
  esac
  if [[ -z "$rows" ]]; then
    echo "STATUS: none"
    return 0
  fi
  echo "STATUS: ok"
  echo "COUNT: $(wc -l <<<"$rows")"
  _print_rows <<<"$rows"
}

_shown() {
  _ensure_state || return 1
  local n
  n="$(awk -F'\t' '$3 == "new"' "$LOG" | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    echo "STATUS: none"
    return 0
  fi
  _rewrite '$3 == "new" { $3 = "shown" } { print }' || return 1
  echo "STATUS: shown"
  echo "COUNT: $n"
}

_correct() {
  local id="${1:-}" text
  text="$(_flat "${2:-}")"
  if ! [[ "$id" =~ ^d[0-9]+$ ]] || [[ -z "$text" ]]; then
    echo "Usage: decisions.sh correct <id> <what the user wanted instead>   (an id looks like d3)" >&2
    return 1
  fi
  _ensure_state || return 1
  if ! awk -F'\t' -v id="$id" '$1 == id { found = 1 } END { exit !found }' "$LOG"; then
    echo "STATUS: not-found"
    return 1
  fi
  # The user saw it: that is how they could correct it.
  # The text travels through the environment, not `awk -v`: -v expands
  # backslash escapes, and a typed "\t" would become a real tab and forge a
  # column.
  CORRECTION_TEXT="$text" _rewrite '$1 == id { $3 = "shown"; $7 = ENVIRON["CORRECTION_TEXT"]; $8 = "pending" } { print }' "id=$id" || return 1
  echo "STATUS: corrected"
  echo "ID: $id"
}

_corrections() {
  _ensure_state || return 1
  local rows
  rows="$(awk -F'\t' '$8 == "pending"' "$LOG")"
  if [[ -z "$rows" ]]; then
    echo "STATUS: none"
    return 0
  fi
  echo "STATUS: pending"
  echo "COUNT: $(wc -l <<<"$rows")"
  _print_rows <<<"$rows"
}

_digested() {
  _ensure_state || return 1
  local n
  n="$(awk -F'\t' '$8 == "pending"' "$LOG" | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    echo "STATUS: none"
    return 0
  fi
  _rewrite '$8 == "pending" { $8 = "digested" } { print }' || return 1
  echo "STATUS: digested"
  echo "COUNT: $n"
}

case "${1:-}" in
  record)      shift; _record "$@" ;;
  list)        _list "${2:-}" ;;
  shown)       _shown ;;
  correct)     shift; _correct "$@" ;;
  corrections) _corrections ;;
  digested)    _digested ;;
  *)
    echo "Usage: decisions.sh record <task> <what> <why> | list [--new] | shown | correct <id> <text> | corrections | digested" >&2
    exit 1
    ;;
esac
