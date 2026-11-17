#!/usr/bin/env bash
# unit-runner-config.sh — docker/runner-config.sh: the DevLead server's
# schedule and limits, validated and rendered from the env file (S11, S16,
# S17, F1 follow-up b).
#
#   bash test/unit-runner-config.sh
#
# SAFETY: runs the script as the current user with every input passed through
# the environment of one command; it writes only into a throwaway directory.
# Nothing here needs Docker or root.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CFG="$REPO_ROOT/docker/runner-config.sh"
RUN_JOB="$REPO_ROOT/docker/run-job.sh"
SANDBOX="$(mktemp -d /tmp/devlead-runner-config.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

# The settings come only from the variables given to each call: the caller's
# shell gets no vote.
SETTINGS=(TZ DEVLEAD_CRON_MORNING DEVLEAD_CRON_LOOP DEVLEAD_CRON_FLEET DEVLEAD_CRON_DISCOVER
          DEVLEAD_MAX_SESSIONS_PER_DAY DEVLEAD_SESSION_TIMEOUT DEVLEAD_AUDIT_RETENTION_DAYS
          DEVLEAD_CLAUDE_BIN)
UNSET=()
for _v in "${SETTINGS[@]}"; do UNSET+=(-u "$_v"); done

# render <outdir> [VAR=value...] — prints combined output; $? is the exit code.
render() {
  local out="$1"; shift
  rm -rf "$out"; mkdir -p "$out"
  env "${UNSET[@]}" "$@" bash "$CFG" render "$out" 2>&1
}
cron_ok() { env "${UNSET[@]}" bash "$CFG" check-cron "$1" >/dev/null 2>&1 && echo valid || echo invalid; }

# ===========================================================================
# The job table: one line per job, read by the renderer
# ===========================================================================
list="$(bash "$RUN_JOB" --list 2>&1)"
check "run-job.sh --list prints the four jobs, in order" "$(cut -d'|' -f1 <<<"$list" | paste -sd, -)" \
  "morning,loop,fleet,discover"
check "each job is scheduled by its own variable" "$(cut -d'|' -f2 <<<"$list" | paste -sd, -)" \
  "DEVLEAD_CRON_MORNING,DEVLEAD_CRON_LOOP,DEVLEAD_CRON_FLEET,DEVLEAD_CRON_DISCOVER"

# ===========================================================================
# Defaults (S16; fleet keeps today's systemd timer, 22:30)
# ===========================================================================
OUT="$SANDBOX/defaults"
out="$(render "$OUT")"; rc=$?
check "defaults: render exits 0" "$rc" "0"
crontab="$(cat "$OUT/crontab" 2>/dev/null)"
conf="$(cat "$OUT/runner.conf" 2>/dev/null)"
contains "default morning: 06:30 Monday to Friday" "$crontab" "30 6 * * 1-5 $RUN_JOB morning"
contains "default loop: 22:00 every day" "$crontab" "0 22 * * * $RUN_JOB loop"
contains "default fleet: 22:30 every day, as devlead-fleet.timer" "$crontab" "30 22 * * * $RUN_JOB fleet"
contains "default discover: Monday 05:00" "$crontab" "0 5 * * 1 $RUN_JOB discover"
contains "transcripts are pruned daily" "$crontab" "$RUN_JOB --prune"
check "the crontab has exactly five schedule lines" "$(grep -cv '^#' <<<"$crontab")" "5"
check "default limits" "$(grep -v '^#' <<<"$conf")" \
  "$(printf 'TZ=UTC\nMAX_SESSIONS_PER_DAY=8\nSESSION_TIMEOUT=60m\nSESSION_KILL_AFTER=30s\nAUDIT_RETENTION_DAYS=30')"
check "both files are 0644" "$(stat -c %a "$OUT/crontab" "$OUT/runner.conf" | paste -sd' ' -)" "644 644"
check "no temporary file is left behind" "$(find "$OUT" -name '*.new*' | wc -l)" "0"

# ===========================================================================
# The operator's values (S16, S17)
# ===========================================================================
OUT="$SANDBOX/custom"
out="$(render "$OUT" TZ=America/Bogota 'DEVLEAD_CRON_MORNING=15 7 * * mon-fri' 'DEVLEAD_CRON_LOOP=*/30 7-20 * * *' \
  DEVLEAD_CRON_DISCOVER=off DEVLEAD_MAX_SESSIONS_PER_DAY=3 DEVLEAD_SESSION_TIMEOUT=90s DEVLEAD_AUDIT_RETENTION_DAYS=7)"; rc=$?
check "custom: render exits 0" "$rc" "0"
crontab="$(cat "$OUT/crontab" 2>/dev/null)"
conf="$(cat "$OUT/runner.conf" 2>/dev/null)"
contains "the morning schedule is the operator's" "$crontab" "15 7 * * mon-fri $RUN_JOB morning"
contains "the loop schedule is the operator's" "$crontab" "*/30 7-20 * * * $RUN_JOB loop"
contains "an unset job keeps its default" "$crontab" "30 22 * * * $RUN_JOB fleet"
lacks "off: no discover line" "$crontab" "$RUN_JOB discover"
contains "off: the crontab says the job is off" "$crontab" "# discover: off (DEVLEAD_CRON_DISCOVER=off)"
contains "TZ is recorded" "$conf" "TZ=America/Bogota"
contains "the daily cap is recorded" "$conf" "MAX_SESSIONS_PER_DAY=3"
contains "the timeout is recorded" "$conf" "SESSION_TIMEOUT=90s"
contains "the retention is recorded" "$conf" "AUDIT_RETENTION_DAYS=7"
OUT="$SANDBOX/empty"
render "$OUT" DEVLEAD_CRON_LOOP= TZ= >/dev/null
contains "an empty value means the default" "$(cat "$OUT/crontab")" "0 22 * * * $RUN_JOB loop"
contains "an empty TZ means UTC" "$(cat "$OUT/runner.conf")" "TZ=UTC"

# ===========================================================================
# Cron expressions: five fields, validated before supercronic sees them
# ===========================================================================
for e in '30 6 * * 1-5' '0 22 * * *' '0 5 * * MON' '0 5 * * mon-fri' '*/15 7-20 * * *' \
         '0,30 8,12 1-15 jan-jun 0' '1-5/2 * * * *' '0 0 * * 7' '59 23 31 12 6' ' 0 22 * * * '; do
  check "valid schedule: [$e]" "$(cron_ok "$e")" "valid"
done
for e in '61 22 * * *' '0 24 * * *' '0 0 0 * *' '0 0 32 * *' '0 0 * 13 *' '0 0 * * 8' \
         '0 22 * *' '0 22 * * * *' '@daily' '0 22 * * * /bin/sh' 'a b c d e' '5-1 * * * *' \
         '*/0 * * * *' '1,,2 * * * *' ',1 * * * *' '* * * * ;' '0 0 * * $(id)' '' 'off-ish * * * *' '0 0 * xyz *'; do
  check "invalid schedule: [$e]" "$(cron_ok "$e")" "invalid"
done

# ===========================================================================
# Fail closed: any invalid value stops the render and names the variable
# ===========================================================================
bad() { # bad <label> <expected message> VAR=value...
  local label="$1" msg="$2" out rc; shift 2
  OUT="$SANDBOX/bad"
  out="$(render "$OUT" "$@")"; rc=$?
  check "$label: render refuses" "$([[ $rc -ne 0 ]] && echo refused || echo "accepted (rc=0)")" "refused"
  contains "$label: says why" "$out" "$msg"
  check "$label: writes no crontab" "$([[ -e $OUT/crontab ]] && echo written || echo none)" "none"
  check "$label: writes no runner.conf" "$([[ -e $OUT/runner.conf ]] && echo written || echo none)" "none"
}
bad "bad loop schedule" "DEVLEAD_CRON_LOOP='61 22 * * *' is not a valid schedule" 'DEVLEAD_CRON_LOOP=61 22 * * *'
bad "bad fleet schedule" "DEVLEAD_CRON_FLEET='@daily' is not a valid schedule" 'DEVLEAD_CRON_FLEET=@daily'
bad "unknown time zone" "TZ='Mars/Olympus' is not a time zone" TZ=Mars/Olympus
bad "time zone path" "TZ='../../etc/passwd' is not a time zone" TZ=../../etc/passwd
bad "daily cap not a number" "DEVLEAD_MAX_SESSIONS_PER_DAY='lots' must be a whole number from 0 to 1000" DEVLEAD_MAX_SESSIONS_PER_DAY=lots
bad "daily cap too big" "DEVLEAD_MAX_SESSIONS_PER_DAY='5000' must be a whole number from 0 to 1000" DEVLEAD_MAX_SESSIONS_PER_DAY=5000
bad "timeout without a unit" "DEVLEAD_SESSION_TIMEOUT='60' needs a unit" DEVLEAD_SESSION_TIMEOUT=60
bad "timeout zero" "DEVLEAD_SESSION_TIMEOUT='0m' needs a unit" DEVLEAD_SESSION_TIMEOUT=0m
bad "timeout over a day" "DEVLEAD_SESSION_TIMEOUT='25h' needs a unit" DEVLEAD_SESSION_TIMEOUT=25h
bad "retention zero" "DEVLEAD_AUDIT_RETENTION_DAYS='0' must be a whole number from 1 to 3650" DEVLEAD_AUDIT_RETENTION_DAYS=0
bad "claude binary other than the wrapper (F1 follow-up b)" \
  "DEVLEAD_CLAUDE_BIN='/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe' is not the claude wrapper" \
  DEVLEAD_CLAUDE_BIN=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
OUT="$SANDBOX/many"
out="$(render "$OUT" 'DEVLEAD_CRON_LOOP=61 22 * * *' TZ=Nowhere/City)"
contains "several errors: all of them are named (loop)" "$out" "DEVLEAD_CRON_LOOP"
contains "several errors: all of them are named (TZ)" "$out" "TZ='Nowhere/City'"

for ok in claude /usr/local/bin/claude ""; do
  OUT="$SANDBOX/bin-ok"
  render "$OUT" DEVLEAD_CLAUDE_BIN="$ok" >/dev/null; rc=$?
  check "DEVLEAD_CLAUDE_BIN='$ok' is the wrapper: accepted" "$rc" "0"
done

# Rendering replaces the files whole: an earlier crontab is not merged.
OUT="$SANDBOX/replace"
render "$OUT" >/dev/null
env "${UNSET[@]}" DEVLEAD_CRON_FLEET=off bash "$CFG" render "$OUT" >/dev/null 2>&1
lacks "a second render replaces the crontab" "$(cat "$OUT/crontab")" "$RUN_JOB fleet"

out="$(env "${UNSET[@]}" bash "$CFG" 2>&1)"; rc=$?
check "no subcommand: usage, exit 2" "$rc" "2"
contains "no subcommand: prints the usage" "$out" "usage: runner-config.sh"
out="$(env "${UNSET[@]}" bash "$CFG" render "$SANDBOX/does/not/exist" 2>&1)"; rc=$?
check "missing output directory: refused" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
