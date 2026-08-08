#!/usr/bin/env bash
# run-state.sh — durable per-run task progress for DevLead autonomous runs.
#
# A sweep run holds its queue in memory only, so an interrupted run (quota
# exhaustion, crash, machine sleep) restarts from the first task and redoes
# work that already produced a PR. This script is the disk half of that: the
# pipeline marks each task as it finishes, and a later invocation skips what
# is already recorded.
#
# Usage:
#   run-state.sh mark    <run-id> <task-id> <status> [reason...]
#   run-state.sh is-done <run-id> <task-id>
#   run-state.sh reason  <run-id> <task-id>
#   run-state.sh list    <run-id>
#
# Exit codes:
#   is-done -> 0 when the task is recorded done, 1 otherwise (including
#              unknown run, unknown task, or any non-done status).
#   others  -> 0 on success, 1 on usage or I/O error.
#
# Storage: $DEVLEAD_RUN_STATE_DIR (default ~/.devlead/run-state)/<run-id>/<task-id>
#   line 1  : status
#   line 2+ : reason, verbatim and unmodified (A4 — a PARK reason is never
#             paraphrased, so it is stored and returned byte for byte).
#
# Writes land at task boundaries, never while the QA gate runs its suites —
# this repo's smoke tests assert ~/.devlead is unchanged across their own run.

set -uo pipefail

STATE_ROOT="${DEVLEAD_RUN_STATE_DIR:-$HOME/.devlead/run-state}"

_usage() {
  echo "usage: run-state.sh mark <run-id> <task-id> <status> [reason...]" >&2
  echo "       run-state.sh is-done <run-id> <task-id>" >&2
  echo "       run-state.sh reason  <run-id> <task-id>" >&2
  echo "       run-state.sh list    <run-id>" >&2
}

# Identifiers become path segments. Reject anything that could escape the
# state root or collide across runs. LOCAL-PLAN already validates task ids
# against git ref rules, but this script is callable on its own.
_validate_id() {
  local _kind="$1" _val="$2"
  if [[ -z "$_val" ]]; then
    echo "run-state: $_kind must not be empty" >&2
    return 1
  fi
  if [[ "$_val" == *"/"* || "$_val" == *".."* || "$_val" =~ [[:space:]] ]]; then
    echo "run-state: invalid $_kind '$_val' (no '/', '..' or whitespace)" >&2
    return 1
  fi
  return 0
}

_task_file() {
  printf '%s/%s/%s' "$STATE_ROOT" "$1" "$2"
}

_do_mark() {
  local _run="${1:-}" _task="${2:-}" _status="${3:-}"
  shift 3 2>/dev/null || true
  local _reason="$*"

  _validate_id "run-id" "$_run" || return 1
  _validate_id "task-id" "$_task" || return 1
  if [[ -z "$_status" ]]; then
    echo "run-state: status must not be empty" >&2
    return 1
  fi

  local _dir="$STATE_ROOT/$_run"
  if ! mkdir -p "$_dir" 2>/dev/null; then
    echo "run-state: cannot create $_dir" >&2
    return 1
  fi

  # Write via temp + mv so a crash mid-write never leaves a half record that
  # a later run would read as authoritative.
  local _file _tmp
  _file="$(_task_file "$_run" "$_task")"
  _tmp="${_file}.tmp.$$"
  # `if` rather than `[[ ... ]] &&`: a false test as the group's last command
  # makes the whole group exit non-zero, which would report a write failure
  # for every status recorded without a reason.
  {
    printf '%s\n' "$_status"
    if [[ -n "$_reason" ]]; then
      printf '%s\n' "$_reason"
    fi
  } > "$_tmp" 2>/dev/null || {
    echo "run-state: cannot write $_tmp" >&2
    rm -f "$_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_tmp" "$_file" 2>/dev/null || {
    echo "run-state: cannot finalise $_file" >&2
    rm -f "$_tmp" 2>/dev/null
    return 1
  }
  return 0
}

_do_is_done() {
  local _run="${1:-}" _task="${2:-}"
  _validate_id "run-id" "$_run" >/dev/null 2>&1 || return 1
  _validate_id "task-id" "$_task" >/dev/null 2>&1 || return 1

  local _file
  _file="$(_task_file "$_run" "$_task")"
  [[ -f "$_file" ]] || return 1
  [[ "$(head -n 1 "$_file" 2>/dev/null)" == "done" ]]
}

_do_reason() {
  local _run="${1:-}" _task="${2:-}"
  _validate_id "run-id" "$_run" || return 1
  _validate_id "task-id" "$_task" || return 1

  local _file
  _file="$(_task_file "$_run" "$_task")"
  if [[ ! -f "$_file" ]]; then
    echo "run-state: no record for $_run/$_task" >&2
    return 1
  fi
  # Verbatim: everything after the status line, unmodified.
  tail -n +2 "$_file"
  return 0
}

_do_list() {
  local _run="${1:-}"
  _validate_id "run-id" "$_run" || return 1

  local _dir="$STATE_ROOT/$_run"
  [[ -d "$_dir" ]] || return 0

  local _f _task _status
  for _f in "$_dir"/*; do
    [[ -f "$_f" ]] || continue
    case "$_f" in *.tmp.*) continue ;; esac
    _task="$(basename "$_f")"
    _status="$(head -n 1 "$_f" 2>/dev/null)"
    printf '%s\t%s\n' "$_task" "$_status"
  done
  return 0
}

_cmd="${1:-}"
shift 2>/dev/null || true

case "$_cmd" in
  mark)    _do_mark "$@" ;;
  is-done) _do_is_done "$@" ;;
  reason)  _do_reason "$@" ;;
  list)    _do_list "$@" ;;
  ""|-h|--help|help) _usage; exit 1 ;;
  *) echo "run-state: unknown subcommand '$_cmd'" >&2; _usage; exit 1 ;;
esac
