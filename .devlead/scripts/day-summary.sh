#!/usr/bin/env bash
# day-summary.sh — the end-of-day summary of the DevLead server (S1, S16,
# S19). The server runs it at 18:30 Monday to Friday (docker/run-job.sh, job
# `endofday`). Plain bash: it starts no claude session.
#
# Usage: day-summary.sh [YYYY-MM-DD]     the day to sum up (default: today)
#
# It reads:
#   - the day's lines of ~/.devlead/audit/YYYY-MM.jsonl (run-job.sh): the
#     runs by outcome, the claude sessions, the PRs opened, the work units
#     parked, the runs that failed;
#   - live state: each enrolled repo's open PRs by the authenticated account,
#     asked of GitHub now (gh pr list, from the repo's clone).
# It prints the summary (the container log), then sends it ONCE at level
# `agenda` (notify.sh, GOVERNANCE.md §escalation-channel): the code carries
# only counts, which is all that leaves the machine by default; the message
# carries the lists — PR links, issue numbers, the failed jobs, the open PRs
# per repo — and reaches the push only with DEVLEAD_NOTIFY_DETAIL=1.
#
# The audit is the user's, so a session could have written into it: every
# value is checked against its shape (a job name, an outcome of the closed
# list, a github.com pull URL, a number) and anything else is left out. No
# issue text is ever read.
#
# What it does not do: the journal. Why something is blocked, what was
# decided, what comes next is written with the user in /cerremos; this job
# only reports what happened.
#
# Exit codes: 0 the summary was built (sending never fails it); 2 misuse.
set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_BIN="$_dir/notify.sh"
AUDIT_DIR="$HOME/.devlead/audit"
REPOS_FILE="$HOME/.devlead/autonomous-repos"
GH_TIMEOUT_SECS=30
MESSAGE_MAX_CHARS=1500

day="$(date +%F)"
if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && ! [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }; then
  echo "usage: day-summary.sh [YYYY-MM-DD]" >&2
  exit 2
fi
[[ $# -eq 1 ]] && day="$1"

# --- The day's runs, from the audit --------------------------------------------
_audit="$AUDIT_DIR/${day:0:7}.jsonl"
_stats='{"runs":0,"outcomes":{},"sessions":0,"prs":[],"parked":0,"issues":[],"failed":[]}'
if [[ -f "$_audit" && ! -L "$_audit" ]]; then
  _stats="$(jq -R -c 'fromjson? | objects' "$_audit" 2>/dev/null | jq -s -c --arg d "$day" '
    [ .[] | select((.started_at | strings | .[0:10]) == $d)
          | select((.trigger | strings | test("^[a-z]{1,20}$"))
                   and (.outcome | strings | IN("ok","failed","timeout","refused","paused","skipped"))) ] as $runs
    | { runs: ($runs | length),
        outcomes: ($runs | group_by(.outcome) | map({ key: .[0].outcome, value: length }) | from_entries),
        sessions: ([ $runs[] | (.session_ids // []) | arrays | length ] | add // 0),
        prs: ([ $runs[] | (.prs_opened // []) | arrays | .[] | strings
                | select(test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]{1,9}$")) ] | unique),
        parked: ([ $runs[] | (.parked.count // 0) | numbers | select(. >= 0 and . == floor) ] | add // 0),
        issues: ([ $runs[] | (.parked.issues // []) | arrays | .[] | numbers | select(. >= 0 and . == floor) ] | unique),
        failed: [ $runs[] | select(.outcome | IN("failed","timeout","refused")) | "\(.trigger) (\(.outcome))" ] }' 2>/dev/null)" \
    || _stats=""
  [[ -n "$_stats" ]] || _stats='{"runs":0,"outcomes":{},"sessions":0,"prs":[],"parked":0,"issues":[],"failed":[]}'
fi
_get() { jq -r "$1" <<<"$_stats"; }
runs="$(_get .runs)"
sessions="$(_get .sessions)"
prs="$(_get '.prs | length')"
parked="$(_get .parked)"
failed="$(_get '.failed | length')"

# --- Live state: what waits for the user now -----------------------------------
_t=()
command -v timeout >/dev/null 2>&1 && _t=(timeout "$GH_TIMEOUT_SECS")
open_lines=()
if [[ -f "$REPOS_FILE" ]]; then
  while IFS= read -r repo; do
    repo="${repo%$'\r'}"
    [[ "$repo" == /* && -d "$repo" ]] || continue
    out="$(cd "$repo" && "${_t[@]}" gh pr list --state open --author @me --json isDraft -q '.[] | .isDraft' </dev/null 2>/dev/null)"
    if [[ $? -ne 0 ]] || grep -qvxE 'true|false' <<<"${out:-true}"; then
      open_lines+=("${repo##*/}: unknown")
    else
      open_lines+=("${repo##*/}: $(grep -c . <<<"$out") open ($(grep -cx true <<<"$out") draft)")
    fi
  done < <(grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$REPOS_FILE")
fi

# --- The summary ----------------------------------------------------------------
code="day $day: $runs run(s), $prs PR(s) opened, $parked parked, $failed failed"
parts=()
[[ "$prs" -gt 0 ]] && parts+=("PRs opened: $(_get '.prs | join(" ")')")
[[ "$parked" -gt 0 ]] && parts+=("parked: $parked$(_get 'if (.issues | length) > 0 then " (" + (.issues | map("#\(.)") | join(" ")) + ")" else "" end') — reasons in ~/.devlead/reports/")
[[ "$failed" -gt 0 ]] && parts+=("failed runs: $(_get '.failed | join(", ")')")
[[ ${#open_lines[@]} -gt 0 ]] && parts+=("open PRs now: $(printf '%s, ' "${open_lines[@]}" | sed 's/, $//')")
parts+=("claude sessions: $sessions")
parts+=("the journal is yours: /cerremos")
message="$(printf '%s | ' "${parts[@]}" | sed 's/ | $//')"
if [[ ${#message} -gt $MESSAGE_MAX_CHARS ]]; then
  message="${message:0:$MESSAGE_MAX_CHARS}…"
fi

echo "DevLead — end of day $day"
echo "runs: $runs ($(_get '.outcomes | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end'))"
echo "claude sessions: $sessions"
echo "PRs opened: $prs"
[[ "$prs" -gt 0 ]] && _get '.prs[] | "  " + .'
echo "parked work units: $parked$(_get 'if (.issues | length) > 0 then " (" + (.issues | map("#\(.)") | join(" ")) + ")" else "" end')"
echo "failed runs: $failed"
[[ "$failed" -gt 0 ]] && _get '.failed[] | "  " + .'
echo "open PRs now:"
if [[ ${#open_lines[@]} -gt 0 ]]; then printf '  %s\n' "${open_lines[@]}"; else echo "  (no enrolled repo)"; fi
echo "The journal — why something is blocked, what was decided, what comes next — is written with you in /cerremos."

if [[ -f "$NOTIFY_BIN" ]]; then
  bash "$NOTIFY_BIN" send agenda "$code" "$message" </dev/null >/dev/null 2>&1 || true
fi
exit 0
