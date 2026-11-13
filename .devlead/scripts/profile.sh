#!/usr/bin/env bash
# profile.sh — what DevLead knows about how its user writes and decides.
#
# Usage:
#   profile.sh capture                 read the user's own new messages from the
#                                      Claude Code conversations on this machine
#   profile.sh pending [--here] [--limit N]
#                                      captured messages not yet turned into
#                                      profile entries (oldest first)
#   profile.sh digested [--here] <N>   mark the first N of those as processed
#   profile.sh add <kind> <source> <text>
#                                      record one entry; kind is style | decision
#   profile.sh confirm <id>            the entry still holds: restart its clock
#   profile.sh remove <id>             drop an entry (kept, so it is not re-learned)
#   profile.sh list                    every entry with its state
#   profile.sh show                    the active profile, as text for a prompt
#   profile.sh engram                  recent Engram context for this repository
#
# The loop: `capture` collects what the user wrote -> the session reads
# `pending`, writes each pattern it sees with `add`, and marks them `digested`
# -> every later run reads `show` and works that way. The user removes what
# does not fit; nothing waits for an approval.
#
# Two scopes, kept apart on purpose:
#   - this profile is GLOBAL: how the user writes and decides, whatever the
#     project. It is fed from the conversations of every project.
#   - facts about one project (names, technical decisions) are NOT stored
#     here. They go to learn.sh, which is keyed by repository, and never reach
#     another one. `pending --here` lists only this repository's messages for
#     that purpose.
#
# Whose words count: only what the user typed. A conversation file also holds
# tool results, hook output, task notifications, command expansions, pasted
# material and summaries, all under the user role. `capture` keeps a line only
# when Claude Code itself marked it as written by a human, and drops pasted
# blocks from it. Text nobody typed can never become a profile entry.
#
# What an entry is NOT: authority. `add` refuses a sentence that talks about
# merging, limits, gates, credentials or production, in code. The doors, the
# envelope, the gates and guard.sh never read this script or its files.
#
# Small on purpose: the active profile has a hard size cap. When it is full,
# `add` fails and the session has to merge or remove entries first — a profile
# that only grows stops being read. An entry nobody confirmed for
# DEVLEAD_PROFILE_TTL_DAYS (default 90) expires: it stays on file and stops
# being shown.
#
# State (local only, nothing leaves the machine):
#   ~/.devlead/profile/seen.tsv     <conversation file> TAB <bytes already read>
#   ~/.devlead/profile/inbox.tsv    <id> TAB <date> TAB <repo path> TAB <new|digested> TAB <text>
#   ~/.devlead/profile/profile.tsv  <id> TAB <added> TAB <confirmed> TAB <active|removed> TAB <kind> TAB <source> TAB <text>
#
# Environment:
#   DEVLEAD_PROFILE_DIR             state directory (default ~/.devlead/profile)
#   DEVLEAD_TRANSCRIPTS_DIR         conversations (default ~/.claude/projects)
#   DEVLEAD_PROFILE_MAX_CHARS       cap on the active profile's text (default 3000)
#   DEVLEAD_PROFILE_TTL_DAYS        days without confirmation before an entry expires (default 90)
#   DEVLEAD_PROFILE_CAPTURE_BYTES   bytes of conversation read per `capture` (default 200 MB);
#                                   what is left over is read by the next run
#   DEVLEAD_PROFILE_DATE            today's date, YYYY-MM-DD (tests)
#
# Exit codes: 0 ok (including "nothing new") · 1 misuse, a refused entry, a
# full profile, or a local write that failed.

# shellcheck disable=SC2016 # awk and jq programs are single-quoted on purpose
set -uo pipefail

PROFILE_DIR="${DEVLEAD_PROFILE_DIR:-$HOME/.devlead/profile}"
TRANSCRIPTS_DIR="${DEVLEAD_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
MAX_CHARS="${DEVLEAD_PROFILE_MAX_CHARS:-3000}"
TTL_DAYS="${DEVLEAD_PROFILE_TTL_DAYS:-90}"
CAPTURE_BYTES="${DEVLEAD_PROFILE_CAPTURE_BYTES:-209715200}"
TODAY="${DEVLEAD_PROFILE_DATE:-$(date +%F)}"

SEEN="$PROFILE_DIR/seen.tsv"
INBOX="$PROFILE_DIR/inbox.tsv"
PROFILE="$PROFILE_DIR/profile.tsv"

MESSAGE_MAX_CHARS=1500     # one captured message
MESSAGE_MIN_CHARS=20       # shorter than this says nothing about style
ENTRY_MIN_CHARS=10
ENTRY_MAX_CHARS=200
INBOX_MAX_ROWS=3000        # pending backlog; the oldest rows fall off

for _n in "$MAX_CHARS" "$TTL_DAYS" "$CAPTURE_BYTES"; do
  if ! [[ "$_n" =~ ^[1-9][0-9]{0,11}$ ]]; then
    echo "profile: a numeric setting is not a positive integer ('$_n')" >&2
    exit 1
  fi
done

_flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//'; }

_ensure_state() {
  if ! mkdir -p "$PROFILE_DIR" 2>/dev/null; then
    echo "profile: cannot create $PROFILE_DIR" >&2
    return 1
  fi
  touch "$SEEN" "$INBOX" "$PROFILE" 2>/dev/null || { echo "profile: cannot write in $PROFILE_DIR" >&2; return 1; }
}

# _rewrite <file> <awk program> [awk -v assignments...]
_rewrite() {
  local file="$1" prog="$2" tmp
  shift 2
  local -a vars=()
  local v
  for v in "$@"; do vars+=(-v "$v"); done
  if ! tmp="$(mktemp "$PROFILE_DIR/.profile.XXXXXX")"; then
    echo "profile: cannot create a temp file in $PROFILE_DIR" >&2
    return 1
  fi
  if ! awk -F'\t' -v OFS='\t' ${vars[@]+"${vars[@]}"} "$prog" "$file" > "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    echo "profile: cannot rewrite $file" >&2
    return 1
  fi
}

_days_since() {
  local t0 t1
  t0="$(date -d "$1" +%s 2>/dev/null)" || return 1
  t1="$(date -d "$TODAY" +%s 2>/dev/null)" || return 1
  echo $(((t1 - t0) / 86400))
}

_here_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------
# What counts as typed by the user. Claude Code marks every user-role line
# with where it came from; a line without that mark (older versions) is kept
# only when it is plain text that no tool, hook or command produced.
# shellcheck disable=SC2016 # a jq program, not shell
_JQ_HUMAN='
  def text:
    if (.message.content | type) == "string" then .message.content
    elif (.message.content | type) == "array" then
      if any(.message.content[]; .type != "text") then ""
      else [.message.content[] | .text // ""] | join("\n") end
    else "" end;
  def typed:
    if (.origin | type) == "object" then
      (.origin.kind == "human") and ((.promptSource // "typed") | IN("typed", "queued"))
    else
      (text | test("^\\s*(<|\\[|Stop hook|This session is being continued|Caveat:)") | not)
    end;
  fromjson?
  | select(type == "object" and .type == "user")
  | select((.isMeta // false) | not)
  | select((.isSidechain // false) | not)
  | select((.isCompactSummary // false) | not)
  | select(typed)
  # One line first, so a block can be matched across what were line breaks.
  # Then every tagged block goes: pasted material, attached context, reminders.
  # None of it was typed. A message that still opens with a tag is dropped.
  | (text
     | gsub("[\\t\\r\\n]+"; " ")
     | gsub("<(?<tag>[a-z][a-z0-9_-]*)(\\s[^>]*)?>.*?</\\k<tag>(\\s[^>]*)?>"; " ")
     | gsub("  +"; " ") | sub("^ +"; "") | sub(" +$"; "")) as $t
  | select(($t | length) >= $min)
  | select($t | test("^<|<pasted_content|<system-reminder") | not)
  | [(.uuid // "" | .[0:12]), (.timestamp // "" | .[0:10]), (.cwd // ""), "new", ($t | .[0:$max])]
  | select(.[0] != "")
  | @tsv
'

_capture() {
  _ensure_state || return 1
  if ! command -v jq >/dev/null 2>&1; then
    echo "STATUS: unavailable"
    echo "NOTE: jq is not installed"
    return 0
  fi
  if [[ ! -d "$TRANSCRIPTS_DIR" ]]; then
    echo "STATUS: none"
    echo "NOTE: no conversations at $TRANSCRIPTS_DIR"
    return 0
  fi

  local -A seen=()
  local path bytes
  while IFS=$'\t' read -r path bytes; do
    [[ -n "$path" && "$bytes" =~ ^[0-9]+$ ]] && seen["$path"]="$bytes"
  done < "$SEEN"

  local tmp chunk new_rows
  tmp="$(mktemp "$PROFILE_DIR/.capture.XXXXXX")" || { echo "profile: cannot create a temp file" >&2; return 1; }
  chunk="$(mktemp "$PROFILE_DIR/.chunk.XXXXXX")" || { rm -f "$tmp"; echo "profile: cannot create a temp file" >&2; return 1; }
  new_rows="$(mktemp "$PROFILE_DIR/.rows.XXXXXX")" || { rm -f "$tmp" "$chunk"; echo "profile: cannot create a temp file" >&2; return 1; }

  local budget="$CAPTURE_BYTES" files=0 left=0 size prev take f
  # Conversations of the main session only: <project>/<session>.jsonl. Newest
  # first, so a first run over a large history starts with what is current.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    size="$(stat -c %s "$f" 2>/dev/null)" || continue
    prev="${seen[$f]:-0}"
    # A file that shrank was rewritten: read it again from the start.
    [[ "$prev" -gt "$size" ]] && prev=0
    [[ "$size" -gt "$prev" ]] || continue
    if [[ "$budget" -le 0 ]]; then left=$((left + 1)); continue; fi
    take=$((size - prev))
    if [[ "$take" -gt "$budget" ]]; then take="$budget"; budget=0; fi
    tail -c +"$((prev + 1))" "$f" 2>/dev/null | head -c "$take" > "$chunk"
    # Whole lines only: a line still being written is left for the next run.
    if [[ -s "$chunk" && "$(tail -c1 "$chunk" | od -An -c | tr -d ' ')" != '\n' ]]; then
      sed -i '$d' "$chunk"
    fi
    take="$(stat -c %s "$chunk")"
    if [[ "$take" -gt 0 ]]; then
      jq -Rr --argjson min "$MESSAGE_MIN_CHARS" --argjson max "$MESSAGE_MAX_CHARS" "$_JQ_HUMAN" "$chunk" >> "$new_rows" 2>/dev/null || true
      seen["$f"]=$((prev + take))
      budget=$((budget - take))
      files=$((files + 1))
    fi
    # Not read to the end (the budget ran out mid-file): the rest is for the
    # next run. A last line still being written does not count as left over.
    if [[ "$budget" -le 0 && $((prev + take)) -lt "$size" ]]; then left=$((left + 1)); fi
  done < <(find "$TRANSCRIPTS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)

  # Append rows whose id is not already in the inbox.
  local added
  # The inbox is loaded in BEGIN and not with the NR==FNR idiom: with an empty
  # first file that idiom takes the second one for the first.
  added="$(awk -F'\t' -v inbox="$INBOX" '
    BEGIN { while ((getline line < inbox) > 0) { split(line, c, "\t"); have[c[1]] = 1; said[c[5]] = 1 } }
    # The same sentence twice (a retried or re-queued prompt) is one message.
    !($1 in have) && !($5 in said) { have[$1] = 1; said[$5] = 1; print }' "$new_rows" | tee -a "$tmp" | wc -l)"
  if [[ "$added" -gt 0 ]]; then
    cat "$tmp" >> "$INBOX" || { rm -f "$tmp" "$chunk" "$new_rows"; echo "profile: cannot write $INBOX" >&2; return 1; }
    # Keep the backlog bounded: digested rows go first, then the oldest.
    if [[ "$(wc -l < "$INBOX")" -gt "$INBOX_MAX_ROWS" ]]; then
      { awk -F'\t' '$4 == "new"' "$INBOX" | tail -n "$INBOX_MAX_ROWS"; } > "$tmp" && mv -f "$tmp" "$INBOX"
    fi
  fi

  : > "$tmp"
  for path in "${!seen[@]}"; do printf '%s\t%s\n' "$path" "${seen[$path]}" >> "$tmp"; done
  sort "$tmp" > "$chunk" && mv -f "$chunk" "$SEEN"
  rm -f "$tmp" "$chunk" "$new_rows"

  if [[ "$added" -gt 0 ]]; then echo "STATUS: captured"; else echo "STATUS: none"; fi
  echo "NEW: $added"
  echo "FILES_READ: $files"
  [[ "$left" -gt 0 ]] && echo "NOTE: $left conversation file(s) left for the next run (read budget reached)"
  return 0
}

# ---------------------------------------------------------------------------
# pending / digested
# ---------------------------------------------------------------------------
# _select_pending <here-root or ""> — the rows `pending` lists, oldest first.
_select_pending() {
  awk -F'\t' -v here="$1" '
    $4 != "new" { next }
    here != "" && $3 != here && index($3, here "/") != 1 { next }
    { print }' "$INBOX" | sort -t$'\t' -k2,2 -s
}

_parse_scope() {
  _scope_here=""
  _scope_limit=40
  _scope_rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --here)
        _scope_here="$(_here_root)"
        if [[ -z "$_scope_here" ]]; then echo "STATUS: not-a-repo"; return 1; fi
        ;;
      --limit)
        shift
        if ! [[ "${1:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then echo "profile: --limit takes a number from 1 to 9999" >&2; return 1; fi
        _scope_limit="$1"
        ;;
      *) _scope_rest+=("$1") ;;
    esac
    shift
  done
}

_pending() {
  _ensure_state || return 1
  _parse_scope "$@" || return 1
  local rows total
  rows="$(_select_pending "$_scope_here")"
  if [[ -z "$rows" ]]; then
    echo "STATUS: none"
    return 0
  fi
  total="$(wc -l <<<"$rows")"
  echo "STATUS: pending"
  echo "COUNT: $total"
  head -n "$_scope_limit" <<<"$rows" | awk -F'\t' '{ n = split($3, p, "/"); printf "[%s] (%s, %s) %s\n", $1, $2, p[n], $5 }'
}

_digested() {
  _ensure_state || return 1
  _parse_scope "$@" || return 1
  local n="${_scope_rest[0]:-}"
  if ! [[ "$n" =~ ^[1-9][0-9]{0,4}$ ]]; then
    echo "Usage: profile.sh digested [--here] <count>" >&2
    return 1
  fi
  local ids
  ids="$(_select_pending "$_scope_here" | head -n "$n" | cut -f1)"
  if [[ -z "$ids" ]]; then
    echo "STATUS: none"
    return 0
  fi
  local idfile
  idfile="$(mktemp "$PROFILE_DIR/.ids.XXXXXX")" || return 1
  printf '%s\n' "$ids" > "$idfile"
  _rewrite "$INBOX" 'BEGIN { while ((getline line < idf) > 0) mark[line] = 1 } ($1 in mark) && $4 == "new" { $4 = "digested" } { print }' "idf=$idfile" || { rm -f "$idfile"; return 1; }
  rm -f "$idfile"
  echo "STATUS: digested"
  echo "COUNT: $(wc -l <<<"$ids")"
}

# ---------------------------------------------------------------------------
# entries
# ---------------------------------------------------------------------------
# An entry describes how the user works. It must not read as a rule about what
# DevLead may do: that is the envelope's and guard.sh's business (A3,
# §hard-limits), and a profile line must never look like it changes them.
_AUTHORITY_RE='(merge|mergea|envelope|guard\.sh|[^a-z]gates?[^a-z]|secret|[^a-z]tokens?[^a-z]|credencial|credential|password|contrase|producci[oó]n|production|deploy|desplieg|permis|autoriz|authori[sz]|bypass|--no-verify|--force|force[- ]push|sudo|rama por defecto|default branch|[^a-z]main[^a-z]|[^a-z]master[^a-z]|(skip|salte|omit)[a-z]* (a |the |el |la |los |las )?(gate|test|prueba|review|revisi|check))'

# _used_chars — text size of the entries `show` prints.
_used_chars() {
  awk -F'\t' -v today="$TODAY" -v ttl="$TTL_DAYS" '
    function days(d,   cmd, s) { cmd = "date -d \"" d "\" +%s 2>/dev/null"; cmd | getline s; close(cmd); return s }
    BEGIN { now = days(today) }
    $4 == "active" { then = days($3); if (then != "" && (now - then) / 86400 <= ttl) n += length($7) }
    END { print n + 0 }' "$PROFILE"
}

_add() {
  local kind="${1:-}" source text
  source="$(_flat "${2:-}")"
  text="$(_flat "${3:-}")"
  if [[ "$kind" != "style" && "$kind" != "decision" ]] || [[ -z "$source" || -z "$text" ]]; then
    echo "Usage: profile.sh add <style|decision> <source> <text>" >&2
    return 1
  fi
  _ensure_state || return 1
  if [[ ${#text} -lt $ENTRY_MIN_CHARS || ${#text} -gt $ENTRY_MAX_CHARS ]]; then
    echo "STATUS: refused"
    echo "REASON: an entry is one line of $ENTRY_MIN_CHARS to $ENTRY_MAX_CHARS characters (this one has ${#text})"
    return 1
  fi
  if [[ " ${text,,} " =~ $_AUTHORITY_RE ]]; then
    echo "STATUS: refused"
    echo "REASON: the entry talks about what DevLead may do (${BASH_REMATCH[1]}). The profile holds how the user writes and decides; limits live in the envelope and in guard.sh"
    return 1
  fi

  # The same sentence again is a confirmation, not a second entry.
  local dup
  dup="$(awk -F'\t' -v t="${text,,}" 'tolower($7) == t { print $1 "\t" $4; exit }' "$PROFILE")"
  if [[ -n "$dup" ]]; then
    if [[ "${dup#*$'\t'}" == "removed" ]]; then
      echo "STATUS: removed-before"
      echo "ID: ${dup%%$'\t'*}"
      echo "NOTE: the user removed this entry; it is not learned again"
      return 0
    fi
    _rewrite "$PROFILE" '$1 == id { $3 = today } { print }' "id=${dup%%$'\t'*}" "today=$TODAY" || return 1
    echo "STATUS: confirmed"
    echo "ID: ${dup%%$'\t'*}"
    return 0
  fi

  local used
  used="$(_used_chars)"
  if [[ $((used + ${#text})) -gt $MAX_CHARS ]]; then
    echo "STATUS: full"
    echo "USED: $used"
    echo "MAX: $MAX_CHARS"
    echo "NOTE: merge entries that say the same thing or remove one that no longer holds, then add again"
    return 1
  fi

  local n id
  n="$(awk -F'\t' '{ sub(/^p/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 1 }' "$PROFILE")"
  id="p$n"
  printf '%s\t%s\t%s\tactive\t%s\t%s\t%s\n' "$id" "$TODAY" "$TODAY" "$kind" "$source" "$text" >> "$PROFILE" \
    || { echo "profile: cannot write $PROFILE" >&2; return 1; }
  echo "STATUS: added"
  echo "ID: $id"
  echo "USED: $((used + ${#text}))"
  echo "MAX: $MAX_CHARS"
}

_set_entry() {   # <verb> <id>
  local verb="$1" id="${2:-}"
  if ! [[ "$id" =~ ^p[0-9]+$ ]]; then
    echo "Usage: profile.sh $verb <id>   (an id looks like p3)" >&2
    return 1
  fi
  _ensure_state || return 1
  local state
  state="$(awk -F'\t' -v id="$id" '$1 == id { print $4; exit }' "$PROFILE")"
  if [[ -z "$state" ]]; then
    echo "STATUS: not-found"
    return 1
  fi
  if [[ "$verb" == "remove" ]]; then
    _rewrite "$PROFILE" '$1 == id { $4 = "removed" } { print }' "id=$id" || return 1
    echo "STATUS: removed"
  else
    if [[ "$state" != "active" ]]; then
      echo "STATUS: removed-before"
      echo "NOTE: a removed entry stays removed"
      return 1
    fi
    _rewrite "$PROFILE" '$1 == id { $3 = today } { print }' "id=$id" "today=$TODAY" || return 1
    echo "STATUS: confirmed"
  fi
  echo "ID: $id"
}

_list() {
  _ensure_state || return 1
  if [[ ! -s "$PROFILE" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: ok"
  local id added confirmed state kind source text age
  while IFS=$'\t' read -r id added confirmed state kind source text; do
    if [[ "$state" == "active" ]]; then
      age="$(_days_since "$confirmed" || echo 0)"
      [[ "$age" -gt "$TTL_DAYS" ]] && state="expired"
    fi
    printf '%s [%s, %s] %s  (confirmed %s, from %s)\n' "$id" "$state" "$kind" "$text" "$confirmed" "$source"
  done < "$PROFILE"
}

_show() {
  _ensure_state || return 1
  local id added confirmed state kind source text age out_style="" out_decision=""
  while IFS=$'\t' read -r id added confirmed state kind source text; do
    [[ "$state" == "active" ]] || continue
    age="$(_days_since "$confirmed" || echo 0)"
    [[ "$age" -gt "$TTL_DAYS" ]] && continue
    if [[ "$kind" == "style" ]]; then out_style+="- $text"$'\n'; else out_decision+="- $text"$'\n'; fi
  done < "$PROFILE"
  if [[ -z "$out_style$out_decision" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: ok"
  echo "USED: $(_used_chars)/$MAX_CHARS"
  if [[ -n "$out_style" ]]; then echo "HOW THE USER WRITES AND WANTS TO BE ANSWERED:"; printf '%s' "$out_style"; fi
  if [[ -n "$out_decision" ]]; then echo "HOW THE USER DECIDES:"; printf '%s' "$out_decision"; fi
}

# ---------------------------------------------------------------------------
# engram
# ---------------------------------------------------------------------------
# Engram already holds decisions and conventions someone chose to save. This
# is a read: project-scoped (Engram resolves the project from the directory),
# bounded, and with the tool's own update notice taken out.
_engram() {
  if ! command -v engram >/dev/null 2>&1; then
    echo "STATUS: unavailable"
    echo "NOTE: engram is not installed"
    return 0
  fi
  local out
  out="$(timeout 20 engram context 2>/dev/null </dev/null | sed '1,/^$/{/^Update available/d;/^To update/d;/^  brew /d;/^  or: /d}' | head -n 80)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    echo "STATUS: none"
    return 0
  fi
  echo "STATUS: ok"
  printf '%s\n' "$out"
}

case "${1:-}" in
  capture)  _capture ;;
  pending)  shift; _pending "$@" ;;
  digested) shift; _digested "$@" ;;
  add)      shift; _add "$@" ;;
  confirm)  _set_entry confirm "${2:-}" ;;
  remove)   _set_entry remove "${2:-}" ;;
  list)     _list ;;
  show)     _show ;;
  engram)   _engram ;;
  *)
    echo "Usage: profile.sh capture | pending [--here] [--limit N] | digested [--here] <count> | add <style|decision> <source> <text> | confirm <id> | remove <id> | list | show | engram" >&2
    exit 1
    ;;
esac
