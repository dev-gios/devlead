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
# The cwd-work-tree guard below defaults every invocation to cwd-dependent
# and skips ONLY when cwd-independence is positively proven: an exact --fleet
# token present AND no --plan anywhere AND no #N issue token anywhere (own
# flags or forwarded after `--`). See the guard's own comment block for why
# this must be derived from sweep-execute.md's mode-selector precedence
# rather than an enumerated flag list.
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
EXTRA_ARGS_ARR=()

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
      # Keep the array as the source of truth (word boundaries preserved) —
      # the flattened string below exists ONLY for building the display/prompt
      # text, never for flag detection (see the cwd guard below).
      EXTRA_ARGS_ARR=("$@")
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
# tree at the invocation cwd for that form is a false positive.
#
# THIS IS THE THIRD ATTEMPT AT THIS GUARD. Rounds 2 and 3 each patched the
# specific case a reviewer named (--plan forwarded after `--`, a flattened
# substring scan) and each missed the next one, because the guard enumerated
# cases instead of encoding the rule. `sweep-execute.md`'s "### Detección de
# modo (scoped vs plan-driven)" section defines the mode selection this guard
# must mirror, and it has THREE selectors, checked in this documented
# precedence order:
#   1. any `#N` token present        → MODO SCOPED       — cwd-dependent,
#      wins over --fleet
#   2. else `--plan <file>` present  → MODO LOCAL-PLAN    — cwd-dependent,
#      wins over --fleet
#   3. else `--fleet` present        → SCOPE = fleet      — NOT cwd-dependent
#      (enumerates ~/.devlead/autonomous-repos)
#   4. else                          → SCOPE = cwd         — cwd-dependent
#
# So instead of enumerating flags, the default is INVERTED: every invocation
# is treated as cwd-dependent, and the guard is skipped ONLY when
# cwd-independence is POSITIVELY PROVEN — the single proof being selector 3
# with both selector 1 and selector 2 absent. Concretely: an exact --fleet
# token is present AND no --plan appears anywhere (sweep-loop's own $PLAN_FILE
# or the extra-args array) AND no #N issue token appears anywhere in the
# extra-args array. Every other combination stays cwd-dependent and gets the
# guard — the fail-safe direction. If --repo/$DEVLEAD_LOOP_REPO was given
# explicitly (REPO_DIR set, handled by the cd block above), the operator
# asked for that directory — validate it regardless of the proof above.
#
# All three selectors are looked up as exact tokens across BOTH sweep-loop's
# own flags and the extra-args ARRAY (never a flattened/joined string — a
# quoted value that merely CONTAINS the text "--fleet" or "#1" must not
# count, which is why $EXTRA_ARGS_ARR is kept as an array instead of "$*").
#
# COUPLING WARNING: this rule is derived from sweep-execute.md's mode
# selectors, not independently invented. ANY new mode selector added to that
# "Detección de modo" section MUST be reflected here, or this guard will
# silently under-fire again — exactly like rounds 2 and 3.
_array_has_token() {
  # Exact match against array elements only, plus the --name=value form.
  # No substring matching against a joined string.
  local _needle="$1"; shift
  local _tok
  for _tok in "$@"; do
    [[ "$_tok" == "$_needle" || "$_tok" == "${_needle}="* ]] && return 0
  done
  return 1
}
_array_has_issue_token() {
  # Selector 1 (MODO SCOPED): an exact `#N` token, N one or more digits.
  # Same token shape as batch.md B0 "### Parsear la cola". No substring
  # matching against a joined string — a value like "#notanumber" must not
  # count, and neither must "--fleet" merely containing a "#" elsewhere.
  local _tok
  for _tok in "$@"; do
    [[ "$_tok" =~ ^#[0-9]+$ ]] && return 0
  done
  return 1
}
_extra_has_fleet=false
_extra_has_plan=false
_extra_has_issue=false
if [[ ${#EXTRA_ARGS_ARR[@]} -gt 0 ]]; then
  _array_has_token "--fleet" "${EXTRA_ARGS_ARR[@]}" && _extra_has_fleet=true
  _array_has_token "--plan" "${EXTRA_ARGS_ARR[@]}" && _extra_has_plan=true
  _array_has_issue_token "${EXTRA_ARGS_ARR[@]}" && _extra_has_issue=true
fi

# Positive proof of cwd-independence (selector 3 alone, selectors 1 and 2
# both absent). Everything else defaults to cwd-dependent.
_cwd_independent=false
if [[ -z "$PLAN_FILE" && "$_extra_has_plan" == "false" && "$_extra_has_issue" == "false" && "$_extra_has_fleet" == "true" ]]; then
  _cwd_independent=true
fi
_cwd_dependent=true
[[ "$_cwd_independent" == "true" ]] && _cwd_dependent=false
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
