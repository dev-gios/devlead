#!/usr/bin/env bash
# unit-config-menu.sh — acceptance coverage for .devlead/scripts/config.sh,
# the interactive machine-setup + envelope editor (GOVERNANCE.md §A3).
#
#   bash test/unit-config-menu.sh
#
# Three properties matter more than the rest, because they are exactly what
# makes this tool governance-safe instead of a fourth hand-maintained field
# list with a write hole in it:
#
#   1. the TTY gate is REAL — a closed stdin refuses before anything is
#      read or written, citing GOVERNANCE.md §A3
#   2. config.sh carries NO list of envelope field names of its own — it
#      renders and edits purely from `envelope.sh schema` at runtime
#   3. the write path never leaves envelope.yml on disk in a state that
#      fails `envelope.sh show` — a change that would break validation is
#      reverted byte-for-byte, and a token is never printed anywhere
#
# Scripted (non-TTY-gate) scenarios drive config.sh over a REAL pseudo-tty
# via `script`(1) — stdin is genuinely a terminal (`[[ -t 0 ]]` is true
# inside), so the TTY gate itself is never bypassed or special-cased for
# testing; it is only ever satisfied honestly. Input lines are paced with a
# short sleep between them so the child's `read -rs` (used for the token
# prompt) has actually disabled terminal echo before the sensitive line is
# delivered — an unpaced burst of input landing before that call runs would
# be echoed by the tty driver regardless of `-rs`, which is a timing
# artifact of the driver, not of config.sh.
#
# SAFETY: every sandbox is a throwaway /tmp directory. HOME is always
# overridden. Nothing here touches the real repo's own envelope.yml or the
# real machine's ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CONFIG_SRC="$REPO_ROOT/.devlead/scripts/config.sh"
SANDBOX="$(mktemp -d /tmp/devlead-config-menu.XXXXXX)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else
    fail "$1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"
  fi
}
not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else
    fail "$1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"
  fi
}
check_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else
    fail "$1"; echo "        expected: [$3]"; echo "        actual: [$2]"
  fi
}

DEFAULT_ENVELOPE='version: 1
enabled: false
select:
  bucket: nuevo-entrante
  exclude_labels: [blocked, wip, discuss]
  require_readiness: true
order:
  by: [priority-label, created-asc]
budget:
  max_issues: 3
  stop_at: null
base:
  strategy: nearest-tag
forbidden_zones: inherit
on_failure:
  policy: park-and-continue
  skip_dependents: true
merge:
  mode: never
report:
  to: journal-per-repo
'

# _new_sandbox name — a throwaway git repo carrying the CURRENT WORKING TREE
# copies of config.sh/envelope.sh/bootstrap-lib.sh/doctor.sh (not a `git
# clone`, deliberately — a clone only carries committed content, and this
# suite must exercise config.sh before it is ever committed) plus a
# default-scaffold envelope.yml. Echoes: "<repo_dir> <home_dir>".
_new_sandbox() {
  local name="$1"
  local dir="$SANDBOX/$name/src"
  local home="$SANDBOX/$name/home"
  mkdir -p "$dir/.devlead/scripts" "$home"
  local f
  for f in config.sh envelope.sh bootstrap-lib.sh doctor.sh; do
    cp "$REPO_ROOT/.devlead/scripts/$f" "$dir/.devlead/scripts/$f"
  done
  chmod +x "$dir"/.devlead/scripts/*.sh
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Test"
  printf '%s' "$DEFAULT_ENVELOPE" > "$dir/.devlead/envelope.yml"
  printf '%s %s\n' "$dir" "$home"
}

# _drive repo_dir home_dir line... — runs config.sh over a real pty (via
# `script`), feeding the given lines paced 0.15s apart. Captures combined
# stdout+stderr (both flow through the same pty). The typescript record
# itself is discarded (/dev/null) — nothing is ever persisted to disk beyond
# what config.sh itself writes.
_drive() {
  local dir="$1" home="$2"; shift 2
  local -a lines=("$@")
  (
    local l
    for l in "${lines[@]}"; do
      printf '%s\n' "$l"
      sleep 0.15
    done
  ) | ( cd "$dir" && HOME="$home" script -qec "bash .devlead/scripts/config.sh" /dev/null 2>&1 )
}

# ===========================================================================
# T1 — TTY gate is real: closed stdin (no pty at all, unlike every other
# scenario below) refuses before reading or writing anything, exit non-zero,
# citing GOVERNANCE.md and §A3.
# ===========================================================================
t1_tty_gate() {
  read -r dir home < <(_new_sandbox t1)
  local out rc
  out="$( (cd "$dir" && HOME="$home" bash .devlead/scripts/config.sh < /dev/null) 2>&1 )"
  rc=$?
  [[ $rc -ne 0 ]] && pass "T1: exits non-zero with closed stdin" || fail "T1: expected non-zero exit, got $rc"
  contains "T1: message cites GOVERNANCE.md" "$out" "GOVERNANCE.md"
  contains "T1: message cites §A3" "$out" "§A3"
  contains "T1: message names the reason (not a TTY)" "$out" "TTY"
  local envelope_after; envelope_after="$(cat "$dir/.devlead/envelope.yml")"
  check_eq "T1: envelope untouched by a refused run" "$envelope_after" "${DEFAULT_ENVELOPE%$'\n'}"
}

# ===========================================================================
# T2 — no hardcoded envelope field list: several representative dotted field
# names (including one recent addition, discover.label) must not appear as
# literals anywhere in config.sh's source.
# ===========================================================================
t2_no_hardcoded_field_list() {
  local -a representative=(
    "select.exclude_labels"
    "budget.max_issues"
    "merge.mode"
    "base.integration_branch"
    "discover.label"
    "discover.modules"
    "on_failure.skip_dependents"
  )
  local f found=""
  for f in "${representative[@]}"; do
    grep -qF "$f" "$CONFIG_SRC" && found+="$f "
  done
  if [[ -z "$found" ]]; then
    pass "T2: none of the representative schema field names appear as literals in config.sh"
  else
    fail "T2: found hardcoded field literal(s) in config.sh: $found"
  fi
}

# ===========================================================================
# T3 — a scripted run that changes one field produces a VALID envelope.
# ===========================================================================
t3_valid_change() {
  read -r dir home < <(_new_sandbox t3)
  _drive "$dir" "$home" \
    "2" \
    "select.require_readiness" \
    "no" \
    "y" \
    "b" \
    "q" \
    >/dev/null

  local show_out
  show_out="$( (cd "$dir" && HOME="$home" bash .devlead/scripts/envelope.sh show) 2>&1 )"
  contains "T3: envelope.sh show reports STATUS: ok after the change" "$show_out" "STATUS: ok"
  contains "T3: the field actually changed" "$show_out" "REQUIRE_READINESS: false"
}

# ===========================================================================
# T4 — a scripted run that WOULD produce an invalid envelope (merge.mode ->
# integration-branch without base.integration_branch declared) leaves the
# original file byte-identical, and reports the exact GAP.
# ===========================================================================
t4_invalid_change_reverts() {
  read -r dir home < <(_new_sandbox t4)
  local before after
  before="$(cat "$dir/.devlead/envelope.yml")"

  local out
  out="$(_drive "$dir" "$home" \
    "2" \
    "merge.mode" \
    "integration-branch" \
    "y" \
    "b" \
    "q")"

  after="$(cat "$dir/.devlead/envelope.yml")"
  check_eq "T4: envelope.yml is byte-for-byte unchanged after a reverted change" "$after" "$before"
  contains "T4: reports the change was reverted" "$out" "REVERTED"
  contains "T4: names the exact GAP from envelope.sh show" "$out" "requires base.integration_branch to be declared"
}

# ===========================================================================
# T5 — the token is never printed anywhere in config.sh's output, and the
# seeded file is written with mode 600.
# ===========================================================================
t5_token_never_leaks() {
  read -r dir home < <(_new_sandbox t5)
  local secret="DEVLEAD-TEST-TOKEN-a1b2c3d4e5"

  local out
  out="$(_drive "$dir" "$home" \
    "1" \
    "3" \
    "y" \
    "$secret" \
    "b" \
    "b" \
    "q")"

  not_contains "T5: the token never appears in config.sh's output" "$out" "$secret"

  local token_file="$home/.devlead/gh-token"
  if [[ -f "$token_file" ]]; then
    check_eq "T5: token file has content" "$(cat "$token_file")" "$secret"
    local perm; perm="$(stat -c '%a' "$token_file" 2>/dev/null || echo "")"
    check_eq "T5: token file mode is 600" "$perm" "600"
  else
    fail "T5: token file was not written at all"
  fi
}

# ===========================================================================
# T6 — wiring: config.sh is in the publish manifest AND the smoke manifest,
# and the `config` subcommand is in the CLI dispatch.
# ===========================================================================
t6_wiring() {
  local lib="$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh"
  grep -qF '.devlead/scripts/config.sh|' "$lib" \
    && pass "T6: config.sh is in bootstrap-lib.sh's publish manifest" \
    || fail "T6: config.sh missing from bootstrap-lib.sh's publish manifest"

  local smoke="$REPO_ROOT/test/smoke-pinned-release.sh"
  grep -qF '.devlead/scripts/config.sh' "$smoke" \
    && pass "T6: config.sh is named in smoke-pinned-release.sh" \
    || fail "T6: config.sh missing from smoke-pinned-release.sh"

  local cli="$REPO_ROOT/.devlead/bin/devlead"
  grep -q '^\s*config)\s*$' "$cli" \
    && pass "T6: 'config' is a case arm in the devlead CLI dispatch" \
    || fail "T6: 'config' is not dispatched by the devlead CLI"
  grep -qF 'config.sh' "$cli" \
    && pass "T6: the devlead CLI dispatch names config.sh" \
    || fail "T6: the devlead CLI dispatch does not reference config.sh"

  local makefile="$REPO_ROOT/Makefile"
  grep -qF 'test/unit-config-menu.sh' "$makefile" \
    && pass "T6: this test is wired into the Makefile" \
    || fail "T6: test/unit-config-menu.sh missing from the Makefile"
}

main() {
  t1_tty_gate
  t2_no_hardcoded_field_list
  t3_valid_change
  t4_invalid_change_reverts
  t5_token_never_leaks
  t6_wiring

  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
  rm -rf "$SANDBOX"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
