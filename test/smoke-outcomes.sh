#!/usr/bin/env bash
# smoke-outcomes.sh — formal sandboxed smoke evidence for the
# devlead-feedback-loop change (pr-outcome-reckoner, REQ-1..REQ-9, see the
# SDD spec/design/tasks artifacts for sdd/devlead-feedback-loop in engram).
#
# NOT wired into any CI/test runner. Run manually:
#   bash test/smoke-outcomes.sh
#
# SAFETY: every scenario below runs `.devlead/scripts/sweep.sh` from THIS
# checkout with $HOME overridden to a throwaway /tmp sandbox directory.
# sweep.sh derives every path it touches (REPOS_FILE, REPORTS_DIR,
# OUTCOMES_DIR, TOKEN_FILE, ENVELOPE_BIN) from $HOME — so overriding $HOME
# is sufficient to fully sandbox the run. `gh` is intercepted via a fake
# binary placed first on $PATH (`envelope.sh` is intercepted by placing a
# fixture at $HOME/.devlead/scripts/envelope.sh, since sweep.sh calls it by
# absolute path, not via $PATH lookup). This script NEVER sets GH_TOKEN to
# a real value, NEVER calls the real `gh` CLI, and NEVER writes to the real
# machine's $HOME, ~/.devlead/outcomes, or ~/.devlead/reports.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SWEEP_BIN="$REPO_ROOT/.devlead/scripts/sweep.sh"
SMOKE_ROOT="$(mktemp -d /tmp/devlead-smoke-outcomes.XXXXXX)"
FAKEBIN="$SMOKE_ROOT/fakebin"
FIXTURES="$SMOKE_ROOT/fixtures"
RESULTS_FILE="$SMOKE_ROOT/results.txt"
KEEP_TMP="${SMOKE_KEEP_TMP:-0}"

mkdir -p "$SMOKE_ROOT/homes" "$SMOKE_ROOT/repos" "$FAKEBIN" "$FIXTURES"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo "SMOKE_KEEP_TMP=1 — sandbox left at $SMOKE_ROOT"
  else
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1" | tee -a "$RESULTS_FILE"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL  $1" | tee -a "$RESULTS_FILE"; FAIL_COUNT=$((FAIL_COUNT+1)); }
note() { echo "NOTE  $1" | tee -a "$RESULTS_FILE"; }

# ---------------------------------------------------------------------------
# Fixtures: fake `envelope.sh` (per-repo `.test-mode`-driven) and fake `gh`
# (per-repo `.gh-mode`-driven). The fake `gh` extracts the REAL -q jq filter
# argument sweep.sh's _reckon_repo passes and applies it via the REAL `jq`
# binary to a fixture PR-list JSON file — so these smoke tests exercise the
# ACTUAL classification expression embedded in sweep.sh, not a hand-rolled
# bash re-implementation of it.
# ---------------------------------------------------------------------------
cat > "$FAKEBIN/envelope-fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"
mode="ok"
[[ -f ".test-mode" ]] && mode="$(cat .test-mode)"
case "$cmd" in
  check)
    case "$mode" in
      not-enrolled) echo "ENROLLED: false"; echo "ENABLED: false" ;;
      not-enabled)  echo "ENROLLED: true";  echo "ENABLED: false" ;;
      *)            echo "ENROLLED: true";  echo "ENABLED: true"  ;;
    esac
    ;;
  plan)
    case "$mode" in
      plan-blocked) echo "STATUS: blocked"; echo "GAP: fixture gap for smoke test" ;;
      plan-paused)  echo "STATUS: paused" ;;
      plan-error)   printf '' ;;
      *)
        echo "=== DEVLEAD ENVELOPE PLAN ==="
        echo "fixture plan body"
        ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/envelope-fixture.sh"

cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
mode="ok"
[[ -f ".gh-mode" ]] && mode="$(cat .gh-mode)"

if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  [[ "$mode" == "auth-unavailable" ]] && exit 1
  echo "fake-gh-token-from-cli"
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  [[ "$mode" == "gh-fail" ]] && exit 1

  _query=""
  _prev=""
  for _arg in "$@"; do
    [[ "$_prev" == "-q" ]] && _query="$_arg"
    _prev="$_arg"
  done

  if [[ "$mode" == "malformed" ]]; then
    printf '{not valid json' | jq -r "$_query" 2>/dev/null
    exit $?
  fi

  _fixture="$GH_PR_FIXTURE"
  [[ "$mode" == "zero-attr" ]] && _fixture="$GH_PR_FIXTURE_EMPTY"
  jq -r "$_query" "$_fixture"
  exit 0
fi

exit 0
EOF
chmod +x "$FAKEBIN/gh"

fresh_home() {
  local d="$SMOKE_ROOT/homes/$1"
  rm -rf "$d"
  mkdir -p "$d/.devlead/scripts"
  cp "$FAKEBIN/envelope-fixture.sh" "$d/.devlead/scripts/envelope.sh"
  printf '%s\n' "$d"
}

# mk_repo <scenario> <name> [test-mode] [gh-mode] — creates a plain (non-git)
# fixture directory; _reckon_repo's `git rev-parse --show-toplevel` fails
# harmlessly there and falls back to the literal repo_path (documented
# fallback), so no git init is needed for these fixtures.
mk_repo() {
  local scenario="$1" name="$2" testmode="${3:-}" ghmode="${4:-}"
  local d="$SMOKE_ROOT/repos/${scenario}-${name}"
  rm -rf "$d"; mkdir -p "$d"
  [[ -n "$testmode" ]] && printf '%s\n' "$testmode" > "$d/.test-mode"
  [[ -n "$ghmode" ]] && printf '%s\n' "$ghmode" > "$d/.gh-mode"
  printf '%s\n' "$d"
}

write_repos_file() {
  local home="$1"; shift
  mkdir -p "$home/.devlead"
  printf '%s\n' "$@" > "$home/.devlead/autonomous-repos"
}

run_sweep() {
  local home="$1" fixture="${2:-}" fixture_empty="${3:-}"
  ( GH_PR_FIXTURE="$fixture" GH_PR_FIXTURE_EMPTY="$fixture_empty" \
    HOME="$home" PATH="$FAKEBIN:$PATH" bash "$SWEEP_BIN" )
}

repo_key() { printf '%s' "${1//\//_}"; }
digest_file() { local home="$1"; find "$home/.devlead/reports" -maxdepth 1 -name '*.md' | head -1; }

# ===========================================================================
# O1 — REQ-1 (attribution regex) + REQ-2/3 (in-jq classification) +
# CRITICAL-1 regression (OPEN, mergedAt=null, reviewDecision=CHANGES_REQUESTED
# must classify changes-requested, never merged).
# ===========================================================================
o1_attribution_and_classification() {
  local home; home="$(fresh_home o1)"
  local repo; repo="$(mk_repo o1 h ok mixed)"
  write_repos_file "$home" "$repo"

  cat > "$FIXTURES/o1-prs.json" <<EOF
[
  {"state":"CLOSED","headRefName":"feat/issue-1-a","reviewDecision":"CHANGES_REQUESTED","mergedAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"state":"CLOSED","headRefName":"fix/issue-2-b","reviewDecision":null,"mergedAt":null,"updatedAt":"2026-07-02T00:00:00Z"},
  {"state":"OPEN","headRefName":"chore/issue-3-c","reviewDecision":"CHANGES_REQUESTED","mergedAt":null,"updatedAt":"2026-07-03T00:00:00Z"},
  {"state":"OPEN","headRefName":"docs/issue-4-d","reviewDecision":null,"mergedAt":null,"updatedAt":"$(date -u -d '8 days ago' +%FT%TZ)"},
  {"state":"OPEN","headRefName":"dependabot/npm_and_yarn/lodash-4.17.21","reviewDecision":null,"mergedAt":null,"updatedAt":"2026-07-01T00:00:00Z"},
  {"state":"OPEN","headRefName":"main","reviewDecision":null,"mergedAt":null,"updatedAt":"2026-07-01T00:00:00Z"}
]
EOF

  run_sweep "$home" "$FIXTURES/o1-prs.json" >/dev/null

  local key jf; key="$(repo_key "$repo")"; jf="$home/.devlead/outcomes/${key}.jsonl"
  [[ -f "$jf" ]] && pass "O1 REQ-5: JSONL written at repo-key path" || { fail "O1 REQ-5: JSONL not found at $jf"; return; }

  local line; line="$(tail -1 "$jf")"
  echo "$line" | grep -q '"merged":1' && echo "$line" | grep -q '"closed_sin_merge":1' \
    && echo "$line" | grep -q '"changes_requested":1' && echo "$line" | grep -q '"pending":1' \
    && echo "$line" | grep -q '"attributable":4' \
    && pass "O1 REQ-1/REQ-3: dependabot+main excluded, 4 attributable, one PR per bucket" \
    || fail "O1 REQ-1/REQ-3: unexpected bucket counts — got: $line"

  echo "$line" | grep -q '"merged":1' \
    && pass "O1 CRITICAL-1 regression: null-mergedAt+CHANGES_REQUESTED PR did NOT inflate merged count (merged=1, only the genuinely-merged PR)" \
    || fail "O1 CRITICAL-1 regression: merged count wrong — possible misclassification — got: $line"

  echo "$line" | grep -q '"merge_rate":"50%"' && pass "O1 REQ-4: merge-rate = 1/(1+1) = 50%" \
    || fail "O1 REQ-4: merge-rate wrong — got: $line"
  echo "$line" | grep -q '"oldest_pending_days":8' && pass "O1 REQ-4: oldest-pending aging = 8 days" \
    || fail "O1 REQ-4: aging wrong — got: $line"

  local digest; digest="$(digest_file "$home")"
  grep -q "PRs DevLead: 1 merged, 1 closed-sin-merge, 1 pending (más viejo: 8 días) — merge-rate 50%" "$digest" \
    && pass "O1 REQ-6: digest has-data line matches exact copy" \
    || fail "O1 REQ-6: digest has-data line missing/mismatched — $(grep "$repo" "$digest" || true)"
}

# ===========================================================================
# O2 — REQ-4: merge-rate div-by-zero guard (only pending/changes-requested).
# ===========================================================================
o2_div_by_zero_merge_rate() {
  local home; home="$(fresh_home o2)"
  local repo; repo="$(mk_repo o2 h ok mixed)"
  write_repos_file "$home" "$repo"

  cat > "$FIXTURES/o2-prs.json" <<EOF
[
  {"state":"OPEN","headRefName":"chore/issue-9-x","reviewDecision":"CHANGES_REQUESTED","mergedAt":null,"updatedAt":"2026-07-01T00:00:00Z"},
  {"state":"OPEN","headRefName":"docs/issue-10-y","reviewDecision":null,"mergedAt":null,"updatedAt":"$(date -u -d '2 days ago' +%FT%TZ)"}
]
EOF
  run_sweep "$home" "$FIXTURES/o2-prs.json" >/dev/null

  local key jf; key="$(repo_key "$repo")"; jf="$home/.devlead/outcomes/${key}.jsonl"
  grep -q '"merge_rate":"n/a"' "$jf" && pass "O2 REQ-4: JSONL merge_rate literal n/a on 0 merged + 0 closed" \
    || fail "O2 REQ-4: JSONL merge_rate not n/a — got: $(tail -1 "$jf")"
  grep -q '"merge_rate":"0%"' "$jf" && fail "O2 REQ-4: merge_rate rendered as 0% (forbidden)"

  local digest; digest="$(digest_file "$home")"
  grep -q "merge-rate n/a" "$digest" && pass "O2 REQ-4: digest line shows literal n/a" \
    || fail "O2 REQ-4: digest line missing n/a — $(grep "$repo" "$digest" || true)"
}

# ===========================================================================
# O3 — REQ-6: zero-attributable PRs must print the exact fixed string, never
# all-zero counts; REQ-5: still measured -> JSONL line appended.
# ===========================================================================
o3_zero_attributable() {
  local home; home="$(fresh_home o3)"
  local repo; repo="$(mk_repo o3 h ok zero-attr)"
  write_repos_file "$home" "$repo"
  echo '[]' > "$FIXTURES/o3-empty.json"

  run_sweep "$home" "" "$FIXTURES/o3-empty.json" >/dev/null

  local digest; digest="$(digest_file "$home")"
  grep -q "sin PRs de DevLead todavía" "$digest" && pass "O3 REQ-6: zero-attributable prints exact fixed string" \
    || fail "O3 REQ-6: zero-attributable string missing — $(grep "$repo" "$digest" || true)"
  grep -qE "0 merged, 0 closed" "$digest" && fail "O3 REQ-6: all-zero counts leaked into digest (forbidden)"

  local key jf; key="$(repo_key "$repo")"; jf="$home/.devlead/outcomes/${key}.jsonl"
  [[ -f "$jf" ]] && grep -q '"attributable":0' "$jf" && grep -q '"merge_rate":"n/a"' "$jf" \
    && pass "O3 REQ-5: measured-but-empty JSONL line still appended (merged, found none)" \
    || fail "O3 REQ-5: expected an all-zero JSONL line — got: $(cat "$jf" 2>&1)"
}

# ===========================================================================
# O4 — REQ-6: reckoner gh failure -> honest "no medible" line, never
# fabricated; REQ-5: never-measured -> no JSONL line.
# ===========================================================================
o4_gh_failed() {
  local home; home="$(fresh_home o4)"
  local repo; repo="$(mk_repo o4 h ok gh-fail)"
  write_repos_file "$home" "$repo"

  run_sweep "$home" >/dev/null

  local digest; digest="$(digest_file "$home")"
  grep -q "no medible — gh pr list falló o devolvió vacío\." "$digest" \
    && pass "O4 REQ-6: gh-failed prints exact honest line" \
    || fail "O4 REQ-6: gh-failed line missing — $(grep "$repo" "$digest" || true)"

  local key jf; key="$(repo_key "$repo")"; jf="$home/.devlead/outcomes/${key}.jsonl"
  [[ ! -f "$jf" ]] && pass "O4 REQ-5: no JSONL line on a run that never measured (gh failed)" \
    || fail "O4 REQ-5: JSONL was written despite gh failure — got: $(cat "$jf")"
}

# ===========================================================================
# O5 — REQ-6 (every exit path honest, never omitted) + structural
# regression guard: exactly ONE grouped "## Outcomes" heading across 8
# repos spanning every _sweep_repo exit path (cannot-cd, not-enrolled,
# not-enabled, auth-unavailable, plan-blocked, plan-paused, plan-error,
# included/has-data).
# ===========================================================================
o5_mixed_gates_structural() {
  local home; home="$(fresh_home o5)"
  local r_cd="$SMOKE_ROOT/repos/o5-does-not-exist"
  local r_ne;  r_ne="$(mk_repo o5 notenrolled not-enrolled)"
  local r_na;  r_na="$(mk_repo o5 notenabled not-enabled)"
  local r_au;  r_au="$(mk_repo o5 authfail ok auth-unavailable)"
  local r_bl;  r_bl="$(mk_repo o5 blocked plan-blocked)"
  local r_pa;  r_pa="$(mk_repo o5 paused plan-paused)"
  local r_er;  r_er="$(mk_repo o5 error plan-error)"
  local r_in;  r_in="$(mk_repo o5 included ok mixed)"
  write_repos_file "$home" "$r_cd" "$r_ne" "$r_na" "$r_au" "$r_bl" "$r_pa" "$r_er" "$r_in"

  cat > "$FIXTURES/o5-prs.json" <<EOF
[
  {"state":"CLOSED","headRefName":"feat/issue-1-a","reviewDecision":null,"mergedAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
EOF
  run_sweep "$home" "$FIXTURES/o5-prs.json" >/dev/null

  local digest; digest="$(digest_file "$home")"
  local heading_count; heading_count="$(grep -c '^## Outcomes' "$digest" || true)"
  [[ "$heading_count" -eq 1 ]] && pass "O5 structural: exactly ONE grouped ## Outcomes heading ($heading_count)" \
    || fail "O5 structural: expected exactly 1 ## Outcomes heading, got $heading_count"

  grep -q -- "- $r_cd: no medible — cannot-cd; repo inaccesible\." "$digest" && pass "O5 cannot-cd line present" || fail "O5 cannot-cd line missing"
  grep -q -- "- $r_ne: no medible — not-enrolled\." "$digest" && pass "O5 not-enrolled line present" || fail "O5 not-enrolled line missing"
  grep -q -- "- $r_na: no medible — not-enabled\." "$digest" && pass "O5 not-enabled line present" || fail "O5 not-enabled line missing"
  grep -q -- "- $r_au: no medible — auth-unavailable; sin token\." "$digest" && pass "O5 auth-unavailable line present" || fail "O5 auth-unavailable line missing"
  grep -q -- "- $r_bl: no medible — plan-blocked; sin snapshot de PRs\." "$digest" && pass "O5 plan-blocked line present" || fail "O5 plan-blocked line missing"
  grep -q -- "- $r_pa: no medible — plan-paused; sin snapshot de PRs\." "$digest" && pass "O5 plan-paused line present" || fail "O5 plan-paused line missing"
  grep -q -- "- $r_er: no medible — plan-error; sin snapshot de PRs\." "$digest" && pass "O5 plan-error line present" || fail "O5 plan-error line missing"
  grep -q -- "- $r_in: PRs DevLead: 1 merged, 0 closed-sin-merge, 0 pending" "$digest" && pass "O5 included/has-data line present" || fail "O5 included/has-data line missing"

  local outcomes_lines; outcomes_lines="$(sed -n '/^## Outcomes/,$p' "$digest" | grep -c '^- ')"
  [[ "$outcomes_lines" -eq 8 ]] && pass "O5 REQ-6: all 8 repos have exactly one Outcomes line each, none silently omitted" \
    || fail "O5 REQ-6: expected 8 Outcomes lines, got $outcomes_lines"

  grep -q '\*\*STATUS: plan-blocked\*\*' "$digest" && pass "O5 plan-flow immutability: plan-blocked STATUS still rendered in plan section" \
    || fail "O5 plan-flow immutability: plan-blocked STATUS missing from plan section"
}

# ===========================================================================
# O6 — REQ-5 (append-only across runs) + REQ-9 (digest is a snapshot,
# JSONL is cumulative): run twice same day, same repo.
# ===========================================================================
o6_dual_run_append_and_snapshot() {
  local home; home="$(fresh_home o6)"
  local repo; repo="$(mk_repo o6 h ok mixed)"
  write_repos_file "$home" "$repo"
  cat > "$FIXTURES/o6-prs.json" <<EOF
[
  {"state":"CLOSED","headRefName":"feat/issue-5-a","reviewDecision":null,"mergedAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
EOF

  run_sweep "$home" "$FIXTURES/o6-prs.json" >/dev/null
  local key jf; key="$(repo_key "$repo")"; jf="$home/.devlead/outcomes/${key}.jsonl"
  local line1_after_run1; line1_after_run1="$(sed -n '1p' "$jf")"
  local count1; count1="$(wc -l < "$jf")"

  run_sweep "$home" "$FIXTURES/o6-prs.json" >/dev/null
  local line1_after_run2; line1_after_run2="$(sed -n '1p' "$jf")"
  local count2; count2="$(wc -l < "$jf")"

  [[ "$count1" -eq 1 && "$count2" -eq 2 ]] && pass "O6 REQ-5: JSONL gained exactly 1 line per run (1 -> 2)" \
    || fail "O6 REQ-5: expected 1 then 2 lines, got $count1 then $count2"
  [[ "$line1_after_run1" == "$line1_after_run2" ]] && pass "O6 REQ-5: line 1 byte-identical across runs (append-only, never rewritten)" \
    || fail "O6 REQ-5: line 1 changed across runs — append-only violated"

  local mdcount; mdcount="$(find "$home/.devlead/reports" -maxdepth 1 -name '*.md' | wc -l)"
  [[ "$mdcount" -eq 1 ]] && pass "O6 REQ-9: exactly ONE digest file exists after 2 same-day runs (snapshot overwrite)" \
    || fail "O6 REQ-9: expected exactly 1 digest file, got $mdcount"
}

# ===========================================================================
# O7 — REQ-8: reckoner failure (malformed JSON) on repo A does not corrupt
# repo A's plan section nor prevent repo B from processing normally.
# ===========================================================================
o7_malformed_json_isolation() {
  local home; home="$(fresh_home o7)"
  local r_a; r_a="$(mk_repo o7 a ok malformed)"
  local r_b; r_b="$(mk_repo o7 b ok mixed)"
  write_repos_file "$home" "$r_a" "$r_b"
  cat > "$FIXTURES/o7-prs.json" <<EOF
[
  {"state":"CLOSED","headRefName":"feat/issue-6-a","reviewDecision":null,"mergedAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
EOF
  run_sweep "$home" "$FIXTURES/o7-prs.json" >/dev/null

  local digest; digest="$(digest_file "$home")"
  local sectionA; sectionA="$(awk -v r="### $r_a" -v r2="### $r_b" '
    $0==r {p=1} $0==r2 {p=0} p' "$digest")"
  echo "$sectionA" | grep -q '\*\*STATUS: included\*\*' && echo "$sectionA" | grep -q '~~~' \
    && pass "O7 REQ-8: repo A plan section (STATUS: included + fenced plan) unchanged despite reckoner failure" \
    || fail "O7 REQ-8: repo A plan section corrupted — $sectionA"
  grep -q -- "- $r_a: no medible — gh pr list falló o devolvió vacío\." "$digest" \
    && pass "O7 REQ-8: repo A Outcomes line honestly reports reckoner failure" \
    || fail "O7 REQ-8: repo A Outcomes line missing/wrong"
  grep -q -- "- $r_b: PRs DevLead: 1 merged" "$digest" \
    && pass "O7 REQ-8: repo B processed normally, unaffected by repo A's reckoner failure" \
    || fail "O7 REQ-8: repo B did not process normally"
}

# ===========================================================================
# O8 — REQ-7 (zero GitHub writes, static grep) + structural source checks.
# ===========================================================================
o8_static_checks() {
  local hits
  hits="$(rg -n 'gh pr (create|merge|close|edit|comment|review)' "$SWEEP_BIN" || true)"
  [[ -z "$hits" ]] && pass "O8 REQ-7: zero GitHub write verbs found in sweep.sh" \
    || fail "O8 REQ-7: found a write verb — $hits"

  local amp4_count; amp4_count="$(grep -c '>&4' "$SWEEP_BIN" || true)"
  [[ "$amp4_count" -eq 10 ]] && pass "O8 structural: exactly 10 fd-4 emission points (7 sweep_repo branches + 3 reckoner outcomes)" \
    || fail "O8 structural: expected 10 >&4 occurrences, got $amp4_count"

  local outcomes_headings; outcomes_headings="$(grep -c '^ *echo "## Outcomes"' "$SWEEP_BIN" || true)"
  [[ "$outcomes_headings" -eq 1 ]] && pass "O8 structural: exactly ONE 'echo \"## Outcomes\"' emission in sweep.sh source" \
    || fail "O8 structural: expected exactly 1 'echo \"## Outcomes\"' emission, got $outcomes_headings"
}

# Real-$HOME safety net: snapshot BEFORE any sandboxed scenario runs (main()
# calls this first) and compare AFTER all scenarios complete — every
# scenario above only ever passes HOME=<sandbox> to sweep.sh, so the real
# machine's ~/.devlead must be byte-for-byte/mtime-for-mtime untouched.
REALHOME_SNAPSHOT_BEFORE=""
snapshot_real_home() {
  if [[ -d "$HOME/.devlead" ]]; then
    find "$HOME/.devlead" -printf '%p %T@ %s\n' 2>/dev/null | sort | md5sum
  else
    echo "no-real-devlead-dir"
  fi
}

main() {
  : > "$RESULTS_FILE"
  REALHOME_SNAPSHOT_BEFORE="$(snapshot_real_home)"

  o1_attribution_and_classification
  o2_div_by_zero_merge_rate
  o3_zero_attributable
  o4_gh_failed
  o5_mixed_gates_structural
  o6_dual_run_append_and_snapshot
  o7_malformed_json_isolation
  o8_static_checks

  local after; after="$(snapshot_real_home)"
  [[ "$REALHOME_SNAPSHOT_BEFORE" == "$after" ]] \
    && pass "O9 safety-net: real \$HOME/.devlead tree (or its absence) unchanged after all sandboxed scenarios" \
    || fail "O9 safety-net: real \$HOME/.devlead tree changed during this smoke run — INVESTIGATE IMMEDIATELY"

  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SMOKE_ROOT) ==="
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
