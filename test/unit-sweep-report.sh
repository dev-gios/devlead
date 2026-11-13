#!/usr/bin/env bash
# unit-sweep-report.sh — sandboxed coverage for sweep.sh's Gate 1/Gate 2
# digest STATUS wording (fleet-single-source-devlead change, REQ-1/REQ-2/
# REQ-4/REQ-5). Exercises the REAL envelope.sh (not a fixture double) so the
# ENROLLED/ENABLED KEY:value contract it emits is the one sweep.sh actually
# parses — smoke-outcomes.sh intentionally uses a fixture double instead;
# this suite closes that gap for the two skip gates specifically.
#
# SAFETY: every scenario runs `.devlead/scripts/sweep.sh` from THIS checkout
# with $HOME overridden to a throwaway /tmp sandbox. sweep.sh derives every
# path it touches (REPOS_FILE, REPORTS_DIR, ENVELOPE_BIN, TOKEN_FILE) from
# $HOME, so overriding $HOME is sufficient. GH_TOKEN is explicitly unset and
# a stub `gh` (whose `auth token` always fails) is placed first on $PATH —
# this suite NEVER calls the real `gh` CLI and NEVER touches the real
# machine's $HOME.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SWEEP_BIN="$REPO_ROOT/.devlead/scripts/sweep.sh"
ENVELOPE_SRC="$REPO_ROOT/.devlead/scripts/envelope.sh"
BOOTSTRAP_SRC="$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh"
SANDBOX_ROOT="$(mktemp -d /tmp/devlead-unit-sweep-report.XXXXXX)"
FAKEBIN="$SANDBOX_ROOT/fakebin"
KEEP_TMP="${SWEEP_REPORT_KEEP_TMP:-0}"

mkdir -p "$SANDBOX_ROOT/homes" "$SANDBOX_ROOT/repos" "$FAKEBIN"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo "SWEEP_REPORT_KEEP_TMP=1 — sandbox left at $SANDBOX_ROOT"
  else
    rm -rf "$SANDBOX_ROOT"
  fi
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
note() { echo "NOTE  $1"; }

# Stub `gh` — `auth token` always fails (offline), so _ensure_auth's step 3
# never succeeds and every scenario lands deterministically on Gate 1/Gate 2
# without ever reaching the real network.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAKEBIN/gh"

# fresh_home <name> — sandboxed $HOME with the REAL envelope.sh + its
# sibling bootstrap-lib.sh copied in (envelope.sh:13 sources it by resolving
# its own BASH_SOURCE directory, so the sibling must sit next to it).
fresh_home() {
  local d="$SANDBOX_ROOT/homes/$1"
  rm -rf "$d"
  mkdir -p "$d/.devlead/scripts"
  cp "$ENVELOPE_SRC" "$d/.devlead/scripts/envelope.sh"
  cp "$BOOTSTRAP_SRC" "$d/.devlead/scripts/bootstrap-lib.sh"
  chmod +x "$d/.devlead/scripts/envelope.sh"
  printf '%s\n' "$d"
}

# mk_repo <scenario> <name> [envelope-body] — plain (non-git) fixture dir;
# _repo_root() falls back to `pwd` when git rev-parse fails, so no git init
# is needed. When envelope-body is given, writes .devlead/envelope.yml.
mk_repo() {
  local scenario="$1" name="$2" envelope_body="${3:-}"
  local d="$SANDBOX_ROOT/repos/${scenario}-${name}"
  rm -rf "$d"; mkdir -p "$d/.devlead"
  if [[ -n "$envelope_body" ]]; then
    printf '%s\n' "$envelope_body" > "$d/.devlead/envelope.yml"
  fi
  printf '%s\n' "$d"
}

write_repos_file() {
  local home="$1"; shift
  mkdir -p "$home/.devlead"
  printf '%s\n' "$@" > "$home/.devlead/autonomous-repos"
}

digest_file() { local home="$1"; find "$home/.devlead/reports" -maxdepth 1 -name '*.md' | head -1; }

run_sweep() {
  local home="$1"
  ( unset GH_TOKEN
    HOME="$home" PATH="$FAKEBIN:$PATH" bash "$SWEEP_BIN" )
}

# Frozen fd-4 tokens (C3) — must never change regardless of digest wording.
FD4_NOT_ENROLLED='no medible — not-enrolled.'
FD4_NOT_ENABLED='no medible — not-enabled.'

# ---------------------------------------------------------------------------
# S1 — listed, no envelope.yml at all (Gate 1).
# ---------------------------------------------------------------------------
s1_no_envelope() {
  local home; home="$(fresh_home s1)"
  local repo; repo="$(mk_repo s1 h)"
  write_repos_file "$home" "$repo"

  run_sweep "$home" >/dev/null
  local digest; digest="$(digest_file "$home")"

  grep -qF "no envelope.yml (ENROLLED: false) — listed in the fleet but nothing authorizes work here. Fix: cd '$repo' && devlead init" "$digest" \
    && pass "S1 REQ-1: no-envelope STATUS line names the exact fix command" \
    || fail "S1 REQ-1: no-envelope STATUS line missing/mismatched — $(grep -A2 "### $repo" "$digest" || true)"

  grep -qF -- "- $repo: $FD4_NOT_ENROLLED" "$digest" \
    && pass "S1 C3: fd-4 not-enrolled token stays byte-identical" \
    || fail "S1 C3: fd-4 not-enrolled token changed — $(grep "$repo" "$digest" || true)"
}

# ---------------------------------------------------------------------------
# S2 — listed, envelope.yml present with enabled: false (Gate 2, deliberate).
# ---------------------------------------------------------------------------
s2_enabled_false() {
  local home; home="$(fresh_home s2)"
  local repo; repo="$(mk_repo s2 h "enabled: false")"
  write_repos_file "$home" "$repo"

  run_sweep "$home" >/dev/null
  local digest; digest="$(digest_file "$home")"

  grep -qF "disabled (ENABLED: false) — the envelope's kill-switch is off by choice. No action needed." "$digest" \
    && pass "S2 REQ-2: disabled STATUS line reads sober, no fix command" \
    || fail "S2 REQ-2: disabled STATUS line missing/mismatched — $(grep -A2 "### $repo" "$digest" || true)"

  grep -qE "disabled.*(Fix:|Check:)" "$digest" \
    && fail "S2 REQ-2: disabled STATUS line unexpectedly names an action" \
    || pass "S2 REQ-2: disabled STATUS line names no fix/check command"

  grep -qF -- "- $repo: $FD4_NOT_ENABLED" "$digest" \
    && pass "S2 C3: fd-4 not-enabled token stays byte-identical" \
    || fail "S2 C3: fd-4 not-enabled token changed — $(grep "$repo" "$digest" || true)"
}

# ---------------------------------------------------------------------------
# S3 — listed, envelope.yml present with enabled: true (both gates clear
# offline, lands on Gate 3 auth-unavailable — proves Gate 1 and Gate 2 both
# cleared without ever touching real GitHub).
# ---------------------------------------------------------------------------
s3_enabled_true() {
  local home; home="$(fresh_home s3)"
  local repo; repo="$(mk_repo s3 h "enabled: true")"
  write_repos_file "$home" "$repo"

  run_sweep "$home" >/dev/null
  local digest; digest="$(digest_file "$home")"

  grep -qF '**STATUS: auth-unavailable**' "$digest" \
    && pass "S3 REQ-1/REQ-2: enabled:true clears both Gate 1 and Gate 2 offline, reaching Gate 3 (auth-unavailable)" \
    || fail "S3: expected auth-unavailable after clearing both gates — $(grep -A2 "### $repo" "$digest" || true)"

  grep -qF -- "- $repo: no medible — auth-unavailable; sin token." "$digest" \
    && pass "S3: fd-4 auth-unavailable line present (unrelated to C3's frozen tokens, sanity check only)" \
    || fail "S3: fd-4 auth-unavailable line missing"
}

# ---------------------------------------------------------------------------
# S4 — listed, envelope.yml present with a non-boolean enabled value (Gate 2,
# unreadable switch — must NOT be conflated with the deliberate-off case).
# ---------------------------------------------------------------------------
s4_enabled_maybe() {
  local home; home="$(fresh_home s4)"
  local repo; repo="$(mk_repo s4 h "enabled: maybe")"
  write_repos_file "$home" "$repo"

  run_sweep "$home" >/dev/null
  local digest; digest="$(digest_file "$home")"

  grep -qF "ENABLED: unknown — envelope.yml exists but its switch could not be read. Check: cd '$repo' && devlead check" "$digest" \
    && pass "S4 REQ-2/D2: unreadable-switch STATUS line is actionable and distinct from the deliberate-off wording" \
    || fail "S4: unreadable-switch STATUS line missing/mismatched — $(grep -A2 "### $repo" "$digest" || true)"

  grep -qF "the envelope's kill-switch is off by choice" "$digest" \
    && fail "S4: unreadable-switch STATUS line wrongly reused the deliberate-off wording" \
    || pass "S4: unreadable-switch STATUS line does not reuse the deliberate-off wording"

  grep -qF -- "- $repo: $FD4_NOT_ENABLED" "$digest" \
    && pass "S4 C3: fd-4 not-enabled token stays byte-identical for the unreadable-switch shape too" \
    || fail "S4 C3: fd-4 not-enabled token changed — $(grep "$repo" "$digest" || true)"
}

# ---------------------------------------------------------------------------
# S5 — REQ-5/C1 static guard: sweep.sh must never write to the fleet list.
# Matches actual redirection syntax targeting $REPOS_FILE/autonomous-repos
# outside string literals; explicitly excludes the two quoted advisory
# strings ("Add repos with: echo /path/to/repo >> $REPOS_FILE") which are
# themselves inside echo "..." string literals, not real redirections.
# Pure static source check (plain grep -nE, no yq/rg dependency) — this is
# the ONLY automated guard of §A1 (sweep.sh must never write to the fleet
# list), so it MUST run even when yq is missing, unlike S1-S4 which
# genuinely execute envelope.sh and need yq to read 'enabled'.
# ---------------------------------------------------------------------------
s5_sweep_never_writes_fleet_list() {
  local hits
  hits="$(grep -nE '(>>?\s*"?\$REPOS_FILE"?|>>?\s*"?\$HOME/\.devlead/autonomous-repos"?)' "$SWEEP_BIN" \
    | grep -v 'echo "Add repos with:' || true)"
  [[ -z "$hits" ]] \
    && pass "S5 REQ-5/C1: zero real writes to REPOS_FILE/autonomous-repos in sweep.sh (advisory echo strings excluded)" \
    || fail "S5 REQ-5/C1: found a write shape targeting the fleet list — $hits"
}

main() {
  # S5 is a pure static source check (plain grep, no yq/rg dependency) — it
  # is the ONLY automated guard of §A1 and must ALWAYS run, even when yq is
  # missing from PATH. Only S1-S4 genuinely execute envelope.sh and need the
  # yq gate below.
  s5_sweep_never_writes_fleet_list

  if ! command -v yq &>/dev/null; then
    note "yq not found on PATH — skipping S1-S4 (envelope.sh requires yq to read 'enabled')"
  else
    s1_no_envelope
    s2_enabled_false
    s3_enabled_true
    s4_enabled_maybe
  fi

  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX_ROOT) ==="
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
