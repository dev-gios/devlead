#!/usr/bin/env bash
# unit-open-pr.sh — coverage for .devlead/scripts/open-pr.sh
#
#   bash test/unit-open-pr.sh
#
# open-pr.sh is the single door through which the pipeline opens a PR: it runs
# the full gate and the forbidden-zone check, and only then calls
# `gh pr create`. These tests pin the property that matters when no human is
# watching: a red gate or a forbidden zone means `gh pr create` is NEVER
# invoked, and the exact reason comes back on stdout.
#
# The REAL gate-check.sh and forbidden-check.sh run here (repo layout); only
# `gh` is faked.
#
# SAFETY: every scenario runs inside a throwaway /tmp git sandbox with bare
# local "origin" remotes. $HOME and $XDG_CACHE_HOME point at sandbox paths, so
# no session registry, no test-result cache and no real `gh` are ever touched.
# No DevLead session is registered anywhere: that is the autonomous path.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OPEN_PR_SH="$REPO_ROOT/.devlead/scripts/open-pr.sh"
SANDBOX="$(mktemp -d /tmp/devlead-open-pr.XXXXXX)"
FAKE_HOME="$SANDBOX/home"
FAKE_CACHE="$SANDBOX/cache"
FAKEBIN="$SANDBOX/fakebin"
GH_LOG="$SANDBOX/gh.log"
mkdir -p "$FAKE_HOME" "$FAKE_CACHE" "$FAKEBIN"

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

# Fake gh: logs one line per invocation (one argument per tab-separated field)
# and, for `pr create`, prints a PR URL. FAKE_GH_RC overrides the exit code.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CALL'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$GH_LOG"
if [[ "${FAKE_GH_RC:-0}" != "0" ]]; then
  echo "fake gh: permission denied" >&2
  exit "$FAKE_GH_RC"
fi
echo "https://example.test/acme/repo/pull/7"
EOF
chmod +x "$FAKEBIN/gh"

gh_calls() {
  if [[ -f "$GH_LOG" ]]; then wc -l < "$GH_LOG" | tr -d ' '; else echo 0; fi
}

# mk_repo <name> — bare "origin" + clone with one commit on main (pushed, with
# origin/HEAD set), then a feature branch checked out with nothing on it yet.
mk_repo() {
  local name="$1"
  git init -q --bare "$SANDBOX/${name}-origin.git"
  git clone -q "$SANDBOX/${name}-origin.git" "$SANDBOX/$name" 2>/dev/null
  cd "$SANDBOX/$name" || exit 1
  git config user.email smoke@example.com
  git config user.name "Smoke Test"
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git push -q -u origin main 2>/dev/null
  git remote set-head origin main 2>/dev/null
  git checkout -q -b feat/unit
  : > "$GH_LOG"
}

# commit_file <path> <content> — one committed change on the current branch.
commit_file() {
  mkdir -p "$(dirname "$1")"
  echo "$2" > "$1"
  git add "$1"
  git commit -q -m "add $1"
}

# run_door <args...> — invoke the door from the current repo, isolated.
run_door() {
  HOME="$FAKE_HOME" XDG_CACHE_HOME="$FAKE_CACHE" GH_LOG="$GH_LOG" \
    PATH="$FAKEBIN:$PATH" bash "$OPEN_PR_SH" "$@"
}

# ===========================================================================
# All green -> gh pr create runs exactly once, arguments intact
# ===========================================================================
mk_repo green
commit_file notes.txt "a harmless change"
out="$(run_door --base main --title "feat: a title with spaces" --body "Closes #7" 2>/dev/null)"
rc=$?
check "green: exit 0" "$rc" "0"
check "green: gh invoked exactly once" "$(gh_calls)" "1"
check "green: gh gets the door's own argument list, values intact" "$(cat "$GH_LOG")" \
  "$(printf 'CALL\tpr\tcreate\t--base\tmain\t--head\tfeat/unit\t--title\tfeat: a title with spaces\t--body\tCloses #7')"
check "green: stdout is the PR URL and nothing else" "$out" \
  "https://example.test/acme/repo/pull/7"

# --- the --base=<branch> spelling resolves the same way ---------------------
: > "$GH_LOG"
out="$(run_door --base=main --title t 2>/dev/null)"
rc=$?
check "green, --base=main form: exit 0" "$rc" "0"
check "green, --base=main form: gh invoked once" "$(gh_calls)" "1"

# ===========================================================================
# Red gate -> gh never runs, the gate's own words come back verbatim
# ===========================================================================
mk_repo dirty
commit_file notes.txt "a harmless change"
echo "uncommitted" >> notes.txt
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "red gate: exit 2" "$rc" "2"
check "red gate: gh never invoked" "$(gh_calls)" "0"
contains "red gate: reason is prefixed" "$out" "PARK_REASON: "
contains "red gate: reason carries the gate's own text" "$out" "Uncommitted changes:"
contains "red gate: reason names the dirty file" "$out" "notes.txt"

# --- the gate's escape hatch does not open this door -------------------------
out="$(DEVLEAD_FORCE_CLOSE=1 run_door --base main --title t 2>/dev/null)"
rc=$?
check "red gate + DEVLEAD_FORCE_CLOSE=1: still exit 2" "$rc" "2"
check "red gate + DEVLEAD_FORCE_CLOSE=1: gh never invoked" "$(gh_calls)" "0"

# ===========================================================================
# Forbidden zone in the diff -> gh never runs, the zone is named
# ===========================================================================
mk_repo zone
commit_file db/migrations/001_init.sql "create table t (id int);"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "forbidden zone: exit 2" "$rc" "2"
check "forbidden zone: gh never invoked" "$(gh_calls)" "0"
contains "forbidden zone: reason names the zone" "$out" "PARK_REASON: forbidden-zone: db-migrations"
contains "forbidden zone: reason names the path" "$out" "db/migrations/001_init.sql"

# --- both checks red -> both reasons reported (no short-circuit) -------------
echo "uncommitted" >> seed.txt
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "both red: exit 2" "$rc" "2"
check "both red: gh never invoked" "$(gh_calls)" "0"
contains "both red: gate reason present" "$out" "Uncommitted changes:"
contains "both red: zone reason present" "$out" "forbidden-zone: db-migrations"

# ===========================================================================
# The zone check must see every path the branch touches, however git would
# abbreviate or quote it
# ===========================================================================

# --- renaming a file OUT of a zone still touches the zone --------------------
mk_repo rename
git checkout -q main
commit_file .github/workflows/ci.yml "name: ci"
git push -q origin main 2>/dev/null
git checkout -q feat/unit
git merge -q --ff-only main
git mv .github/workflows/ci.yml disabled-ci.yml
git commit -q -m "move the workflow out of its directory"
: > "$GH_LOG"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "rename out of a zone: exit 2" "$rc" "2"
check "rename out of a zone: gh never invoked" "$(gh_calls)" "0"
contains "rename out of a zone: reason names the zone" "$out" "PARK_REASON: forbidden-zone: ci-cd"

# --- a non-ASCII name must not hide its extension behind git's quoting -------
mk_repo quoting
commit_file "esquema-migración.sql" "create table t (id int);"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "non-ASCII forbidden path: exit 2" "$rc" "2"
check "non-ASCII forbidden path: gh never invoked" "$(gh_calls)" "0"
contains "non-ASCII forbidden path: reason names the zone" "$out" "forbidden-zone: db-migrations"

# --- same for a name git quotes even with quotepath off (a TAB) --------------
mk_repo tabname
commit_file "$(printf 'infra\tprod.tf')" "resource {}"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "TAB in a forbidden path: exit 2" "$rc" "2"
check "TAB in a forbidden path: gh never invoked" "$(gh_calls)" "0"

# ===========================================================================
# The gate is judged from the repo root, wherever the caller happens to stand
# ===========================================================================
mk_repo subdir
cat > Makefile <<'EOF'
.PHONY: test
test:
	@echo "suite is red"
	@exit 1
EOF
git add Makefile
git commit -q -m "add a failing test target"
commit_file pkg/notes.txt "a harmless change"
cd pkg || exit 1
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "red tests, called from a subdirectory: exit 2" "$rc" "2"
check "red tests, called from a subdirectory: gh never invoked" "$(gh_calls)" "0"
contains "red tests, called from a subdirectory: runner output reported" "$out" "suite is red"

# ===========================================================================
# The PR must be for the work that was checked
# ===========================================================================
mk_repo closedlist
commit_file notes.txt "a harmless change"
# Every spelling gh would accept for "another repo / head / base" is refused:
# the door takes a closed list of options and names the head itself.
for spelling in "--repo other/repo" "-R other/repo" "-Rother/repo" "-R=other/repo" \
                "-dRother/repo" "--head feat/x" "-Hfeat/x" "-Bother" "--fill" "extra"; do
  : > "$GH_LOG"
  # shellcheck disable=SC2086  # word-splitting the spelling is the point
  out="$(run_door --base main --title t $spelling 2>/dev/null)"
  rc=$?
  check "unsupported [$spelling]: exit 2" "$rc" "2"
  check "unsupported [$spelling]: gh never invoked" "$(gh_calls)" "0"
  contains "unsupported [$spelling]: reason says so" "$out" "PARK_REASON: open-pr: unsupported argument: "
done

: > "$GH_LOG"
out="$(run_door --base=main --title=t --label a --label=b --draft 2>/dev/null)"
rc=$?
check "labels + draft: exit 0" "$rc" "0"
check "labels + draft: forwarded in the door's order" "$(cat "$GH_LOG")" \
  "$(printf 'CALL\tpr\tcreate\t--base\tmain\t--head\tfeat/unit\t--title\tt\t--body\t\t--label\ta\t--label\tb\t--draft')"

git checkout -q --detach
: > "$GH_LOG"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "detached HEAD: exit 2" "$rc" "2"
check "detached HEAD: gh never invoked" "$(gh_calls)" "0"

# ===========================================================================
# Nothing to ship -> fail closed
# ===========================================================================
mk_repo empty
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "empty diff vs base: exit 2" "$rc" "2"
check "empty diff vs base: gh never invoked" "$(gh_calls)" "0"
contains "empty diff vs base: reason says so" "$out" "PARK_REASON: empty-diff"

# ===========================================================================
# The base must be known and resolvable -> otherwise fail closed
# ===========================================================================
mk_repo nobase
commit_file notes.txt "a harmless change"
out="$(run_door --title t 2>/dev/null)"
rc=$?
check "missing --base: exit 1" "$rc" "1"
check "missing --base: gh never invoked" "$(gh_calls)" "0"
contains "missing --base: reason says so" "$out" "PARK_REASON: "

out="$(run_door --base no-such-branch --title t 2>/dev/null)"
rc=$?
check "unresolvable --base: exit 2" "$rc" "2"
check "unresolvable --base: gh never invoked" "$(gh_calls)" "0"
contains "unresolvable --base: reason names the branch" "$out" "no-such-branch"

# --- outside a git repo ------------------------------------------------------
mkdir -p "$SANDBOX/not-a-repo"
cd "$SANDBOX/not-a-repo" || exit 1
: > "$GH_LOG"
out="$(run_door --base main --title t 2>/dev/null)"
rc=$?
check "not a git repo: exit 2" "$rc" "2"
check "not a git repo: gh never invoked" "$(gh_calls)" "0"

# ===========================================================================
# gh itself fails after green gates -> non-zero, reason reported, one attempt
# ===========================================================================
mk_repo ghfail
commit_file notes.txt "a harmless change"
out="$(FAKE_GH_RC=4 run_door --base main --title t 2>/dev/null)"
rc=$?
check "gh failure: exit code is gh's" "$rc" "4"
check "gh failure: exactly one attempt, no retry" "$(gh_calls)" "1"
contains "gh failure: reason reported" "$out" "PARK_REASON: gh pr create failed (exit 4)"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
