#!/usr/bin/env bash
# unit-envelope-plan.sh — `envelope.sh plan` end to end against a fake GitHub
#
#   bash test/unit-envelope-plan.sh
#
# Runs the REAL envelope.sh (show + plan). Only its two data sources are
# replaced: `state.sh` is a fixture placed in the sandboxed $HOME (plan calls
# it there by absolute path) that renders the ASSIGNED_ISSUES/BRANCHES/OPEN_PRS
# sections from JSON fixtures, and `gh` is a fake on $PATH dispatched on its
# exact argument string, so every call plan makes is pinned.
#
# Pins:
#   - the assigned-only plan, byte for byte, as it was before the intake label
#     existed (no intake fields → same output, no extra GitHub calls);
#   - S5: issues carrying select.intake_label join the queue only when the
#     LATEST `labeled` event for that label came from an allowed login
#     (select.intake_labelers, or by default the authenticated gh user), and
#     go through the same checks, ordering and budget cut as assigned issues;
#     every lookup failure fails closed (`intake-label-unverified`);
#   - the `show` validation of both new fields.
#
# SAFETY: $HOME is a sandbox, the repo is a throwaway git repo under /tmp and
# `gh` never reaches the network.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ENVELOPE_SH="$REPO_ROOT/.devlead/scripts/envelope.sh"
SANDBOX="$(mktemp -d /tmp/devlead-envplan.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
FAKEBIN="$SANDBOX/fakebin"
FAKE_HOME="$SANDBOX/home"
FIX="$SANDBOX/fix"
GH_LOG="$SANDBOX/gh.log"
WORK="$SANDBOX/work"
export FIX GH_LOG
mkdir -p "$FAKEBIN" "$FAKE_HOME/.devlead/scripts" "$FIX"
unset GH_REPO GH_HOST GH_TOKEN FAKE_FAIL FAKE_ME

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

# --- Fixture state.sh: the three sections plan reads, from JSON fixtures ---
cat > "$FAKE_HOME/.devlead/scripts/state.sh" <<'EOF'
#!/usr/bin/env bash
echo "=== DEVLEAD STATE ==="
echo "--- BRANCHES ---"
cat "$FIX/branches.tsv" 2>/dev/null
echo ""
echo "--- OPEN_PRS ---"
echo ""
echo "--- ASSIGNED_ISSUES ---"
jq -r '.[] | [("#" + (.number | tostring)), .title,
  (if (.labels | length) == 0 then "" else [.labels[].name] | join(",") end),
  .updatedAt] | @tsv' "$FIX/assigned.json"
echo ""
echo "--- WARNINGS ---"
echo ""
echo "=== END ==="
EOF

# --- Fake gh: one arm per call shape plan makes; anything else is logged ---
# FAKE_FAIL is a space-separated list of call names that must fail.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
fail() { [[ " ${FAKE_FAIL:-} " == *" $1 "* ]]; }
case "$*" in
  "issue list --assignee @me --state open --limit 50 --json number,createdAt")
    fail created && exit 1
    jq '[.[] | {number, createdAt}]' "$FIX/assigned.json" ;;
  "issue list --assignee @me --state open --limit 50 --json number,body")
    fail body && exit 1
    jq '[.[] | {number, body}]' "$FIX/assigned.json" ;;
  "issue list --label "*" --state open --limit 50 --json number,title,labels,createdAt,updatedAt,body")
    fail intake && exit 1
    jq '.' "$FIX/intake.json" ;;
  "api user -q .login")
    [[ -z "${GH_REPO:-}${GH_HOST:-}" ]] || echo "LEAK GH_REPO/GH_HOST reached gh api user" >> "$GH_LOG"
    fail user && exit 1
    echo "${FAKE_ME-owner}" ;;
  "api repos/{owner}/{repo}/issues/"*"/events --paginate")
    n="${2#repos/\{owner\}/\{repo\}/issues/}"; n="${n%/events}"
    fail events && exit 1
    fail "events-$n" && exit 1
    cat "$FIX/events-$n.json" 2>/dev/null || echo "[]" ;;
  *) echo "UNEXPECTED: $*" >> "$GH_LOG"; exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh" "$FAKE_HOME/.devlead/scripts/state.sh"

# --- Sandbox repo -----------------------------------------------------------
git init -q "$WORK"
mkdir -p "$WORK/.devlead"
GIT_ROOT="$(cd "$WORK" && git rev-parse --show-toplevel)"

# issue <num> <title> <labels csv> <created date> <body> — one issue object.
issue() {
  jq -n --argjson n "$1" --arg t "$2" --arg l "$3" --arg c "${4}T00:00:00Z" --arg b "$5" \
    '{number: $n, title: $t, labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      createdAt: $c, updatedAt: $c, body: $b}'
}
assigned() { jq -s '.' > "$FIX/assigned.json"; }
intake() { jq -s '.' > "$FIX/intake.json"; }
# ev <event> <login> <label> <timestamp> — one issue event.
ev() {
  jq -n --arg e "$1" --arg a "$2" --arg l "$3" --arg c "$4" \
    '{event: $e, actor: {login: $a}, label: {name: $l}, created_at: $c}'
}
# events <num> — stdin event objects → one page of the events API.
events() { jq -s '.' > "$FIX/events-$1.json"; }

# write_envelope — knobs via env: EXCL READY MAX SELECT_EXTRA DISC
write_envelope() {
  {
    echo "version: 1"
    echo "enabled: true"
    echo "select:"
    echo "  bucket: nuevo-entrante"
    echo "  exclude_labels: ${EXCL:-[blocked, wip]}"
    echo "  require_readiness: ${READY:-true}"
    [[ -n "${SELECT_EXTRA:-}" ]] && printf '%s\n' "$SELECT_EXTRA"
    echo "order:"
    echo "  by: [priority-label, created-asc]"
    echo "budget:"
    echo "  max_issues: ${MAX:-3}"
    echo "  stop_at: null"
    echo "base:"
    echo "  strategy: nearest-tag"
    echo "forbidden_zones: inherit"
    echo "on_failure:"
    echo "  policy: park-and-continue"
    echo "  skip_dependents: true"
    echo "merge:"
    echo "  mode: never"
    echo "report:"
    echo "  to: journal-per-repo"
    [[ -n "${DISC:-}" ]] && printf '%s\n' "$DISC"
  } > "$WORK/.devlead/envelope.yml"
}

# run <subcommand> — sets OUT, ERR, RC; the gh log starts empty each run.
run() {
  : > "$GH_LOG"
  OUT="$(cd "$WORK" && HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" bash "$ENVELOPE_SH" "$1" 2>"$SANDBOX/stderr")"
  RC=$?
  ERR="$(cat "$SANDBOX/stderr")"
}
included() { printf '%s\n' "$OUT" | grep -E '^[0-9]+\. #[0-9]+  '; }
excluded_line() { printf '%s\n' "$OUT" | grep -E "^#$1  "; }

# Base fixture: six assigned issues covering every pre-existing exclusion.
base_fixture() {
  {
    issue 1 "Fix login" "bug" 2026-11-02 "Steps to reproduce"
    issue 2 "Add export" "p0" 2026-11-03 "Export to CSV"
    issue 3 "Docs: update guide" "" 2026-11-01 "Update the guide"
    issue 4 "WIP thing" "wip" 2026-11-04 "Later"
    issue 5 "Empty body" "" 2026-11-05 "   "
    issue 6 "Has branch" "" 2026-11-06 "Already started"
  } | assigned
  printf 'feat/issue-6-has-branch\t2026-11-06\t1\t0\n' > "$FIX/branches.tsv"
  echo "[]" > "$FIX/intake.json"
}

# ===========================================================================
# Previous behaviour: assigned-only plan, no intake fields
# ===========================================================================
base_fixture
MAX=2 write_envelope
run plan
expected="=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ===
ENVELOPE: $GIT_ROOT/.devlead/envelope.yml  ENABLED: true
DATA_SOURCES: state.sh(ASSIGNED_ISSUES,BRANCHES,OPEN_PRS); gh issue list(createdAt,body)
ORDER: priority-label,created-asc  MAX_ISSUES: 2  EXCLUDE_LABELS: blocked,wip  READINESS: true
FORBIDDEN_ZONES: inherit (labels-based pre-check only)

--- INCLUDED (queue order) ---
1. #2  Add export
   basis: tier=p0, created=2026-11-03, nuevo-entrante  [zone-check: pre-check only, labels-based]
2. #1  Fix login
   basis: tier=bug, created=2026-11-02, nuevo-entrante  [zone-check: pre-check only, labels-based]

--- EXCLUDED ---
#4  WIP thing   reason: excluded-label (wip)
#5  Empty body   reason: not-ready (empty body)
#6  Has branch   reason: not-nuevo-entrante (branch issue-6-* exists)
#3  \"Docs: update guide\"   reason: budget-cut (beyond max_issues=2)

=== END PLAN ==="
check "assigned-only: plan output unchanged" "$OUT" "$expected"
check "assigned-only: exit 0" "$RC" "0"
check "assigned-only: nothing on stderr" "$ERR" ""
lacks "assigned-only: no intake listing" "$(cat "$GH_LOG")" "--label"
lacks "assigned-only: no events lookup" "$(cat "$GH_LOG")" "/events"
lacks "assigned-only: no login lookup" "$(cat "$GH_LOG")" "api user"
lacks "assigned-only: no unexpected gh call" "$(cat "$GH_LOG")" "UNEXPECTED"

READY=false MAX=9 write_envelope
run plan
contains "readiness off: header unchanged" "$OUT" "DATA_SOURCES: state.sh(ASSIGNED_ISSUES,BRANCHES,OPEN_PRS); gh issue list(createdAt)"$'\n'
contains "readiness off: empty body is not excluded" "$(included)" "#5  Empty body"
check "readiness off: exit 0" "$RC" "0"

base_fixture
write_envelope
run show
expected_show="STATUS: ok
VERSION: 1
ENABLED: true
BUCKET: nuevo-entrante
EXCLUDE_LABELS: blocked,wip
REQUIRE_READINESS: true
ORDER_BY: priority-label,created-asc
MAX_ISSUES: 3
STOP_AT: null
BASE_STRATEGY: nearest-tag
INTEGRATION_BRANCH: dev
FORBIDDEN_ZONES: inherit
ON_FAILURE_POLICY: park-and-continue
SKIP_DEPENDENTS: true
MERGE_MODE: never
REPORT_TO: journal-per-repo
DISCOVER_ENABLED: false"
check "show without intake fields: output unchanged" "$OUT" "$expected_show"
check "show without intake fields: exit 0" "$RC" "0"

# ===========================================================================
# S5 — intake label applied by an allowed login (explicit allowlist)
# ===========================================================================
base_fixture
{
  issue 10 "Intake task" "devlead,bug" 2026-11-01 "Please add retries"
  issue 2 "Add export" "p0,devlead" 2026-11-03 "Export to CSV"
} | intake
{ ev labeled alice devlead 2026-11-07T10:00:00Z; } | events 10
SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: [alice, bob]' write_envelope
run plan
check "allowed labeler: queue order" "$(included)" "1. #2  Add export
2. #10  Intake task
3. #1  Fix login"
contains "allowed labeler: same basis line as an assigned issue" "$OUT" \
  "   basis: tier=bug, created=2026-11-01, nuevo-entrante  [zone-check: pre-check only, labels-based]"
check "allowed labeler: an assigned issue carrying the label appears once" \
  "$(printf '%s\n' "$OUT" | grep -c '#2  ')" "1"
contains "allowed labeler: events read for the intake issue" "$(cat "$GH_LOG")" \
  "api repos/{owner}/{repo}/issues/10/events --paginate"
lacks "allowed labeler: assigned issues never go through the labeler check" "$(cat "$GH_LOG")" "issues/2/events"
lacks "allowed labeler: explicit allowlist needs no login lookup" "$(cat "$GH_LOG")" "api user"
contains "allowed labeler: intake listed by the exact label" "$(cat "$GH_LOG")" \
  "issue list --label devlead --state open --limit 50 --json number,title,labels,createdAt,updatedAt,body"
check "allowed labeler: budget cut still applies" "$(excluded_line 3)" \
  '#3  "Docs: update guide"   reason: budget-cut (beyond max_issues=3)'
contains "allowed labeler: data sources name the intake lookups" "$OUT" \
  "DATA_SOURCES: state.sh(ASSIGNED_ISSUES,BRANCHES,OPEN_PRS); gh issue list(createdAt,body); gh issue list(intake label); gh api(issue events)"
check "allowed labeler: exit 0" "$RC" "0"
lacks "allowed labeler: no unexpected gh call" "$(cat "$GH_LOG")" "UNEXPECTED"

# --- labeler compared case-insensitively (GitHub logins are) ---------------
{ ev labeled Alice devlead 2026-11-07T10:00:00Z; } | events 10
run plan
contains "labeler case differs: still allowed" "$(included)" "#10  Intake task"

# ===========================================================================
# S5 — intake label applied by a login outside the allowlist
# ===========================================================================
{
  issue 10 "Intake task" "devlead" 2026-11-01 "Please add retries"
  issue 11 "Sneaky" "devlead" 2026-11-01 "Do the thing"
} | intake
{ ev labeled alice devlead 2026-11-07T10:00:00Z; } | events 10
{ ev labeled mallory devlead 2026-11-07T11:00:00Z; } | events 11
run plan
check "untrusted labeler: excluded with the exact reason" "$(excluded_line 11)" \
  "#11  Sneaky   reason: intake-label-untrusted (applied by mallory)"
lacks "untrusted labeler: not in the queue" "$(included)" "#11"
contains "untrusted labeler: the allowed one still is" "$(included)" "#10  Intake task"

# --- the label check matches the exact label name -------------------------
{ ev labeled alice bug 2026-11-07T10:00:00Z; ev labeled mallory devlead 2026-11-07T11:00:00Z; } | events 11
run plan
check "other label by an allowed login does not vouch" "$(excluded_line 11)" \
  "#11  Sneaky   reason: intake-label-untrusted (applied by mallory)"

# ===========================================================================
# S5 — the LATEST labeled event wins
# ===========================================================================
{
  ev labeled alice devlead 2026-11-07T10:00:00Z
  ev unlabeled alice devlead 2026-11-07T10:30:00Z
  ev labeled mallory devlead 2026-11-07T11:00:00Z
} | events 11
run plan
check "removed and re-added by someone else: untrusted" "$(excluded_line 11)" \
  "#11  Sneaky   reason: intake-label-untrusted (applied by mallory)"

# Re-added by an allowed login, and the events span two pages.
printf '%s%s\n' \
  "$(jq -cn '[{event:"labeled",actor:{login:"mallory"},label:{name:"devlead"},created_at:"2026-11-07T10:00:00Z"},
             {event:"unlabeled",actor:{login:"alice"},label:{name:"devlead"},created_at:"2026-11-07T10:30:00Z"}]')" \
  "$(jq -cn '[{event:"labeled",actor:{login:"alice"},label:{name:"devlead"},created_at:"2026-11-07T11:00:00Z"}]')" \
  > "$FIX/events-11.json"
run plan
# It passes the labeler gate and lands in the queue's budget cut (max 3).
check "re-added by an allowed login (paginated): trusted" "$(excluded_line 11)" \
  "#11  Sneaky   reason: budget-cut (beyond max_issues=3)"

# ===========================================================================
# S5 — default allowlist is the authenticated login
# ===========================================================================
{ ev labeled owner devlead 2026-11-07T10:00:00Z; } | events 10
{ ev labeled alice devlead 2026-11-07T10:00:00Z; } | events 11
SELECT_EXTRA='  intake_label: devlead' write_envelope
export GH_REPO=someone/else
run plan
unset GH_REPO
contains "default allowlist: the authenticated login's label is trusted" "$(included)" "#10  Intake task"
check "default allowlist: anyone else is untrusted" "$(excluded_line 11)" \
  "#11  Sneaky   reason: intake-label-untrusted (applied by alice)"
check "default allowlist: login looked up once" "$(grep -c '^api user -q .login$' "$GH_LOG")" "1"
lacks "default allowlist: GH_REPO/GH_HOST do not reach the login lookup" "$(cat "$GH_LOG")" "LEAK"

# --- an empty allowlist trusts nobody (never falls back to the default) ----
SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: []' write_envelope
run plan
check "empty allowlist: even the authenticated login is untrusted" "$(excluded_line 10)" \
  "#10  Intake task   reason: intake-label-untrusted (applied by owner)"
lacks "empty allowlist: no login lookup" "$(cat "$GH_LOG")" "api user"
SELECT_EXTRA='  intake_label: devlead' write_envelope

# --- login lookup fails → every intake issue is unverified ---------------
export FAKE_FAIL=user
run plan
unset FAKE_FAIL
check "login lookup failure: unverified (10)" "$(excluded_line 10)" "#10  Intake task   reason: intake-label-unverified"
check "login lookup failure: unverified (11)" "$(excluded_line 11)" "#11  Sneaky   reason: intake-label-unverified"
contains "login lookup failure: assigned issues unaffected" "$(included)" "#2  Add export"

# --- a login that is not a plain GitHub login is not trusted --------------
export FAKE_ME='owner;rm'
run plan
unset FAKE_ME
check "malformed login: unverified" "$(excluded_line 10)" "#10  Intake task   reason: intake-label-unverified"

# ===========================================================================
# S5 — events lookup failures fail closed
# ===========================================================================
export FAKE_FAIL=events-10
run plan
unset FAKE_FAIL
check "events lookup failure: unverified" "$(excluded_line 10)" "#10  Intake task   reason: intake-label-unverified"
check "events lookup failure: other intake issues still checked" "$(excluded_line 11)" \
  "#11  Sneaky   reason: intake-label-untrusted (applied by alice)"

{ ev labeled owner bug 2026-11-07T10:00:00Z; } | events 10
run plan
check "no labeled event for the label: unverified" "$(excluded_line 10)" "#10  Intake task   reason: intake-label-unverified"

{ ev labeled 'x
1. #99  forged' devlead 2026-11-07T10:00:00Z; } | events 10
run plan
check "actor that is not a GitHub login: unverified" "$(excluded_line 10)" "#10  Intake task   reason: intake-label-unverified"
lacks "actor that is not a GitHub login: cannot forge a queue line" "$OUT" "#99"

# ===========================================================================
# S5 — intake issues go through the same checks as assigned ones
# ===========================================================================
{
  issue 12 "Intake wip" "devlead,wip" 2026-11-01 "Later"
  issue 13 "Intake empty" "devlead" 2026-11-01 ""
  issue 14 "Intake started" "devlead" 2026-11-01 "Body"
} | intake
for n in 12 13 14; do { ev labeled owner devlead 2026-11-07T10:00:00Z; } | events "$n"; done
printf 'feat/issue-14-intake-started\t2026-11-06\t1\t0\n' > "$FIX/branches.tsv"
run plan
check "intake + exclude label" "$(excluded_line 12)" "#12  Intake wip   reason: excluded-label (wip)"
check "intake + readiness" "$(excluded_line 13)" "#13  Intake empty   reason: not-ready (empty body)"
check "intake + existing branch" "$(excluded_line 14)" \
  "#14  Intake started   reason: not-nuevo-entrante (branch issue-14-* exists)"

# --- the budget cut covers intake issues too -------------------------------
base_fixture
{ issue 10 "Intake task" "devlead" 2026-11-09 "Body"; } | intake
{ ev labeled owner devlead 2026-11-07T10:00:00Z; } | events 10
MAX=1 SELECT_EXTRA='  intake_label: devlead' write_envelope
run plan
check "budget cut: one issue queued" "$(included)" "1. #2  Add export"
check "budget cut: intake issue cut like any other" "$(excluded_line 10)" \
  "#10  Intake task   reason: budget-cut (beyond max_issues=1)"

# --- a label with ':' survives show's quoting ------------------------------
SELECT_EXTRA='  intake_label: "devlead:ready"' write_envelope
run plan
contains "colon label: listed by the de-quoted label" "$(cat "$GH_LOG")" "issue list --label devlead:ready --state open"
lacks "colon label: no quote reaches gh" "$(cat "$GH_LOG")" '"devlead:ready"'

# --- the intake listing fails → plan is blocked, never silently partial ----
SELECT_EXTRA='  intake_label: devlead' write_envelope
export FAKE_FAIL=intake
run plan
unset FAKE_FAIL
check "intake listing failure: blocked" "$OUT" "STATUS: blocked
GAP:    gh issue list (intake label) failed — check gh auth status"
check "intake listing failure: exit 0" "$RC" "0"

# ===========================================================================
# show — validation of the new fields
# ===========================================================================
show_blocked() { # <label> <expected GAP substring> — on the current envelope
  run show
  contains "$1: blocked" "$OUT" "STATUS: blocked"
  contains "$1: names the problem" "$OUT" "$2"
  check "$1: exit 0" "$RC" "0"
}
SELECT_EXTRA='  intake_label: ""' write_envelope
show_blocked "empty intake_label" "select.intake_label must be a non-empty string"
SELECT_EXTRA='  intake_label: [devlead]' write_envelope
show_blocked "non-string intake_label" "select.intake_label must be a YAML string"
EXCL='[blocked, devlead]' SELECT_EXTRA='  intake_label: devlead' write_envelope
show_blocked "intake_label excluded" "select.intake_label 'devlead' must not appear in select.exclude_labels"
EXCL='[blocked, discuss]' SELECT_EXTRA='  intake_label: discuss' \
  DISC=$'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src\n      spec: docs/spec.md' write_envelope
show_blocked "intake_label equals discover.label" "select.intake_label 'discuss' must not equal discover.label"
SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: [alice, "bad login"]' write_envelope
show_blocked "labeler with a space" "select.intake_labelers entries must be GitHub logins"
SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: ["x;rm"]' write_envelope
show_blocked "labeler with shell metacharacters" "select.intake_labelers entries must be GitHub logins"
SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: alice' write_envelope
show_blocked "labelers not a list" "select.intake_labelers must be a YAML list"
SELECT_EXTRA='  intake_labelers: [alice]' write_envelope
show_blocked "labelers without intake_label" "select.intake_labelers requires select.intake_label"
SELECT_EXTRA=$'  intake_label: devlead\n  bogus: 1' write_envelope
show_blocked "select stays a closed schema" "unknown key 'bogus' under select"

SELECT_EXTRA=$'  intake_label: devlead\n  intake_labelers: [alice, bob]' write_envelope
run show
contains "valid intake fields: accepted" "$OUT" "STATUS: ok"
contains "valid intake fields: label emitted after the select block" "$OUT" \
  $'REQUIRE_READINESS: true\nINTAKE_LABEL: devlead\nINTAKE_LABELERS: alice,bob\nORDER_BY:'
SELECT_EXTRA='  intake_label: devlead' write_envelope
run show
contains "label alone: accepted" "$OUT" "INTAKE_LABEL: devlead"
lacks "label alone: absent labelers are omitted" "$OUT" "INTAKE_LABELERS"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
