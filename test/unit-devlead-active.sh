#!/usr/bin/env bash
# unit-devlead-active.sh — regression coverage for .devlead/scripts/devlead-active.sh
#
#   bash test/unit-devlead-active.sh
#
# Covers .devlead/specs/plan-session-expiry.md REQ-1..REQ-11:
#   - REQ-1/REQ-2: on writes path<TAB>epoch, refreshes in place, absorbs
#     legacy bare lines, exactly one entry per path.
#   - REQ-3/REQ-4: check never mutates the file and evaluates freshness via a
#     fail-closed ladder (0 <= age < TTL*3600, else INERT).
#   - REQ-5: on/off rewrite via field-based matching that preserves foreign
#     lines byte-for-byte; check parses via the two-var read loop.
#   - REQ-6/REQ-7: configurable + pinned TTL, invalid overrides fall back to
#     the default and warn on stderr, never disabling the gate.
#   - REQ-8: check writes nothing to stdout.
#   - REQ-9: off removes by field match, both entry formats.
#   - REQ-11: this suite + the gate-check fixture + Makefile wiring.
#
# SAFETY: every scenario runs under an isolated $HOME inside a throwaway
# /tmp sandbox — never the real machine's ~/.devlead/active-repos. All
# invocations also pin GIT_CEILING_DIRECTORIES to the sandbox so a sandbox
# path never accidentally resolves to a real ancestor git repo.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.devlead/scripts/devlead-active.sh"
SANDBOX="$(mktemp -d /tmp/devlead-active.XXXXXX)"

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
# Fixture helpers
# ---------------------------------------------------------------------------

mkhome() { mktemp -d "$SANDBOX/home.XXXXXX"; }
mkroot() { mktemp -d "$SANDBOX/repo.XXXXXX"; }

# entry <path> <ts> — one path<TAB>ts fixture line (ts may be empty).
entry() { printf '%s\t%s' "$1" "$2"; }
# entry3 <path> <ts> <extra> — a malformed 3-field line.
entry3() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# write_file <home> [line ...] — (re)creates ~/.devlead/active-repos with the
# given lines. Called with no lines, it creates an empty (0-byte) file.
write_file() {
  local home="$1"
  shift
  mkdir -p "$home/.devlead"
  if [[ "$#" -eq 0 ]]; then
    : > "$home/.devlead/active-repos"
  else
    printf '%s\n' "$@" > "$home/.devlead/active-repos"
  fi
}

# ts_of <file> <path> — prints the ts field of the first line matching path,
# using the same field-based (not whole-line) comparison the script itself
# uses, so the test harness never depends on awk -v / grep -x either.
ts_of() {
  local f="$1" p="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%$'\t'*}" == "$p" ]]; then
      printf '%s' "${line#*$'\t'}"
      return 0
    fi
  done < "$f"
}

# count_for <file> <path> — counts lines whose path field equals <path>.
count_for() {
  local f="$1" p="$2" line n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "${line%%$'\t'*}" == "$p" ]] && n=$((n + 1))
  done < "$f"
  printf '%s' "$n"
}

# run_cmd <home> <cwd> <cmd> [ENV=val ...] — runs devlead-active.sh <cmd> with
# HOME=<home> and cwd=<cwd>, pinning GIT_CEILING_DIRECTORIES to the sandbox.
# Sets RUN_OUT, RUN_ERR, RUN_RC.
run_cmd() {
  local home="$1" cwd="$2" cmd="$3" errfile
  shift 3
  errfile="$(mktemp "$SANDBOX/stderr.XXXXXX")"
  RUN_OUT="$(cd "$cwd" && HOME="$home" GIT_CEILING_DIRECTORIES="$SANDBOX" env "$@" bash "$SCRIPT" "$cmd" 2>"$errfile")"
  RUN_RC=$?
  RUN_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

# run_cmd_noarg <home> <cwd> [ENV=val ...] — same as run_cmd but invokes the
# script with NO positional argument at all (proves the "${1:-check}" default).
run_cmd_noarg() {
  local home="$1" cwd="$2" errfile
  shift 2
  errfile="$(mktemp "$SANDBOX/stderr.XXXXXX")"
  RUN_OUT="$(cd "$cwd" && HOME="$home" GIT_CEILING_DIRECTORIES="$SANDBOX" env "$@" bash "$SCRIPT" 2>"$errfile")"
  RUN_RC=$?
  RUN_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

NOW="$(date -u +%s)"

# ===========================================================================
# check ladder (REQ-3, REQ-4) — pinned DEVLEAD_SESSION_TTL_HOURS=4 (14400s)
# so no scenario here depends on the real 16h default.
# ===========================================================================
TTL_SEC=$((4 * 3600))

g1_home="$(mkhome)"; g1_root="$(mkroot)"
write_file "$g1_home" "$(entry "$g1_root" "$NOW")"
run_cmd "$g1_home" "$g1_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: fresh entry (age 0) -> active" "$RUN_RC" "0"

g2_home="$(mkhome)"; g2_root="$(mkroot)"
write_file "$g2_home" "$(entry "$g2_root" "$((NOW - (TTL_SEC - 60)))")"
run_cmd "$g2_home" "$g2_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: age TTL*3600-60 -> active" "$RUN_RC" "0"

g3_home="$(mkhome)"; g3_root="$(mkroot)"
write_file "$g3_home" "$(entry "$g3_root" "$((NOW - TTL_SEC))")"
run_cmd "$g3_home" "$g3_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: age exactly TTL*3600 -> inert" "$RUN_RC" "1"

g4_home="$(mkhome)"; g4_root="$(mkroot)"
write_file "$g4_home" "$(entry "$g4_root" "$((NOW - (TTL_SEC + 60)))")"
g4_before="$(< "$g4_home/.devlead/active-repos")"
run_cmd "$g4_home" "$g4_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: expired -> inert" "$RUN_RC" "1"
g4_after="$(< "$g4_home/.devlead/active-repos")"
check "ladder: expired line still present verbatim after check" "$g4_after" "$g4_before"

g5_home="$(mkhome)"; g5_root="$(mkroot)"
write_file "$g5_home" "$g5_root"
run_cmd "$g5_home" "$g5_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: bare legacy line -> inert" "$RUN_RC" "1"

g6_home="$(mkhome)"; g6_root="$(mkroot)"
write_file "$g6_home" "$(entry "$g6_root" "$((NOW + 100000))")"
run_cmd "$g6_home" "$g6_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: future timestamp -> inert" "$RUN_RC" "1"

g7_home="$(mkhome)"; g7_root="$(mkroot)"
write_file "$g7_home" "$(entry "$g7_root" "abc")"
run_cmd "$g7_home" "$g7_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: non-numeric ts (abc) -> inert" "$RUN_RC" "1"

g8_home="$(mkhome)"; g8_root="$(mkroot)"
write_file "$g8_home" "$(entry "$g8_root" "")"
run_cmd "$g8_home" "$g8_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: empty ts field -> inert" "$RUN_RC" "1"

g9_home="$(mkhome)"; g9_root="$(mkroot)"
write_file "$g9_home" "$(entry "$g9_root" "-100")"
run_cmd "$g9_home" "$g9_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: negative ts (-100) -> inert" "$RUN_RC" "1"

g10_home="$(mkhome)"; g10_root="$(mkroot)"
write_file "$g10_home" "$(entry3 "$g10_root" "$NOW" "extra")"
run_cmd "$g10_home" "$g10_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: 3-field line -> inert" "$RUN_RC" "1"

g11_home="$(mkhome)"; g11_root="$(mkroot)"
run_cmd "$g11_home" "$g11_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: missing file -> inert" "$RUN_RC" "1"

g12_home="$(mkhome)"; g12_root="$(mkroot)"
write_file "$g12_home"
run_cmd "$g12_home" "$g12_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: empty file -> inert" "$RUN_RC" "1"

g13_home="$(mkhome)"; g13_root="$(mkroot)"; g13_other="$(mkroot)"
write_file "$g13_home" "$(entry "$g13_other" "$NOW")"
run_cmd "$g13_home" "$g13_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: path absent from file -> inert" "$RUN_RC" "1"

g14_home="$(mkhome)"; g14_root="$(mkroot)"; g14_other="$(mkroot)"
write_file "$g14_home" \
  "$(entry "$g14_root" "$NOW")" \
  "$(entry "$g14_other" "$((NOW - 999999))")"
run_cmd "$g14_home" "$g14_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: our fresh entry active despite another repo's expired entry" "$RUN_RC" "0"

g15_home="$(mkhome)"; g15_root="$(mkroot)"
write_file "$g15_home" \
  "$(entry "$g15_root" "$((NOW - 999999))")" \
  "$(entry "$g15_root" "$NOW")"
run_cmd "$g15_home" "$g15_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: stale-then-fresh duplicate -> active" "$RUN_RC" "0"

g16_home="$(mkhome)"; g16_root="$(mkroot)"
write_file "$g16_home" \
  "$(entry "$g16_root" "$NOW")" \
  "$(entry "$g16_root" "$((NOW - 999999))")"
run_cmd "$g16_home" "$g16_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: fresh-then-stale duplicate -> active" "$RUN_RC" "0"

g17_home="$(mkhome)"; g17_root="$SANDBOX/repo with space"
mkdir -p "$g17_root"
write_file "$g17_home" "$(entry "$g17_root" "$NOW")"
run_cmd "$g17_home" "$g17_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "ladder: path containing a space -> active" "$RUN_RC" "0"

# F2: a leading-zero timestamp ("09") is octal-looking — bash's $(( )) would
# error out on it if the ts regex accepted plain digits. It must be rejected
# by field validation (continue, not abort), and the scan must still reach a
# later well-formed fresh line for the same path.
g18_home="$(mkhome)"; g18_root="$(mkroot)"
write_file "$g18_home" \
  "$(entry "$g18_root" "09")" \
  "$(entry "$g18_root" "$NOW")"
run_cmd "$g18_home" "$g18_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "F2: leading-zero ts rejected without aborting scan of later valid entry" "$RUN_RC" "0"

# ===========================================================================
# check purity: silent stdout on both exit paths; file bytes untouched.
# ===========================================================================
run_cmd "$g1_home" "$g1_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "purity: stdout empty on active (exit 0) path" "$RUN_OUT" ""
p1_before="$(< "$g1_home/.devlead/active-repos")"
run_cmd "$g1_home" "$g1_root" check DEVLEAD_SESSION_TTL_HOURS=4
p1_after="$(< "$g1_home/.devlead/active-repos")"
check "purity: file bytes identical before/after on exit 0" "$p1_after" "$p1_before"

run_cmd "$g4_home" "$g4_root" check DEVLEAD_SESSION_TTL_HOURS=4
check "purity: stdout empty on inert (exit 1) path" "$RUN_OUT" ""
p2_before="$(< "$g4_home/.devlead/active-repos")"
run_cmd "$g4_home" "$g4_root" check DEVLEAD_SESSION_TTL_HOURS=4
p2_after="$(< "$g4_home/.devlead/active-repos")"
check "purity: file bytes identical before/after on exit 1" "$p2_after" "$p2_before"

# ===========================================================================
# TTL override (REQ-6, REQ-7)
# ===========================================================================
t1_home="$(mkhome)"; t1_root="$(mkroot)"
write_file "$t1_home" "$(entry "$t1_root" "$((NOW - 2 * 3600))")"
run_cmd "$t1_home" "$t1_root" check DEVLEAD_SESSION_TTL_HOURS=1
check "TTL override: TTL=1, age 2h -> inert" "$RUN_RC" "1"

t2_home="$(mkhome)"; t2_root="$(mkroot)"
write_file "$t2_home" "$(entry "$t2_root" "$((NOW - 20 * 3600))")"
run_cmd "$t2_home" "$t2_root" check DEVLEAD_SESSION_TTL_HOURS=48
check "TTL override: TTL=48, age 20h -> active" "$RUN_RC" "0"

for bad in abc 0 -5 16.5; do
  b1_home="$(mkhome)"; b1_root="$(mkroot)"
  write_file "$b1_home" "$(entry "$b1_root" "$((NOW - 1 * 3600))")"
  run_cmd "$b1_home" "$b1_root" check DEVLEAD_SESSION_TTL_HOURS="$bad"
  check "TTL override: invalid '$bad' falls back to default, 1h-old -> active" "$RUN_RC" "0"
  contains "TTL override: invalid '$bad' warns with offending value" "$RUN_ERR" "$bad"
  contains "TTL override: invalid '$bad' warns with fallback 16h" "$RUN_ERR" "16h"

  b2_home="$(mkhome)"; b2_root="$(mkroot)"
  write_file "$b2_home" "$(entry "$b2_root" "$((NOW - 17 * 3600))")"
  run_cmd "$b2_home" "$b2_root" check DEVLEAD_SESSION_TTL_HOURS="$bad"
  check "TTL override: invalid '$bad', 17h-old (default+1h) -> inert (default not disabled)" "$RUN_RC" "1"
done

e1_home="$(mkhome)"; e1_root="$(mkroot)"
write_file "$e1_home" "$(entry "$e1_root" "$((NOW - 1 * 3600))")"
run_cmd "$e1_home" "$e1_root" check DEVLEAD_SESSION_TTL_HOURS=""
check "TTL override: empty string -> default used, 1h-old -> active" "$RUN_RC" "0"
check "TTL override: empty string -> no stderr warning" "$RUN_ERR" ""

# ===========================================================================
# Default pin (REQ-6) — extract the literal from the script itself, then
# prove it is the EFFECTIVE default with the env var unset.
# ===========================================================================
DEFAULT_TTL="$(awk -F= '/^_TTL_DEFAULT_HOURS=/{print $2}' "$SCRIPT")"
check "default pin: _TTL_DEFAULT_HOURS literal is 16" "$DEFAULT_TTL" "16"

DEFAULT_SEC=$((DEFAULT_TTL * 3600))

d1_home="$(mkhome)"; d1_root="$(mkroot)"
write_file "$d1_home" "$(entry "$d1_root" "$((NOW - (DEFAULT_SEC - 120)))")"
run_cmd "$d1_home" "$d1_root" check
check "default pin: age D*3600-120, env unset -> active" "$RUN_RC" "0"

d2_home="$(mkhome)"; d2_root="$(mkroot)"
write_file "$d2_home" "$(entry "$d2_root" "$((NOW - (DEFAULT_SEC + 120)))")"
run_cmd "$d2_home" "$d2_root" check
check "default pin: age D*3600+120, env unset -> inert" "$RUN_RC" "1"

# ===========================================================================
# on (REQ-1, REQ-2, REQ-5)
# ===========================================================================
o1_home="$(mkhome)"; o1_root="$(mkroot)"
run_cmd "$o1_home" "$o1_root" on
check "on: creates ~/.devlead/active-repos" "$([[ -f "$o1_home/.devlead/active-repos" ]] && echo yes || echo no)" "yes"
o1_line="$(< "$o1_home/.devlead/active-repos")"
o1_ts="$(ts_of "$o1_home/.devlead/active-repos" "$o1_root")"
check "on: writes exactly one path<TAB>digits line" "$o1_line" "$(entry "$o1_root" "$o1_ts")"
check "on: ts field is all digits" "$([[ "$o1_ts" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes"

o2_home="$(mkhome)"; o2_root="$(mkroot)"
run_cmd "$o2_home" "$o2_root" on
run_cmd "$o2_home" "$o2_root" on
o2_n="$(count_for "$o2_home/.devlead/active-repos" "$o2_root")"
check "on: running twice still leaves exactly one entry" "$o2_n" "1"

o3_home="$(mkhome)"; o3_root="$(mkroot)"
write_file "$o3_home" "$(entry "$o3_root" "$((NOW - 999999))")"
run_cmd "$o3_home" "$o3_root" on
o3_ts="$(ts_of "$o3_home/.devlead/active-repos" "$o3_root")"
o3_after="$(date -u +%s)"
o3_age=$((o3_after - o3_ts))
check "on: refreshes a stale entry to a fresh timestamp" "$([[ "$o3_age" -ge 0 && "$o3_age" -le 10 ]] && echo yes || echo no)" "yes"

o4_home="$(mkhome)"; o4_root="$(mkroot)"
write_file "$o4_home" "$o4_root"
run_cmd "$o4_home" "$o4_root" on
run_cmd "$o4_home" "$o4_root" check
check "on: absorbs a bare legacy line for our path, subsequent check is active" "$RUN_RC" "0"
o4_n="$(count_for "$o4_home/.devlead/active-repos" "$o4_root")"
check "on: absorbing a legacy line leaves exactly one entry" "$o4_n" "1"

o5_home="$(mkhome)"; o5_root="$(mkroot)"
o5_foreign_bare="$SANDBOX/foreign-bare-repo"
o5_foreign_extra="$(entry3 "$SANDBOX/foreign-extra-repo" "$NOW" "extra")"
write_file "$o5_home" "$o5_foreign_bare" "$o5_foreign_extra"
run_cmd "$o5_home" "$o5_root" on
o5_after="$(< "$o5_home/.devlead/active-repos")"
contains "on: preserves a foreign bare line verbatim" "$o5_after" "$o5_foreign_bare"
contains "on: preserves a foreign 3-field line verbatim" "$o5_after" "$o5_foreign_extra"

o6_home="$(mkhome)"; o6_root="$(mkroot)"
run_cmd "$o6_home" "$o6_root" on
contains "on: prints the activation message" "$RUN_OUT" "DevLead activo en:"

o7_home="$(mkhome)"; o7_root="$(mkroot)"
run_cmd "$o7_home" "$o7_root" on DEVLEAD_SESSION_TTL_HOURS=garbage
check "on: no stderr even with a garbage TTL override (validation is check-only)" "$RUN_ERR" ""

# ===========================================================================
# off (REQ-3 n/a, REQ-9)
# ===========================================================================
f1_home="$(mkhome)"; f1_root="$(mkroot)"
run_cmd "$f1_home" "$f1_root" on
run_cmd "$f1_home" "$f1_root" off
f1_n="$(count_for "$f1_home/.devlead/active-repos" "$f1_root")"
check "off: removes its own timestamped entry" "$f1_n" "0"

f2_home="$(mkhome)"; f2_root="$(mkroot)"
write_file "$f2_home" "$f2_root"
run_cmd "$f2_home" "$f2_root" off
f2_n="$(count_for "$f2_home/.devlead/active-repos" "$f2_root")"
check "off: removes its own bare legacy line" "$f2_n" "0"

f3_home="$(mkhome)"; f3_root="$(mkroot)"; f3_foreign="$(mkroot)"
write_file "$f3_home" \
  "$(entry "$f3_root" "$NOW")" \
  "$(entry "$f3_foreign" "$NOW")"
run_cmd "$f3_home" "$f3_root" off
f3_after="$(< "$f3_home/.devlead/active-repos")"
contains "off: leaves a foreign entry verbatim" "$f3_after" "$(entry "$f3_foreign" "$NOW")"

f4_base="$SANDBOX/prefix-x"
mkdir -p "$f4_base/repo" "$f4_base/repo2"
f4_home="$(mkhome)"
write_file "$f4_home" \
  "$(entry "$f4_base/repo" "$NOW")" \
  "$(entry "$f4_base/repo2" "$NOW")"
run_cmd "$f4_home" "$f4_base/repo" off
f4_n_repo="$(count_for "$f4_home/.devlead/active-repos" "$f4_base/repo")"
f4_n_repo2="$(count_for "$f4_home/.devlead/active-repos" "$f4_base/repo2")"
check "off: exact-match, removes only the exact path (not a path-prefix sibling)" "$f4_n_repo" "0"
check "off: exact-match, sibling with a similar prefix survives" "$f4_n_repo2" "1"

f5_home="$(mkhome)"; f5_root="$(mkroot)"
run_cmd "$f5_home" "$f5_root" off
check "off: no file present -> exit 0" "$RUN_RC" "0"
contains "off: no file present -> still prints the deactivation message" "$RUN_OUT" "DevLead inactivo en:"
check "off: no file present -> creates nothing" "$([[ -e "$f5_home/.devlead/active-repos" ]] && echo yes || echo no)" "no"

f6_home="$(mkhome)"; f6_root="$(mkroot)"
run_cmd "$f6_home" "$f6_root" on
run_cmd "$f6_home" "$f6_root" off
run_cmd "$f6_home" "$f6_root" off
check "off: idempotent, second call still exits 0" "$RUN_RC" "0"

f7_home="$(mkhome)"; f7_root="$(mkroot)"
run_cmd "$f7_home" "$f7_root" on
run_cmd "$f7_home" "$f7_root" off DEVLEAD_SESSION_TTL_HOURS=garbage
check "off: no stderr on garbage TTL (validation is check-only)" "$RUN_ERR" ""

# ===========================================================================
# CLI (usage / defaults / hook-guard invocation form)
# ===========================================================================
c1_home="$(mkhome)"; c1_root="$(mkroot)"
run_cmd_noarg "$c1_home" "$c1_root"
check "CLI: no arg defaults to check (inert when nothing active)" "$RUN_RC" "1"

c2_home="$(mkhome)"; c2_root="$(mkroot)"
run_cmd "$c2_home" "$c2_root" bogus
check "CLI: bogus subcommand -> exit 2" "$RUN_RC" "2"
check "CLI: bogus subcommand -> stdout empty" "$RUN_OUT" ""
contains "CLI: bogus subcommand -> usage on stderr" "$RUN_ERR" "uso: devlead-active.sh"

c3_home="$(mkhome)"; c3_root="$(mkroot)"
write_file "$c3_home" "$(entry "$c3_root" "$((NOW - 999999))")"
(
  cd "$c3_root" || exit 1
  HOME="$c3_home" GIT_CEILING_DIRECTORIES="$SANDBOX" bash "$SCRIPT" check 2>/dev/null
)
c3_rc=$?
check "CLI: hook-guard invocation form is non-zero when expired" "$c3_rc" "1"

# ===========================================================================
# Self-wiring (REQ-11) — mirrors test/unit-config-menu.sh:264-267.
# ===========================================================================
w_makefile="$REPO_ROOT/Makefile"
w_hit="no"
grep -qF "test/unit-devlead-active.sh" "$w_makefile" && w_hit="yes"
check "self-wiring: this suite is referenced by the Makefile" "$w_hit" "yes"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
