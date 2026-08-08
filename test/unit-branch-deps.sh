#!/usr/bin/env bash
# unit-branch-deps.sh — predecessor resolution in .devlead/scripts/branch.sh
#
#   bash test/unit-branch-deps.sh
#
# Covers the 4th positional argument (dep) for both producers of a work unit:
# a GitHub issue, whose branch slug is `issue-{N}-…`, and a LOCAL-PLAN task,
# whose slug is `plan-{task-id}-…`.
#
# SAFETY: everything runs inside a throwaway /tmp git sandbox with a local bare
# repo standing in for origin. Never touches the real repo, ~/.devlead, or any
# network remote.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BRANCH_SH="$REPO_ROOT/.devlead/scripts/branch.sh"
SANDBOX="$(mktemp -d /tmp/devlead-branch-deps.XXXXXX)"

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

field() { printf '%s\n' "$1" | grep "^$2:" | sed "s/^$2:[[:space:]]*//" | head -n1; }

# --- Sandbox: bare origin + working clone ---------------------------------
git init -q --bare "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work" 2>/dev/null
cd "$SANDBOX/work" || exit 1
git config user.email smoke@example.com
git config user.name "Smoke Test"
git checkout -q -b main
echo seed > seed.txt
git add seed.txt
git commit -q -m "seed"
git push -q -u origin main 2>/dev/null

# Predecessors: one produced by a plan task, one produced by an issue.
git checkout -q -b feat/plan-alpha-first-task
echo a > a.txt; git add a.txt; git commit -q -m "alpha"
git push -q -u origin feat/plan-alpha-first-task 2>/dev/null

git checkout -q -b feat/issue-42-legacy-task main
echo b > b.txt; git add b.txt; git commit -q -m "legacy"
git push -q -u origin feat/issue-42-legacy-task 2>/dev/null

git checkout -q main

# --- Plan-task predecessor resolves and stacks -----------------------------
out="$(bash "$BRANCH_SH" plan-beta "Second plan task" feat "plan-alpha" "main" 2>&1)"
check "plan dep: STATUS created" "$(field "$out" STATUS)" "created"
check "plan dep: STACKED names the predecessor branch" \
  "$(field "$out" STACKED)" "feat/plan-alpha-first-task"
# BASE may be the local branch or its origin/ counterpart depending on which
# `git branch -a` lists first; in a real run the predecessor exists locally
# because branch.sh created it moments earlier. What matters is that the base
# is the predecessor and not the integration branch.
contains "plan dep: BASE is the predecessor, not main" \
  "$(field "$out" BASE)" "feat/plan-alpha-first-task"

git checkout -q main

# --- Numeric dep keeps the historical issue- prefix (regression) -----------
out="$(bash "$BRANCH_SH" 99 "Dependent issue" feat "42" "main" 2>&1)"
check "issue dep: STATUS created" "$(field "$out" STATUS)" "created"
check "issue dep: STACKED names the issue branch" \
  "$(field "$out" STACKED)" "feat/issue-42-legacy-task"

git checkout -q main

# --- Missing predecessor blocks, and says which one ------------------------
out="$(bash "$BRANCH_SH" plan-gamma "Orphan plan task" feat "plan-missing" "main" 2>&1)"
check "missing plan dep: STATUS blocked" "$(field "$out" STATUS)" "blocked"
contains "missing plan dep: GAP names the predecessor" "$out" "plan-missing"

out="$(bash "$BRANCH_SH" 98 "Orphan issue" feat "777" "main" 2>&1)"
check "missing issue dep: STATUS blocked" "$(field "$out" STATUS)" "blocked"
contains "missing issue dep: GAP uses the # form" "$out" "#777"

git checkout -q main

# --- No dep at all still roots on the integration branch -------------------
out="$(bash "$BRANCH_SH" plan-delta "Root plan task" feat "" "main" 2>&1)"
check "no dep: STATUS created" "$(field "$out" STATUS)" "created"
check "no dep: no STACKED emitted" "$(field "$out" STACKED)" ""

git checkout -q main

# --- FIX 5 regression: a '.' in the dep slug must NOT act as a regex --------
# wildcard in the "already merged" fallback check. A dep id like "plan-a.b"
# (no local/remote branch, so branch.sh falls back to the gh-merged-PRs
# check) must not match an unrelated branch "plan-aXb-something" — the '.'
# is a literal character in a dep slug, never a basic-regex any-char.
FAKEBIN="$(mktemp -d /tmp/devlead-branch-deps-fakebin.XXXXXX)"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  # Merged-PR headRefNames: only the UNRELATED branch is merged. The real
  # predecessor ("plan-a.b-...") is never merged.
  echo "plan-aXb-something"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKEBIN/gh"

out="$(PATH="$FAKEBIN:$PATH" bash "$BRANCH_SH" plan-epsilon "Dotted dep task" feat "plan-a.b" "main" 2>&1)"
check "dotted dep: '.' does not regex-match an unrelated branch — STATUS blocked" \
  "$(field "$out" STATUS)" "blocked"
contains "dotted dep: GAP names the real (unmerged) predecessor" "$out" "plan-a.b"
rm -rf "$FAKEBIN"

git checkout -q main

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
