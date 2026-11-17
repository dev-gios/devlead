#!/usr/bin/env bash
# unit-poll-issues.sh — .devlead/scripts/poll-issues.sh, the DevLead server's
# issue poll (S4, S16): new eligible work found from bash, one run only when
# there is some, the seen record (flock, no links).
#
#   bash test/unit-poll-issues.sh
#
# A copy of poll-issues.sh runs in a sandbox scripts directory. Its siblings:
# envelope.sh and envelope-auth.sh are stubs that print, per repo, the check
# and the plan a test wrote there (the real plan, intake rules and scan are
# tested in unit-envelope-plan.sh and unit-untrusted.sh); agenda.sh is the
# real one; sweep-loop.sh is a stub that logs how it was started.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SANDBOX="$(mktemp -d /tmp/devlead-poll.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

lacks() {
  if [[ "$2" != *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

export HOME="$SANDBOX/home"
export DEVLEAD_AGENDA_DIR="$HOME/.devlead/agenda"
SCRIPTS="$SANDBOX/scripts"
LOG="$SANDBOX/calls.log"
SEEN="$HOME/.devlead/run-state/poll-seen.tsv"
mkdir -p "$SCRIPTS" "$HOME/.devlead/run-state"
cp "$REPO_ROOT/.devlead/scripts/poll-issues.sh" "$REPO_ROOT/.devlead/scripts/agenda.sh" "$SCRIPTS/"
cat > "$SCRIPTS/envelope.sh" <<'EOF'
#!/usr/bin/env bash
echo "envelope.sh $* in $PWD" >> "$LOG"
[[ "${1:-}" == check ]] && cat .stub-check 2>/dev/null
EOF
cat > "$SCRIPTS/envelope-auth.sh" <<'EOF'
#!/usr/bin/env bash
echo "envelope-auth.sh $* in $PWD" >> "$LOG"
[[ -n "${STUB_PLAN_SLEEP:-}" ]] && sleep "$STUB_PLAN_SLEEP"
[[ "${1:-}" == plan ]] && cat .stub-plan 2>/dev/null
EOF
cat > "$SCRIPTS/sweep-loop.sh" <<'EOF'
#!/usr/bin/env bash
printf 'sweep-loop.sh' >> "$LOG"; printf ' [%s]' "$@" >> "$LOG"; printf '\n' >> "$LOG"
exit "${STUB_LOOP_RC:-0}"
EOF
chmod +x "$SCRIPTS"/*.sh
export LOG

# repo <name> — a git repo, enrolled and enabled.
repo() {
  mkdir -p "$SANDBOX/work/$1"
  git -C "$SANDBOX/work/$1" init -q -b main 2>/dev/null
  printf 'ENROLLED: true\nENABLED: true\n' > "$SANDBOX/work/$1/.stub-check"
}
# plan <name> <issue>... — the plan envelope.sh would print, titles included:
# the first PLAN_MAX issues (default 9) INCLUDED, the rest budget-cut.
plan() {
  local name="$1" i=1 n max="${PLAN_MAX:-9}" cut=()
  shift
  {
    echo "=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ==="
    echo "ORDER: priority-label,created-asc  MAX_ISSUES: $max  EXCLUDE_LABELS: blocked  READINESS: true"
    echo ""
    echo "--- INCLUDED (queue order) ---"
    [[ $# -gt 0 ]] || echo "(none)"
    for n in "$@"; do
      if [[ $i -gt $max ]]; then cut+=("$n"); continue; fi
      printf '%d. #%s  Fix #99 and $(touch %s/pwned)\n' "$i" "$n" "$SANDBOX"
      printf '   basis: tier=none, created=2026-11-17, nuevo-entrante\n'
      i=$((i + 1))
    done
    echo ""
    echo "--- EXCLUDED ---"
    echo "#77  something   reason: label-excluded: blocked"
    echo "#78  x   reason: budget-cut (beyond max_issues=3)   reason: label-excluded: blocked"
    for n in "${cut[@]}"; do printf '#%s  later work   reason: budget-cut (beyond max_issues=%s)\n' "$n" "$max"; done
    echo ""
    echo "=== END PLAN ==="
  } > "$SANDBOX/work/$name/.stub-plan"
}
poll() { : > "$LOG"; OUT="$(cd "$SANDBOX" && env "$@" bash "$SCRIPTS/poll-issues.sh" 2>&1)"; RC=$?; }
loops() { grep -c '^sweep-loop.sh' "$LOG"; }
seen_of() { awk -F'\t' -v r="$SANDBOX/work/$1" '$1 == r {print $2}' "$SEEN" 2>/dev/null | paste -sd, -; }

# ===========================================================================
# Nothing enrolled, nothing to do
# ===========================================================================
poll
check "no fleet list: exit 0" "$RC" "0"
contains "no fleet list: says so" "$OUT" "nothing to poll"
check "no fleet list: no run" "$(loops)" "0"

repo a; repo b
printf '%s\n' "$SANDBOX/work/a" "# a comment" "" "$SANDBOX/work/b" > "$HOME/.devlead/autonomous-repos"
plan a 3 5
plan b

# ===========================================================================
# First poll: the backlog is recorded, nothing starts
# ===========================================================================
poll
check "first poll: exit 0" "$RC" "0"
check "first poll: no run, no session" "$(loops)" "0"
check "first poll of a: the repo and its queue are recorded" "$(seen_of a)" "-,3,5"
check "first poll of b: the repo is recorded" "$(seen_of b)" "-"
contains "first poll: says the backlog is the fleet's" "$OUT" "first poll — 2 eligible issue(s) recorded as seen"
contains "the plan comes from envelope-auth.sh plan, in the repo" "$(cat "$LOG")" "envelope-auth.sh plan in $SANDBOX/work/a"
check "the record: path TAB number TAB utc time" \
  "$(awk -F'\t' 'NF == 3 && $3 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$/' "$SEEN" | wc -l | tr -d ' ')" "4"

# ===========================================================================
# Nothing new: nothing starts
# ===========================================================================
poll
check "nothing new: exit 0" "$RC" "0"
check "nothing new: no run" "$(loops)" "0"
contains "nothing new: says no session started" "$OUT" "nothing new — no claude session started"

# ===========================================================================
# New work: one run, for the new issues only
# ===========================================================================
plan a 3 5 8 9
poll
check "new work: one run" "$(loops)" "1"
check "new work: the launcher, scoped to the new issues in queue order" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/a] [--max-iterations] [1] [--] [#8] [#9]"
check "new work: recorded as seen before the run" "$(seen_of a)" "-,3,5,8,9"
check "new work: exit code is the run's" "$RC" "0"
check "a title is never read: no #99, nothing ran from it" "$([[ -e "$SANDBOX/pwned" ]] && echo ran || echo clean)" "clean"
poll
check "the same issues next time: no run" "$(loops)" "0"

# A run that fails is not started again every poll.
plan a 3 5 8 9 10
poll STUB_LOOP_RC=3
check "a failing run: its exit code" "$RC" "3"
poll STUB_LOOP_RC=3
check "a failing run: not started again" "$(loops)" "0"

# ===========================================================================
# Two repos with new work: the first gets this poll, the next one the next
# ===========================================================================
plan a 3 5 8 9 10 11
plan b 20
poll
check "two repos: one run" "$(loops)" "1"
contains "two repos: the first one in the fleet list" "$(grep '^sweep-loop.sh' "$LOG")" "[$SANDBOX/work/a]"
poll
contains "two repos: the next poll takes the second" "$(grep '^sweep-loop.sh' "$LOG")" "[$SANDBOX/work/b] [--max-iterations] [1] [--] [#20]"

# ===========================================================================
# The agenda: what the user skipped today stays out, and is not recorded
# ===========================================================================
plan a 3 5 8 9 10 11 12 13
( cd "$SANDBOX/work/a" && bash "$SCRIPTS/agenda.sh" publish < .stub-plan >/dev/null 2>&1 \
  && bash "$SCRIPTS/agenda.sh" skip 12 >/dev/null 2>&1 && bash "$SCRIPTS/agenda.sh" first 13 >/dev/null 2>&1 )
poll
check "agenda: the skipped issue is left out, the first one leads" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/a] [--max-iterations] [1] [--] [#13]"
check "agenda: the skipped issue is not recorded" "$(seen_of a)" "-,3,5,8,9,10,11,13"
( cd "$SANDBOX/work/a" && bash "$SCRIPTS/agenda.sh" reset >/dev/null 2>&1 )
poll
check "agenda: once the skip is gone, the next poll takes it" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/a] [--max-iterations] [1] [--] [#12]"

# ===========================================================================
# Repos that give no plan are skipped, never guessed
# ===========================================================================
plan a 3 5 8 9 10 11 12 13 14
printf 'ENROLLED: true\nENABLED: false\n' > "$SANDBOX/work/a/.stub-check"
poll
check "disabled envelope: no run" "$(loops)" "0"
contains "disabled envelope: says so" "$OUT" "not enrolled, or its envelope is disabled — skipped"
printf 'ENROLLED: true\nENABLED: true\n' > "$SANDBOX/work/a/.stub-check"
printf 'STATUS: blocked\nGAP:    auth-unavailable\n' > "$SANDBOX/work/a/.stub-plan"
poll
check "blocked plan: no run" "$(loops)" "0"
contains "blocked plan: names the status" "$OUT" "no plan (STATUS: blocked) — skipped"
printf '%s\n' "/nowhere/repo" "relative/repo" >> "$HOME/.devlead/autonomous-repos"
poll
contains "a path that cannot be entered is skipped" "$OUT" "poll: /nowhere/repo: cannot enter it — skipped"
contains "a relative path is skipped" "$OUT" "poll: relative/repo: cannot enter it — skipped"
check "nothing new after all: exit 0" "$RC" "0"

# ===========================================================================
# The seen record: never through a link, written under its lock
# ===========================================================================
plan a 3 5 8 9 10 11 12 13 14
mv "$SEEN" "$SANDBOX/seen.real"
ln -s "$SANDBOX/elsewhere.tsv" "$SEEN"
poll
check "a planted link: refused" "$RC" "1"
check "a planted link: no run" "$(loops)" "0"
check "a planted link: nothing written through it" "$([[ -e "$SANDBOX/elsewhere.tsv" ]] && echo written || echo untouched)" "untouched"
rm -f "$SEEN"; mv "$SANDBOX/seen.real" "$SEEN"
if command -v flock >/dev/null 2>&1; then
  flock "$SEEN" sleep 2 &
  holder=$!
  sleep 0.3
  t0="$(date +%s)"
  poll
  t1="$(date +%s)"
  wait "$holder"
  check "the record is written under its lock: the poll waited for the holder" "$(( t1 - t0 >= 1 ))" "1"
  check "under the lock: the run still starts once" "$(loops)" "1"
else
  echo "SKIP  flock is not installed"
fi

# ===========================================================================
# New means never seen, not "newly inside the max_issues window" (B2):
# budget-cut rows are eligible and recorded like INCLUDED ones
# ===========================================================================
only() { printf '%s\n' "$SANDBOX/work/$1" > "$HOME/.devlead/autonomous-repos"; }

# Repro A: max_issues 3, five issues. The first poll records all five; once
# the fleet takes 11-13, 14 and 15 move into the window: nothing new.
repo ra; only ra
PLAN_MAX=3 plan ra 11 12 13 14 15
poll
check "window A: the first poll records INCLUDED and budget-cut issues" "$(seen_of ra)" "-,11,12,13,14,15"
check "window A: the first poll starts nothing" "$(loops)" "0"
PLAN_MAX=3 plan ra 14 15
poll
check "window A: issues moving into the window are not new: no run" "$(loops)" "0"
contains "window A: says nothing new" "$OUT" "nothing new — no claude session started"

# Repro B: three old issues fill the window; #20, created today, is cut.
repo rb; only rb
PLAN_MAX=3 plan rb 1 2 3
poll
PLAN_MAX=3 plan rb 1 2 3 20
poll
check "window B: a new issue beyond the window is new work: one run for it" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/rb] [--max-iterations] [1] [--] [#20]"
check "window B: recorded" "$(seen_of rb)" "-,1,2,3,20"

# At most max_issues new issues per run, oldest first; the rest stay unseen.
repo rc; only rc
PLAN_MAX=2 plan rc 1
poll
PLAN_MAX=2 plan rc 1 30 31 32
poll
check "cap: the run takes max_issues new issues, in the plan's order" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/rc] [--max-iterations] [1] [--] [#30] [#31]"
check "cap: the one beyond the cap stays unseen" "$(seen_of rc)" "-,1,30,31"
poll
check "cap: the next poll takes it" "$(grep '^sweep-loop.sh' "$LOG")" \
  "sweep-loop.sh [--repo] [$SANDBOX/work/rc] [--max-iterations] [1] [--] [#32]"
lacks_seen() { [[ ",$(seen_of "$1")," != *",$2,"* ]] && echo absent || echo recorded; }
check "a title that imitates a budget-cut reason is not eligible (#78)" "$(lacks_seen rc 78)" "absent"
check "another exclusion is not eligible (#77)" "$(lacks_seen rc 77)" "absent"

# Two polls at once never hand the same issue to two runs: reading, choosing
# and recording happen under one lock (both fetch their plan first).
repo rd; only rd
plan rd 1
poll
plan rd 1 8 9
: > "$LOG"
( cd "$SANDBOX" && STUB_PLAN_SLEEP=1 bash "$SCRIPTS/poll-issues.sh" >/dev/null 2>&1 ) &
p1=$!
( cd "$SANDBOX" && STUB_PLAN_SLEEP=1 bash "$SCRIPTS/poll-issues.sh" >/dev/null 2>&1 ) &
p2=$!
wait "$p1" "$p2"
check "two concurrent polls: one run between them" "$(loops)" "1"
check "two concurrent polls: each issue recorded once" "$(seen_of rd)" "-,1,8,9"

OUT="$(bash "$SCRIPTS/poll-issues.sh" --what 2>&1)"; RC=$?
check "an argument is misuse: exit 2" "$RC" "2"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
