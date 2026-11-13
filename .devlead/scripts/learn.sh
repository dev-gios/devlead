#!/usr/bin/env bash
# learn.sh — what DevLead learns from how the human reviews its work.
#
# Usage:
#   learn.sh capture                  store the user's own PR comments (new ones)
#   learn.sh pending                  captured feedback not yet turned into preferences
#   learn.sh digested                 mark everything pending as processed
#   learn.sh pref-add <source> <text> record a preference; it is active at once
#   learn.sh pref-list                active preferences, then the removed ones
#   learn.sh pref-new                 active preferences the user has not been shown
#   learn.sh pref-shown               mark those as shown
#   learn.sh pref-remove <id>         deactivate a preference (kept, so it is not re-learned)
#   learn.sh outcomes                 summary of the last measured PR outcomes
#   learn.sh trust                    whether the measured record is steady enough
#                                     to be worth the user's attention
#
# The loop this supports: the user comments on a PR -> `capture` stores the
# comment -> /arranquemos reads `pending`, writes each lesson with `pref-add`
# and shows it -> every later run reads `pref-list` and follows it. The user
# removes whatever does not fit; nothing waits for an approval.
#
# What a preference is NOT: authority. It is one line of working style handed
# to the implementation stages. open-pr.sh, merge.sh, envelope.sh, the gates
# and the forbidden zones never read this script or its files, so no sentence
# stored here can open a PR, merge, or move a limit (A3). A test pins that.
#
# Whose words count: only comments written by the account `gh` is logged in
# as. Text from any other account is dropped at capture, so a stranger's PR
# comment can never become an instruction to an unattended run.
#
# State (local only, nothing leaves the machine):
#   ~/.devlead/learn/<repo-key>/feedback.tsv
#       <id> TAB <created> TAB <kind> TAB <url> TAB <path> TAB <new|digested> TAB <body>
#   ~/.devlead/learn/<repo-key>/prefs.tsv
#       <id> TAB <added> TAB <active|removed> TAB <unseen|seen> TAB <source> TAB <text>
#   ~/.devlead/learn/<repo-key>/repo      the repository path the key stands for
#
# Exit codes: 0 ok (including "nothing new" and a failed `gh`, reported as a
# STATUS line) · 1 misuse or a local write that failed.
#
# Environment:
#   DEVLEAD_LEARN_DIR      state root (default: ~/.devlead/learn)
#   DEVLEAD_OUTCOMES_DIR   where sweep.sh keeps outcomes (default: ~/.devlead/outcomes)

# shellcheck disable=SC2016 # awk programs are single-quoted on purpose
set -uo pipefail

LEARN_ROOT="${DEVLEAD_LEARN_DIR:-$HOME/.devlead/learn}"
OUTCOMES_DIR="${DEVLEAD_OUTCOMES_DIR:-$HOME/.devlead/outcomes}"
BODY_MAX_CHARS=2000
PREF_MAX_CHARS=300
CAPTURE_PAGE=100
CAPTURE_PR_LIMIT=30
# `trust` calls the record steady only after this many measured runs in a
# row with nothing rejected, and at least this many merged PRs.
TRUST_MIN_RUNS=5
TRUST_MIN_MERGED=10

_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$_root" ]]; then
  echo "STATUS: not-a-repo"
  exit 0
fi
# Same key sweep.sh uses for outcomes: a hash, so no two paths can collide.
_key="$(printf '%s' "$_root" | sha256sum | cut -c1-20)"
STATE_DIR="$LEARN_ROOT/$_key"
FEEDBACK="$STATE_DIR/feedback.tsv"
PREFS="$STATE_DIR/prefs.tsv"

# _flat <text> — one line, no tabs: both files are line- and tab-delimited.
_flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//'; }

_ensure_state() {
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "learn: cannot create $STATE_DIR" >&2
    return 1
  fi
  [[ -f "$STATE_DIR/repo" ]] || printf '%s\n' "$_root" > "$STATE_DIR/repo" 2>/dev/null
  return 0
}

# _rewrite <file> <awk program> [awk -v assignments...] — replace <file> with
# the program's output, through a temp file in the same directory.
_rewrite() {
  local file="$1" prog="$2" tmp
  shift 2
  local -a vars=()
  local v
  for v in "$@"; do vars+=(-v "$v"); done
  if ! tmp="$(mktemp "$STATE_DIR/.learn.XXXXXX")"; then
    echo "learn: cannot create a temp file in $STATE_DIR" >&2
    return 1
  fi
  if ! awk -F'\t' -v OFS='\t' ${vars[@]+"${vars[@]}"} "$prog" "$file" > "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    echo "learn: cannot rewrite $file" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------
_capture() {
  if ! command -v gh &>/dev/null; then
    echo "STATUS: gh-failed"
    echo "REASON: gh not found"
    return 0
  fi
  # GH_REPO / GH_HOST would make `gh` read another repository's comments and
  # file them under this one.
  unset GH_REPO GH_HOST

  local me
  if ! me="$(gh api user -q .login 2>/dev/null)" || [[ ! "$me" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "STATUS: gh-failed"
    echo "REASON: cannot resolve the authenticated user"
    return 0
  fi

  # Three reads, all-or-nothing: a partial capture would mark a PR as seen
  # while its comments were never stored. `$me` is validated above, so it is
  # safe inside the jq expressions.
  local inline issue reviews
  if ! inline="$(gh api "repos/{owner}/{repo}/pulls/comments?sort=created&direction=desc&per_page=$CAPTURE_PAGE" \
        -q ".[] | select(.user.login == \"$me\") | select((.body // \"\") != \"\")
            | [(\"rc-\" + (.id|tostring)), .created_at, \"inline\", .html_url, (if (.path // \"\") == \"\" then \"-\" else .path end), .body] | @tsv" 2>/dev/null)" \
     || ! issue="$(gh api "repos/{owner}/{repo}/issues/comments?sort=created&direction=desc&per_page=$CAPTURE_PAGE" \
        -q ".[] | select(.user.login == \"$me\") | select(.html_url | contains(\"/pull/\")) | select((.body // \"\") != \"\")
            | [(\"ic-\" + (.id|tostring)), .created_at, \"comment\", .html_url, \"-\", .body] | @tsv" 2>/dev/null)" \
     || ! reviews="$(gh pr list --state all --limit "$CAPTURE_PR_LIMIT" --json url,reviews \
        -q ".[] | .url as \$u | .reviews[] | select(.author.login == \"$me\") | select((.body // \"\") != \"\")
            | [(\"rv-\" + (.id|tostring)), .submittedAt, (\"review:\" + .state), \$u, \"-\", .body] | @tsv" 2>/dev/null)"; then
    echo "STATUS: gh-failed"
    echo "REASON: a GitHub read failed — nothing was stored"
    return 0
  fi

  _ensure_state || return 1
  local id created kind url path body added=0 rows=""
  while IFS=$'\t' read -r id created kind url path body; do
    [[ -n "$id" && -n "$body" ]] || continue
    if [[ -f "$FEEDBACK" ]] && grep -q "^${id}"$'\t' "$FEEDBACK"; then continue; fi
    if grep -q "^${id}"$'\t' <<<"$rows"; then continue; fi
    rows+="$(printf '%s\t%s\t%s\t%s\t%s\tnew\t%s' "$id" "$created" "$kind" "$url" "$path" "${body:0:$BODY_MAX_CHARS}")"$'\n'
    added=$((added + 1))
  done <<<"$inline"$'\n'"$issue"$'\n'"$reviews"

  if (( added == 0 )); then
    echo "STATUS: none"
    return 0
  fi
  if ! printf '%s' "$rows" >> "$FEEDBACK"; then
    echo "learn: cannot write $FEEDBACK" >&2
    return 1
  fi
  echo "STATUS: new"
  echo "COUNT: $added"
}

_pending() {
  local n=0
  [[ -f "$FEEDBACK" ]] && n="$(awk -F'\t' '$6 == "new"' "$FEEDBACK" | wc -l | tr -d ' ')"
  if (( n == 0 )); then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: pending"
  echo "COUNT: $n"
  awk -F'\t' '$6 == "new" { printf "[%s] %s  %s  %s\n    %s\n", $1, $3, $4, $5, $7 }' "$FEEDBACK"
}

_digested() {
  if [[ ! -f "$FEEDBACK" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  _rewrite "$FEEDBACK" '{ if ($6 == "new") $6 = "digested"; print }' || return 1
  echo "STATUS: digested"
}

# ---------------------------------------------------------------------------
# preferences
# ---------------------------------------------------------------------------
_pref_add() {
  local source text id existing
  source="$(_flat "${1:-}")"
  text="$(_flat "${2:-}")"
  if [[ -z "$source" || -z "$text" ]]; then
    echo "learn: usage: learn.sh pref-add <source> <text>" >&2
    return 1
  fi
  if (( ${#text} > PREF_MAX_CHARS )); then
    echo "learn: a preference is one line of at most $PREF_MAX_CHARS characters (got ${#text})" >&2
    return 1
  fi
  _ensure_state || return 1
  if [[ -f "$PREFS" ]]; then
    # The text travels through the environment: `awk -v` would interpret
    # backslash escapes in it and never match the row stored literally.
    existing="$(LEARN_TEXT="$text" awk -F'\t' 'tolower($6) == tolower(ENVIRON["LEARN_TEXT"]) { print $1 "\t" $3; exit }' "$PREFS")"
    if [[ -n "$existing" ]]; then
      # Already known. A removed one stays removed: the user took it out.
      echo "STATUS: duplicate"
      echo "ID: ${existing%%$'\t'*}"
      echo "STATE: ${existing##*$'\t'}"
      return 0
    fi
  fi
  # Next id = highest existing + 1 (not a line count: a hand-edited file may
  # lack its final newline, which is also repaired here before appending).
  local last=0
  if [[ -s "$PREFS" ]]; then
    last="$(awk -F'\t' '{ n = substr($1, 2) + 0; if (n > m) m = n } END { print m + 0 }' "$PREFS")"
    [[ -z "$(tail -c 1 "$PREFS")" ]] || printf '\n' >> "$PREFS"
  fi
  id="p$(( last + 1 ))"
  if ! printf '%s\t%s\tactive\tunseen\t%s\t%s\n' "$id" "$(date -u +%FT%TZ)" "$source" "$text" >> "$PREFS"; then
    echo "learn: cannot write $PREFS" >&2
    return 1
  fi
  echo "STATUS: added"
  echo "ID: $id"
}

_pref_list() {
  local active=0 removed=0
  if [[ -f "$PREFS" ]]; then
    active="$(awk -F'\t' '$3 == "active"' "$PREFS" | wc -l | tr -d ' ')"
    removed="$(awk -F'\t' '$3 == "removed"' "$PREFS" | wc -l | tr -d ' ')"
  fi
  if (( active == 0 && removed == 0 )); then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: ok"
  echo "ACTIVE: $active"
  awk -F'\t' '$3 == "active" { printf "[%s] %s  (from %s)\n", $1, $6, $5 }' "$PREFS"
  echo "REMOVED: $removed"
  awk -F'\t' '$3 == "removed" { printf "[%s] %s\n", $1, $6 }' "$PREFS"
}

_pref_new() {
  local n=0
  [[ -f "$PREFS" ]] && n="$(awk -F'\t' '$3 == "active" && $4 == "unseen"' "$PREFS" | wc -l | tr -d ' ')"
  if (( n == 0 )); then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: new"
  echo "COUNT: $n"
  awk -F'\t' '$3 == "active" && $4 == "unseen" { printf "[%s] %s  (from %s)\n", $1, $6, $5 }' "$PREFS"
}

_pref_shown() {
  if [[ ! -f "$PREFS" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  _rewrite "$PREFS" '{ $4 = "seen"; print }' || return 1
  echo "STATUS: shown"
}

_pref_remove() {
  local id="${1:-}"
  if [[ ! "$id" =~ ^p[1-9][0-9]*$ ]]; then
    echo "learn: usage: learn.sh pref-remove <id>   (an id looks like p3)" >&2
    return 1
  fi
  if [[ ! -f "$PREFS" ]] || ! grep -q "^${id}"$'\t' "$PREFS"; then
    echo "learn: no preference with id $id" >&2
    return 1
  fi
  _rewrite "$PREFS" '{ if ($1 == id) $3 = "removed"; print }' "id=$id" || return 1
  echo "STATUS: removed"
  echo "ID: $id"
}

# ---------------------------------------------------------------------------
# outcomes — read-only view of what sweep.sh measured for this repository
# ---------------------------------------------------------------------------
# _field <json line> <key> — value of a top-level number or string field.
_field() { sed -n "s/.*\"$2\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" <<<"$1"; }

_outcomes() {
  local file="$OUTCOMES_DIR/${_key}.jsonl"
  if [[ ! -s "$file" ]]; then
    echo "STATUS: none"
    return 0
  fi
  local runs last prev
  runs="$(wc -l < "$file" | tr -d ' ')"
  last="$(tail -n 1 "$file")"
  echo "STATUS: ok"
  echo "RUNS: $runs"
  echo "LAST_TS: $(_field "$last" ts)"
  echo "MERGED: $(_field "$last" merged)"
  echo "CLOSED_SIN_MERGE: $(_field "$last" closed_sin_merge)"
  echo "CHANGES_REQUESTED: $(_field "$last" changes_requested)"
  echo "PENDING: $(_field "$last" pending)"
  echo "MERGE_RATE: $(_field "$last" merge_rate)"
  echo "OLDEST_PENDING_DAYS: $(_field "$last" oldest_pending_days)"
  if (( runs > 1 )); then
    prev="$(tail -n 2 "$file" | head -n 1)"
    echo "PREV_TS: $(_field "$prev" ts)"
    echo "PREV_CLOSED_SIN_MERGE: $(_field "$prev" closed_sin_merge)"
    echo "PREV_CHANGES_REQUESTED: $(_field "$prev" changes_requested)"
    echo "PREV_MERGE_RATE: $(_field "$prev" merge_rate)"
  fi
}

# trust — a reading of the measured record, for the human. It grants nothing
# and changes nothing: this script cannot reach the limits it talks about,
# and the only thing a `steady` verdict does is let /arranquemos mention that
# the user may want to look at their own settings. Deliberately strict, and
# deliberately blind to anything it cannot measure:
#   - `merged` counts every merged PR, including one that needed changes
#     before it was merged; the record does not keep that history.
#   - a snapshot holds what GitHub showed that morning, not a full history.
_trust() {
  local file="$OUTCOMES_DIR/${_key}.jsonl"
  if [[ ! -s "$file" ]]; then
    echo "STATUS: none"
    return 0
  fi
  local runs last merged closed changes window clean=0 line n
  runs="$(wc -l < "$file" | tr -d ' ')"
  last="$(tail -n 1 "$file")"
  merged="$(_field "$last" merged)"
  closed="$(_field "$last" closed_sin_merge)"
  changes="$(_field "$last" changes_requested)"
  for n in "$merged" "$closed" "$changes"; do
    # Plain decimals only: a leading zero would be read as octal below, and
    # a count that cannot be compared must not fall through to a verdict.
    if [[ ! "$n" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
      echo "STATUS: unreadable"
      return 0
    fi
  done
  # How many of the most recent snapshots show nothing rejected and nothing
  # waiting on requested changes.
  window="$(tail -n "$TRUST_MIN_RUNS" "$file")"
  while IFS= read -r line; do
    [[ "$(_field "$line" closed_sin_merge)" == "0" && "$(_field "$line" changes_requested)" == "0" ]] && clean=$((clean + 1))
  done <<<"$window"

  echo "STATUS: ok"
  echo "RUNS: $runs"
  echo "MERGED: $merged"
  echo "CLOSED_SIN_MERGE: $closed"
  echo "CHANGES_REQUESTED: $changes"
  echo "CLEAN_RECENT_RUNS: $clean of $TRUST_MIN_RUNS"
  if (( runs < TRUST_MIN_RUNS )); then
    echo "VERDICT: not-yet"
    echo "REASON: only $runs measured run(s); $TRUST_MIN_RUNS are needed"
  elif (( merged < TRUST_MIN_MERGED )); then
    echo "VERDICT: not-yet"
    echo "REASON: $merged merged PR(s); $TRUST_MIN_MERGED are needed"
  elif (( clean < TRUST_MIN_RUNS )); then
    echo "VERDICT: not-yet"
    echo "REASON: a PR was closed without merging or had changes requested in the last $TRUST_MIN_RUNS runs"
  else
    echo "VERDICT: steady"
    echo "REASON: $merged merged PR(s), none closed without merging and none with changes requested in the last $TRUST_MIN_RUNS runs"
  fi
  echo "NOTE: a merged PR that needed changes first still counts as merged — the record does not keep that"
}

case "${1:-}" in
  capture)     _capture ;;
  pending)     _pending ;;
  digested)    _digested ;;
  pref-add)    shift; _pref_add "$@" ;;
  pref-list)   _pref_list ;;
  pref-new)    _pref_new ;;
  pref-shown)  _pref_shown ;;
  pref-remove) shift; _pref_remove "$@" ;;
  outcomes)    _outcomes ;;
  trust)       _trust ;;
  *)
    echo "Usage: learn.sh capture | pending | digested | pref-add <source> <text> | pref-list | pref-new | pref-shown | pref-remove <id> | outcomes | trust" >&2
    exit 1 ;;
esac
