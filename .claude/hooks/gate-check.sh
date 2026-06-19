#!/usr/bin/env bash
# Stop hook — gate check before session closes
# Accumulates ALL failures (never short-circuits) and reports them together.
# Escape hatch: DEVLEAD_FORCE_CLOSE=1 emits warning and exits 0.
#
# Gates:
#   1. No uncommitted changes (unstaged + staged)
#   2. Test runner passes (if detected) — result cached per tree state
#   3. shellcheck clean on changed .sh files
#
# Exit semantics (Stop hooks): exit 2 BLOCKS stoppage and feeds stderr back
# to Claude. exit 1 is advisory only — it does NOT gate anything.

set -uo pipefail

# ---------------------------------------------------------------------------
# Stop-loop guard — Claude Code sets stop_hook_active=true in the stdin JSON
# when the session already continued because of a Stop hook this turn.
# Without this guard, exit 2 loops forever: block → respond → Stop → block...
# ---------------------------------------------------------------------------
_hook_input="$(cat 2>/dev/null || true)"
if [[ -n "$_hook_input" ]] && command -v jq &>/dev/null; then
  if [[ "$(jq -r '.stop_hook_active // false' <<<"$_hook_input" 2>/dev/null)" == "true" ]]; then
    echo "gate-check: stop_hook_active — already gated this turn, allowing close" >&2
    exit 0
  fi
fi

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

  # Detect test runner: package.json → Makefile → go.mod → pyproject.toml
  if [[ -f "$PWD/package.json" ]]; then
    # Prefer test:run (single-pass, no watch) over test (may launch watch mode)
    if jq -e '.scripts["test:run"]' "$PWD/package.json" &>/dev/null 2>&1; then
      _runner="npm run test:run"
    elif jq -e '.scripts.test' "$PWD/package.json" &>/dev/null 2>&1; then
      _runner="npm test"
    fi
  elif [[ -f "$PWD/Makefile" ]]; then
    if grep -q '^test:' "$PWD/Makefile" 2>/dev/null; then
      _runner="make test"
    fi
  elif [[ -f "$PWD/go.mod" ]]; then
    _runner="go test ./..."
  elif [[ -f "$PWD/pyproject.toml" ]]; then
    # Python: only gate if pytest is actually configured/declared — otherwise
    # `pytest` would error on a project that uses a different runner.
    if grep -qE '\[tool\.pytest|pytest' "$PWD/pyproject.toml" 2>/dev/null; then
      # Prefer uv (lockfile or binary present) for hermetic deps; else fall
      # back to the active interpreter's module invocation.
      if [[ -f "$PWD/uv.lock" ]] || command -v uv &>/dev/null; then
        _runner="uv run pytest"
      else
        _runner="python -m pytest"
      fi
    fi
  fi

  if [[ -z "$_runner" ]]; then
    echo "gate-check: no test runner detected — skipping test gate" >&2
    return
  fi

  # --- Clean-tree guard: if nothing is staged or modified, the developer   ---
  # --- made no changes this session — no point gating on pre-existing       ---
  # --- failures that belong to the baseline, not to this work unit.         ---
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    local _dirty_count
    _dirty_count="$(
      { git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; } \
        | sort -u | grep -c .
    )" || _dirty_count=0
    if [[ "$_dirty_count" -eq 0 ]]; then
      echo "gate-check: working tree clean — skipping test gate (no changes to validate)" >&2
      return
    fi
  fi

  # --- Result cache: identical tree state → identical result. Long suites ---
  # --- (this repo: ~4 min) must run at most ONCE per tree state.          ---
  local _cache_dir="$HOME/.devlead/cache/gate-tests"
  mkdir -p "$_cache_dir"
  # Prune stale entries so the cache never grows unbounded
  find "$_cache_dir" -type f -mtime +7 -delete 2>/dev/null

  local _tree_key="" _cache_file=""
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    _tree_key="$(
      {
        git rev-parse HEAD 2>/dev/null
        git diff HEAD 2>/dev/null
        git status --porcelain 2>/dev/null
      } | sha256sum | cut -d' ' -f1
    )"
    _cache_file="$_cache_dir/$(basename "$PWD")-${_tree_key}"
  fi

  if [[ -n "$_cache_file" && -f "$_cache_file" ]]; then
    local _cached
    _cached="$(head -n 1 "$_cache_file")"
    echo "gate-check: tree unchanged since last run — cached result: $_cached" >&2
    if [[ "$_cached" != "pass" ]]; then
      _add_failure "Test runner failed: $_runner (cached — tree unchanged since last failing run)"
    fi
    return
  fi

  # --- Scoped pytest: narrow the run to tests relevant to the changed files. ---
  # --- Only pytest runners are scoped; npm/make/go are left untouched. When  ---
  # --- scoping cannot be PROVEN safe we fall back to the full suite. Speed    ---
  # --- never comes at the cost of silently under-testing.                     ---
  if [[ "$_runner" == *pytest* ]] && git rev-parse --is-inside-work-tree &>/dev/null; then
    local _changed=()
    while IFS= read -r _cf; do
      [[ -n "$_cf" ]] && _changed+=("$_cf")
    done < <(
      { git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only HEAD 2>/dev/null; } \
        | sort -u
    )

    # Defensive: if the changed set is empty here (no git / no HEAD / detached
    # weirdness) yet the cache/clean-tree guards let us through, prove nothing
    # and run everything.
    if [[ ${#_changed[@]} -eq 0 ]]; then
      echo "gate-check: pytest scope — no changed files resolved vs HEAD — running full suite" >&2
    else
      # Broad/core change patterns: anything that can affect tests globally.
      # Conservative and repo-agnostic — when matched, scope is abandoned.
      local _broad_re='(^|/)(pyproject\.toml|uv\.lock|requirements[^/]*\.txt|setup\.cfg|tox\.ini|conftest\.py)$|(^|/)(core|shared|common|db|database|config)/|^(app|src)/main\.py$|(^|/)migrations/'

      local _broad_hit="" _unmapped="" _f
      local _targets=()
      for _f in "${_changed[@]}"; do
        if [[ "$_f" =~ $_broad_re ]]; then
          _broad_hit="$_f"
          break
        fi
      done

      if [[ -n "$_broad_hit" ]]; then
        echo "gate-check: broad/core change ($_broad_hit) — running full suite" >&2
      else
        for _f in "${_changed[@]}"; do
          # A changed test file: target it directly if it still exists.
          if [[ "$_f" =~ (^|/)tests?/ ]]; then
            [[ -f "$_f" ]] && _targets+=("$_f")
            continue
          fi

          # A changed source file: derive a generic test directory candidate.
          #   app/modules/<X>/...  -> tests/<X>/
          #   app/<X>/...          -> tests/<X>/
          #   src/<X>/...          -> tests/<X>/
          local _cand=""
          if [[ "$_f" =~ ^app/modules/([^/]+)/ ]]; then
            _cand="tests/${BASH_REMATCH[1]}/"
          elif [[ "$_f" =~ ^(app|src)/([^/]+)/ ]]; then
            _cand="tests/${BASH_REMATCH[2]}/"
          fi

          if [[ -n "$_cand" && -d "$_cand" ]]; then
            _targets+=("$_cand")
          else
            # Source file we cannot map to an existing test target → unsafe to
            # scope; we must not silently skip whatever it might break.
            _unmapped="$_f"
            break
          fi
        done

        if [[ -n "$_unmapped" ]]; then
          echo "gate-check: unmapped change ($_unmapped) — running full suite" >&2
        elif [[ ${#_targets[@]} -eq 0 ]]; then
          echo "gate-check: no test targets resolved — running full suite" >&2
        else
          # Deduplicate targets while preserving order.
          local _seen=" " _deduped=() _t
          for _t in "${_targets[@]}"; do
            if [[ "$_seen" != *" $_t "* ]]; then
              _deduped+=("$_t")
              _seen+="$_t "
            fi
          done
          _runner="$_runner ${_deduped[*]}"
          echo "gate-check: scoped tests to: ${_deduped[*]}" >&2
        fi
      fi
    fi
  fi

  echo "gate-check: running tests: $_runner" >&2
  local _log="$_cache_dir/last-run.log"
  if eval "$_runner" >"$_log" 2>&1; then
    [[ -n "$_cache_file" ]] && echo "pass" >"$_cache_file"
  else
    [[ -n "$_cache_file" ]] && echo "fail" >"$_cache_file"
    _add_failure "Test runner failed: $_runner
$(tail -n 15 "$_log" | sed 's/^/    /')
    Full log: $_log"
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

# exit 2 is the ONLY code that blocks a Stop hook — stderr goes back to Claude.
# (exit 1 would be advisory only; the gate would never actually gate.)
echo "$_summary" >&2
exit 2
