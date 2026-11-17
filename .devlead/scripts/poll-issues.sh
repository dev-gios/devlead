#!/usr/bin/env bash
# poll-issues.sh — new eligible work, found from bash; a claude session only
# when there is some (S4, S16). The DevLead server runs it every 30 minutes
# from 07:00 (docker/run-job.sh, job `poll`).
#
# Usage: poll-issues.sh
#
# For each repo of ~/.devlead/autonomous-repos, in order:
#   1. envelope.sh check: enrolled and enabled, or the repo is skipped;
#   2. envelope-auth.sh plan: the issues the envelope's policy makes
#      eligible. Who may hand DevLead an issue (assigned to the user, or the
#      intake label applied by an allowlisted login — S5) and the
#      untrusted-content scan (S6) are applied there, never here. Eligible
#      means the INCLUDED rows and the EXCLUDED rows whose reason is
#      budget-cut (beyond the window of budget.max_issues), in the plan's
#      order, oldest first. Only the issue numbers are read; a title is the
#      issue's own text and never leaves the plan;
#   3. minus every issue the poll has already seen (the seen record): new
#      means never seen, not "newly inside the max_issues window";
#   4. through agenda.sh apply: what the user skipped today stays out, in the
#      order the user asked;
#   5. at most budget.max_issues of them (S17); the rest stay unseen, for
#      the next poll.
# The first repo with something left gets ONE run, for those issues only:
#   sweep-loop.sh --repo <repo> --max-iterations 1 -- '#N' ...
# (the same launcher as the nightly runs: permission flags, drift guard, the
# claude wrapper's limits). The issues are recorded as seen before the run
# starts, so a run that fails is not started again every 30 minutes; the
# nightly fleet run still takes them, from the plan. The next repo with new
# work gets the next poll.
#
# Nothing new anywhere: nothing is started, no claude session counts, exit 0.
#
# The first time a repo is polled every eligible issue is recorded as seen
# without starting anything: the backlog is the fleet run's, the poll reacts
# to what arrives after. An issue skipped today is not recorded, so a later
# poll takes it once the skip is over.
#
# The seen record, shared with the host's ~/.devlead (S14):
#   ~/.devlead/run-state/poll-seen.tsv
#   <repo path> TAB <issue number, or - for "this repo was polled"> TAB <utc time>
# Appended only; never written through a symbolic link. Reading what was
# seen, choosing the new issues and recording them happen under one
# exclusive flock on the file itself (waiting up to LOCK_WAIT_SECS), so two
# polls never hand the same issue to two runs.
#
# Exit codes: 0 nothing to start, or the run's own exit code; 1 the seen
# record is a link or cannot be written (nothing started); 2 misuse.
set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVELOPE_BIN="$_dir/envelope.sh"
ENVELOPE_AUTH_BIN="$_dir/envelope-auth.sh"
AGENDA_BIN="$_dir/agenda.sh"
LOOP_BIN="$_dir/sweep-loop.sh"
REPOS_FILE="$HOME/.devlead/autonomous-repos"
SEEN="$HOME/.devlead/run-state/poll-seen.tsv"
LOCK_WAIT_SECS=30

if [[ $# -gt 0 ]]; then
  echo "usage: poll-issues.sh" >&2
  exit 2
fi

# _no_links <path>... — never write through a symbolic link in the state
# (A3): a link a session planted would send this write somewhere else.
_no_links() {
  local p
  for p in "$@"; do
    if [[ -L "$p" ]]; then
      echo "poll: $p is a symbolic link — DevLead does not write through links in its state; nothing started" >&2
      return 1
    fi
  done
}

# _lock / _unlock — the seen record's lock, held while a repo's seen issues
# are read, compared and recorded. _LOCK_FD is also the append descriptor.
_LOCK_FD=""
_lock() {
  _no_links "${SEEN%/*}" "$SEEN" || return 1
  mkdir -p "${SEEN%/*}" 2>/dev/null || return 1
  { exec {_LOCK_FD}>>"$SEEN"; } 2>/dev/null || return 1
  if command -v flock >/dev/null 2>&1 && ! flock -w "$LOCK_WAIT_SECS" "$_LOCK_FD"; then
    echo "poll: another DevLead process kept $SEEN locked for ${LOCK_WAIT_SECS}s" >&2
    _unlock
    return 1
  fi
}
_unlock() { [[ -n "$_LOCK_FD" ]] && exec {_LOCK_FD}>&-; _LOCK_FD=""; }

# _record <repo> <number|->... — append to the seen record; the lock is held.
_record() {
  local repo="$1" n now
  shift
  now="$(date -u +%FT%TZ)"
  for n in "$@"; do
    printf '%s\t%s\t%s\n' "$repo" "$n" "$now" >&"$_LOCK_FD" || return 1
  done
}

# _seen <repo> <number|-> — the record has that line.
_seen() {
  [[ -f "$SEEN" ]] || return 1
  awk -F'\t' -v r="$1" -v n="$2" '$1 == r && $2 == n { found = 1 } END { exit !found }' "$SEEN"
}

# _eligible <plan output> — the INCLUDED issue numbers in queue order, then
# the budget-cut ones in the order plan lists them. A budget-cut row counts
# only when that reason ENDS the line: plan writes it last, after the title,
# so a title cannot imitate it.
_eligible() {
  awk '
    /^--- INCLUDED/ { sec = "in"; next }
    /^--- EXCLUDED/ { sec = "ex"; next }
    /^--- / || /^=== END PLAN/ { sec = "" }
    sec == "in" && match($0, /^[0-9]+\. #[0-9]+  /) {
      s = substr($0, 1, RLENGTH - 2); sub(/^[0-9]+\. #/, "", s); print s
    }
    sec == "ex" && $0 ~ /   reason: budget-cut \(beyond max_issues=[0-9]+\)[[:space:]]*$/ && match($0, /^#[0-9]+  /) {
      print substr($0, 2, RLENGTH - 3)
    }' <<<"$1"
}
# _max_issues <plan output> — budget.max_issues, from plan's own header.
_max_issues() { sed -nE 's/^ORDER: .*  MAX_ISSUES: ([1-9][0-9]{0,3})  .*/\1/p' <<<"$1" | head -n 1; }

if [[ ! -f "$REPOS_FILE" ]]; then
  echo "poll: no repos enrolled ($REPOS_FILE missing) — nothing to poll"
  exit 0
fi
_no_links "${SEEN%/*}" "$SEEN" || exit 1

target=""
todo=()
while IFS= read -r repo; do
  repo="${repo%$'\r'}"
  [[ -n "${repo//[[:space:]]/}" && "$repo" != \#* ]] || continue
  if [[ "$repo" != /* ]] || ! cd "$repo" 2>/dev/null; then
    echo "poll: $repo: cannot enter it — skipped"
    continue
  fi
  check="$(bash "$ENVELOPE_BIN" check </dev/null 2>/dev/null)"
  if ! grep -qx 'ENROLLED: true' <<<"$check" || ! grep -qx 'ENABLED: true' <<<"$check"; then
    echo "poll: $repo: not enrolled, or its envelope is disabled — skipped"
    continue
  fi
  plan="$(bash "$ENVELOPE_AUTH_BIN" plan </dev/null 2>/dev/null)"
  if ! grep -q '^=== DEVLEAD ENVELOPE PLAN' <<<"$plan"; then
    echo "poll: $repo: no plan ($(grep -m1 '^STATUS:' <<<"$plan" || echo 'no output')) — skipped"
    continue
  fi
  max="$(_max_issues "$plan")"
  if [[ -z "$max" ]]; then
    echo "poll: $repo: the plan does not say its max_issues — skipped"
    continue
  fi
  mapfile -t eligible < <(_eligible "$plan")
  # Read, compare and record under one lock: a poll running meanwhile sees
  # what this one took.
  _lock || { echo "poll: cannot use $SEEN — nothing started" >&2; exit 1; }
  if ! _seen "$repo" -; then
    _record "$repo" - "${eligible[@]}" || { _unlock; echo "poll: cannot write $SEEN — nothing started" >&2; exit 1; }
    _unlock
    echo "poll: $repo: first poll — ${#eligible[@]} eligible issue(s) recorded as seen; the backlog is the fleet run's"
    continue
  fi
  new=()
  for n in "${eligible[@]}"; do _seen "$repo" "$n" || new+=("$n"); done
  if [[ ${#new[@]} -eq 0 ]]; then
    _unlock
    echo "poll: $repo: nothing new"
    continue
  fi
  applied="$(printf '%s\n' "${new[@]}" | bash "$AGENDA_BIN" apply 2>/dev/null)"
  if [[ $? -ne 0 ]] || ! grep -q '^QUEUE:' <<<"$applied"; then
    _unlock
    echo "poll: $repo: ${#new[@]} new issue(s), but today's agenda cannot be applied — not started this time"
    continue
  fi
  mapfile -t todo < <(sed -n 's/^QUEUE:[[:space:]]*//p' <<<"$applied" | head -n 1 | grep -oE '[0-9]+' | head -n "$max")
  if [[ ${#todo[@]} -eq 0 ]]; then
    _unlock
    echo "poll: $repo: ${#new[@]} new issue(s), all skipped today in the agenda"
    continue
  fi
  _record "$repo" "${todo[@]}" || { _unlock; echo "poll: cannot write $SEEN — nothing started" >&2; exit 1; }
  _unlock
  target="$repo"
  break
done < "$REPOS_FILE"

if [[ -z "$target" ]]; then
  echo "poll: nothing new — no claude session started"
  exit 0
fi

args=()
for n in "${todo[@]}"; do args+=("#$n"); done
echo "poll: $target: new issue(s) ${args[*]} — starting one run (at most $max, budget.max_issues)"
exec bash "$LOOP_BIN" --repo "$target" --max-iterations 1 -- "${args[@]}"
