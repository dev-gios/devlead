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

not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"
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


# ===========================================================================
# Round-4 regression: the guard must be derived from sweep-execute.md's THREE
# mode selectors (#N > --plan > --fleet), not from an enumerated --fleet/
# --plan flag pair. Bypass reproduced pre-fix: from a non-git cwd,
# `sweep-loop.sh -- --fleet '#1'` skipped the guard and exited 0, even though
# the dispatched command is MODO SCOPED (a #N token wins over --fleet) and
# DOES resolve from cwd. Each scenario sets its OWN throwaway non-git /tmp
# cwd — never inherits the repo checkout's cwd, which is exactly what hid
# the round-2/round-3 regressions originally.
# ===========================================================================

# --- --fleet plus a #N token still fires the guard (the reproduced bypass) -
R4_DIR_A="$(mktemp -d /tmp/devlead-sweeploop-r4a.XXXXXX)"
out="$(cd "$R4_DIR_A" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet '#1' 2>&1)"
rc=$?
check "-- --fleet '#1' still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd (--fleet '#1')" "$out" "not inside a git work tree"
rm -rf "$R4_DIR_A"

# --- Order must not matter: #N before --fleet also fires the guard --------
R4_DIR_B="$(mktemp -d /tmp/devlead-sweeploop-r4b.XXXXXX)"
out="$(cd "$R4_DIR_B" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- '#1' --fleet 2>&1)"
rc=$?
check "-- '#1' --fleet still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd ('#1' --fleet)" "$out" "not inside a git work tree"
rm -rf "$R4_DIR_B"

# --- Scoped with no --fleet at all still fires (sanity: was already true,
#     kept here as an explicit regression anchor for MODO SCOPED) ----------
R4_DIR_C="$(mktemp -d /tmp/devlead-sweeploop-r4c.XXXXXX)"
out="$(cd "$R4_DIR_C" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- '#12' '#34' 2>&1)"
rc=$?
check "-- '#12' '#34' (scoped, no fleet) fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd ('#12' '#34')" "$out" "not inside a git work tree"
rm -rf "$R4_DIR_C"

# --- A value that merely LOOKS like an issue token but is not `#<digits>`
#     must not count — --fleet still wins and the guard is skipped ---------
R4_DIR_D="$(mktemp -d /tmp/devlead-sweeploop-r4d.XXXXXX)"
out="$(cd "$R4_DIR_D" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet '#notanumber' 2>&1)"
rc=$?
check "-- --fleet '#notanumber' skips the guard (exit 0)" "$rc" "0"
contains "'#notanumber' run reaches the dry-run announcement" "$out" "would run"
rm -rf "$R4_DIR_D"

# --- Bare --fleet still skips the guard (must keep working) ----------------
R4_DIR_E="$(mktemp -d /tmp/devlead-sweeploop-r4e.XXXXXX)"
out="$(cd "$R4_DIR_E" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet 2>&1)"
rc=$?
check "bare -- --fleet (round-4 anchor) still exits 0" "$rc" "0"
contains "bare -- --fleet (round-4 anchor) still reaches the dry-run announcement" "$out" "would run"
rm -rf "$R4_DIR_E"

# --- --fleet plus --plan still fires (existing behaviour preserved) -------
R4_DIR_F="$(mktemp -d /tmp/devlead-sweeploop-r4f.XXXXXX)"
out="$(cd "$R4_DIR_F" && DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --max-iterations 1 -- --fleet --plan f.yml 2>&1)"
rc=$?
check "-- --fleet --plan f.yml (round-4 anchor) still fires the guard (exit 1)" "$rc" "1"
contains "the diagnostic names the non-git cwd (round-4 --fleet --plan)" "$out" "not inside a git work tree"
rm -rf "$R4_DIR_F"

# ===========================================================================
# Reactive check: the pre-check guard above is a fast path, not the
# guarantee. sweep-loop must react to a `STATUS: not-a-git-repo` line in the
# dispatched invocation's own output and stop immediately — no matter what
# the pre-check predicted. A fake `claude` on DEVLEAD_CLAUDE_BIN stands in so
# nothing real is ever invoked. Each scenario gets its OWN throwaway TMPDIR so
# leftover-scratch-file assertions never see another test's files.
# ===========================================================================

# A passing doctor stub — these reactive-check scenarios are not testing the
# drift guard, so they must not be at the mercy of whatever the REAL machine
# running this test currently has installed under ~/.devlead (see the
# dedicated "Drift guard" section further below for that).
FAKE_DOCTOR_OK="$SANDBOX/fake-doctor-ok"
cat > "$FAKE_DOCTOR_OK" <<'FAKE'
#!/usr/bin/env bash
echo "STATUS: ok"
exit 0
FAKE
chmod +x "$FAKE_DOCTOR_OK"

FAKE_CLAUDE_NOTAGITREPO="$SANDBOX/fake-claude-notagitrepo"
cat > "$FAKE_CLAUDE_NOTAGITREPO" <<'FAKE'
#!/usr/bin/env bash
echo "STATUS: not-a-git-repo"
echo "No se pudo resolver el repo actual (git rev-parse --show-toplevel falló)."
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_NOTAGITREPO"

FAKE_CLAUDE_NORMAL="$SANDBOX/fake-claude-normal"
cat > "$FAKE_CLAUDE_NORMAL" <<'FAKE'
#!/usr/bin/env bash
echo "sweep-execute: did some normal work here"
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_NORMAL"

# --- A STATUS: not-a-git-repo line stops the loop after the FIRST iteration,
#     even with a generous cap, prints a diagnostic, and exits non-zero -----
REACT_TMP_A="$SANDBOX/react-tmp-a"
mkdir -p "$REACT_TMP_A"
out="$(TMPDIR="$REACT_TMP_A" DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_OK" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_NOTAGITREPO" DEVLEAD_LOOP_SLEEP=0 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 5 2>&1)"
rc=$?
check "STATUS: not-a-git-repo from claude's own output exits non-zero" "$rc" "1"
contains "the diagnostic names the reactive STATUS line" "$out" "STATUS: not-a-git-repo"
contains "the diagnostic names the cwd that was used" "$out" "cwd used was"
contains "the diagnostic suggests --repo or DEVLEAD_LOOP_REPO" "$out" "DEVLEAD_LOOP_REPO"
check "exactly one iteration was invoked" "$(printf '%s' "$out" | grep -c -- '— invoking')" "1"
not_contains "a second iteration never starts, even with --max-iterations 5" "$out" "iteration 2/5"
check "no scratch file remains after the reactive exit" \
  "$(find "$REACT_TMP_A" -name 'sweep-loop-out.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- Normal output iterates to the cap and exits 0 as before, and the
#     dispatched invocation's own output is still streamed to the caller ----
REACT_TMP_B="$SANDBOX/react-tmp-b"
mkdir -p "$REACT_TMP_B"
out="$(TMPDIR="$REACT_TMP_B" DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_OK" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_NORMAL" DEVLEAD_LOOP_SLEEP=0 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 2 2>&1)"
rc=$?
check "normal output iterates to the cap and exits 0" "$rc" "0"
contains "the fake claude's own output is streamed to the caller" "$out" "did some normal work here"
check "both iterations were invoked" "$(printf '%s' "$out" | grep -c -- '— invoking')" "2"
contains "the cap-reached message still appears" "$out" "iteration cap"
check "no scratch file remains after the normal-cap path" \
  "$(find "$REACT_TMP_B" -name 'sweep-loop-out.*' 2>/dev/null | wc -l | tr -d ' ')" "0"


# ===========================================================================
# Drift guard: sweep-loop refuses to run unattended when doctor.sh reports
# the installed artifacts do not verify AS THE REVIEWED TRUNK. A stub
# doctor.sh stands in via DEVLEAD_DOCTOR_BIN — doctor.sh's own integrity/
# provenance detection logic is covered separately by test/unit-doctor.sh;
# this only exercises the wiring: does sweep-loop call it, read its
# STATUS/NOTE output (NOT just its exit code — STATUS: ok with a provenance
# NOTE also exits 0), and respect DEVLEAD_ALLOW_DRIFT / DEVLEAD_LOOP_DRYRUN
# correctly.
# ===========================================================================

FAKE_DOCTOR_FAIL="$SANDBOX/fake-doctor-fail"
cat > "$FAKE_DOCTOR_FAIL" <<'FAKE'
#!/usr/bin/env bash
echo "STATUS: drifted"
echo "TRUNK:  main @ deadbee"
echo "SOURCE: /fake/source/repo"
echo "DRIFT:  1 of 4 artifacts differ from the trunk"
echo "DIFF:   /fake/home/.devlead/hooks/gate-check.sh (content differs from the trunk)"
exit 1
FAKE
chmod +x "$FAKE_DOCTOR_FAIL"

# A doctor stub reporting STATUS: ok (exit 0, integrity intact) but from a
# BRANCH, not the trunk — a provenance gap, not an integrity failure. This is
# the exact case the feature exists for: sweep-loop must not key off the
# exit code alone, because this one is 0.
FAKE_DOCTOR_BRANCH="$SANDBOX/fake-doctor-branch"
cat > "$FAKE_DOCTOR_BRANCH" <<'FAKE'
#!/usr/bin/env bash
echo "STATUS: ok"
echo "MATCHES: feature @ deadbee"
echo "TRUNK:  main @ cafebabe"
echo "SOURCE: /fake/source/repo"
echo "NOTE:   installed from a branch, not the trunk — expected during development;"
echo "        an unattended run still requires the trunk"
exit 0
FAKE
chmod +x "$FAKE_DOCTOR_BRANCH"

# FAKE_DOCTOR_OK is already defined above, in the "Reactive check" section.

MARKER_FILE="$SANDBOX/claude-was-invoked"
FAKE_CLAUDE_MARKER="$SANDBOX/fake-claude-marker"
cat > "$FAKE_CLAUDE_MARKER" <<FAKE
#!/usr/bin/env bash
touch "$MARKER_FILE"
echo "sweep-execute: ran"
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_MARKER"

# --- doctor fails -> loop exits non-zero, invokes nothing ------------------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_FAIL" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 3 2>&1)"
rc=$?
check "doctor failure exits non-zero" "$rc" "1"
contains "the doctor's own drifted output is surfaced" "$out" "STATUS: drifted"
contains "the doctor's DIFF line is surfaced" "$out" "gate-check.sh"
contains "the remedy is printed" "$out" "git checkout <trunk>"
contains "the escape hatch is mentioned" "$out" "DEVLEAD_ALLOW_DRIFT=1"
check "claude was never invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "no"

# --- doctor fails + DEVLEAD_ALLOW_DRIFT=1 -> loop proceeds AND prints the
#     warning ---------------------------------------------------------------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_FAIL" DEVLEAD_ALLOW_DRIFT=1 \
  DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" DEVLEAD_LOOP_SLEEP=0 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "ALLOW_DRIFT proceeds: exits 0" "$rc" "0"
contains "ALLOW_DRIFT proceeds: prints the ALLOW_DRIFT warning" "$out" "DEVLEAD_ALLOW_DRIFT=1 — PROCEEDING ANYWAY"
contains "ALLOW_DRIFT proceeds: still surfaces what differs" "$out" "gate-check.sh"
check "ALLOW_DRIFT proceeds: claude WAS invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "yes"

# --- DEVLEAD_LOOP_DRYRUN=1 -> the drift check is skipped entirely, no
#     failure even with a failing doctor -------------------------------------
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_FAIL" DEVLEAD_LOOP_DRYRUN=1 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "dry-run skips the drift check even with a failing doctor: exits 0" "$rc" "0"
not_contains "dry-run never surfaces doctor output" "$out" "STATUS: drifted"
contains "dry-run still reaches the announcement" "$out" "would run"

# --- A passing doctor is silent and does not block a normal run ------------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_OK" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" \
  DEVLEAD_LOOP_SLEEP=0 bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "passing doctor: exits 0" "$rc" "0"
not_contains "passing doctor: prints no drift warning" "$out" "STATUS: drifted"
check "passing doctor: claude WAS invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "yes"

# ===========================================================================
# Provenance: doctor.sh exits 0 for "STATUS: ok, from a branch" — the loop
# must not treat that exit code as sufficient. It must read the NOTE and
# still refuse to run unattended, exactly as it does for STATUS: drifted.
# ===========================================================================

# --- doctor says ok-but-from-a-branch -> loop BLOCKS, message names
#     provenance specifically, invokes nothing ------------------------------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_BRANCH" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 3 2>&1)"
rc=$?
check "ok-but-branch exits non-zero" "$rc" "1"
contains "ok-but-branch: the message names provenance" "$out" "provenance"
contains "ok-but-branch: doctor's own STATUS: ok is surfaced" "$out" "STATUS: ok"
contains "ok-but-branch: doctor's own NOTE is surfaced" "$out" "installed from a branch"
contains "ok-but-branch: the remedy is printed" "$out" "git checkout <trunk>"
contains "ok-but-branch: the escape hatch is mentioned" "$out" "DEVLEAD_ALLOW_DRIFT=1"
check "ok-but-branch: claude was never invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "no"

# --- doctor says ok-but-from-a-branch + DEVLEAD_ALLOW_DRIFT=1 -> loop
#     proceeds AND prints the warning ----------------------------------------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_BRANCH" DEVLEAD_ALLOW_DRIFT=1 \
  DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" DEVLEAD_LOOP_SLEEP=0 \
  bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "ok-but-branch + ALLOW_DRIFT: exits 0" "$rc" "0"
contains "ok-but-branch + ALLOW_DRIFT: prints the ALLOW_DRIFT warning" "$out" "DEVLEAD_ALLOW_DRIFT=1 — PROCEEDING ANYWAY"
contains "ok-but-branch + ALLOW_DRIFT: still surfaces the doctor NOTE" "$out" "installed from a branch"
check "ok-but-branch + ALLOW_DRIFT: claude WAS invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "yes"

# --- doctor says ok-and-trunk (no NOTE) -> loop proceeds, no block ---------
rm -f "$MARKER_FILE"
out="$(DEVLEAD_DOCTOR_BIN="$FAKE_DOCTOR_OK" DEVLEAD_CLAUDE_BIN="$FAKE_CLAUDE_MARKER" \
  DEVLEAD_LOOP_SLEEP=0 bash "$LOOP" --repo "$GIT_REPO_DIR" --max-iterations 1 2>&1)"
rc=$?
check "ok-and-trunk: exits 0" "$rc" "0"
not_contains "ok-and-trunk: no provenance block message" "$out" "provenance"
check "ok-and-trunk: claude WAS invoked" "$([[ -f "$MARKER_FILE" ]] && echo yes || echo no)" "yes"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
