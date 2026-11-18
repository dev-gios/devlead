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
# PRESENTATION: these scenarios type "1", "2", "b" at the child, which is the
# numbered-prompt contract. config.sh renders through gum when gum is present,
# and gum's selector reads arrow keys — those digits mean nothing to it, so a
# machine with gum installed would hang here forever rather than fail. Hanging
# tests are worse than failing ones, so the opt-out is exported once, for the
# whole file: the scripted path always drives the plain prompts. The gum path
# has its own scenarios at the end, which assert the branch is chosen
# correctly without trying to type at a selector.
export DEVLEAD_NO_GUM=1
# config.sh refuses inside a Claude Code session (CLAUDECODE) and under a
# Claude Code ancestor. The suite may itself run in one, so the marker is
# dropped and every pty run starts outside this process tree (run_outside).
unset CLAUDECODE
# shellcheck source=test/lib-outside-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-outside-session.sh"
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
  local in
  in="$(lines_file "$SANDBOX" "$@")"
  HOME="$home" run_outside 60 "$in" "cd '$dir' && bash .devlead/scripts/config.sh"
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
    "3" \
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
    "3" \
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

# ===========================================================================
# T7 — the gum presentation branch
#
# The scenarios above deliberately run with DEVLEAD_NO_GUM=1, so without this
# the gum branch would ship completely unexercised. It cannot be driven by
# typing at it — that is the whole reason for the opt-out — so a stub `gum`
# earlier on PATH stands in for the selector and answers with a fixed label.
# That proves the branch is taken and its answer dispatched, which is what
# actually breaks; it does not try to test Charm's rendering.
# ===========================================================================
t7_gum_branch() {
  local dir home
  read -r dir home < <(_new_sandbox t7)

  # A stub gum that records every call and always picks the first real entry.
  local stubdir="$SANDBOX/t7/bin"
  mkdir -p "$stubdir"
  # The stub must eventually answer "Back", or the menu loop never ends: a
  # selector that always returns the first entry walks into a submenu, returns,
  # and is asked again forever. First call descends, every later call backs
  # out — enough to prove the branch works, and it terminates.
  cat > "$stubdir/gum" <<'STUB'
#!/usr/bin/env bash
echo "gum called: $*" >> "$GUM_CALLS"
# Real gum draws its selector on stderr and prints only the pick on stdout.
# The stub draws a marker the same way, so a caller that discards gum's
# stderr hides the menu from the person at the terminal, and this test sees it.
echo "gum drew: ${1:-}" >&2
case "${1:-}" in
  choose)
    n=$(cat "$GUM_CALLS.n" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GUM_CALLS.n"
    if [[ "$n" -eq 1 ]]; then head -n 1; else echo "Back"; fi
    ;;
  confirm) exit 1 ;;     # decline, so nothing is ever written by this test
  *) exit 0 ;;
esac
STUB
  chmod +x "$stubdir/gum"

  local calls="$SANDBOX/t7/gum-calls"; : > "$calls"
  local out
  out="$(HOME="$home" GUM_CALLS="$calls" PATH="$stubdir:$PATH" DEVLEAD_NO_GUM=0 \
      run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh")"

  contains "T7: gum is invoked when present and not opted out" \
    "$(cat "$calls")" "gum called: choose"
  contains "T7: the header names the repo being configured" \
    "$(cat "$calls")" "DevLead config"
  not_contains "T7: the numbered fallback prompt is not rendered too" \
    "$out" "b) Back"
  contains "T7: gum's selector reaches the terminal (gum draws on stderr)" \
    "$out" "gum drew: choose"
  # Every gum call keeps stderr, not only the one this run reaches: input and
  # the boolean chooser sit behind a field edit the stub does not walk into.
  not_contains "T7: no gum call in config.sh discards gum's stderr" \
    "$(grep -E 'gum (choose|input|confirm)' "$CONFIG_SRC" | grep -v '^[[:space:]]*#')" "2>/dev/null"

  # These two exercise the FALLBACK, which reads from the pty — so they must
  # be typed at, exactly like every other scenario here. Redirecting stdin from
  # /dev/null does not end the read: `script` owns the pty and keeps it open,
  # so the child waits forever instead of seeing EOF.
  #
  # The opt-out must win over an installed gum, or the whole suite is a lie.
  # The other direction — opt-out set, or gum absent — is NOT re-driven here on
  # purpose. Every scenario above already runs with DEVLEAD_NO_GUM=1 against a
  # machine that has gum installed, and they all reach the numbered prompts; if
  # the opt-out did not win, this file would hang rather than pass. That is
  # stronger coverage than one more pty invocation, and it cannot rot.
  #
  # The remaining half is the selection predicate itself, which is cheap to
  # assert directly and needs no terminal at all.
  local pred
  pred="$(sed -n '/^_has_gum()/,/^}/p' "$CONFIG_SRC")"
  contains "T7: the opt-out is checked before gum is looked up" \
    "$pred" "DEVLEAD_NO_GUM"
  contains "T7: gum availability is probed, not assumed" \
    "$pred" "command -v gum"
}

# ===========================================================================
# T8 — the unified fleet-enrollment screen (plain pty, DEVLEAD_NO_GUM=1),
# fleet-single-source-devlead REQ-3/REQ-4: per shape (listed+enabled,
# listed+disabled, listed+no-envelope), both halves + both grant lines +
# the derived verdict must render together on ONE screen, plus a fourth
# scenario proving the list-membership toggle actually writes
# ~/.devlead/autonomous-repos under the sandboxed $HOME.
# ===========================================================================
t8_fleet_screen_plain() {
  local dir home out

  # --- shape: listed + enabled ------------------------------------------
  read -r dir home < <(_new_sandbox t8-enabled)
  printf '%s' "${DEFAULT_ENVELOPE/enabled: false/enabled: true}" > "$dir/.devlead/envelope.yml"
  mkdir -p "$home/.devlead"
  printf '%s\n' "$dir" > "$home/.devlead/autonomous-repos"
  out="$(_drive "$dir" "$home" "2" "b" "q")"
  contains "T8 listed+enabled: fleet-list half shows 'listed'" \
    "$out" "fleet list (~/.devlead/autonomous-repos): listed"
  contains "T8 listed+enabled: fleet-list grant line present" \
    "$out" "WHERE the nightly sweep looks. Listing alone authorizes no work."
  contains "T8 listed+enabled: envelope half shows 'on'" \
    "$out" "envelope (.devlead/envelope.yml): on"
  contains "T8 listed+enabled: envelope grant line present" \
    "$out" "WHETHER this repo may work, and how far. Without it every visit ends in a skip."
  contains "T8 listed+enabled: verdict is 'runs tonight'" \
    "$out" "verdict: runs tonight"

  # --- shape: listed + disabled ------------------------------------------
  read -r dir home < <(_new_sandbox t8-disabled)
  mkdir -p "$home/.devlead"
  printf '%s\n' "$dir" > "$home/.devlead/autonomous-repos"
  out="$(_drive "$dir" "$home" "2" "b" "q")"
  contains "T8 listed+disabled: envelope half shows 'off'" \
    "$out" "envelope (.devlead/envelope.yml): off"
  contains "T8 listed+disabled: verdict is the deliberate-off wording" \
    "$out" "verdict: listed, deliberately off — nothing to fix"

  # --- shape: listed + no-envelope ---------------------------------------
  read -r dir home < <(_new_sandbox t8-missing)
  rm -f "$dir/.devlead/envelope.yml"
  mkdir -p "$home/.devlead"
  printf '%s\n' "$dir" > "$home/.devlead/autonomous-repos"
  out="$(_drive "$dir" "$home" "2" "b" "q")"
  contains "T8 listed+no-envelope: envelope half shows 'missing'" \
    "$out" "envelope (.devlead/envelope.yml): missing"
  contains "T8 listed+no-envelope: verdict is the broken-shape wording" \
    "$out" "verdict: listed but can never run — this is the broken shape"
  contains "T8 listed+no-envelope: dynamic action offers to create the envelope" \
    "$out" "Create the envelope here"

  # --- toggle: not-listed -> Add to fleet list writes autonomous-repos ---
  read -r dir home < <(_new_sandbox t8-toggle)
  _drive "$dir" "$home" "2" "1" "y" "b" "q" >/dev/null
  if [[ -f "$home/.devlead/autonomous-repos" ]] && grep -qxF "$dir" "$home/.devlead/autonomous-repos"; then
    pass "T8 toggle: 'Add to fleet list' wrote the repo into the sandboxed autonomous-repos"
  else
    fail "T8 toggle: autonomous-repos missing or does not contain the repo path"
  fi
}

# ===========================================================================
# T9 — the gum presentation branch for the fleet screen. T7's stub always
# picks the FIRST real entry, which cannot reach "Enrollment (this repo)"
# (it is the second top-level item) — this stub instead selects by LABEL
# text, wherever it sits in the list. `confirm` always declines, so this
# scenario never writes anything; a call counter caps the loop so a
# misbehaving selection can never hang the suite.
# ===========================================================================
t9_gum_branch_fleet() {
  local dir home
  read -r dir home < <(_new_sandbox t9)

  local stubdir="$SANDBOX/t9/bin"
  mkdir -p "$stubdir"
  cat > "$stubdir/gum" <<'STUB'
#!/usr/bin/env bash
echo "gum called: $*" >> "$GUM_CALLS"
case "${1:-}" in
  choose)
    n=$(cat "$GUM_CALLS.n" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GUM_CALLS.n"
    if [[ "$n" -eq 1 ]]; then
      # Select by LABEL, not first-entry: find "Enrollment (this repo)"
      # wherever it sits in the piped list (it is NOT the first item).
      grep -F "Enrollment (this repo)" || echo "Back"
    else
      # Every call after the first backs out — caps the loop instead of
      # re-descending into the fleet screen forever.
      echo "Back"
    fi
    ;;
  confirm) exit 1 ;;     # decline everywhere — this stub never writes anything
  *) exit 0 ;;
esac
STUB
  chmod +x "$stubdir/gum"

  local calls="$SANDBOX/t9/gum-calls"; : > "$calls"
  HOME="$home" GUM_CALLS="$calls" PATH="$stubdir:$PATH" DEVLEAD_NO_GUM=0 \
      run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh" >/dev/null

  contains "T9: gum is invoked for the fleet screen" \
    "$(cat "$calls")" "gum called: choose"
  contains "T9: the gum invocation carries the enrollment header" \
    "$(cat "$calls")" "Enrollment (this repo)"

  if [[ -f "$home/.devlead/autonomous-repos" ]]; then
    fail "T9: autonomous-repos was written despite confirm always declining"
  else
    pass "T9: nothing was written — confirm decline path honored"
  fi
}

# ===========================================================================
# T10 — envelope dispatch renders through _menu (plain pty,
# DEVLEAD_NO_GUM=1): "3" picks "Envelope (this repo)" from the main menu,
# "b" backs out of the field list without touching any field, "q" quits. The
# field list itself must come from _menu's own fallback renderer, not a
# hand-rolled printf loop — proven by the "===" header shape and the absence
# of the OLD "--- Envelope (" banner.
# ===========================================================================
t10_envelope_dispatch_via_menu() {
  read -r dir home < <(_new_sandbox t10)
  local out
  out="$(_drive "$dir" "$home" "3" "b" "q")"

  contains "T10: field list renders via _menu's fallback header shape" \
    "$out" "=== Envelope ("
  contains "T10: field list carries the 'b) Back' entry" "$out" "b) Back"
  contains "T10: the no-gum hint line is present" \
    "$out" "pick a number, or type a field's exact name"
  not_contains "T10: the old hand-rolled banner is gone" "$out" "--- Envelope ("
}

# ===========================================================================
# T10b — _input/_edit_field/_envelope_menu stay §A3-private: neither sweep
# script (the only two files that could smuggle the envelope screen into an
# autonomous path) references them at all.
# ===========================================================================
t10b_envelope_helpers_stay_private() {
  local -a helpers=(_input _edit_field _envelope_menu)
  local -a sweep_scripts=(
    "$REPO_ROOT/.devlead/scripts/sweep.sh"
    "$REPO_ROOT/.devlead/scripts/sweep-loop.sh"
  )
  local h s found=""
  for h in "${helpers[@]}"; do
    for s in "${sweep_scripts[@]}"; do
      [[ -f "$s" ]] || continue
      grep -qF "$h" "$s" && found+="$h in $(basename "$s") "
    done
  done
  if [[ -z "$found" ]]; then
    pass "T10b: none of _input/_edit_field/_envelope_menu are referenced by sweep.sh or sweep-loop.sh"
  else
    fail "T10b: found envelope-menu helper reference(s) in sweep scripts: $found"
  fi
}

# ===========================================================================
# T10c — the fallback-only dotted-name path (C4) still resolves through
# _menu's __invalid__<raw> return, and the unknown-option message names the
# TYPED text, never the raw __invalid__-prefixed value.
# ===========================================================================
t10c_dotted_name_unknown_option() {
  read -r dir home < <(_new_sandbox t10c)
  local out
  out="$(_drive "$dir" "$home" "3" "no.such.field" "b" "q")"

  contains "T10c: unknown dotted name reports the typed text" \
    "$out" "unknown option 'no.such.field'"
  not_contains "T10c: the raw __invalid__ prefix never leaks into the message" \
    "$out" "__invalid__no.such.field"
}

# ===========================================================================
# T10d — a blank Enter at the field picker backs out to the caller (the
# shared `_menu` "b" sentinel), matching `_machine_menu`/`_fleet_menu`/
# `_main_menu`'s contract since PR #23: "3" opens the envelope screen, a
# blank line submits nothing, and the main menu header must reappear exactly
# once more — proving `_envelope_menu` returned rather than redisplaying the
# field list (which would hang this pty-driven test on the final "q").
# ===========================================================================
t10d_blank_at_field_picker_backs_out() {
  read -r dir home < <(_new_sandbox t10d)
  local out
  out="$(_drive "$dir" "$home" "3" "" "q")"

  local main_menu_count field_list_count
  main_menu_count="$(grep -c "=== DevLead config" <<< "$out")"
  field_list_count="$(grep -c "=== Envelope (" <<< "$out")"
  check_eq "T10d: blank Enter at the field picker lands back on the main menu (re-rendered once, no redisplay loop)" \
    "$main_menu_count" "2"
  check_eq "T10d: the field picker itself was rendered exactly once, not looped" \
    "$field_list_count" "1"
}

# ===========================================================================
# T11 — gum branch: envelope dispatch + bool field editor. A stub gum
# buffers each call's piped stdin (the "options"), logs it, and picks by
# LABEL: call 1 picks "Envelope (" from the main menu, call 2 picks the
# padded "enabled" field-list row, every later call answers "Back" (the
# T7/T9 self-terminating idiom). `confirm` always declines, so nothing is
# ever committed — envelope.yml must stay byte-identical.
# ===========================================================================
t11_gum_envelope_dispatch_and_bool() {
  local dir home
  read -r dir home < <(_new_sandbox t11)

  local stubdir="$SANDBOX/t11/bin"
  mkdir -p "$stubdir"
  cat > "$stubdir/gum" <<'STUB'
#!/usr/bin/env bash
echo "gum called: $*" >> "$GUM_CALLS"
case "${1:-}" in
  choose)
    stub_opts="$(cat)"
    echo "gum options: $stub_opts" >> "$GUM_CALLS"
    n=$(cat "$GUM_CALLS.n" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GUM_CALLS.n"
    if [[ "$n" -eq 1 ]]; then
      printf '%s\n' "$stub_opts" | grep -F "Envelope ("
    elif [[ "$n" -eq 2 ]]; then
      printf '%s\n' "$stub_opts" | grep -E "^enabled +"
    else
      echo "Back"
    fi
    ;;
  confirm) exit 1 ;;     # decline everywhere — this stub never writes anything
  *) exit 0 ;;
esac
STUB
  chmod +x "$stubdir/gum"

  local calls="$SANDBOX/t11/gum-calls"; : > "$calls"
  local before after
  before="$(cat "$dir/.devlead/envelope.yml")"
  HOME="$home" GUM_CALLS="$calls" PATH="$stubdir:$PATH" DEVLEAD_NO_GUM=0 \
      run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh" >/dev/null
  after="$(cat "$dir/.devlead/envelope.yml")"

  contains "T11: envelope dispatch is rendered via gum choose with the Envelope header" \
    "$(cat "$calls")" "choose --header Envelope ("
  contains "T11: the bool field editor is rendered via its own gum choose header" \
    "$(cat "$calls")" "choose --header New value for enabled"
  # The dispatch call's own options block already contains the substrings
  # "true"/"false" (other fields' current values, e.g.
  # select.require_readiness), so a whole-log `contains` would pass even if
  # the bool widget never ran. Isolate the bool call's OWN options block —
  # the lines between its "gum called:" line and the next one — and assert
  # against exactly that.
  local bool_options_block
  bool_options_block="$(awk '
    /^gum called: choose --header New value for enabled$/ { capture=1; next }
    /^gum called:/ { capture=0 }
    capture
  ' "$calls")"
  check_eq "T11: the bool field editor's own options block is exactly true/false" \
    "$bool_options_block" "$(printf 'gum options: true\nfalse')"
  check_eq "T11: envelope.yml is byte-identical (confirm always declines)" "$after" "$before"
}

# ===========================================================================
# T12 — gum branch: int field prefill. The stub adds an `input)` arm (for
# `gum input`, invoked by `_input`) that logs its arguments and echoes a
# fixed new value, proving the widget is actually invoked with the current
# stored value as --value. `confirm` declines, so nothing is committed.
# ===========================================================================
t12_gum_input_prefill() {
  local dir home
  read -r dir home < <(_new_sandbox t12)

  local stubdir="$SANDBOX/t12/bin"
  mkdir -p "$stubdir"
  cat > "$stubdir/gum" <<'STUB'
#!/usr/bin/env bash
echo "gum called: $*" >> "$GUM_CALLS"
case "${1:-}" in
  choose)
    stub_opts="$(cat)"
    echo "gum options: $stub_opts" >> "$GUM_CALLS"
    n=$(cat "$GUM_CALLS.n" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GUM_CALLS.n"
    if [[ "$n" -eq 1 ]]; then
      printf '%s\n' "$stub_opts" | grep -F "Envelope ("
    elif [[ "$n" -eq 2 ]]; then
      printf '%s\n' "$stub_opts" | grep -E "^budget.max_issues +"
    else
      echo "Back"
    fi
    ;;
  input) echo "7" ;;
  confirm) exit 1 ;;     # decline — this stub never writes anything
  *) exit 0 ;;
esac
STUB
  chmod +x "$stubdir/gum"

  local calls="$SANDBOX/t12/gum-calls"; : > "$calls"
  local before after
  before="$(cat "$dir/.devlead/envelope.yml")"
  HOME="$home" GUM_CALLS="$calls" PATH="$stubdir:$PATH" DEVLEAD_NO_GUM=0 \
      run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh" >/dev/null
  after="$(cat "$dir/.devlead/envelope.yml")"

  contains "T12: gum input is invoked prefilled with the current stored value" \
    "$(cat "$calls")" "--value 3"
  check_eq "T12: envelope.yml is byte-identical (confirm declines)" "$after" "$before"
}

# ===========================================================================
# T13 — gum branch: nullable-time prefill with an UNSET field. `budget.stop_at`
# (type `"string (nullable HH:MM)"`) starts null in the fixture, so this is
# the only scenario that can tell a correct empty `--value ""` apart from a
# regression that accidentally prefills the DECORATED placeholder
# `_current_value` renders for the dispatch list (e.g. "(unset — default:
# null (no cutoff time))") — `_raw_value` must be what reaches `gum input`,
# never that label (D2). The stub's `input)` arm echoes blank, mirroring a
# blank submit; `confirm` declines everywhere (same self-terminating idiom as
# T11/T12), so envelope.yml must stay byte-identical either way.
# ===========================================================================
t13_gum_input_nullable_blank_prefill() {
  local dir home
  read -r dir home < <(_new_sandbox t13)

  local stubdir="$SANDBOX/t13/bin"
  mkdir -p "$stubdir"
  cat > "$stubdir/gum" <<'STUB'
#!/usr/bin/env bash
echo "gum called: $*" >> "$GUM_CALLS"
case "${1:-}" in
  choose)
    stub_opts="$(cat)"
    echo "gum options: $stub_opts" >> "$GUM_CALLS"
    n=$(cat "$GUM_CALLS.n" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GUM_CALLS.n"
    if [[ "$n" -eq 1 ]]; then
      printf '%s\n' "$stub_opts" | grep -F "Envelope ("
    elif [[ "$n" -eq 2 ]]; then
      printf '%s\n' "$stub_opts" | grep -E "^budget.stop_at +"
    else
      echo "Back"
    fi
    ;;
  input) echo "" ;;      # blank submit — the only discriminating prefill test
  confirm) exit 1 ;;     # decline — this stub never writes anything
  *) exit 0 ;;
esac
STUB
  chmod +x "$stubdir/gum"

  local calls="$SANDBOX/t13/gum-calls"; : > "$calls"
  local before after
  before="$(cat "$dir/.devlead/envelope.yml")"
  HOME="$home" GUM_CALLS="$calls" PATH="$stubdir:$PATH" DEVLEAD_NO_GUM=0 \
      run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh" >/dev/null
  after="$(cat "$dir/.devlead/envelope.yml")"

  local input_call
  input_call="$(grep '^gum called: input ' "$calls")"
  check_eq "T13: gum input for budget.stop_at is invoked with an EMPTY --value (raw null, not the decorated '(unset — ...)' placeholder)" \
    "$input_call" "gum called: input --header New value HH:MM, or blank to clear --value "
  not_contains "T13: the decorated 'unset' placeholder never reaches gum input" \
    "$input_call" "unset"
  check_eq "T13: envelope.yml is byte-identical (blank submit -> confirm decline)" "$after" "$before"
}

# ===========================================================================
# T14-T17 — Inv 3: a pty is not the user. config.sh refuses inside a Claude
# Code session (CLAUDECODE), under a Claude Code ancestor (found in /proc,
# whatever the environment says), and when /proc cannot be read on Linux.
# Every refusal happens before the envelope is read or written.
# ===========================================================================
_fake_ancestor() { # <name> — a copy of bash under that name: a renamed process
  local d="$SANDBOX/fake-ancestors"
  mkdir -p "$d"
  cp "$(command -v bash)" "$d/$1"
  printf '%s' "$d/$1"
}

t14_claudecode_refused() {
  local dir home out rc
  read -r dir home < <(_new_sandbox t14)
  out="$(HOME="$home" CLAUDECODE=1 run_outside 60 /dev/null "cd '$dir' && bash .devlead/scripts/config.sh")"; rc=$?
  [[ $rc -ne 0 ]] && pass "T14: refused inside a Claude Code session" || fail "T14: expected non-zero exit, got $rc"
  contains "T14: says it is a Claude Code session" "$out" "Claude Code session"
  contains "T14: points at the user's own terminal, not the ! prefix" "$out" "not through Claude Code's ! prefix"
  not_contains "T14: no menu was shown" "$out" "=== DevLead config"
  check_eq "T14: envelope untouched" "$(cat "$dir/.devlead/envelope.yml")" "${DEFAULT_ENVELOPE%$'\n'}"
}

t15_claude_ancestor_refused() {
  local dir home out rc claude in
  read -r dir home < <(_new_sandbox t15)
  claude="$(_fake_ancestor claude)"
  in="$(lines_file "$SANDBOX" 3 enabled yes y b q)"
  out="$(HOME="$home" run_outside 60 "$in" "'$claude' -c 'cd \"$dir\" && bash .devlead/scripts/config.sh; exit \$?'")"; rc=$?
  [[ $rc -ne 0 ]] && pass "T15: refused under a claude ancestor, with CLAUDECODE unset" || fail "T15: expected non-zero exit, got $rc"
  contains "T15: names Claude Code as the reason" "$out" "refusing to run under Claude Code"
  contains "T15: names the ancestor" "$out" "claude"
  contains "T15: points at the user's own terminal" "$out" "from your own terminal"
  not_contains "T15: no menu was shown" "$out" "=== DevLead config"
  check_eq "T15: envelope untouched" "$(cat "$dir/.devlead/envelope.yml")" "${DEFAULT_ENVELOPE%$'\n'}"
}

t16_node_claude_code_ancestor_refused() {
  local dir home out rc node
  read -r dir home < <(_new_sandbox t16)
  node="$(_fake_ancestor node)"
  out="$(HOME="$home" run_outside 60 /dev/null "'$node' -c 'cd \"$dir\" && bash .devlead/scripts/config.sh; exit \$?' /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js")"; rc=$?
  [[ $rc -ne 0 ]] && pass "T16: refused under node running Claude Code's CLI" || fail "T16: expected non-zero exit, got $rc"
  contains "T16: names Claude Code as the reason" "$out" "refusing to run under Claude Code"
  # A node process that is not Claude Code is no reason to refuse.
  out="$(HOME="$home" run_outside 60 "$(lines_file "$SANDBOX" q)" "'$node' -c 'cd \"$dir\" && bash .devlead/scripts/config.sh; exit \$?' /srv/app/server.js")"; rc=$?
  check_eq "T16: another node program as ancestor: config runs (exit 0)" "$rc" "0"
  contains "T16: ...and shows its menu" "$out" "=== DevLead config"
}

t17_proc_unreadable_fails_closed() {
  if ! unshare -rm true 2>/dev/null; then
    echo "NOTE  T17 skipped: unshare -rm is not available here"
    return 0
  fi
  local dir home out rc
  read -r dir home < <(_new_sandbox t17)
  out="$(HOME="$home" run_outside 60 /dev/null "unshare -rm bash -c 'mount -t tmpfs none /proc && cd \"$dir\" && bash .devlead/scripts/config.sh'")"; rc=$?
  [[ $rc -ne 0 ]] && pass "T17: /proc unreadable on Linux: refused (fail closed)" || fail "T17: expected non-zero exit, got $rc"
  contains "T17: says why" "$out" "cannot read /proc"
  check_eq "T17: envelope untouched" "$(cat "$dir/.devlead/envelope.yml")" "${DEFAULT_ENVELOPE%$'\n'}"
}

# ===========================================================================
# T18 — S25: a repo with an entry in the envelope store is edited there. The
# repo's own .devlead/envelope.yml is not written, and the screens name the
# file in use.
# ===========================================================================
t18_store_entry_is_the_file_edited() {
  read -r dir home < <(_new_sandbox t18)
  local entry repo_before out show_out
  entry="$home/.devlead/envelopes$(cd "$dir" && pwd -P)/envelope.yml"
  mkdir -p "$(dirname "$entry")"
  printf '%s' "$DEFAULT_ENVELOPE" > "$entry"
  repo_before="$(sha256sum < "$dir/.devlead/envelope.yml")"

  out="$(_drive "$dir" "$home" "3" "select.require_readiness" "no" "y" "b" "q")"

  check_eq "T18: the store entry holds the change" "$(yq e '.select.require_readiness' "$entry")" "false"
  check_eq "T18: the repo's own envelope.yml is byte-for-byte unchanged" \
    "$(sha256sum < "$dir/.devlead/envelope.yml")" "$repo_before"
  contains "T18: the editor names the store file" "$out" "Envelope ($entry)"
  show_out="$( (cd "$dir" && HOME="$home" bash .devlead/scripts/envelope.sh show) 2>&1 )"
  contains "T18: envelope.sh reads the changed value" "$show_out" "REQUIRE_READINESS: false"
  check_eq "T18: no backup or temporary file is left in the store" \
    "$(find "$(dirname "$entry")" -type f | wc -l | tr -d ' ')" "1"

  out="$(_drive "$dir" "$home" "2" "b" "q")"
  contains "T18: the enrollment screen names the store file" "$out" "envelope ($entry):"
}

main() {
  t1_tty_gate
  t2_no_hardcoded_field_list
  t3_valid_change
  t4_invalid_change_reverts
  t5_token_never_leaks
  t6_wiring
  t7_gum_branch
  t8_fleet_screen_plain
  t9_gum_branch_fleet
  t10_envelope_dispatch_via_menu
  t10b_envelope_helpers_stay_private
  t10c_dotted_name_unknown_option
  t10d_blank_at_field_picker_backs_out
  t11_gum_envelope_dispatch_and_bool
  t12_gum_input_prefill
  t13_gum_input_nullable_blank_prefill
  t14_claudecode_refused
  t15_claude_ancestor_refused
  t16_node_claude_code_ancestor_refused
  t17_proc_unreadable_fails_closed
  t18_store_entry_is_the_file_edited

  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
  rm -rf "$SANDBOX"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
