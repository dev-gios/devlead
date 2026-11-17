#!/usr/bin/env bash
# poll-issues.sh — new eligible work, found from bash; a claude session only
# when there is some (S4, S16). The DevLead server runs it every 30 minutes
# from 07:00 (docker/run-job.sh, job `poll`).
#
# Usage: poll-issues.sh
#
# For each repo of ~/.devlead/autonomous-repos, in order:
#   1. envelope.sh check: enrolled and enabled, or the repo is skipped;
#   2. envelope-auth.sh plan: the queue the envelope's policy produces. Who
#      may hand DevLead an issue (assigned to the user, or the intake label
#      applied by an allowlisted login — S5) and the untrusted-content scan
#      (S6) are applied there, never here. Only the INCLUDED issue numbers are
#      read; a title is the issue's own text and never leaves the plan;
#   3. minus the issues the poll already handed to a run (the seen record);
#   4. through agenda.sh apply: what the user skipped today stays out, in the
#      order the user asked.
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
# The first time a repo is polled its current queue is recorded as seen
# without starting anything: the backlog is the fleet run's, the poll reacts
# to what arrives after. An issue skipped today is not recorded, so a later
# poll takes it once the skip is over.
#
# The seen record, shared with the host's ~/.devlead (S14):
#   ~/.devlead/run-state/poll-seen.tsv
#   <repo path> TAB <issue number, or - for "this repo was polled"> TAB <utc time>
# Appended only, under an exclusive flock on the file itself (waiting up to
# LOCK_WAIT_SECS); never written through a symbolic link.
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

# _record <repo> <number|->... — append to the seen record under its lock.
_record() {
  local repo="$1" n now fd
  shift
  _no_links "${SEEN%/*}" "$SEEN" || return 1
  mkdir -p "${SEEN%/*}" 2>/dev/null || return 1
  { exec {fd}>>"$SEEN"; } 2>/dev/null || return 1
  if command -v flock >/dev/null 2>&1 && ! flock -w "$LOCK_WAIT_SECS" "$fd"; then
    echo "poll: another DevLead process kept $SEEN locked for ${LOCK_WAIT_SECS}s" >&2
    exec {fd}>&-
    return 1
  fi
  now="$(date -u +%FT%TZ)"
  for n in "$@"; do
    printf '%s\t%s\t%s\n' "$repo" "$n" "$now" >&"$fd" || { exec {fd}>&-; return 1; }
  done
  exec {fd}>&-
}

# _seen <repo> <number|-> — the record has that line.
_seen() {
  [[ -f "$SEEN" ]] || return 1
  awk -F'\t' -v r="$1" -v n="$2" '$1 == r && $2 == n { found = 1 } END { exit !found }' "$SEEN"
}

# _included <plan output> — the INCLUDED issue numbers, in queue order.
_included() {
  awk '
    /^--- INCLUDED/ { on = 1; next }
    /^--- / || /^=== END PLAN/ { on = 0 }
    on && match($0, /^[0-9]+\. #[0-9]+  /) {
      s = substr($0, 1, RLENGTH - 2); sub(/^[0-9]+\. #/, "", s); print s
    }' <<<"$1"
}

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
  mapfile -t queue < <(_included "$plan")
  if ! _seen "$repo" -; then
    _record "$repo" - "${queue[@]}" || { echo "poll: cannot write $SEEN — nothing started" >&2; exit 1; }
    echo "poll: $repo: first poll — ${#queue[@]} eligible issue(s) recorded as seen; the backlog is the fleet run's"
    continue
  fi
  new=()
  for n in "${queue[@]}"; do _seen "$repo" "$n" || new+=("$n"); done
  if [[ ${#new[@]} -eq 0 ]]; then
    echo "poll: $repo: nothing new"
    continue
  fi
  applied="$(printf '%s\n' "${new[@]}" | bash "$AGENDA_BIN" apply 2>/dev/null)"
  if [[ $? -ne 0 ]] || ! grep -q '^QUEUE:' <<<"$applied"; then
    echo "poll: $repo: ${#new[@]} new issue(s), but today's agenda cannot be applied — not started this time"
    continue
  fi
  mapfile -t todo < <(sed -n 's/^QUEUE:[[:space:]]*//p' <<<"$applied" | head -n 1 | grep -oE '[0-9]+')
  if [[ ${#todo[@]} -eq 0 ]]; then
    echo "poll: $repo: ${#new[@]} new issue(s), all skipped today in the agenda"
    continue
  fi
  target="$repo"
  break
done < "$REPOS_FILE"

if [[ -z "$target" ]]; then
  echo "poll: nothing new — no claude session started"
  exit 0
fi

args=()
for n in "${todo[@]}"; do args+=("#$n"); done
_record "$target" "${todo[@]}" || { echo "poll: cannot write $SEEN — nothing started" >&2; exit 1; }
echo "poll: $target: new issue(s) ${args[*]} — starting one run"
exec bash "$LOOP_BIN" --repo "$target" --max-iterations 1 -- "${args[@]}"
