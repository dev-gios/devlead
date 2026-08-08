#!/usr/bin/env bash
# unit-run-state.sh — acceptance coverage for .devlead/scripts/run-state.sh
#
#   bash test/unit-run-state.sh
#
# SAFETY: every scenario runs against a throwaway /tmp state root injected via
# $DEVLEAD_RUN_STATE_DIR. This script never reads or writes the real
# ~/.devlead tree.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
R="$REPO_ROOT/.devlead/scripts/run-state.sh"
STATE_ROOT="$(mktemp -d /tmp/devlead-run-state.XXXXXX)"
export DEVLEAD_RUN_STATE_DIR="$STATE_ROOT"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected: [$3]"
    echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Core contract: mark -> is-done ---------------------------------------
bash "$R" mark run1 task-a "done"
check "mark done then is-done exits 0" \
  "$(bash "$R" is-done run1 task-a; echo $?)" "0"
check "never-marked task exits 1" \
  "$(bash "$R" is-done run1 never-seen; echo $?)" "1"
check "unknown run exits 1" \
  "$(bash "$R" is-done other-run task-a; echo $?)" "1"

# --- A4: a parked task is not done, and its reason survives verbatim -------
bash "$R" mark run1 task-b parked "gate-check: Test runner failed: make test"
check "parked does not count as done" \
  "$(bash "$R" is-done run1 task-b; echo $?)" "1"
check "reason returned verbatim" \
  "$(bash "$R" reason run1 task-b)" "gate-check: Test runner failed: make test"

bash "$R" mark run1 task-c parked "line 1
line 2  with   spacing"
check "multi-line reason preserved byte for byte" \
  "$(bash "$R" reason run1 task-c)" "line 1
line 2  with   spacing"

check "reason for unrecorded task exits 1" \
  "$(bash "$R" reason run1 ghost >/dev/null 2>&1; echo $?)" "1"

# --- Regression: a status with no reason must still be written ------------
# A false test as the last command of the write group made the group exit
# non-zero, so every reasonless mark reported a write failure and stored
# nothing.
bash "$R" mark run2 no-reason "done"
check "reasonless mark is persisted" \
  "$(bash "$R" is-done run2 no-reason; echo $?)" "0"
check "reasonless mark yields empty reason" \
  "$(bash "$R" reason run2 no-reason)" ""

# --- Identifier validation: ids become path segments ----------------------
check "traversal id rejected" \
  "$(bash "$R" mark run1 ../escape "done" >/dev/null 2>&1; echo $?)" "1"
check "slash in id rejected" \
  "$(bash "$R" mark run1 a/b "done" >/dev/null 2>&1; echo $?)" "1"
check "whitespace in id rejected" \
  "$(bash "$R" mark run1 "a b" "done" >/dev/null 2>&1; echo $?)" "1"
check "empty run-id rejected" \
  "$(bash "$R" mark "" task "done" >/dev/null 2>&1; echo $?)" "1"
check "empty status rejected" \
  "$(bash "$R" mark run1 task-z "" >/dev/null 2>&1; echo $?)" "1"
check "traversal wrote nothing outside the state root" \
  "$(find "$STATE_ROOT/.." -maxdepth 1 -name 'escape' 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- CLI surface -----------------------------------------------------------
check "unknown subcommand exits 1" \
  "$(bash "$R" bogus >/dev/null 2>&1; echo $?)" "1"
check "no arguments exits 1" \
  "$(bash "$R" >/dev/null 2>&1; echo $?)" "1"

# --- Listing and overwrite -------------------------------------------------
check "list reports every recorded task" \
  "$(bash "$R" list run1 | sort | tr '\n' ';')" \
  "task-a	done;task-b	parked;task-c	parked;"

bash "$R" mark run1 task-a parked "superseded"
check "mark overwrites a previous status" \
  "$(bash "$R" is-done run1 task-a; echo $?)" "1"
check "no orphaned temp files remain" \
  "$(find "$STATE_ROOT" -name '*.tmp.*' | wc -l | tr -d ' ')" "0"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $STATE_ROOT) ==="
rm -rf "$STATE_ROOT"
[[ "$FAIL_COUNT" -eq 0 ]]
