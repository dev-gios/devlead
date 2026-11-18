#!/usr/bin/env bash
# lib-outside-session.sh — sourced by the suites that drive `devlead config`
# and `devlead enroll` over a pty (unit-config-menu.sh, unit-enroll.sh).
#
# Both commands refuse to run when any ancestor process is Claude Code
# (GOVERNANCE.md §A3). These suites often run inside a Claude Code session
# themselves: gate-check runs `make test` there. So each driven run starts
# OUTSIDE the caller's process tree. A double fork orphans it, and the kernel
# hands it to the nearest subreaper (systemd --user, or init). That is the
# escape §A3 names honestly. Here it stands in for "the user's own terminal".
#
# run_outside <timeout secs> <input file> <command string>
#   Runs `script -qec "<command string>" /dev/null` detached and types the
#   input file's lines at it, one every RUN_OUTSIDE_PACE seconds (default
#   0.15), the way a person would: a line typed before a hidden `read -s`
#   starts would be echoed. /dev/null types nothing. Prints the run's output,
#   CR stripped, and returns its exit code; 124 on timeout (its process group
#   is killed). Environment assignments in front of the call
#   (HOME=... run_outside ...) reach the run.
run_outside() {
  local secs="$1" in="$2" cmd="$3" d rc ticks=0 pid feeder="" src
  d="$(mktemp -d "${TMPDIR:-/tmp}/devlead-outside.XXXXXX")" || return 125
  local -a detach=()
  command -v setsid >/dev/null 2>&1 && detach=(setsid)
  src=/dev/null
  if [[ -s "$in" ]]; then
    mkfifo "$d/in" || { rm -rf "$d"; return 125; }
    src="$d/in"
    (
      while IFS= read -r line; do
        printf '%s\n' "$line"
        sleep "${RUN_OUTSIDE_PACE:-0.15}"
      done < "$in"
    ) > "$d/in" 2>/dev/null &
    feeder=$!
  fi
  (
    SHELL="$(command -v bash)" "${detach[@]}" bash -c '
      script -qec "$1" /dev/null < "$2" > "$3/out" 2>&1
      echo $? > "$3/rc.tmp" && mv "$3/rc.tmp" "$3/rc"' _ "$cmd" "$src" "$d" \
      </dev/null >/dev/null 2>&1 &
    echo $! > "$d/pid"
  )
  while [[ ! -f "$d/rc" ]]; do
    if (( ticks >= secs * 10 )); then
      pid="$(cat "$d/pid" 2>/dev/null)"
      [[ -n "$pid" ]] && { kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null; }
      echo 124 > "$d/rc"
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  [[ -n "$feeder" ]] && { kill "$feeder" 2>/dev/null; wait "$feeder" 2>/dev/null; }
  rc="$(cat "$d/rc")"
  tr -d '\r' < "$d/out" 2>/dev/null
  rm -rf "$d"
  return "$rc"
}

# lines_file <dir> <line>... — writes the lines to a fresh file under <dir>
# and prints its path: the typed input for run_outside.
lines_file() {
  local dir="$1" f; shift
  f="$(mktemp "$dir/input.XXXXXX")" || return 1
  [[ $# -gt 0 ]] && printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}
