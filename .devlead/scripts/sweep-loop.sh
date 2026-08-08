#!/usr/bin/env bash
# sweep-loop.sh — headless re-invocation of /sweep-execute.
#
# A sweep run lives inside one Claude session: when the turn ends, quota runs
# out, or the process dies, nothing starts it again. This is the outer loop —
# it re-invokes `claude -p` until the plan is exhausted or the iteration cap is
# reached, so an interrupted run resumes instead of stopping for the night.
#
# Usage:
#   sweep-loop.sh --plan <file> [--max-iterations N]
#   sweep-loop.sh [--max-iterations N] [-- <extra sweep-execute args>]
#
# Environment:
#   DEVLEAD_LOOP_DRYRUN=1   print the exact `claude -p` command per iteration
#                           and exit 0 without invoking anything
#   DEVLEAD_LOOP_MAX        default iteration cap (default 10; --max-iterations wins)
#   DEVLEAD_LOOP_SLEEP      seconds between iterations (default 5)
#   DEVLEAD_CLAUDE_BIN      claude binary (default: claude)
#
# Exit codes:
#   0  plan exhausted, cap reached, or dry run — all normal outcomes
#   1  usage error, or a plan file that cannot be read
#
# The cap is a backstop, never a schedule: with --plan the loop stops as soon as
# run-state.sh reports every task settled. Without one there is no completion
# signal, so the cap is the only bound and the loop always runs it out.

set -uo pipefail

_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
RUN_STATE="$_SCRIPT_DIR/run-state.sh"
CLAUDE_BIN="${DEVLEAD_CLAUDE_BIN:-claude}"
MAX_ITER="${DEVLEAD_LOOP_MAX:-10}"
SLEEP_SECS="${DEVLEAD_LOOP_SLEEP:-5}"
DRYRUN="${DEVLEAD_LOOP_DRYRUN:-0}"
PLAN_FILE=""
EXTRA_ARGS=""

_usage() {
  echo "usage: sweep-loop.sh --plan <file> [--max-iterations N]" >&2
  echo "       sweep-loop.sh [--max-iterations N] [-- <extra args>]" >&2
}

# --- Arguments -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN_FILE="${2:-}"
      if [[ -z "$PLAN_FILE" ]]; then
        echo "sweep-loop: --plan requires a file path" >&2
        _usage
        exit 1
      fi
      shift 2
      ;;
    --max-iterations)
      MAX_ITER="${2:-}"
      if ! [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || [[ "$MAX_ITER" -lt 1 ]]; then
        echo "sweep-loop: --max-iterations requires a positive integer" >&2
        exit 1
      fi
      shift 2
      ;;
    --)
      shift
      EXTRA_ARGS="$*"
      break
      ;;
    -h|--help)
      _usage
      exit 1
      ;;
    *)
      echo "sweep-loop: unknown argument '$1'" >&2
      _usage
      exit 1
      ;;
  esac
done

if [[ -n "$PLAN_FILE" && ! -f "$PLAN_FILE" ]]; then
  echo "sweep-loop: plan file not found: $PLAN_FILE" >&2
  exit 1
fi

# --- Run id: derived from plan CONTENT, matching sweep-execute Paso 8.0 -----
# Same plan -> same id -> the loop sees the progress the run recorded. Edit the
# plan and the id changes, which is a different run by definition.
RUN_ID=""
if [[ -n "$PLAN_FILE" ]]; then
  RUN_ID="plan-$(sha256sum "$PLAN_FILE" | cut -c1-16)"
fi

# --- Completion: every task in the plan has a recorded outcome -------------
# Only `done` ends a task. A parked one is retried next iteration, because PARK
# is not a pass (GOVERNANCE.md §A4) — but a task that parks every time would
# spin forever, so the cap still bounds the loop.
_plan_settled() {
  [[ -n "$PLAN_FILE" ]] || return 1
  command -v yq &>/dev/null || return 1
  [[ -x "$RUN_STATE" || -f "$RUN_STATE" ]] || return 1

  local _task _total=0 _done=0
  while IFS= read -r _task; do
    [[ -n "$_task" ]] || continue
    _total=$((_total + 1))
    if bash "$RUN_STATE" is-done "$RUN_ID" "$_task" 2>/dev/null; then
      _done=$((_done + 1))
    fi
  done < <(yq e '.tasks[].id' "$PLAN_FILE" 2>/dev/null)

  [[ "$_total" -gt 0 && "$_done" -eq "$_total" ]]
}

# --- The prompt each iteration would run -----------------------------------
# Built as a string, invoked through an argv array — never eval'd. A plan path
# containing a space stays one argument instead of becoming two.
_sweep_prompt() {
  local _prompt="/sweep-execute"
  [[ -n "$PLAN_FILE" ]] && _prompt="$_prompt --plan $PLAN_FILE"
  [[ -n "$EXTRA_ARGS" ]] && _prompt="$_prompt $EXTRA_ARGS"
  printf '%s' "$_prompt"
}

# Readable form for the dry run: what you would type, not %q's backslash soup.
_sweep_display() {
  printf '%s -p "%s"' "$CLAUDE_BIN" "$(_sweep_prompt)"
}

# --- Loop ------------------------------------------------------------------
_iter=0
while [[ "$_iter" -lt "$MAX_ITER" ]]; do
  _iter=$((_iter + 1))

  if _plan_settled; then
    echo "sweep-loop: every task in $PLAN_FILE is done — stopping after $((_iter - 1)) iteration(s)"
    exit 0
  fi

  if [[ "$DRYRUN" == "1" ]]; then
    echo "sweep-loop: [dry-run] iteration $_iter/$MAX_ITER would run:"
    echo "  $(_sweep_display)"
    if [[ "$_iter" -ge "$MAX_ITER" ]]; then
      echo "sweep-loop: [dry-run] iteration cap reached — nothing was invoked"
      exit 0
    fi
    continue
  fi

  echo "sweep-loop: iteration $_iter/$MAX_ITER — invoking $CLAUDE_BIN"
  "$CLAUDE_BIN" -p "$(_sweep_prompt)"
  _rc=$?
  echo "sweep-loop: iteration $_iter exited $_rc"

  if [[ "$_iter" -lt "$MAX_ITER" ]]; then
    sleep "$SLEEP_SECS"
  fi
done

if _plan_settled; then
  echo "sweep-loop: every task in $PLAN_FILE is done — stopping"
else
  echo "sweep-loop: iteration cap ($MAX_ITER) reached with work still outstanding"
fi
exit 0
