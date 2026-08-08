#!/usr/bin/env bash
# unit-envelope-merge-mode.sh — merge.mode validation in envelope.sh
#
#   bash test/unit-envelope-merge-mode.sh
#
# GOVERNANCE.md §A3 grants merge authority through `merge.mode` in a
# pre-declared envelope. These cases pin the two clauses that keep that from
# becoming a hole: `default-branch` stays rejected, and an integration branch
# that IS the default branch is refused.
#
# SAFETY: every scenario runs inside a throwaway /tmp git repo with a local
# bare remote. Never reads or writes the real repo or ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ENVELOPE_SH="$REPO_ROOT/.devlead/scripts/envelope.sh"
SANDBOX="$(mktemp -d /tmp/devlead-envmerge.XXXXXX)"

PASS_COUNT=0
FAIL_COUNT=0

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected substring: [$3]"
    echo "        actual:             [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

lacks() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        unexpected substring: [$3]"
    echo "        actual:               [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

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

# --- Sandbox repo with a resolvable default branch -------------------------
git init -q --bare "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work" 2>/dev/null
cd "$SANDBOX/work" || exit 1
git config user.email smoke@example.com
git config user.name "Smoke Test"
git checkout -q -b main
mkdir -p .devlead
echo seed > seed.txt
git add seed.txt
git commit -q -m seed
git push -q -u origin main 2>/dev/null
git remote set-head origin main 2>/dev/null

# Writes an envelope with the given merge block appended.
write_envelope() {
  cat > .devlead/envelope.yml <<YML
version: 1
enabled: true
select:
  bucket: nuevo-entrante
  exclude_labels: [blocked]
  require_readiness: true
order:
  by: [priority-label, created-asc]
budget:
  max_issues: 3
  stop_at: null
base:
  strategy: nearest-tag
$1
forbidden_zones: inherit
on_failure:
  policy: park-and-continue
  skip_dependents: true
merge:
  mode: $2
report:
  to: journal-per-repo
YML
}

# --- never: the default, still accepted ------------------------------------
write_envelope "" "never"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
lacks "merge.mode never is accepted" "$out" "STATUS: blocked"

# --- default-branch: RESERVED, must stay rejected --------------------------
write_envelope "  integration_branch: dev" "default-branch"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "default-branch is blocked" "$out" "STATUS: blocked"
contains "default-branch says it is RESERVED" "$out" "RESERVED"

# --- unknown value ---------------------------------------------------------
write_envelope "" "whatever"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "unknown merge.mode is blocked" "$out" "STATUS: blocked"

# --- integration-branch without a declared branch --------------------------
write_envelope "" "integration-branch"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "integration-branch requires the branch to be declared" \
  "$out" "requires base.integration_branch to be declared"

# --- A3 clause 2: the integration branch must not be the default branch ----
write_envelope "  integration_branch: main" "integration-branch"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "integration_branch == default branch is blocked" "$out" "STATUS: blocked"
contains "the block names the trunk risk" "$out" "must not be the default branch"

# --- The legitimate configuration ------------------------------------------
write_envelope "  integration_branch: feature/nightly" "integration-branch"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
lacks "a non-default integration branch is accepted" "$out" "STATUS: blocked"

# --- FIX 6 regression: a STALE local symref must not defeat the guard ------
# `git remote set-head origin main` (used by the fixture above) is exactly
# what hides this bug in real life: it points refs/remotes/origin/HEAD at
# "main" and git never re-checks it. Scenario: the remote's real default
# branch was RENAMED to "trunk" after the clone. The stale local symref
# still says "main". An attacker declares integration_branch: trunk — the
# NEW real default branch. A guard that trusts ONLY the stale symref would
# compare "trunk" != "main" and wrongly APPROVE it, granting merge-to-trunk.
# `envelope.sh` must prefer a live `gh repo view` lookup (which reports the
# true current default, "trunk") over the stale symref, and still block.
git remote set-head origin main 2>/dev/null  # re-assert the stale symref
FAKEBIN_GH="$(mktemp -d /tmp/devlead-envmerge-fakebin.XXXXXX)"
cat > "$FAKEBIN_GH/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  # Ground truth: the remote's real default branch is now "trunk", NOT the
  # stale local symref's "main".
  echo "trunk"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKEBIN_GH/gh"

write_envelope "  integration_branch: trunk" "integration-branch"
out="$(PATH="$FAKEBIN_GH:$PATH" bash "$ENVELOPE_SH" show 2>&1)"
contains "stale symref: guard still blocks using gh ground truth" "$out" "STATUS: blocked"
contains "stale symref: block names the trunk risk" "$out" "must not be the default branch"
rm -rf "$FAKEBIN_GH"

# --- Round-2 regression: a hung `gh` must not hang envelope.sh -------------
# Both `gh auth status` and `gh repo view` were unbounded. A `gh` stub that
# sleeps well beyond the timeout, combined with a deliberately STALE local
# symref (the fixture's real default branch is "main"; declare
# integration_branch as something ELSE entirely — "feature/nightly" — so a
# correct fallback resolution APPROVES it, while a hang or a wrong fallback
# answer would not), must (a) return within a bounded time instead of
# hanging, and (b) still reach the correct decision via the symref fallback.
# Bound the test itself with an external `timeout` so a regression fails the
# suite instead of hanging CI forever.
git remote set-head origin main 2>/dev/null  # re-assert the local symref
FAKEBIN_GH_HANG="$(mktemp -d /tmp/devlead-envmerge-fakebin-hang.XXXXXX)"
cat > "$FAKEBIN_GH_HANG/gh" <<'EOF'
#!/usr/bin/env bash
# Simulates a hung `gh` (dead network, stalled auth prompt): sleeps well
# beyond envelope.sh's DEVLEAD_GH_TIMEOUT_SECS.
sleep 300
EOF
chmod +x "$FAKEBIN_GH_HANG/gh"

write_envelope "  integration_branch: feature/nightly" "integration-branch"
_hang_start=$(date +%s)
out="$(timeout 30 env PATH="$FAKEBIN_GH_HANG:$PATH" DEVLEAD_GH_TIMEOUT_SECS=2 \
  bash "$ENVELOPE_SH" show 2>&1)"
_hang_rc=$?
_hang_elapsed=$(( $(date +%s) - _hang_start ))
check "a hung gh does not hang envelope.sh (external timeout never fires)" \
  "$([[ $_hang_rc -ne 124 ]] && echo ok || echo TIMED_OUT)" "ok"
check "a hung gh returns within a bounded time (well under the 30s outer bound)" \
  "$([[ $_hang_elapsed -lt 15 ]] && echo ok || echo TOO_SLOW)" "ok"
lacks "a hung gh still resolves the correct non-default branch via symref fallback" \
  "$out" "STATUS: blocked"
contains "a hung gh emits a stderr note naming the timeout" "$out" "timed out after"
rm -rf "$FAKEBIN_GH_HANG"

# --- Round-3 regression: DEVLEAD_GH_TIMEOUT_SECS=0 must not silently
# disable the timeout ---------------------------------------------------
# GNU `timeout 0` means "no timeout" — an unvalidated override of 0 would
# fully reinstate the unbounded hang the fix above closed. envelope.sh must
# reject 0, fall back to the default, and warn. Bound the test itself with
# an external `timeout` so a regression fails the suite instead of hanging.
FAKEBIN_GH_HANG2="$(mktemp -d /tmp/devlead-envmerge-fakebin-hang2.XXXXXX)"
cat > "$FAKEBIN_GH_HANG2/gh" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$FAKEBIN_GH_HANG2/gh"

write_envelope "  integration_branch: feature/nightly" "integration-branch"
_zero_start=$(date +%s)
out="$(timeout 30 env PATH="$FAKEBIN_GH_HANG2:$PATH" DEVLEAD_GH_TIMEOUT_SECS=0 \
  bash "$ENVELOPE_SH" show 2>&1)"
_zero_rc=$?
_zero_elapsed=$(( $(date +%s) - _zero_start ))
check "DEVLEAD_GH_TIMEOUT_SECS=0 does not hang envelope.sh (external timeout never fires)" \
  "$([[ $_zero_rc -ne 124 ]] && echo ok || echo TIMED_OUT)" "ok"
check "DEVLEAD_GH_TIMEOUT_SECS=0 returns within a bounded time (well under the 30s outer bound)" \
  "$([[ $_zero_elapsed -lt 25 ]] && echo ok || echo TOO_SLOW)" "ok"
contains "DEVLEAD_GH_TIMEOUT_SECS=0 emits a warning naming the offending value" "$out" "DEVLEAD_GH_TIMEOUT_SECS='0'"
contains "DEVLEAD_GH_TIMEOUT_SECS=0 warning names the fallback value used" "$out" "using 10s instead"
rm -rf "$FAKEBIN_GH_HANG2"

# --- A non-numeric override falls back to the default too ------------------
FAKEBIN_GH_HANG3="$(mktemp -d /tmp/devlead-envmerge-fakebin-hang3.XXXXXX)"
cat > "$FAKEBIN_GH_HANG3/gh" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$FAKEBIN_GH_HANG3/gh"

write_envelope "  integration_branch: feature/nightly" "integration-branch"
_nan_start=$(date +%s)
out="$(timeout 30 env PATH="$FAKEBIN_GH_HANG3:$PATH" DEVLEAD_GH_TIMEOUT_SECS=abc \
  bash "$ENVELOPE_SH" show 2>&1)"
_nan_rc=$?
_nan_elapsed=$(( $(date +%s) - _nan_start ))
check "a non-numeric override does not hang envelope.sh (external timeout never fires)" \
  "$([[ $_nan_rc -ne 124 ]] && echo ok || echo TIMED_OUT)" "ok"
check "a non-numeric override returns within a bounded time" \
  "$([[ $_nan_elapsed -lt 25 ]] && echo ok || echo TOO_SLOW)" "ok"
contains "a non-numeric override emits a warning naming the offending value" "$out" "DEVLEAD_GH_TIMEOUT_SECS='abc'"
contains "a non-numeric override warning names the fallback value used" "$out" "using 10s instead"
rm -rf "$FAKEBIN_GH_HANG3"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
