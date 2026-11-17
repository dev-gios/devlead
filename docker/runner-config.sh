#!/usr/bin/env bash
# runner-config.sh — the DevLead server's schedule and limits (S11, S16, S17),
# turned from the env file into two root-owned files at container start.
#
#   runner-config.sh render <dir>       validate the settings below and write
#                                       <dir>/crontab and <dir>/runner.conf
#   runner-config.sh check-cron <expr>  exit 0 when <expr> is a valid schedule
#
# entrypoint.sh runs `render /etc/devlead` as root, before privileges are
# dropped, so both files are root's: no session can change its own schedule
# or its own limits. Every invalid value is named and stops the start (fail
# closed); nothing is written until all of them are valid. A value holding a
# newline, a carriage return or any other control character is refused, never
# echoed: written to the crontab it would add a line of its own.
#
# Settings, from the env file (all optional; empty means the default):
#   TZ                             time zone of the schedule and of the daily
#                                  cap's calendar day (default UTC)
#   DEVLEAD_CRON_<JOB>             one per job of run-job.sh's table: five cron
#                                  fields (minute hour day-of-month month
#                                  day-of-week), or "off" to never run the job
#   DEVLEAD_MAX_SESSIONS_PER_DAY   claude sessions per calendar day (default 8)
#   DEVLEAD_SESSION_TIMEOUT        time limit of one claude session, with its
#                                  unit: s, m or h, at most 24h (default 60m)
#   DEVLEAD_AUDIT_RETENTION_DAYS   days a run's transcripts are kept (default 30)
#   DEVLEAD_CLAUDE_BIN             if set, must name the claude wrapper: the
#                                  launchers never run another binary here
#
# runner.conf (KEY=value lines, parsed and never sourced) is read by the claude
# wrapper and by run-job.sh; the crontab by supercronic. Missed runs are never
# made up: supercronic keeps no state between starts.
set -uo pipefail

_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RUN_JOB="$_DIR/run-job.sh"
ZONEINFO=/usr/share/zoneinfo
WRAPPER=/usr/local/bin/claude
SESSION_KILL_AFTER=30s
PRUNE_SCHEDULE="17 4 * * *"

DEFAULT_MAX_SESSIONS=8
DEFAULT_TIMEOUT=60m
DEFAULT_RETENTION=30

_usage() {
  echo "usage: runner-config.sh render <dir> | check-cron <expression>" >&2
}

# --- Cron expressions ----------------------------------------------------------
# Five fields, each a comma list of `*`, N or N-M, optionally /STEP. Months and
# days of the week also by their three-letter English names. Nothing else: no
# @daily, no seconds field, no command — the schedule is a schedule.
_MONTHS=(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
_DAYS=(SUN MON TUE WED THU FRI SAT)

# _cron_value <token> <min> <max> <kind> — sets _VALUE, or returns 1.
_cron_value() {
  local t="${1^^}" i
  if [[ "$t" =~ ^[0-9]{1,2}$ ]]; then
    (( 10#$t >= $2 && 10#$t <= $3 )) || return 1
    _VALUE=$((10#$t))
    return 0
  fi
  case "$4" in
    month) for i in "${!_MONTHS[@]}"; do [[ "$t" == "${_MONTHS[$i]}" ]] && { _VALUE=$((i + 1)); return 0; }; done ;;
    dow)   for i in "${!_DAYS[@]}"; do [[ "$t" == "${_DAYS[$i]}" ]] && { _VALUE=$i; return 0; }; done ;;
  esac
  return 1
}

# _cron_field <field> <min> <max> <kind>
_cron_field() {
  local field="$1" min="$2" max="$3" kind="$4" item base step lo items=()
  [[ -n "$field" && "$field" != ,* && "$field" != *, && "$field" != *,,* ]] || return 1
  IFS=, read -ra items <<<"$field"
  for item in "${items[@]}"; do
    base="$item"
    if [[ "$item" == */* ]]; then
      base="${item%%/*}"
      step="${item#*/}"
      [[ "$step" =~ ^[0-9]{1,2}$ ]] && (( 10#$step >= 1 && 10#$step <= max )) || return 1
    fi
    [[ "$base" == "*" ]] && continue
    if [[ "$base" == *-* ]]; then
      _cron_value "${base%%-*}" "$min" "$max" "$kind" || return 1
      lo="$_VALUE"
      _cron_value "${base#*-}" "$min" "$max" "$kind" || return 1
      (( lo <= _VALUE )) || return 1
    else
      _cron_value "$base" "$min" "$max" "$kind" || return 1
    fi
  done
  return 0
}

# _has_control <value> — holds a newline, a carriage return, a tab or any
# other control character.
_has_control() { [[ "$1" == *[[:cntrl:]]* ]]; }
_CONTROL="contains a newline, a carriage return or another control character — give the value on one line, in plain text"

# _valid_cron <expression>
_valid_cron() {
  local f=()
  _has_control "$1" && return 1
  read -ra f <<<"$1"
  [[ ${#f[@]} -eq 5 ]] || return 1
  _cron_field "${f[0]}" 0 59 num || return 1
  _cron_field "${f[1]}" 0 23 num || return 1
  _cron_field "${f[2]}" 1 31 num || return 1
  _cron_field "${f[3]}" 1 12 month || return 1
  _cron_field "${f[4]}" 0 7 dow || return 1
}

# _trim <text> — without leading and trailing whitespace.
_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# --- Other settings ------------------------------------------------------------
_valid_tz() {
  local tz="$1" magic=""
  [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -f "$ZONEINFO/$tz" ]] || return 1
  read -r -n 4 magic < "$ZONEINFO/$tz" 2>/dev/null || true
  [[ "$magic" == "TZif" ]]
}

# _timeout_secs <value> — seconds, or returns 1. A unit is required: `timeout`
# alone would read 60 as sixty seconds, the operator likely meant minutes.
_timeout_secs() {
  [[ "$1" =~ ^([1-9][0-9]{0,4})([smh])$ ]] || return 1
  local n="${BASH_REMATCH[1]}" secs
  case "${BASH_REMATCH[2]}" in
    s) secs=$n ;;
    m) secs=$((n * 60)) ;;
    h) secs=$((n * 3600)) ;;
  esac
  (( secs <= 86400 )) || return 1
  printf '%s' "$secs"
}

_whole() { # _whole <value> <min> <max>
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

# --- render --------------------------------------------------------------------
_render() {
  local dir="$1" errors=() line name var default value tz max timeout retention bin
  local cron_lines=()
  [[ -d "$dir" && ! -L "$dir" ]] || { echo "runner-config: ERROR: output directory $dir does not exist" >&2; return 1; }

  local table
  table="$(bash "$RUN_JOB" --list)" || { echo "runner-config: ERROR: cannot read the job table from $RUN_JOB" >&2; return 1; }
  [[ -n "$table" ]] || { echo "runner-config: ERROR: the job table in $RUN_JOB is empty" >&2; return 1; }

  while IFS='|' read -r name var default; do
    [[ -n "$name" ]] || continue
    if _has_control "${!var:-}"; then
      errors+=("$var $_CONTROL")
      continue
    fi
    value="$(_trim "${!var:-}")"
    if [[ -z "$value" ]]; then
      value="$default"
      _valid_cron "$value" || errors+=("the default schedule of job $name ('$value') is not valid — fix run-job.sh")
    elif [[ "$value" == "off" ]]; then
      cron_lines+=("# $name: off ($var=off)")
      continue
    elif ! _valid_cron "$value"; then
      errors+=("$var='$value' is not a valid schedule: give five cron fields (minute hour day-of-month month day-of-week, e.g. '0 22 * * *') or 'off'")
      continue
    fi
    cron_lines+=("# $name ($var)" "$value $RUN_JOB $name")
  done <<<"$table"

  for var in TZ DEVLEAD_MAX_SESSIONS_PER_DAY DEVLEAD_SESSION_TIMEOUT DEVLEAD_AUDIT_RETENTION_DAYS DEVLEAD_CLAUDE_BIN; do
    _has_control "${!var:-}" && errors+=("$var $_CONTROL")
  done

  tz="$(_trim "${TZ:-}")"
  [[ -n "$tz" ]] || tz=UTC
  _has_control "${TZ:-}" || _valid_tz "$tz" \
    || errors+=("TZ='$tz' is not a time zone of $ZONEINFO (e.g. Europe/Madrid, America/Bogota, UTC)")

  max="$(_trim "${DEVLEAD_MAX_SESSIONS_PER_DAY:-}")"
  [[ -n "$max" ]] || max="$DEFAULT_MAX_SESSIONS"
  if _whole "$max" 0 1000; then max=$((10#$max)); elif ! _has_control "${DEVLEAD_MAX_SESSIONS_PER_DAY:-}"; then
    errors+=("DEVLEAD_MAX_SESSIONS_PER_DAY='$max' must be a whole number from 0 to 1000")
  fi

  timeout="$(_trim "${DEVLEAD_SESSION_TIMEOUT:-}")"
  [[ -n "$timeout" ]] || timeout="$DEFAULT_TIMEOUT"
  _has_control "${DEVLEAD_SESSION_TIMEOUT:-}" || _timeout_secs "$timeout" >/dev/null \
    || errors+=("DEVLEAD_SESSION_TIMEOUT='$timeout' needs a unit and a value from 1s to 24h: e.g. 90s, 60m, 2h")

  retention="$(_trim "${DEVLEAD_AUDIT_RETENTION_DAYS:-}")"
  [[ -n "$retention" ]] || retention="$DEFAULT_RETENTION"
  if _whole "$retention" 1 3650; then retention=$((10#$retention)); elif ! _has_control "${DEVLEAD_AUDIT_RETENTION_DAYS:-}"; then
    errors+=("DEVLEAD_AUDIT_RETENTION_DAYS='$retention' must be a whole number from 1 to 3650")
  fi

  bin="${DEVLEAD_CLAUDE_BIN:-}"
  if [[ -n "$bin" && "$bin" != "claude" && "$bin" != "$WRAPPER" ]] && ! _has_control "$bin"; then
    errors+=("DEVLEAD_CLAUDE_BIN='$bin' is not the claude wrapper ($WRAPPER): every session in the server goes through it, so its limits and settings hold — remove the variable from the env file")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    for line in "${errors[@]}"; do echo "runner-config: ERROR: $line" >&2; done
    return 1
  fi

  local tmp_cron tmp_conf
  tmp_cron="$(mktemp "$dir/crontab.new.XXXXXX")" || return 1
  tmp_conf="$(mktemp "$dir/runner.conf.new.XXXXXX")" || { rm -f "$tmp_cron"; return 1; }
  {
    echo "# DevLead server schedule (S11, S16). Written by runner-config.sh at container"
    echo "# start from the env file; root's, read by supercronic. Change the DEVLEAD_CRON_*"
    echo "# variables in the env file and restart the container instead of editing it."
    printf '%s\n' "${cron_lines[@]}"
    echo "# transcript retention (fixed)"
    echo "$PRUNE_SCHEDULE $RUN_JOB --prune"
  } > "$tmp_cron"
  {
    echo "# DevLead server limits (S17). Written by runner-config.sh at container start"
    echo "# from the env file; root's. Read, never sourced, by the claude wrapper and"
    echo "# run-job.sh — never from a caller's environment."
    echo "TZ=$tz"
    echo "MAX_SESSIONS_PER_DAY=$max"
    echo "SESSION_TIMEOUT=$timeout"
    echo "SESSION_KILL_AFTER=$SESSION_KILL_AFTER"
    echo "AUDIT_RETENTION_DAYS=$retention"
  } > "$tmp_conf"
  chmod 0644 "$tmp_cron" "$tmp_conf"
  mv -f "$tmp_cron" "$dir/crontab" && mv -f "$tmp_conf" "$dir/runner.conf" || {
    rm -f "$tmp_cron" "$tmp_conf"
    echo "runner-config: ERROR: cannot write $dir/crontab and $dir/runner.conf" >&2
    return 1
  }
  echo "runner-config: schedule and limits written to $dir (TZ=$tz, $max sessions a day, $timeout per session)"
}

case "${1:-}" in
  render)
    [[ $# -eq 2 ]] || { _usage; exit 2; }
    _render "$2" || exit 1
    ;;
  check-cron)
    [[ $# -eq 2 ]] || { _usage; exit 2; }
    ! _has_control "$2" && _valid_cron "$(_trim "$2")" || exit 1
    ;;
  *)
    _usage
    exit 2
    ;;
esac
