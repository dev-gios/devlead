#!/usr/bin/env bash
# unit-sweep-loop.sh — acceptance coverage for .devlead/scripts/sweep-loop.sh
#
#   bash test/unit-sweep-loop.sh
#
# SAFETY: every scenario runs with DEVLEAD_LOOP_DRYRUN=1, so `claude` is never
# invoked, and with $DEVLEAD_RUN_STATE_DIR pointed at a throwaway /tmp root, so
# the real ~/.devlead tree is never read or written.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/.devlead/scripts/sweep-loop.sh"
RUN_STATE="$REPO_ROOT/.devlead/scripts/run-state.sh"
SANDBOX="$(mktemp -d /tmp/devlead-sweeploop.XXXXXX)"
export DEVLEAD_RUN_STATE_DIR="$SANDBOX/state"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

PLAN="$SANDBOX/plan.yml"
cat > "$PLAN" <<'YML'
version: 1
tasks:
  - id: alpha
    title: "First"
    type: feat
  - id: beta
    title: "Second"
    type: feat
YML

RUN_ID="plan-$(sha256sum "$PLAN" | cut -c1-16)"

# --- Dry run prints the exact command and invokes nothing ------------------
out="$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 2 2>&1)"
check "dry run exits 0" \
  "$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 2 >/dev/null 2>&1; echo $?)" "0"
contains "dry run prints the claude -p command" "$out" "claude -p"
contains "dry run passes the plan through" "$out" "--plan $PLAN"
contains "dry run announces it invoked nothing" "$out" "nothing was invoked"

# --- The iteration cap is respected ----------------------------------------
check "cap of 1 yields exactly one iteration line" \
  "$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 1 2>&1 | grep -c 'iteration 1/1')" "1"
check "cap of 3 yields exactly three iteration lines" \
  "$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 3 2>&1 | grep -c 'would run')" "3"

# --- A settled plan stops the loop before any iteration --------------------
bash "$RUN_STATE" mark "$RUN_ID" alpha "done"
out="$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 5 2>&1)"
contains "one task done is not enough to stop" "$out" "would run"

bash "$RUN_STATE" mark "$RUN_ID" beta "done"
out="$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 5 2>&1)"
contains "every task done stops the loop" "$out" "is done — stopping"
check "a settled plan invokes nothing" "$(printf '%s' "$out" | grep -c 'would run')" "0"

# --- A parked task is NOT settled: PARK is not a pass (A4) -----------------
bash "$RUN_STATE" mark "$RUN_ID" beta parked "gate rojo"
out="$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --plan "$PLAN" --max-iterations 2 2>&1)"
contains "a parked task keeps the loop going" "$out" "would run"

# --- Usage errors ----------------------------------------------------------
check "missing plan file exits 1" \
  "$(bash "$LOOP" --plan "$SANDBOX/nope.yml" >/dev/null 2>&1; echo $?)" "1"
check "--plan without a value exits 1" \
  "$(bash "$LOOP" --plan >/dev/null 2>&1; echo $?)" "1"
check "non-numeric --max-iterations exits 1" \
  "$(bash "$LOOP" --max-iterations abc >/dev/null 2>&1; echo $?)" "1"
check "zero --max-iterations exits 1" \
  "$(bash "$LOOP" --max-iterations 0 >/dev/null 2>&1; echo $?)" "1"
check "unknown argument exits 1" \
  "$(bash "$LOOP" --bogus >/dev/null 2>&1; echo $?)" "1"

# --- Without a plan there is no completion signal, only the cap ------------
out="$(DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --max-iterations 2 2>&1)"
check "planless run honours the cap" "$(printf '%s' "$out" | grep -c 'would run')" "2"
contains "planless command carries no --plan" "$out" 'claude -p "/sweep-execute"'

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
