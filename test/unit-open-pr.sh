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

# ===========================================================================
# S3: an unattended run opens a draft unless the envelope grants merging.
# Unattended: the server image's marker (a copy of the scripts whose
# SERVER_MARKER points at a sandbox file), or DEVLEAD_GUARD=1 from a launcher.
# This gh answers the default-branch question envelope.sh asks ("main").
# ===========================================================================
S3BIN="$SANDBOX/s3bin"
mkdir -p "$S3BIN"
cat > "$S3BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") echo main; exit 0 ;;
esac
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$GH_LOG"
echo "https://example.test/acme/repo/pull/7"
EOF
chmod +x "$S3BIN/gh"
SRV="$SANDBOX/srv"
mkdir -p "$SRV/.devlead" "$SRV/.claude"
cp -r "$REPO_ROOT/.devlead/scripts" "$SRV/.devlead/scripts"
cp -r "$REPO_ROOT/.claude/hooks" "$SRV/.claude/hooks"
MARKER="$SANDBOX/server-mode"
check "open-pr.sh has the fixed path SERVER_MARKER" "$(grep -c '^SERVER_MARKER=' "$SRV/.devlead/scripts/open-pr.sh")" "1"
sed -i "s|^SERVER_MARKER=.*|SERVER_MARKER=$MARKER|" "$SRV/.devlead/scripts/open-pr.sh"
# s3_door <door> <env...> -- <args...>: OUT, RC; the pr create call in CREATE.
s3_door() {
  local door="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  : > "$GH_LOG"
  OUT="$(env "${envs[@]}" HOME="$FAKE_HOME" XDG_CACHE_HOME="$FAKE_CACHE" GH_LOG="$GH_LOG" \
    PATH="$S3BIN:$PATH" bash "$door" "$@" 2>"$SANDBOX/s3.err")"; RC=$?
  CREATE="$(grep $'^CALL\tpr\tcreate' "$GH_LOG")"
}
# envelope_yml <merge.mode> — a valid envelope granting or not.
envelope_yml() {
  printf '%s\n' 'version: 1' 'enabled: true' 'select: {bucket: nuevo-entrante, exclude_labels: [x], require_readiness: true}' \
    'order: {by: [priority-label, created-asc]}' 'budget: {max_issues: 3, stop_at: null}' \
    'base: {strategy: nearest-tag, integration_branch: dev}' 'forbidden_zones: inherit' \
    'on_failure: {policy: park-and-continue, skip_dependents: true}' "merge: {mode: $1}" 'report: {to: journal-per-repo}'
}
DRAFT_CALL="$(printf 'CALL\tpr\tcreate\t--base\tmain\t--head\tfeat/unit\t--title\tt\t--body\t\t--draft')"
READY_CALL="$(printf 'CALL\tpr\tcreate\t--base\tmain\t--head\tfeat/unit\t--title\tt\t--body\t')"

# The envelope is committed on origin's main and the feature branch is cut
# from it; envelope_on_origin replaces what origin holds.
envelope_on_origin() {
  local here; here="$(git symbolic-ref --short HEAD)"
  git checkout -q main && mkdir -p .devlead && envelope_yml "$1" > .devlead/envelope.yml
  git add .devlead/envelope.yml && git commit -q -m "envelope $1" && git push -q origin main 2>/dev/null
  git checkout -q "$here"
}
# on_branch <merge.mode> — the envelope as the feature branch commits it.
on_branch() { mkdir -p .devlead && envelope_yml "$1" > .devlead/envelope.yml && git add .devlead/envelope.yml && git commit -q -m "envelope $1 on the branch"; }
mk_repo s3
envelope_on_origin never
git rebase -q main 2>/dev/null
commit_file notes.txt "a harmless change"

# --- interactive host: exactly as asked, whatever the envelope says ---------
s3_door "$OPEN_PR_SH" -u DEVLEAD_GUARD -- --base main --title t
check "S3 interactive, merge.mode never: exit 0" "$RC" "0"
check "S3 interactive: the PR opens as asked (no --draft added)" "$CREATE" "$READY_CALL"
check "S3 interactive: stdout is the PR URL" "$OUT" "https://example.test/acme/repo/pull/7"

# --- host launcher (DEVLEAD_GUARD=1): the working tree's envelope decides ---
s3_door "$OPEN_PR_SH" DEVLEAD_GUARD=1 -- --base main --title t
check "S3 unattended host, never: exit 0" "$RC" "0"
check "S3 unattended host, never: draft" "$CREATE" "$DRAFT_CALL"
check "S3 unattended host, never: stdout is still only the PR URL" "$OUT" "https://example.test/acme/repo/pull/7"
contains "S3 unattended host, never: says why on stderr" "$(cat "$SANDBOX/s3.err")" "the PR opens as a draft"
on_branch integration-branch
s3_door "$OPEN_PR_SH" DEVLEAD_GUARD=1 -- --base main --title t
check "S3 unattended host, merge granted: no draft" "$CREATE" "$READY_CALL"
s3_door "$OPEN_PR_SH" DEVLEAD_GUARD=1 -- --base main --title t --draft
check "S3 unattended host, merge granted, --draft asked: still a draft" "$CREATE" "$DRAFT_CALL"
git rm -q .devlead/envelope.yml && git commit -q -m "no envelope"
s3_door "$OPEN_PR_SH" DEVLEAD_GUARD=1 -- --base main --title t
check "S3 unattended host, no envelope: draft" "$CREATE" "$DRAFT_CALL"

# --- server: origin's envelope decides, never the working tree --------------
touch "$MARKER"
on_branch integration-branch
s3_door "$SRV/.devlead/scripts/open-pr.sh" -u DEVLEAD_GUARD -- --base main --title t
check "S3 server, origin never, working tree rewritten to grant: exit 0" "$RC" "0"
check "S3 server, origin never, working tree rewritten to grant: draft" "$CREATE" "$DRAFT_CALL"
envelope_on_origin integration-branch
on_branch never
s3_door "$SRV/.devlead/scripts/open-pr.sh" -u DEVLEAD_GUARD -- --base main --title t
check "S3 server, origin grants: no draft" "$CREATE" "$READY_CALL"
git remote set-url origin "$SANDBOX/gone.git"
s3_door "$SRV/.devlead/scripts/open-pr.sh" -u DEVLEAD_GUARD -- --base main --title t
check "S3 server, origin cannot be fetched: draft" "$CREATE" "$DRAFT_CALL"
git remote set-url origin "$SANDBOX/s3-origin.git"
rm -f "$MARKER"
s3_door "$SRV/.devlead/scripts/open-pr.sh" -u DEVLEAD_GUARD -- --base main --title t
check "S3 copy without the marker, interactive: as asked" "$CREATE" "$READY_CALL"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
