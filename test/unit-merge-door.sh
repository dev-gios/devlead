#!/usr/bin/env bash
# unit-merge-door.sh — coverage for .devlead/scripts/merge.sh
#
#   bash test/unit-merge-door.sh
#
# merge.sh is the single door through which the pipeline merges a PR. Its
# authority comes from the repo's envelope and nowhere else (GOVERNANCE.md
# §A3): these tests pin that `gh pr merge` is NEVER invoked without an envelope
# that grants `merge.mode: integration-branch`, nor for a PR whose base is not
# `base.integration_branch`.
#
# The REAL envelope.sh runs here; only `gh` is faked.
#
# SAFETY: throwaway /tmp git sandbox with a bare local "origin"; $HOME points
# at a sandbox path; no real `gh` is ever called.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
MERGE_SH="$REPO_ROOT/.devlead/scripts/merge.sh"
SANDBOX="$(mktemp -d /tmp/devlead-merge-door.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
FAKE_HOME="$SANDBOX/home"
FAKEBIN="$SANDBOX/fakebin"
GH_LOG="$SANDBOX/gh.log"
mkdir -p "$FAKE_HOME" "$FAKEBIN"

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

# Fake gh. The remote's default branch is "main". `pr view` reports the PR's
# base (FAKE_PR_BASE) and state (FAKE_PR_STATE); only `pr merge` is logged.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view")
    [[ "${FAKE_REPO_VIEW_RC:-0}" == "0" ]] || exit "$FAKE_REPO_VIEW_RC"
    echo "${FAKE_DEFAULT_BRANCH:-main}"; exit 0 ;;
  "pr view")
    [[ "${FAKE_PR_VIEW_RC:-0}" == "0" ]] || { echo "fake gh: no such PR" >&2; exit "$FAKE_PR_VIEW_RC"; }
    echo "fake gh: a warning nobody asked for" >&2
    printf '%s\t%s\t%s\n' "${FAKE_PR_BASE:-}" "${FAKE_PR_STATE:-OPEN}" \
      "${FAKE_PR_URL:-https://example.test/acme/repo/pull/7}"
    exit 0 ;;
  "pr merge")
    { printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$GH_LOG"
    [[ -z "${GH_REPO:-}${GH_HOST:-}" ]] || echo "LEAK GH_REPO/GH_HOST reached gh" >> "$GH_LOG"
    if [[ "${FAKE_MERGE_RC:-0}" != "0" ]]; then
      echo "fake gh: merge conflict" >&2
      exit "$FAKE_MERGE_RC"
    fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/gh"

merge_calls() {
  if [[ -f "$GH_LOG" ]]; then wc -l < "$GH_LOG" | tr -d ' '; else echo 0; fi
}

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

# write_envelope <base-extra-line> <merge.mode>
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

# run_door <args...> — FAKE_* variables set by the caller pass through.
run_door() {
  : > "$GH_LOG"
  HOME="$FAKE_HOME" GH_LOG="$GH_LOG" PATH="$FAKEBIN:$PATH" bash "$MERGE_SH" "$@"
}

# refused <label> <expected-substring> <args...> — the door must exit 2, never
# call `gh pr merge`, and explain itself on stdout.
refused() {
  local label="$1" needle="$2" out rc
  shift 2
  out="$(run_door "$@" 2>/dev/null)"
  rc=$?
  check "$label: exit 2" "$rc" "2"
  check "$label: gh pr merge never invoked" "$(merge_calls)" "0"
  contains "$label: reason" "$out" "PARK_REASON: $needle"
}

# ===========================================================================
# No authority -> no merge
# ===========================================================================
rm -f .devlead/envelope.yml
FAKE_PR_BASE=dev refused "no envelope" "merge refused: envelope blocked" 7

write_envelope "  integration_branch: dev" "never"
FAKE_PR_BASE=dev refused "merge.mode never" "merge refused: merge.mode is 'never'" 7

write_envelope "  integration_branch: dev" "default-branch"
FAKE_PR_BASE=dev refused "reserved default-branch mode" "merge refused: envelope blocked" 7

write_envelope "  integration_branch: main" "integration-branch"
FAKE_PR_BASE=main refused "integration branch is the default branch" \
  "merge refused: envelope blocked" 7

# ===========================================================================
# Authority granted -> only PRs into the integration branch
# ===========================================================================
write_envelope "  integration_branch: dev" "integration-branch"

out="$(FAKE_PR_BASE=dev run_door 7 2>/dev/null)"
rc=$?
check "granted, PR into the integration branch: exit 0" "$rc" "0"
check "granted: gh pr merge invoked exactly once" "$(merge_calls)" "1"
check "granted: exact gh call" "$(cat "$GH_LOG")" "$(printf 'CALL\tpr\tmerge\t7\t--merge')"

out="$(FAKE_PR_BASE=dev run_door https://example.test/acme/repo/pull/7 2>/dev/null)"
rc=$?
check "granted, PR given as URL: exit 0" "$rc" "0"
check "granted, PR given as URL: gh gets the PR number" "$(cat "$GH_LOG")" \
  "$(printf 'CALL\tpr\tmerge\t7\t--merge')"

FAKE_PR_BASE=main refused "PR into the default branch" \
  "merge refused: PR #7 targets 'main', not the integration branch 'dev'" 7
FAKE_PR_BASE=release refused "PR into some other branch" \
  "merge refused: PR #7 targets 'release', not the integration branch 'dev'" 7
FAKE_PR_BASE=dev FAKE_PR_STATE=CLOSED refused "PR is not open" \
  "merge refused: PR #7 is CLOSED" 7
FAKE_PR_VIEW_RC=1 refused "PR cannot be read" "merge refused: cannot read PR #7" 7

out="$(FAKE_PR_BASE=dev run_door https://example.test/acme/repo/pull/7/ 2>/dev/null)"
check "granted, URL with trailing slash: exit 0" "$?" "0"
FAKE_PR_BASE=dev refused "URL of another repository" \
  "merge refused: https://evil.example/other/repo/pull/7 is not PR #7 of this repository" \
  https://evil.example/other/repo/pull/7

out="$(FAKE_PR_BASE=dev run_door 007 2>/dev/null)"
check "leading zeros are normalised before reaching gh" "$(cat "$GH_LOG")" \
  "$(printf 'CALL\tpr\tmerge\t7\t--merge')"

out="$(GH_REPO=other/repo GH_HOST=evil.example FAKE_PR_BASE=dev run_door 7 2>/dev/null)"
check "GH_REPO / GH_HOST never reach gh" "$(cat "$GH_LOG")" \
  "$(printf 'CALL\tpr\tmerge\t7\t--merge')"

mkdir -p sub/dir
out="$(cd sub/dir && FAKE_PR_BASE=dev run_door 7 2>/dev/null)"
check "called from a subdirectory: the repo's envelope still decides (exit 0)" "$?" "0"
write_envelope "  integration_branch: dev" "never"
out="$(cd sub/dir && FAKE_PR_BASE=dev run_door 7 2>/dev/null)"
check "called from a subdirectory with merge.mode never: exit 2" "$?" "2"
write_envelope "  integration_branch: dev" "integration-branch"

# --- the trunk is asked of the remote at merge time; no answer, no merge ----
FAKE_PR_BASE=dev FAKE_REPO_VIEW_RC=1 refused "remote default branch cannot be asked" \
  "merge refused: cannot ask the remote for its default branch" 7
# A stale local symref says "main"; the remote's real default is now "dev".
# envelope.sh's own gh lookup is made to fail (auth down) so it falls back to
# the symref and approves — the door must still refuse.
cat > "$FAKEBIN/gh-authdown" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "auth status" ]] && exit 1
exec "$(dirname "$0")/gh.real" "$@"
EOF
cp "$FAKEBIN/gh" "$FAKEBIN/gh.real"
cp "$FAKEBIN/gh-authdown" "$FAKEBIN/gh"
chmod +x "$FAKEBIN/gh"
FAKE_PR_BASE=dev FAKE_DEFAULT_BRANCH=dev refused "stale symref, remote default is the integration branch" \
  "merge refused: the integration branch 'dev' is the remote's default branch" 7
cp "$FAKEBIN/gh.real" "$FAKEBIN/gh"

# --- a null integration branch, however it is spelled, grants nothing --------
for null in "~" "null" "Null" "NULL" '""'; do
  write_envelope "  integration_branch: $null" "integration-branch"
  FAKE_PR_BASE=dev FAKE_DEFAULT_BRANCH=dev refused "integration_branch: $null" \
    "merge refused: envelope blocked" 7
  FAKE_PR_BASE=dev refused "integration_branch: $null (default is main)" \
    "merge refused: envelope blocked" 7
done
write_envelope "  integration_branch: dev" "integration-branch"

# ===========================================================================
# Closed interface: one PR reference, nothing else
# ===========================================================================
for bad in "--admin" "7 --admin" "7 --squash" "-R other/repo 7" "7 8" "feature-branch" "-7" \
           "７" "1234567890" "x7" "7x" "https://example.test/acme/repo/pull/7/files" \
           "xhttps://example.test/acme/repo/pull/7"; do
  # shellcheck disable=SC2086  # word-splitting the spelling is the point
  out="$(FAKE_PR_BASE=dev run_door $bad 2>/dev/null)"
  rc=$?
  check "bad arguments [$bad]: exit 1" "$rc" "1"
  check "bad arguments [$bad]: gh pr merge never invoked" "$(merge_calls)" "0"
done
out="$(FAKE_PR_BASE=dev run_door 2>/dev/null)"
check "no arguments: exit 1" "$?" "1"

# ===========================================================================
# gh fails -> one attempt, reason reported, gh's exit code
# ===========================================================================
out="$(FAKE_PR_BASE=dev FAKE_MERGE_RC=5 run_door 7 2>/dev/null)"
rc=$?
check "merge failure: exit code is gh's" "$rc" "5"
check "merge failure: exactly one attempt" "$(merge_calls)" "1"
contains "merge failure: gh's own words reported" "$out" "PARK_REASON: fake gh: merge conflict"

out="$(FAKE_PR_BASE=dev FAKE_PR_VIEW_RC=0 run_door 7 2>&1 >/dev/null)"
check "a warning on gh's stderr does not stop a valid merge" "$(merge_calls)" "1"

# ===========================================================================
# The door never writes the envelope
# ===========================================================================
before="$(sha256sum .devlead/envelope.yml)"
FAKE_PR_BASE=dev run_door 7 >/dev/null 2>&1
check "envelope untouched" "$(sha256sum .devlead/envelope.yml)" "$before"

# ===========================================================================
# Server mode (L21 A1): authority is the envelope committed on origin's
# default branch, fetched at merge time — never the clone's working tree.
# A copy of the scripts whose SERVER_MARKER points at a sandbox file.
# ===========================================================================
SRV="$SANDBOX/server-scripts"
cp -r "$REPO_ROOT/.devlead/scripts" "$SRV"
MARKER="$SANDBOX/server-mode"
check "merge.sh has the fixed path SERVER_MARKER" "$(grep -c '^SERVER_MARKER=' "$SRV/merge.sh")" "1"
sed -i "s|^SERVER_MARKER=.*|SERVER_MARKER=$MARKER|" "$SRV/merge.sh"
touch "$MARKER"
run_server() {
  : > "$GH_LOG"
  HOME="$FAKE_HOME" GH_LOG="$GH_LOG" PATH="$FAKEBIN:$PATH" bash "$SRV/merge.sh" "$@"
}
# srv_refused <label> <expected-substring> — as `refused`, through the copy.
srv_refused() {
  local out rc
  out="$(FAKE_PR_BASE=dev run_server 7 2>/dev/null)"; rc=$?
  check "server: $1: exit 2" "$rc" "2"
  check "server: $1: gh pr merge never invoked" "$(merge_calls)" "0"
  contains "server: $1: reason" "$out" "PARK_REASON: $2"
}
# on_origin <merge.mode> — commit an envelope to origin's default branch, then
# leave the working tree's copy as it was.
on_origin() {
  local keep; keep="$(cat .devlead/envelope.yml)"
  git checkout -q main
  write_envelope "  integration_branch: dev" "$1"
  git add .devlead/envelope.yml && git commit -q -m "envelope: $1" && git push -q origin main 2>/dev/null
  printf '%s\n' "$keep" > .devlead/envelope.yml
}

# The working tree grants merging; origin has no envelope at all.
write_envelope "  integration_branch: dev" "integration-branch"
srv_refused "no envelope on origin, the working tree grants" "merge refused: envelope blocked — no envelope.yml on origin's default branch 'main'"

on_origin never
write_envelope "  integration_branch: dev" "integration-branch"
srv_refused "origin says never, the working tree was rewritten to grant" "merge refused: merge.mode is 'never'"
check "server: the working tree's envelope is left as it is" "$(grep -c 'mode: integration-branch' .devlead/envelope.yml)" "1"

on_origin integration-branch
write_envelope "  integration_branch: dev" "never"
out="$(FAKE_PR_BASE=dev run_server 7 2>/dev/null)"; rc=$?
check "server: origin grants, the working tree says never: merged (exit 0)" "$rc" "0"
check "server: origin grants: exact gh call" "$(cat "$GH_LOG")" "$(printf 'CALL\tpr\tmerge\t7\t--merge')"

# A stale local origin/main still grants; origin itself was moved to never.
# The door fetches before it reads.
_stale="$(git rev-parse origin/main)"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
( cd "$SANDBOX/other" && git checkout -q main && sed -i 's/mode: integration-branch/mode: never/' .devlead/envelope.yml \
  && git -c user.email=t@t -c user.name=t commit -q -am "envelope: never" && git push -q origin main 2>/dev/null )
check "server: the local origin/main is stale before the merge" "$(git rev-parse origin/main)" "$_stale"
write_envelope "  integration_branch: dev" "integration-branch"
srv_refused "stale local origin/main grants, origin says never" "merge refused: merge.mode is 'never'"

# A replace ref planted in the clone cannot swap the blob read from origin.
git checkout -q -b fake origin/main
write_envelope "  integration_branch: dev" "integration-branch"
git add .devlead/envelope.yml && git commit -q -m "fake grant"
git replace "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
git checkout -q main
srv_refused "a planted refs/replace entry" "merge refused: merge.mode is 'never'"
git replace -d "$(git rev-parse origin/main)" >/dev/null

# An envelope on origin that does not validate refuses like any blocked one.
( cd "$SANDBOX/other" && git pull -q 2>/dev/null; echo "surprise: key" >> .devlead/envelope.yml \
  && git -c user.email=t@t -c user.name=t commit -q -am "envelope: invalid" && git push -q origin main 2>/dev/null )
srv_refused "invalid envelope on origin" "merge refused: envelope blocked — unknown top-level key 'surprise'"

# origin cannot be fetched: no answer, no merge.
git remote set-url origin "$SANDBOX/gone.git"
srv_refused "origin cannot be fetched" "merge refused: envelope blocked — cannot fetch origin's default branch 'main'"
git remote set-url origin "$SANDBOX/origin.git"

# GitHub cannot be asked (gh auth down) and the local origin/HEAD symref was
# pointed at a branch the session pushed with a granting envelope: the
# symref is never the answer in server mode, so no envelope, no merge.
git checkout -q -b grant main
write_envelope "  integration_branch: dev" "integration-branch"
git add .devlead/envelope.yml && git commit -q --allow-empty -m "a granting envelope on a pushed branch" && git push -q origin grant 2>/dev/null
git checkout -q main
git fetch -q origin 2>/dev/null
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/grant
cp "$FAKEBIN/gh-authdown" "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"
srv_refused "gh cannot answer, the symref points at a pushed granting branch" \
  "merge refused: envelope blocked — cannot ask GitHub for origin's default branch"
cp "$FAKEBIN/gh.real" "$FAKEBIN/gh"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# Without the marker the same copy reads the working tree, as on any host.
rm -f "$MARKER"
write_envelope "  integration_branch: dev" "integration-branch"
out="$(FAKE_PR_BASE=dev run_server 7 2>/dev/null)"; rc=$?
check "no server marker: the working tree's envelope decides (exit 0)" "$rc" "0"
write_envelope "  integration_branch: dev" "never"
out="$(FAKE_PR_BASE=dev run_server 7 2>/dev/null)"; rc=$?
check "no server marker: the working tree's never refuses (exit 2)" "$rc" "2"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
