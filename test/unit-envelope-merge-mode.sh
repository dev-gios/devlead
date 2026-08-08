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

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
