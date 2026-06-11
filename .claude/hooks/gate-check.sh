#!/usr/bin/env bash
# Stop hook — gate check before session closes
# Accumulates ALL failures (never short-circuits) and reports them together.
# Escape hatch: DEVLEAD_FORCE_CLOSE=1 emits warning and exits 0.
#
# Gates:
#   1. No uncommitted changes (unstaged + staged)
#   2. Test runner passes (if detected)
#   3. shellcheck clean on changed .sh files

set -uo pipefail

# ---------------------------------------------------------------------------
# DevLead opt-in guard — inert unless /arranquemos activated THIS repo.
# DevLead is an opt-in mode, not an always-on daemon (DEVLEAD.md §2, decision 7).
# Without this guard a global Stop hook would block every session in every repo.
# ---------------------------------------------------------------------------
if ! bash "$HOME/.devlead/scripts/devlead-active.sh" check 2>/dev/null; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Accumulator — failures collected here, never thrown immediately
# ---------------------------------------------------------------------------
_failures=()
_add_failure() { _failures+=("$1"); }

# ---------------------------------------------------------------------------
# Gate 1: uncommitted changes (unstaged + staged)
# ---------------------------------------------------------------------------
_check_git_clean() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    # Not a git repo — skip silently (hook can fire outside repos)
    return
  fi

  local _dirty_files
  _dirty_files="$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
  if [[ -n "$_dirty_files" ]]; then
    _add_failure "Uncommitted changes:
$(echo "$_dirty_files" | sed 's/^/    /')"
  fi
}

# ---------------------------------------------------------------------------
# Gate 2: test runner (if detected)
# ---------------------------------------------------------------------------
_check_tests() {
  local _runner=""

  # Detect test runner: package.json → Makefile → go.mod
  if [[ -f "$PWD/package.json" ]]; then
    if jq -e '.scripts.test' "$PWD/package.json" &>/dev/null 2>&1; then
      _runner="npm test"
    fi
  elif [[ -f "$PWD/Makefile" ]]; then
    if grep -q '^test:' "$PWD/Makefile" 2>/dev/null; then
      _runner="make test"
    fi
  elif [[ -f "$PWD/go.mod" ]]; then
    _runner="go test ./..."
  fi

  if [[ -z "$_runner" ]]; then
    echo "gate-check: no test runner detected — skipping test gate" >&2
    return
  fi

  echo "gate-check: running tests: $_runner" >&2
  if ! eval "$_runner" >&2 2>&1; then
    _add_failure "Test runner failed: $_runner"
  fi
}

# ---------------------------------------------------------------------------
# Gate 3: shellcheck on changed .sh files
# ---------------------------------------------------------------------------
_check_shellcheck() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return
  fi

  if ! command -v shellcheck &>/dev/null; then
    echo "gate-check: shellcheck not found — skipping shellcheck gate" >&2
    return
  fi

  # Get .sh files that changed relative to HEAD (staged + unstaged)
  local _sh_files
  _sh_files="$(
    { git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only HEAD 2>/dev/null; } \
      | sort -u \
      | grep '\.sh$' \
      | xargs -r printf '%s\n' \
  )"

  if [[ -z "$_sh_files" ]]; then
    return
  fi

  local _sc_failures=()
  while IFS= read -r _f; do
    if [[ -f "$_f" ]]; then
      if ! shellcheck -S warning "$_f" >&2; then
        _sc_failures+=("$_f")
      fi
    fi
  done <<< "$_sh_files"

  if [[ ${#_sc_failures[@]} -gt 0 ]]; then
    _add_failure "shellcheck warnings/errors in: ${_sc_failures[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Run all gates (accumulate, don't short-circuit)
# ---------------------------------------------------------------------------
_check_git_clean
_check_tests
_check_shellcheck

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ ${#_failures[@]} -eq 0 ]]; then
  echo "✓ Gate passed — all checks clean" >&2
  exit 0
fi

# Build failure summary
_summary="✗ Gate failed (${#_failures[@]} issue(s)):"
for _i in "${!_failures[@]}"; do
  _summary+="
  $((${_i}+1)). ${_failures[$_i]}"
done
_summary+="

  Override: DEVLEAD_FORCE_CLOSE=1 claude ..."

# Escape hatch — must come AFTER building the summary so we can report all failures
if [[ "${DEVLEAD_FORCE_CLOSE:-0}" == "1" ]]; then
  echo "⚠ DEVLEAD_FORCE_CLOSE=1 — bypassing gate. Failed checks:" >&2
  echo "$_summary" >&2
  exit 0
fi

echo "$_summary" >&2
exit 1
