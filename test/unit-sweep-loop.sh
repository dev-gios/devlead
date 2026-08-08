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

# ===========================================================================
# FIX 7 regression: the loop must fail loudly outside a git work tree, and
# --repo / DEVLEAD_LOOP_REPO must be able to point it at the real target.
# ===========================================================================
NON_GIT_DIR="$SANDBOX/not-a-repo"
mkdir -p "$NON_GIT_DIR"

GIT_REPO_DIR="$SANDBOX/target-repo"
mkdir -p "$GIT_REPO_DIR"
git -C "$GIT_REPO_DIR" init -q
git -C "$GIT_REPO_DIR" config user.email smoke@example.com
git -C "$GIT_REPO_DIR" config user.name "Smoke Test"

# --- Outside a git work tree: fails loudly instead of a silent no-op -------
out="$(cd "$NON_GIT_DIR" && DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --max-iterations 1 2>&1)"
rc=$?
check "running outside a git work tree exits non-zero" "$rc" "1"
contains "the diagnostic names the non-git cwd" "$out" "not inside a git work tree"
check "nothing was attempted outside a git work tree" \
  "$(printf '%s' "$out" | grep -c 'would run')" "0"

# --- --repo cds into the target repo before the guard runs -----------------
out="$(cd "$NON_GIT_DIR" && DEVLEAD_LOOP_DRYRUN=1 bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "--repo pointed at a real git repo exits 0" "$rc" "0"
contains "--repo run reaches the dry-run announcement" "$out" "would run"

# --- --repo on a non-existent directory is a clean usage error -------------
out="$(cd "$NON_GIT_DIR" && bash "$LOOP" --repo "$SANDBOX/does-not-exist" --max-iterations 1 2>&1)"
rc=$?
check "--repo on a missing directory exits 1" "$rc" "1"
contains "the diagnostic names the missing --repo path" "$out" "does-not-exist"

# --- DEVLEAD_LOOP_REPO is honoured when --repo is not given -----------------
out="$(cd "$NON_GIT_DIR" && DEVLEAD_LOOP_REPO="$GIT_REPO_DIR" DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 2>&1)"
rc=$?
check "DEVLEAD_LOOP_REPO alone exits 0" "$rc" "0"
contains "DEVLEAD_LOOP_REPO run reaches the dry-run announcement" "$out" "would run"

# --- --repo wins over DEVLEAD_LOOP_REPO when both are set -------------------
OTHER_NON_GIT="$SANDBOX/other-not-a-repo"
mkdir -p "$OTHER_NON_GIT"
out="$(cd "$NON_GIT_DIR" && DEVLEAD_LOOP_REPO="$OTHER_NON_GIT" DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "--repo overrides a DEVLEAD_LOOP_REPO pointed elsewhere" "$rc" "0"

# ===========================================================================
# Round-2 regression: the git-work-tree guard broke the documented planless
# `--fleet` form. `--fleet` enumerates ~/.devlead/autonomous-repos and is
# explicitly NOT cwd-dependent — it must keep working from a non-git cwd.
# This test sets its OWN throwaway non-git /tmp cwd (never inherits the repo
# checkout's cwd), which is exactly what masked the regression originally.
# ===========================================================================
FLEET_NON_GIT_DIR="$(mktemp -d /tmp/devlead-sweeploop-fleet.XXXXXX)"

# --- Planless --fleet succeeds from a NON-git directory ---------------------
out="$(cd "$FLEET_NON_GIT_DIR" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet 2>&1)"
rc=$?
check "planless --fleet from a non-git cwd exits 0" "$rc" "0"
contains "planless --fleet reaches the dry-run announcement" "$out" "would run"
contains "planless --fleet carries --fleet through to the prompt" "$out" '--fleet'

# --- The plan form still fails loudly from a non-git directory, even with
#     --fleet also passed through (--plan takes precedence over --fleet in
#     sweep-execute, so the guard still applies) -----------------------------
out="$(cd "$FLEET_NON_GIT_DIR" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --plan "$PLAN" --max-iterations 1 -- --fleet 2>&1)"
rc=$?
check "--plan from a non-git cwd still exits 1 even with --fleet" "$rc" "1"
contains "the diagnostic still names the non-git cwd" "$out" "not inside a git work tree"

rm -rf "$FLEET_NON_GIT_DIR"

# ===========================================================================
# Round-3 regression: the guard must be derived from the EFFECTIVE invocation
# (an array scan for exact --fleet/--plan tokens), not from sweep-loop's own
# $PLAN_FILE plus a substring scan of a flattened extra-args string. Each
# scenario sets its OWN throwaway non-git /tmp cwd — never inherits the repo
# checkout's cwd, which is exactly what hid the original regressions.
# ===========================================================================

# --- --plan forwarded AFTER `--` still fires the guard (bypass #1) ---------
R3_DIR_A="$(mktemp -d /tmp/devlead-sweeploop-r3a.XXXXXX)"
out="$(cd "$R3_DIR_A" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet --plan f.yml 2>&1)"
rc=$?
check "-- --fleet --plan f.yml still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd" "$out" "not inside a git work tree"
rm -rf "$R3_DIR_A"

# --- Order must not matter: --plan before --fleet also fires the guard -----
R3_DIR_B="$(mktemp -d /tmp/devlead-sweeploop-r3b.XXXXXX)"
out="$(cd "$R3_DIR_B" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --plan f.yml --fleet 2>&1)"
rc=$?
check "-- --plan f.yml --fleet still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd (order swapped)" "$out" "not inside a git work tree"
rm -rf "$R3_DIR_B"

# --- A quoted value merely CONTAINING the text "--fleet" must not count
#     (bypass #2: the old flattened-string substring scan) -----------------
R3_DIR_C="$(mktemp -d /tmp/devlead-sweeploop-r3c.XXXXXX)"
out="$(cd "$R3_DIR_C" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --label "release notes --fleet mention" 2>&1)"
rc=$?
check "a value containing the text --fleet still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd (value, not flag)" "$out" "not inside a git work tree"
rm -rf "$R3_DIR_C"

# --- A bare --fleet token still skips the guard (must keep working) --------
R3_DIR_D="$(mktemp -d /tmp/devlead-sweeploop-r3d.XXXXXX)"
out="$(cd "$R3_DIR_D" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet 2>&1)"
rc=$?
check "bare -- --fleet still exits 0" "$rc" "0"
contains "bare -- --fleet still reaches the dry-run announcement" "$out" "would run"
rm -rf "$R3_DIR_D"

# --- Top-level --plan combined with -- --fleet still fires (existing
#     behaviour preserved by the rewritten guard) ---------------------------
R3_DIR_E="$(mktemp -d /tmp/devlead-sweeploop-r3e.XXXXXX)"
out="$(cd "$R3_DIR_E" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --plan "$PLAN" --max-iterations 1 -- --fleet 2>&1)"
rc=$?
check "top-level --plan with -- --fleet still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd (top-level --plan)" "$out" "not inside a git work tree"
rm -rf "$R3_DIR_E"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
