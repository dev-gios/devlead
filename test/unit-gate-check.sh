#!/usr/bin/env bash
# unit-gate-check.sh — regression coverage for .claude/hooks/gate-check.sh
#
#   bash test/unit-gate-check.sh
#
# Covers:
#   - _resolve_base_branch's fallback order (origin/HEAD -> main -> master -> failure)
#   - FIX 1 regression: _check_shellcheck must never silently inspect ZERO
#     files when no integration branch can be resolved — it must fall back to
#     running shellcheck on every tracked .sh file, mirroring _check_tests'
#     existing "cannot prove scope -> run everything" fallback.
#   - the shellcheck gate still fails correctly when a base DOES resolve
#   - the test gate's existing "no changes vs base" skip is untouched
#
# SAFETY: every scenario runs inside a throwaway /tmp git sandbox (bare local
# "origin" remotes, never a real network remote). $HOME and $XDG_CACHE_HOME
# are both overridden to sandbox paths for every gate-check.sh invocation, so
# the DevLead opt-in marker (~/.devlead/active-repos) and the test-runner
# result cache never touch the real machine's $HOME or ~/.cache.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
GATE_SH="$REPO_ROOT/.claude/hooks/gate-check.sh"
DEVLEAD_ACTIVE_SH="$REPO_ROOT/.devlead/scripts/devlead-active.sh"
SANDBOX="$(mktemp -d /tmp/devlead-gate-check.XXXXXX)"

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

# ---------------------------------------------------------------------------
# Extract _resolve_base_branch VERBATIM from the real script (never a
# hand-rolled reimplementation) so this test stays honest as the function
# evolves. gate-check.sh has no library-mode guard — sourcing it wholesale
# would run the entire gate immediately — so we eval only the one function.
# ---------------------------------------------------------------------------
_fn_src="$(awk '/^_resolve_base_branch\(\) \{/,/^}/' "$GATE_SH")"
if [[ -z "$_fn_src" ]]; then
  echo "FATAL: could not extract _resolve_base_branch from $GATE_SH"
  exit 1
fi
eval "$_fn_src"

# mk_repo <name> <branch> — bare "origin" + working clone seeded with one
# commit on <branch>, pushed to origin. No remote HEAD symref by default
# (git does not set one automatically on first push to a fresh bare repo).
mk_repo() {
  local name="$1" branch="$2"
  git init -q --bare "$SANDBOX/${name}-origin.git"
  git clone -q "$SANDBOX/${name}-origin.git" "$SANDBOX/$name" 2>/dev/null
  cd "$SANDBOX/$name" || exit 1
  git config user.email smoke@example.com
  git config user.name "Smoke Test"
  git checkout -q -b "$branch"
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git push -q -u origin "$branch" 2>/dev/null
}

# activate_devlead <repo-dir> <sandbox-home> — makes gate-check.sh's opt-in
# guard treat <repo-dir> as DevLead-active under an isolated $HOME, so the
# full gate actually runs instead of the guard's silent exit 0.
activate_devlead() {
  local repo="$1" home="$2"
  mkdir -p "$home/.devlead/scripts"
  cp "$DEVLEAD_ACTIVE_SH" "$home/.devlead/scripts/devlead-active.sh"
  local root
  root="$(git -C "$repo" rev-parse --show-toplevel)"
  printf '%s\t%s\n' "$root" "$(date -u +%s)" > "$home/.devlead/active-repos"
}

# run_gate <repo-dir> <sandbox-home> <cache-dir> — the one true way to invoke
# the full gate in these tests: empty stdin (explicit-call path, not the
# Stop-hook path), isolated $HOME (opt-in marker) and $XDG_CACHE_HOME (test
# result cache), cwd = the repo under test.
run_gate() {
  local repo="$1" home="$2" cache="$3"
  (
    cd "$repo" || exit 1
    HOME="$home" XDG_CACHE_HOME="$cache" bash "$GATE_SH" </dev/null
  )
}

# ===========================================================================
# _resolve_base_branch — fallback order
# ===========================================================================

# --- origin/HEAD's target, when a local branch of that name also exists ----
mk_repo resolve-origin release-line
git remote set-head origin release-line 2>/dev/null
out="$(_resolve_base_branch)"
check "picks origin/HEAD's target when present" "$out" "release-line"

# --- no origin/HEAD symref -> falls back to local 'main' -------------------
mk_repo resolve-main main
out="$(_resolve_base_branch)"
check "falls back to local 'main' when origin/HEAD unresolved" "$out" "main"

# --- no origin/HEAD, no 'main' -> falls back to local 'master' -------------
mk_repo resolve-master master
out="$(_resolve_base_branch)"
check "falls back to local 'master' when neither origin/HEAD nor main exist" "$out" "master"

# --- none of the three resolve -> failure, no stdout ------------------------
mk_repo resolve-none trunk
out="$(_resolve_base_branch)"
rc=$?
check "returns failure when no candidate resolves" "$rc" "1"
check "prints nothing on failure" "$out" ""

# ===========================================================================
# FIX 1 regression: unresolved base must never leave the shellcheck gate
# inspecting zero files.
# ===========================================================================

# Repro from the fix report: only a 'trunk' branch, no origin/HEAD, no main,
# no master — _resolve_base_branch fails — plus a COMMITTED .sh file with a
# real shellcheck warning (SC2164). Before the fix, the third source of
# _sh_files was skipped when the base was empty, and since the pipeline
# already committed the work, the other two sources (uncommitted diffs) were
# empty too — the gate inspected NOTHING and reported clean.
mk_repo fix1-repro trunk
cat > offender.sh <<'EOF'
#!/usr/bin/env bash
cd /nonexistent
echo hi
EOF
git add offender.sh
git commit -q -m "add offender.sh (SC2164)"

FIX1_HOME="$(mktemp -d /tmp/devlead-gate-check-home.XXXXXX)"
FIX1_CACHE="$(mktemp -d /tmp/devlead-gate-check-cache.XXXXXX)"
activate_devlead "$SANDBOX/fix1-repro" "$FIX1_HOME"
out="$(run_gate "$SANDBOX/fix1-repro" "$FIX1_HOME" "$FIX1_CACHE" 2>&1)"
rc=$?
check "FIX 1: unresolved-base repo with a real shellcheck offender FAILS the gate" "$rc" "2"
contains "FIX 1: failure names the offending file" "$out" "offender.sh"
contains "FIX 1: gate explains it fell back to all tracked .sh files" \
  "$out" "shellchecking all tracked .sh files"
rm -rf "$FIX1_HOME" "$FIX1_CACHE"

# ===========================================================================
# With a resolvable base, a dirty .sh file (vs base) still fails the gate.
# ===========================================================================
mk_repo fix1-resolved-dirty main
git remote set-head origin main 2>/dev/null
git checkout -q -b feat/dirty-sh
cat > offender.sh <<'EOF'
#!/usr/bin/env bash
cd /nonexistent
echo hi
EOF
git add offender.sh
git commit -q -m "add offender.sh (SC2164) on feature branch"

DIRTY_HOME="$(mktemp -d /tmp/devlead-gate-check-home.XXXXXX)"
DIRTY_CACHE="$(mktemp -d /tmp/devlead-gate-check-cache.XXXXXX)"
activate_devlead "$SANDBOX/fix1-resolved-dirty" "$DIRTY_HOME"
out="$(run_gate "$SANDBOX/fix1-resolved-dirty" "$DIRTY_HOME" "$DIRTY_CACHE" 2>&1)"
rc=$?
check "resolvable base: dirty .sh vs base still fails the gate" "$rc" "2"
contains "resolvable base: failure names the offending file" "$out" "offender.sh"
rm -rf "$DIRTY_HOME" "$DIRTY_CACHE"

# ===========================================================================
# Clean tree, no changes vs base -> test gate skips (existing behaviour,
# untouched by FIX 1). Uses a Makefile so _check_tests reaches the "no
# changes vs base" skip instead of short-circuiting on "no runner detected".
# ===========================================================================
mk_repo clean-skip main
git remote set-head origin main 2>/dev/null
cat > Makefile <<'EOF'
.PHONY: test
test:
	@echo "should never run in this scenario"
	@exit 1
EOF
git add Makefile
git commit -q -m "add Makefile with a test target that must not run here"

CLEAN_HOME="$(mktemp -d /tmp/devlead-gate-check-home.XXXXXX)"
CLEAN_CACHE="$(mktemp -d /tmp/devlead-gate-check-cache.XXXXXX)"
activate_devlead "$SANDBOX/clean-skip" "$CLEAN_HOME"
out="$(run_gate "$SANDBOX/clean-skip" "$CLEAN_HOME" "$CLEAN_CACHE" 2>&1)"
rc=$?
check "clean tree, no changes vs base: gate passes" "$rc" "0"
contains "clean tree: test gate reports 'no changes vs' skip" "$out" "no changes vs"
rm -rf "$CLEAN_HOME" "$CLEAN_CACHE"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
