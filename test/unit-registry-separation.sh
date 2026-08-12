#!/usr/bin/env bash
# unit-registry-separation.sh — static guard proving the two DevLead
# enablement registries are never read across their intended boundary.
#
#   bash test/unit-registry-separation.sh
#
# DevLead has two enablement registries with different authority:
#   ~/.devlead/active-repos      — session-scoped, ephemeral, grants nothing
#                                   (devlead-active.sh, /arranquemos, /cerremos)
#   ~/.devlead/autonomous-repos  — durable, grants unsupervised branches,
#                                   commits and PRs (Inv 3 authority; sweep.sh,
#                                   sweep-loop.sh)
# This suite proves neither registry is read on the other's path, and locks
# that invariant before two sibling tasks (session expiry, the
# active-repos -> session-repos rename) touch the surrounding code.
#
# Covers: REQ-1 REQ-2 REQ-3 REQ-4 REQ-5 REQ-6 REQ-7 REQ-8 REQ-9 REQ-10 REQ-11
#
# SAFETY: pure STATIC scanner — every production source is read with
# `grep -nE`, none is ever executed. All fixtures live under a throwaway
# $SANDBOX in /tmp, never under $HOME or ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# ---------------------------------------------------------------------------
# Harness — copied verbatim (naming/style) from test/unit-doctor.sh
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SANDBOX="$(mktemp -d /tmp/devlead-registry-separation.XXXXXX)"

# ---------------------------------------------------------------------------
# Data block — registry identity + path-sets, rename-resilient (REQ-7).
# The coming active-repos -> session-repos rename touches ONLY this block;
# no assertion logic below hardcodes a registry literal inline.
# ---------------------------------------------------------------------------
SESSION_NAMES=( "active-repos" "session-repos" )      # current + post-rename
SESSION_VARS=( "ACTIVE_FILE" "SESSION_FILE" )
SESSION_SCRIPT="devlead-active.sh"                    # indirect authority — a
                                                       # bare mention is not a
                                                       # real read; only an
                                                       # actual on|off|check
                                                       # invocation counts.
AUTO_NAMES=( "autonomous-repos" )
AUTO_VARS=( "REPOS_FILE" )

# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $2)
AUTONOMOUS_ROOTS=( .devlead/scripts/sweep.sh .devlead/scripts/sweep-loop.sh )
# shellcheck disable=SC2034 # read through _set_diff_report's nameref (arg $2)
AUTONOMOUS_EXPECTED=( sweep.sh sweep-loop.sh envelope.sh bootstrap-lib.sh
                      state.sh run-state.sh doctor.sh )
AUTONOMOUS_EXTRA=( .claude/commands/sweep-execute.md )     # string-scan only
SESSION_PATH_SET=( .claude/hooks/post-edit.sh .claude/hooks/gate-check.sh
                   .devlead/scripts/devlead-active.sh )
# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $3)
CLOSURE_DIRS=( .devlead/scripts .claude/hooks )
# shellcheck disable=SC2034 # read through _set_diff_report's nameref (arg $2)
EXPECTED_UNRESOLVED=( install.sh )

# ---------------------------------------------------------------------------
# Regexes — joined from the data block above with `local IFS='|'`, never
# hardcoded literals inline (REQ-7).
# ---------------------------------------------------------------------------
_build_session_re() {
  local IFS='|'
  local names="${SESSION_NAMES[*]}"
  local vars="${SESSION_VARS[*]}"
  # Real-read shape for the indirect script: name optionally quote-closed,
  # then whitespace, then an actual subcommand. A bare mention (e.g. a
  # publish-manifest entry or a prose aside) does NOT match — see
  # bootstrap-lib.sh:226 (REQ-5) and envelope.sh:221 (REQ-4).
  local script_re="${SESSION_SCRIPT//./\\.}[\"']?[[:space:]]+(on|off|check)"
  printf '%s' "(${names}|${vars}|${script_re})"
}

_build_auto_re() {
  local IFS='|'
  local names="${AUTO_NAMES[*]}"
  local vars="${AUTO_VARS[*]}"
  printf '%s' "(${names}|${vars})"
}

SESSION_RE="$(_build_session_re)"
AUTO_RE="$(_build_auto_re)"

# EDGE_RE — the syntactic SHAPE of a call-graph edge: source/dot form,
# command-position bash|sh|exec (anchored to line-start or a preceding
# &&, ||, ;, |, ( — so a bare "sh" can never substring-match the "sh"
# inside a name like "envelope.sh"), or a scalar variable assignment
# ([local ]NAME=...). Deliberately NOT a bare "*.sh" basename mention:
# bootstrap-lib.sh's publish manifest names every script as an array
# element, and array elements always start with a quote — excluded here
# because a quoted line can never match either shape below.
EDGE_RE='^[[:space:]]*(source|\.)[[:space:]]+|(^|&&|\|\||;|\||\()[[:space:]]*(bash|sh|exec)[[:space:]]|^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='

# ---------------------------------------------------------------------------
# scan_file <abs> <rel-label> <regex> -> stdout: zero+ "rel:LINE: trimmed-src"
# Pure function, no globals, no exit — testable against fixtures with the
# harness above. Real-tree assertion: check "..." "$out" "".
# ---------------------------------------------------------------------------
scan_file() {
  local hit lineno src
  while IFS= read -r hit; do
    lineno="${hit%%:*}"; src="${hit#*:}"
    # Prose exemption (REQ-4): skip lines whose first non-blank char is '#'.
    # This same shell-comment semantics is applied uniformly to every scanned
    # file, including .claude/commands/sweep-execute.md (markdown) — that
    # file uses no '#'-prefixed lines mentioning either registry today, so
    # the strip is vacuously safe there, but the rule still applies if one
    # is ever added.
    [[ "$src" =~ ^[[:space:]]*# ]] && continue
    printf '%s:%s: %s\n' "$2" "$lineno" "${src#"${src%%[![:space:]]*}"}"
  done < <(grep -nE "$3" "$1" 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# _scan_edges <abs> -> stdout: zero+ basenames of *.sh files referenced on
# EDGE_RE-shaped lines. Only lines whose SHAPE is an edge are considered, and
# only literal *.sh tokens embedded in those lines are extracted — a
# variable-only reference (no literal basename on the line) yields nothing,
# which is exactly what keeps sweep.sh's `bash "$ENVELOPE_BIN" check` from
# producing a phantom edge distinct from its own `ENVELOPE_BIN=...envelope.sh`
# assignment line.
# ---------------------------------------------------------------------------
_scan_edges() {
  local f="$1" hit src base
  while IFS= read -r hit; do
    src="${hit#*:}"
    [[ "$src" =~ ^[[:space:]]*# ]] && continue
    while [[ "$src" =~ ([A-Za-z0-9_.-]+\.sh) ]]; do
      base="${BASH_REMATCH[1]}"
      printf '%s\n' "$base"
      src="${src#*"$base"}"
    done
  done < <(grep -nE "$EDGE_RE" "$f" 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# _closure_walk <base-dir> <roots-array-name> <closure-dirs-array-name>
# Derives the transitive closure of *.sh files reachable from the given
# roots via EDGE_RE-shaped lines, resolved against the given closure dirs.
# Populates the globals DERIVED_SET (resolved basenames, walk order) and
# UNRESOLVED_SET (basenames mentioned but never found under closure dirs).
# Also populates RESOLVED_PATH[basename] with the path (relative to
# base-dir) each derived basename was first resolved at.
# ---------------------------------------------------------------------------
declare -A RESOLVED_PATH=()

_closure_walk() {
  local base_dir="$1"
  local -n _roots="$2"
  local -n _cdirs="$3"

  local -a queue=( "${_roots[@]}" )
  local -A visited=()
  local -A unresolved_seen=()
  DERIVED_SET=()
  UNRESOLVED_SET=()
  RESOLVED_PATH=()

  local cur base edge resolved dir cand
  while [[ ${#queue[@]} -gt 0 ]]; do
    cur="${queue[0]}"
    queue=( "${queue[@]:1}" )
    base="$(basename "$cur")"
    [[ -n "${visited[$base]+_}" ]] && continue
    visited["$base"]=1
    DERIVED_SET+=( "$base" )
    RESOLVED_PATH["$base"]="$cur"

    while IFS= read -r edge; do
      [[ -n "$edge" ]] || continue
      [[ -n "${visited[$edge]+_}" ]] && continue
      resolved=""
      for dir in "${_cdirs[@]}"; do
        cand="$base_dir/$dir/$edge"
        if [[ -f "$cand" ]]; then
          resolved="$dir/$edge"
          break
        fi
      done
      if [[ -n "$resolved" ]]; then
        queue+=( "$resolved" )
      elif [[ -z "${unresolved_seen[$edge]+_}" ]]; then
        unresolved_seen["$edge"]=1
        UNRESOLVED_SET+=( "$edge" )
      fi
    done < <(_scan_edges "$base_dir/$cur")
  done
}

# ---------------------------------------------------------------------------
# _set_diff_report <derived-array-name> <expected-array-name>
# Compares two arrays as sets. Returns 0 and prints nothing when equal;
# returns 1 and prints a message naming every extra/missing entry otherwise
# (REQ-8: "FAIL naming any extra/missing entries on mismatch").
# ---------------------------------------------------------------------------
_set_diff_report() {
  local -n _derived="$1"
  local -n _expected="$2"
  local -a sorted_d=() sorted_e=()
  mapfile -t sorted_d < <(printf '%s\n' "${_derived[@]:-}" | sort -u)
  mapfile -t sorted_e < <(printf '%s\n' "${_expected[@]:-}" | sort -u)

  local -a extra=() missing=()
  local item d e found
  for item in "${sorted_d[@]}"; do
    [[ -n "$item" ]] || continue
    found=0
    for e in "${sorted_e[@]}"; do [[ "$item" == "$e" ]] && { found=1; break; }; done
    [[ "$found" -eq 0 ]] && extra+=( "$item" )
  done
  for item in "${sorted_e[@]}"; do
    [[ -n "$item" ]] || continue
    found=0
    for d in "${sorted_d[@]}"; do [[ "$item" == "$d" ]] && { found=1; break; }; done
    [[ "$found" -eq 0 ]] && missing+=( "$item" )
  done

  if [[ ${#extra[@]} -eq 0 && ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  local msg="closure mismatch"
  [[ ${#extra[@]} -gt 0 ]] && msg+=" — extra: ${extra[*]}"
  [[ ${#missing[@]} -gt 0 ]] && msg+=" — missing: ${missing[*]}"
  printf '%s' "$msg"
  return 1
}

# ===========================================================================
# Phase 4: Real-tree assertions (REQ-1, REQ-2, REQ-8, REQ-9 prep, REQ-11)
# ===========================================================================

# --- REQ-8: derive the autonomous closure, assert it equals the declaration
_closure_walk "$REPO_ROOT" AUTONOMOUS_ROOTS CLOSURE_DIRS

_derived_report="$(_set_diff_report DERIVED_SET AUTONOMOUS_EXPECTED)"
_derived_rc=$?
check "closure: derived autonomous set matches declared AUTONOMOUS_EXPECTED (REQ-8)" "$_derived_rc" "0"
[[ "$_derived_rc" -ne 0 ]] && echo "        $_derived_report"

_unresolved_report="$(_set_diff_report UNRESOLVED_SET EXPECTED_UNRESOLVED)"
_unresolved_rc=$?
check "closure: unresolved basenames match declared EXPECTED_UNRESOLVED (REQ-8)" "$_unresolved_rc" "0"
[[ "$_unresolved_rc" -ne 0 ]] && echo "        $_unresolved_report"

# --- REQ-1: nothing on the autonomous path (closure + extras) reads the
#     session registry.
_autonomous_out=""
for _base in "${DERIVED_SET[@]:-}"; do
  [[ -n "$_base" ]] || continue
  _rel="${RESOLVED_PATH[$_base]}"
  _autonomous_out+="$(scan_file "$REPO_ROOT/$_rel" "$_rel" "$SESSION_RE")"$'\n'
done
for _rel in "${AUTONOMOUS_EXTRA[@]}"; do
  _autonomous_out+="$(scan_file "$REPO_ROOT/$_rel" "$_rel" "$SESSION_RE")"$'\n'
done
_autonomous_out="$(printf '%s' "$_autonomous_out" | sed '/^$/d')"
check "no session-registry read on the autonomous path (REQ-1)" "$_autonomous_out" ""

# --- REQ-2: nothing on the session path reads the autonomous registry.
_session_out=""
for _rel in "${SESSION_PATH_SET[@]}"; do
  _session_out+="$(scan_file "$REPO_ROOT/$_rel" "$_rel" "$AUTO_RE")"$'\n'
done
_session_out="$(printf '%s' "$_session_out" | sed '/^$/d')"
check "no autonomous-registry read on the session path (REQ-2)" "$_session_out" ""

# 4.3 — a passing 4.1 above implicitly proves envelope.sh:221 (prose mention)
# and bootstrap-lib.sh:226 (manifest-string mention) both stay silent on the
# real tree; no separate assertion is needed beyond 4.1 passing.

# ===========================================================================
# Phase 5: Fixture self-tests (8 fixtures) — proves the scanner both detects
# real violations and stays quiet on the documented exemptions.
# ===========================================================================
FIXTURES="$SANDBOX/fixtures"
mkdir -p "$FIXTURES"

# --- Fixture 1: forward violation (fires) ---------------------------------
FIX_FORWARD="$FIXTURES/forward.sh"
cat > "$FIX_FORWARD" <<'EOF'
#!/usr/bin/env bash
_x="$HOME/.devlead/active-repos"
EOF
out="$(scan_file "$FIX_FORWARD" "fixtures/forward.sh" "$SESSION_RE")"
contains "fixture forward: session-registry read fires" "$out" "fixtures/forward.sh:2: _x=\"\$HOME/.devlead/active-repos\""

# --- Fixture 2: reverse violation (fires) ---------------------------------
FIX_REVERSE="$FIXTURES/reverse.sh"
cat > "$FIX_REVERSE" <<'EOF'
#!/usr/bin/env bash
_y="$HOME/.devlead/autonomous-repos"
EOF
out="$(scan_file "$FIX_REVERSE" "fixtures/reverse.sh" "$AUTO_RE")"
contains "fixture reverse: autonomous-registry read fires" "$out" "fixtures/reverse.sh:2: _y=\"\$HOME/.devlead/autonomous-repos\""

# --- Fixture 3: indirect authority via devlead-active.sh subcommand (fires)
FIX_INDIRECT="$FIXTURES/indirect.sh"
cat > "$FIX_INDIRECT" <<'EOF'
#!/usr/bin/env bash
bash "$HOME/.devlead/scripts/devlead-active.sh" check
EOF
out="$(scan_file "$FIX_INDIRECT" "fixtures/indirect.sh" "$SESSION_RE")"
contains "fixture indirect: devlead-active.sh subcommand invocation fires" "$out" "fixtures/indirect.sh:2:"

# --- Fixture 4: prose mention (silent — exercises the '#'-strip) ---------
FIX_PROSE="$FIXTURES/prose.sh"
cat > "$FIX_PROSE" <<'EOF'
#!/usr/bin/env bash
# design note: mirrors active-repos handling, no registry read here
EOF
out="$(scan_file "$FIX_PROSE" "fixtures/prose.sh" "$SESSION_RE")"
check "fixture prose: comment-only mention stays silent" "$out" ""

# --- Fixture 5: envelope.sh:221 verbatim (silent) -------------------------
FIX_ENVELOPE221="$FIXTURES/envelope-221.sh"
cat > "$FIX_ENVELOPE221" <<'EOF'
#!/usr/bin/env bash
  # pattern used elsewhere in this codebase (e.g. devlead-active.sh): a plain
EOF
out="$(scan_file "$FIX_ENVELOPE221" "fixtures/envelope-221.sh" "$SESSION_RE")"
check "fixture envelope-221: real prose case stays silent" "$out" ""

# --- Fixture 6: bootstrap-lib.sh:226 verbatim (silent) --------------------
FIX_MANIFEST226="$FIXTURES/manifest-226.sh"
cat > "$FIX_MANIFEST226" <<'EOF'
#!/usr/bin/env bash
    "$repo_dir/.devlead/scripts/devlead-active.sh|$devlead_dir/scripts/devlead-active.sh|x"
EOF
out="$(scan_file "$FIX_MANIFEST226" "fixtures/manifest-226.sh" "$SESSION_RE")"
check "fixture manifest-226: manifest-string mention stays silent" "$out" ""

# --- Fixture 7: closure happy-path (derives {a,b}, not c) -----------------
FIX7_ROOT="$FIXTURES/closure7"
mkdir -p "$FIX7_ROOT/scripts"
cat > "$FIX7_ROOT/scripts/a.sh" <<'EOF'
#!/usr/bin/env bash
B="$SCRIPT_DIR/b.sh"
local -a _pairs=(
  "$SCRIPT_DIR/c.sh|x"
)
EOF
cat > "$FIX7_ROOT/scripts/b.sh" <<'EOF'
#!/usr/bin/env bash
echo "leaf"
EOF
cat > "$FIX7_ROOT/scripts/c.sh" <<'EOF'
#!/usr/bin/env bash
echo "must not be walked — only reachable via an array element"
EOF
# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $2)
FIX7_ROOTS=( scripts/a.sh )
# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $3)
FIX7_DIRS=( scripts )
_closure_walk "$FIX7_ROOT" FIX7_ROOTS FIX7_DIRS
# shellcheck disable=SC2034 # read through _set_diff_report's nameref (arg $2)
FIX7_EXPECTED=( a.sh b.sh )
_fix7_report="$(_set_diff_report DERIVED_SET FIX7_EXPECTED)"
_fix7_rc=$?
check "fixture closure happy-path: derives {a.sh, b.sh}, not c.sh" "$_fix7_rc" "0"
[[ "$_fix7_rc" -ne 0 ]] && echo "        $_fix7_report"

# --- Fixture 8 (C4): closure-mismatch reported as FAIL, naming the entries
FIX8_ROOT="$FIXTURES/closure8"
mkdir -p "$FIX8_ROOT/scripts"
cat > "$FIX8_ROOT/scripts/root.sh" <<'EOF'
#!/usr/bin/env bash
X="$SCRIPT_DIR/child.sh"
EOF
cat > "$FIX8_ROOT/scripts/child.sh" <<'EOF'
#!/usr/bin/env bash
Y="$SCRIPT_DIR/grandchild.sh"
EOF
cat > "$FIX8_ROOT/scripts/grandchild.sh" <<'EOF'
#!/usr/bin/env bash
echo "leaf"
EOF
# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $2)
FIX8_ROOTS=( scripts/root.sh )
# shellcheck disable=SC2034 # read through _closure_walk's nameref (arg $3)
FIX8_DIRS=( scripts )
_closure_walk "$FIX8_ROOT" FIX8_ROOTS FIX8_DIRS
# Deliberately WRONG declaration — missing grandchild.sh — to prove the
# comparison reports a mismatch and names the missing entry, distinct from
# fixture 7's happy-path (equal-sets) case.
# shellcheck disable=SC2034 # read through _set_diff_report's nameref (arg $2)
FIX8_WRONG_EXPECTED=( root.sh child.sh )
_fix8_report="$(_set_diff_report DERIVED_SET FIX8_WRONG_EXPECTED)"
_fix8_rc=$?
check "fixture closure-mismatch: an undeclared call-graph member is detected" "$_fix8_rc" "1"
contains "fixture closure-mismatch: report names the missing entry" "$_fix8_report" "grandchild.sh"

# ===========================================================================
# Trailer
# ===========================================================================
echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
