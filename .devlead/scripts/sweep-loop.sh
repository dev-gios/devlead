#!/usr/bin/env bash
# sweep-loop.sh — headless re-invocation of /sweep-execute.
#
# A sweep run lives inside one Claude session: when the turn ends, quota runs
# out, or the process dies, nothing starts it again. This is the outer loop —
# it re-invokes `claude -p` until the plan is exhausted or the iteration cap is
# reached, so an interrupted run resumes instead of stopping for the night.
#
# Usage:
#   sweep-loop.sh --plan <file> [--repo <path>] [--max-iterations N]
#   sweep-loop.sh [--repo <path>] [--max-iterations N] [-- <extra sweep-execute args>]
#
# Environment:
#   DEVLEAD_LOOP_DRYRUN=1   print the exact `claude -p` command per iteration
#                           and exit 0 without invoking anything
#   DEVLEAD_LOOP_MAX        default iteration cap (default 10; --max-iterations wins)
#   DEVLEAD_LOOP_SLEEP      seconds between iterations (default 5)
#   DEVLEAD_CLAUDE_BIN      claude binary (default: claude)
#   DEVLEAD_LOOP_REPO       target repo path to cd into before running; --repo wins
#                           when both are given (see FIX 7: the systemd unit has no
#                           WorkingDirectory pointed at a real repo, so LOCAL-PLAN's
#                           cwd-derived repo resolution needs an explicit target)
#
# Exit codes:
#   0  plan exhausted, cap reached, or dry run — all normal outcomes
#   1  usage error, a plan file that cannot be read, --repo does not exist,
#      or the resolved cwd is not inside a git work tree
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
REPO_DIR="${DEVLEAD_LOOP_REPO:-}"
EXTRA_ARGS=""

_usage() {
  echo "usage: sweep-loop.sh --plan <file> [--repo <path>] [--max-iterations N]" >&2
  echo "       sweep-loop.sh [--repo <path>] [--max-iterations N] [-- <extra args>]" >&2
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
    --repo)
      REPO_DIR="${2:-}"
      if [[ -z "$REPO_DIR" ]]; then
        echo "sweep-loop: --repo requires a directory path" >&2
        _usage
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

# Resolve PLAN_FILE to an absolute path BEFORE any --repo cd below, so a
# relative path typed from the caller's original cwd keeps working after
# the cwd moves.
if [[ -n "$PLAN_FILE" ]]; then
  case "$PLAN_FILE" in
    /*) ;;
    *) PLAN_FILE="$PWD/$PLAN_FILE" ;;
  esac
fi

# --- Target repo: --repo wins over $DEVLEAD_LOOP_REPO ----------------------
if [[ -n "$REPO_DIR" ]]; then
  if [[ ! -d "$REPO_DIR" ]]; then
    echo "sweep-loop: --repo/DEVLEAD_LOOP_REPO directory not found: $REPO_DIR" >&2
    exit 1
  fi
  cd "$REPO_DIR" || {
    echo "sweep-loop: could not cd into --repo/DEVLEAD_LOOP_REPO: $REPO_DIR" >&2
    exit 1
  }
fi

# --- Guard: refuse to run outside a git work tree ---------------------------
# LOCAL-PLAN resolves its target repo from cwd via `git rev-parse
# --show-toplevel` (FIX 7). Without this guard, a misconfigured systemd unit
# (no WorkingDirectory pointed at a real repo, no DEVLEAD_LOOP_REPO) lands
# cwd on something that is not a git repo — historically $HOME, systemd's
# default cwd for a user unit with no WorkingDirectory= — and the loop would
# silently no-op every night while systemd still reports success (oneshot
# exits 0). Fail loudly instead so the failure is visible.
#
# BUT this guard only applies when the run is cwd-dependent. `--fleet` mode
# enumerates ~/.devlead/autonomous-repos and is explicitly NOT cwd-dependent
# (documented planless `--fleet` usage line above) — requiring a git work
# tree at the invocation cwd for that form is a false positive. `--plan`
# takes precedence over `--fleet` in sweep-execute (LOCAL-PLAN wins even if
# `--fleet` is also passed through), so the plan check comes first: the run
# is cwd-dependent when --plan is given, OR when the extra args do NOT
# contain --fleet. If --repo/$DEVLEAD_LOOP_REPO was given explicitly (REPO_DIR
# set, handled by the cd block above), the operator asked for that directory
# — validate it regardless of fleet.
_cwd_dependent=true
if [[ -z "$PLAN_FILE" ]]; then
  case " $EXTRA_ARGS " in
    *" --fleet "*) _cwd_dependent=false ;;
  esac
fi
if [[ -n "$REPO_DIR" ]]; then
  _cwd_dependent=true
fi
if [[ "$_cwd_dependent" == "true" ]] && ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "sweep-loop: cwd is not inside a git work tree: $PWD" >&2
  echo "sweep-loop: pass --repo <path>, set \$DEVLEAD_LOOP_REPO, or run from inside a repo" >&2
  exit 1
fi

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
