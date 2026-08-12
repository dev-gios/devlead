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
# Two guards protect this loop from running a cwd-dependent sweep-execute
# outside a git work tree, and they are NOT redundant — one is a fast path,
# the other is the actual guarantee:
#
# 1. PRE-CHECK (fast path, best-effort). Before spending a `claude -p`
#    invocation, this loop tries to PREDICT whether the dispatched
#    /sweep-execute will resolve its repo from cwd, by inspecting its own
#    argv. It defaults every invocation to cwd-dependent and skips ONLY when
#    cwd-independence is positively proven: an exact --fleet token present
#    AND no --plan anywhere AND no #N issue token forwarded after `--`. See
#    the guard's own comment block below for why this must be derived from
#    sweep-execute.md's mode-selector precedence rather than an enumerated
#    flag list. It is worth keeping — it fails fast, before paying for an
#    invocation — but five rounds of adversarial review established that it
#    CANNOT be made exact here, so it is not the safety property.
#
# 2. REACTIVE CHECK (the guarantee). sweep-execute's own PRE-repo early
#    exits print `STATUS: not-a-git-repo` as the first line of their output
#    when they cannot resolve a repo from cwd (see sweep-execute.md's
#    "Detección de modo" — the contract note under the first such block).
#    After every iteration this loop scans the captured output for that
#    line. A hit means the dispatched invocation structurally could not
#    work, no matter what the pre-check predicted — so the loop stops and
#    exits non-zero instead of quietly re-invoking the same broken
#    invocation N more times. Whatever the pre-check misses, this catches,
#    loudly.
#
# KNOWN LIMITATION (of the pre-check only) — it inspects the argv ARRAY;
# sweep-execute only ever sees the FLATTENED prompt string, and its mode
# detection is natural language read by an LLM. batch.md's queue grammar,
# which sweep-execute imports verbatim for MODO SCOPED, accepts "cualquier
# variante en español con números de issue precedidos de `#`" — an open
# grammar no shell regex can mirror. So these two shapes still slip past the
# pre-check and it does not fail fast for them, even though the dispatched
# run is SCOPED and does resolve its repo from cwd:
#
#   sweep-loop.sh -- --fleet '#12,'                        (comma-suffixed)
#   sweep-loop.sh -- --fleet --note "closes #42 tonight"   (#N inside a value)
#
# Neither shape is used by any shipped systemd unit; both require hand-passing
# free text alongside --fleet from a non-repo directory. But they are no
# longer a silent no-op: the reactive check catches BOTH of them after the
# first iteration, because sweep-execute still emits `STATUS: not-a-git-repo`
# when it cannot resolve a repo, regardless of which shape reached it. The
# loop reports the failure and exits non-zero instead of re-invoking a
# structurally broken command up to the iteration cap. This is what closes
# the gap the five review rounds escalated — not by making the pre-check
# exact (proven impossible), but by making the loop react to what actually
# happened instead of only predicting what will happen. Prediction belongs
# where the knowledge is, and the knowledge is in sweep-execute, not in the
# loop that invokes it.
#
# Environment:
#   DEVLEAD_LOOP_DRYRUN=1   print the exact `claude -p` command per iteration
#                           and exit 0 without invoking anything (the reactive
#                           check never fires in this mode — claude is never
#                           invoked, so there is no output to scan)
#   DEVLEAD_LOOP_MAX        default iteration cap (default 10; --max-iterations wins)
#   DEVLEAD_LOOP_SLEEP      seconds between iterations (default 5)
#   DEVLEAD_LOOP_STALL      consecutive no-change iterations tolerated before
#                           the loop declares convergence and stops (default 2;
#                           0 disables the check and restores cap-only bounding)
#   DEVLEAD_CLAUDE_BIN      claude binary (default: claude)
#   DEVLEAD_LOOP_REPO       target repo path to cd into before running; --repo wins
#                           when both are given (see FIX 7: the systemd unit has no
#                           WorkingDirectory pointed at a real repo, so LOCAL-PLAN's
#                           cwd-derived repo resolution needs an explicit target)
#   DEVLEAD_ALLOW_DRIFT=1   escape hatch for supervised development: proceed even
#                           when the drift guard below (doctor.sh) reports the
#                           published artifacts are stale or unreviewed. Prints a
#                           prominent multi-line warning naming what differs — this
#                           is meant to be impossible to miss in a journal, never
#                           the default posture for an unattended run.
#   DEVLEAD_DOCTOR_BIN      doctor.sh binary the drift guard invokes (default:
#                           the sibling doctor.sh next to this script) — override
#                           for testing with a stub.
#
# DRIFT GUARD — this loop IS the unattended path; a human typing
# /sweep-execute interactively does not go through it, and can eyeball
# whether their own checkout looks right. Before the FIRST invocation this
# loop runs doctor.sh, which reports whether the artifacts published to this
# machine (gate-check.sh, envelope.sh's A3 guard, the governance mirrors in
# the command files, this very script) are INTEGRITY-ok — do they match some
# coherent commit at all — and separately, as PROVENANCE, whether that
# commit IS the reviewed trunk (see doctor.sh's own header comment for the
# full split). doctor.sh's exit code alone answers only the integrity
# question: it exits 0 for BOTH "matches the trunk" and "matches a branch
# tip during active development" — both are coherent installs. This loop's
# question is narrower than doctor.sh's: an UNATTENDED run must use
# REVIEWED artifacts specifically, so it does not key off doctor.sh's exit
# code alone. Instead it reads doctor.sh's own STATUS/NOTE lines and
# proceeds only when the installed set matches the trunk with no provenance
# NOTE attached. Anything else — STATUS: drifted, STATUS: unknown, or
# STATUS: ok with a provenance NOTE (installed from some other branch) — is
# treated the same way: the loop refuses to run, naming exactly which of the
# three it saw. See the guard block below for the exact remedy printed.
# Skipped ENTIRELY under DEVLEAD_LOOP_DRYRUN=1, deliberately: nothing is
# invoked in dry-run, so there is nothing at risk running against whatever
# happens to be installed, and dry-run is also how the guard's own wiring
# gets tested without a real git sandbox.
#
# Exit codes:
#   0  plan exhausted, cap reached, or dry run — all normal outcomes
#   1  usage error, a plan file that cannot be read, --repo does not exist,
#      the resolved cwd is not inside a git work tree (pre-check), the
#      installed artifacts do not verify as the reviewed trunk — doctor.sh
#      reported drifted, unknown, or ok-but-from-a-branch (drift guard,
#      unless DEVLEAD_ALLOW_DRIFT=1) — or a dispatched invocation reported
#      `STATUS: not-a-git-repo` (reactive check) — in these cases the loop
#      stops immediately, it does not keep iterating
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
# Consecutive no-change iterations tolerated before the loop declares it has
# converged. 1 stops at the first repeat; 0 disables the check and restores the
# old cap-only behaviour. Default 2, so one repeat is treated as a possible
# flake and two as a pattern.
STALL_LIMIT="${DEVLEAD_LOOP_STALL:-2}"
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

# --- Drift guard: refuse to run unattended against stale/unreviewed artifacts
# See the header comment above for the full rationale. Skipped entirely under
# DEVLEAD_LOOP_DRYRUN=1 — dry-run invokes nothing, so nothing is at risk.
#
# doctor.sh's exit code answers INTEGRITY only (does the install match SOME
# commit at all) — it is 0 for both "matches the trunk" and "matches a
# branch tip". This loop's bar is PROVENANCE: the matched commit must BE the
# trunk. So the exit code alone is not read here; doctor.sh's own STATUS and
# NOTE lines are parsed to tell the three refusal cases apart from the one
# case that is allowed to proceed unattended.
DOCTOR_BIN="${DEVLEAD_DOCTOR_BIN:-$_SCRIPT_DIR/doctor.sh}"
if [[ "$DRYRUN" != "1" ]]; then
  _DOCTOR_OUT="$(bash "$DOCTOR_BIN" 2>&1)"
  _DOCTOR_STATUS="$(printf '%s\n' "$_DOCTOR_OUT" | grep -m1 '^STATUS: ' | sed 's/^STATUS: //')"
  _DOCTOR_HAS_NOTE=false
  printf '%s\n' "$_DOCTOR_OUT" | grep -q '^NOTE:' && _DOCTOR_HAS_NOTE=true

  # The only case allowed to proceed unattended: doctor.sh matched the
  # installed set to the trunk itself, with no provenance NOTE attached.
  _TRUNK_VERIFIED=false
  if [[ "$_DOCTOR_STATUS" == "ok" && "$_DOCTOR_HAS_NOTE" == "false" ]]; then
    _TRUNK_VERIFIED=true
  fi

  if [[ "$_TRUNK_VERIFIED" == "false" ]]; then
    if [[ "${DEVLEAD_ALLOW_DRIFT:-0}" == "1" ]]; then
      {
        echo "############################################################"
        echo "# sweep-loop: DEVLEAD_ALLOW_DRIFT=1 — PROCEEDING ANYWAY.  #"
        echo "# The published DevLead artifacts on this machine do NOT  #"
        echo "# verify as the repo's reviewed trunk (see doctor.sh      #"
        echo "# output below for exactly why). This run uses UNREVIEWED #"
        echo "# OR STALE artifacts, including whatever code enforces    #"
        echo "# DevLead's own limits. Do not leave this set for         #"
        echo "# unattended/nightly runs.                                #"
        echo "############################################################"
        echo "$_DOCTOR_OUT"
      } >&2
    else
      _reason="doctor.sh did not report a recognizable STATUS — refusing to run unattended"
      case "$_DOCTOR_STATUS" in
        drifted)
          _reason="doctor.sh reports STATUS: drifted (integrity) — the installed artifacts do not match any known commit — refusing to run unattended"
          ;;
        unknown)
          _reason="doctor.sh reports STATUS: unknown — the reviewed trunk could not be resolved — refusing to run unattended"
          ;;
        ok)
          _reason="doctor.sh reports STATUS: ok but from a branch, not the trunk (provenance) — installed artifacts are coherent but not reviewed — refusing to run unattended"
          ;;
      esac
      {
        echo "sweep-loop: $_reason"
        echo "$_DOCTOR_OUT"
        echo "sweep-loop: remedy: git checkout <trunk> && git pull && bash install.sh"
        echo "sweep-loop: escape hatch for supervised development: DEVLEAD_ALLOW_DRIFT=1"
      } >&2
      exit 1
    fi
  fi
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

# --- Convergence detection --------------------------------------------------
# The cap above bounds the loop; it does not detect that the loop has stopped
# learning. Those are different jobs, and only the first one was being done: a
# plan whose tasks all park for the same reason re-invokes until the cap, each
# iteration paying a full `claude -p` to reproduce the previous verdict. That
# is not hypothetical — the first unattended run on this repo burned ten
# identical iterations, 3h09m wall, to park the same three tasks on the same
# root cause every time.
#
# The signal is the run-state itself: task, status and park reason. A reason
# that CHANGES means the agent learned something and the next iteration is
# worth paying for, even when the status stays `parked`. A snapshot identical
# to the previous one means it did not.
_run_snapshot() {
  [[ -n "$PLAN_FILE" ]] || return 0
  command -v yq &>/dev/null || return 0
  [[ -x "$RUN_STATE" || -f "$RUN_STATE" ]] || return 0

  local _task _status _reason
  while IFS= read -r _task; do
    [[ -n "$_task" ]] || continue
    if bash "$RUN_STATE" is-done "$RUN_ID" "$_task" 2>/dev/null; then
      _status="done"
    else
      _status="pending"
    fi
    _reason="$(bash "$RUN_STATE" reason "$RUN_ID" "$_task" 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$_task" "$_status" "$_reason"
  done < <(yq e '.tasks[].id' "$PLAN_FILE" 2>/dev/null)
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

# --- Launcher-scoped environment --------------------------------------------
# Every DEVLEAD_* knob this script consumes is launcher-only: it tells THIS
# script where to cd, how often to iterate, which binaries to call. None of
# them is read by sweep-execute, nor by anything sweep-execute runs
# (gate-check.sh, envelope.sh, run-state.sh, branch.sh, the hooks).
#
# That matters because the systemd unit sets EnvironmentFile=, which puts these
# in the SERVICE's environment — so every descendant inherits them, `make test`
# included. Not hypothetical: DEVLEAD_LOOP_REPO reached the sandbox of
# test/unit-sweep-loop.sh and made its 21 "outside a git work tree" guard tests
# fail, turning the gate red on ten consecutive runs while the task work in the
# branches was already complete. The gate was right to fail — the environment
# lied to it about where the repo was.
#
# Stripping at the invocation boundary fixes the class. Unsetting the variable
# inside the one test that happened to notice would leave every other child
# process still reading the launcher's private configuration.
_LAUNCHER_ONLY_VARS=(
  DEVLEAD_LOOP_DRYRUN
  DEVLEAD_LOOP_MAX
  DEVLEAD_LOOP_SLEEP
  DEVLEAD_LOOP_STALL
  DEVLEAD_CLAUDE_BIN
  DEVLEAD_LOOP_REPO
  DEVLEAD_ALLOW_DRIFT
  DEVLEAD_DOCTOR_BIN
)
_ENV_STRIP=()
for _v in "${_LAUNCHER_ONLY_VARS[@]}"; do _ENV_STRIP+=(-u "$_v"); done
unset _v

# Readable form for the dry run: what you would type, not %q's backslash soup.
# Renders the strip flags too — a dry run that hides them would no longer be a
# preview of the real invocation, and this dry run is the verification tool.
_sweep_display() {
  local _v
  printf 'env'
  for _v in "${_LAUNCHER_ONLY_VARS[@]}"; do printf ' -u %s' "$_v"; done
  printf ' %s -p "%s"' "$CLAUDE_BIN" "$(_sweep_prompt)"
}

# --- Reactive not-a-git-repo detection --------------------------------------
# The pre-check guard above is a fast path, not the guarantee (see the header
# comment block). This is the guarantee: each iteration's output is streamed
# to the caller AND captured via `tee` to a scratch file, then scanned for the
# `STATUS: not-a-git-repo` contract line sweep-execute.md documents. A hit
# means the dispatched invocation structurally could not resolve a repo, no
# matter what the pre-check predicted — re-invoking it again would just waste
# another turn, so the loop stops immediately instead of running out the cap.
# Never created in dry-run mode: claude is never invoked there, so there is
# nothing to capture. The trap guarantees cleanup on every exit path this
# script takes after the file is created, including the reactive exit below.
_SWEEP_OUT=""
if [[ "$DRYRUN" != "1" ]]; then
  _SWEEP_OUT="$(mktemp "${TMPDIR:-/tmp}/sweep-loop-out.XXXXXX")"
  trap '[[ -n "$_SWEEP_OUT" ]] && rm -f "$_SWEEP_OUT"' EXIT
fi

# --- Loop ------------------------------------------------------------------
_iter=0
_stall=0
_prev_snapshot=""
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
  env "${_ENV_STRIP[@]}" "$CLAUDE_BIN" -p "$(_sweep_prompt)" | tee "$_SWEEP_OUT"
  _rc=${PIPESTATUS[0]}
  echo "sweep-loop: iteration $_iter exited $_rc"

  if grep -q '^STATUS: not-a-git-repo' "$_SWEEP_OUT"; then
    echo "sweep-loop: dispatched invocation reported STATUS: not-a-git-repo — it could not resolve a repo from cwd" >&2
    echo "sweep-loop: cwd used was: $PWD" >&2
    echo "sweep-loop: pass --repo <path> or set \$DEVLEAD_LOOP_REPO to the target repo instead" >&2
    echo "sweep-loop: stopping after iteration $_iter — re-invoking would repeat the same failure" >&2
    exit 1
  fi

  if [[ "$STALL_LIMIT" -gt 0 ]]; then
    _snapshot="$(_run_snapshot)"
    if [[ -n "$_snapshot" && "$_snapshot" == "$_prev_snapshot" ]]; then
      _stall=$((_stall + 1))
      echo "sweep-loop: iteration $_iter changed nothing in the run state ($_stall/$STALL_LIMIT)"
    else
      _stall=0
    fi
    _prev_snapshot="$_snapshot"

    if [[ "$_stall" -ge "$STALL_LIMIT" ]]; then
      echo "sweep-loop: converged — $((_stall + 1)) consecutive iterations left the run state identical"
      echo "sweep-loop: stopping at iteration $_iter of $MAX_ITER; re-invoking would reproduce the same verdict"
      echo "sweep-loop: outstanding work and why it is stuck:"
      printf '%s\n' "$_snapshot" | sed 's/^/  /'
      exit 0
    fi
  fi

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
