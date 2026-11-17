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
          DEVLEAD_CLAUDE_BIN DEVLEAD_WORKSPACE DEVLEAD_REPOS DEVLEAD_LOOP_REPO)
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
  "$(printf 'TZ=UTC\nMAX_SESSIONS_PER_DAY=8\nSESSION_TIMEOUT=60m\nSESSION_KILL_AFTER=30s\nAUDIT_RETENTION_DAYS=30\nWORKSPACE=')"
check "default: no repo enrolled" "$(grep -cv '^#' "$OUT/repos")" "0"
check "the three files are 0644" "$(stat -c %a "$OUT/crontab" "$OUT/runner.conf" "$OUT/repos" | paste -sd' ' -)" "644 644 644"
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
  check "$label: render refuses (exit 1)" "$rc" "1"
  contains "$label: says why" "$out" "$msg"
  check "$label: writes no crontab" "$([[ -e $OUT/crontab ]] && echo written || echo none)" "none"
  check "$label: writes no runner.conf" "$([[ -e $OUT/runner.conf ]] && echo written || echo none)" "none"
  check "$label: writes no repos" "$([[ -e $OUT/repos ]] && echo written || echo none)" "none"
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
# A value spanning lines would add lines of its own to the crontab (or to
# runner.conf): a newline, a carriage return or any other control character
# is refused in every value, and the value is not echoed back.
CTRL="contains a newline, a carriage return or another control character"
bad "newline in a schedule (crontab injection)" "DEVLEAD_CRON_LOOP $CTRL" $'DEVLEAD_CRON_LOOP=0 22 * * *\n* * * * * touch /tmp/pwned'
lacks "newline in a schedule: the injected line is not echoed" "$out" "touch /tmp/pwned"
bad "carriage return in a schedule" "DEVLEAD_CRON_FLEET $CTRL" $'DEVLEAD_CRON_FLEET=30 22 * * *\r'
bad "trailing newline in a schedule" "DEVLEAD_CRON_MORNING $CTRL" $'DEVLEAD_CRON_MORNING=30 6 * * 1-5\n'
bad "newline in TZ" "TZ $CTRL" $'TZ=UTC\n'
bad "tab in the daily cap" "DEVLEAD_MAX_SESSIONS_PER_DAY $CTRL" $'DEVLEAD_MAX_SESSIONS_PER_DAY=8\t'
bad "carriage return in the timeout" "DEVLEAD_SESSION_TIMEOUT $CTRL" $'DEVLEAD_SESSION_TIMEOUT=60m\r'
bad "newline in the retention" "DEVLEAD_AUDIT_RETENTION_DAYS $CTRL" $'DEVLEAD_AUDIT_RETENTION_DAYS=30\n'
bad "newline in DEVLEAD_CLAUDE_BIN" "DEVLEAD_CLAUDE_BIN $CTRL" $'DEVLEAD_CLAUDE_BIN=claude\nx'
check "check-cron: a newline makes it invalid" "$(cron_ok $'0 22 * * *\n* * * * * id')" "invalid"
check "check-cron: a carriage return makes it invalid" "$(cron_ok $'0 22 * * *\r')" "invalid"

OUT="$SANDBOX/many"
out="$(render "$OUT" 'DEVLEAD_CRON_LOOP=61 22 * * *' TZ=Nowhere/City)"
contains "several errors: all of them are named (loop)" "$out" "DEVLEAD_CRON_LOOP"
contains "several errors: all of them are named (TZ)" "$out" "TZ='Nowhere/City'"

# ===========================================================================
# Enrolled repos (S13): each clone at its host path, inside the workspace
# ===========================================================================
WS=/home/me/Work
OUT="$SANDBOX/repos"
out="$(render "$OUT" DEVLEAD_WORKSPACE="$WS/" "DEVLEAD_REPOS= $WS/app=acme/app , $WS/clients/x/site=Acme-Co/site.git,," \
  DEVLEAD_LOOP_REPO="$WS/app")"; rc=$?
check "repos: render exits 0" "$rc" "0"
check "repos: one line per repo, host path TAB owner/repo (.git dropped)" "$(grep -v '^#' "$OUT/repos")" \
  "$(printf '%s\tacme/app\n%s\tAcme-Co/site' "$WS/app" "$WS/clients/x/site")"
contains "repos: the workspace is recorded, without the trailing slash" "$(cat "$OUT/runner.conf")" "WORKSPACE=$WS"
contains "repos: says how many" "$out" "2 enrolled repo(s) written to $OUT/repos"
OUT="$SANDBOX/repos-none"
render "$OUT" DEVLEAD_WORKSPACE="$WS" >/dev/null; rc=$?
check "a workspace with no repo: accepted, an empty list" "$rc $(grep -cv '^#' "$OUT/repos")" "0 0"

nothing_echoed() { # nothing_echoed <label> <value that must not appear>
  lacks "$1: the value is not echoed" "$out" "$2"
}
bad "a repo without a workspace" "DEVLEAD_REPOS entry 1: DEVLEAD_WORKSPACE is not set" "DEVLEAD_REPOS=$WS/app=acme/app"
bad "a repo outside the workspace" "DEVLEAD_REPOS entry 2: the path is not inside DEVLEAD_WORKSPACE" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=acme/app,/home/me/Secret/x=acme/x"
nothing_echoed "a repo outside the workspace" "/home/me/Secret/x"
bad "the workspace itself as a repo" "DEVLEAD_REPOS entry 1: the path is not inside DEVLEAD_WORKSPACE" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS=acme/app"
bad "a sibling with the workspace as prefix" "DEVLEAD_REPOS entry 1: the path is not inside DEVLEAD_WORKSPACE" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=${WS}2/app=acme/app"
bad "a relative path" "DEVLEAD_REPOS entry 1: the path must be absolute" DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=Work/app=acme/app"
bad "a .. in the path" "DEVLEAD_REPOS entry 1: the path must be absolute" DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/../../etc=acme/app"
bad "a space in the path" "DEVLEAD_REPOS entry 1: the path must be absolute" DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/my app=acme/app"
bad "no owner/repo" "DEVLEAD_REPOS entry 1 is not <host path>=<owner>/<repo>" DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app"
bad "not a GitHub name" "DEVLEAD_REPOS entry 1: <owner>/<repo> is not the name of a GitHub repository" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=https://evil.example/x"
nothing_echoed "not a GitHub name" "evil.example"
bad "a repo named .." "DEVLEAD_REPOS entry 1: <owner>/<repo> is not the name" DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=acme/.."
bad "two repos at one path" "DEVLEAD_REPOS entries 1 and 2: one clone would be the other or sit inside it" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=acme/app,$WS/app=acme/other"
bad "a repo inside another one's clone" "DEVLEAD_REPOS entries 1 and 2: one clone would be the other or sit inside it" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=acme/app,$WS/app/vendor/lib=acme/lib"
bad "the root as workspace" "DEVLEAD_WORKSPACE must be an absolute path" DEVLEAD_WORKSPACE=/
for w in /etc /opt/devlead /home /home/devlead /home/devlead/Work /tmp/x /var/lib /usr/local/src; do
  bad "workspace $w" "DEVLEAD_WORKSPACE overlaps" DEVLEAD_WORKSPACE="$w"
done
bad "a relative workspace" "DEVLEAD_WORKSPACE must be an absolute path" DEVLEAD_WORKSPACE=Work
bad "a loop repo that is not enrolled" "DEVLEAD_LOOP_REPO must be one of the paths in DEVLEAD_REPOS" \
  DEVLEAD_WORKSPACE="$WS" "DEVLEAD_REPOS=$WS/app=acme/app" DEVLEAD_LOOP_REPO="$WS/other"
nothing_echoed "a loop repo that is not enrolled" "$WS/other"
bad "a loop repo with no repo enrolled" "DEVLEAD_LOOP_REPO must be one of the paths" DEVLEAD_LOOP_REPO=/home/me/Work/app
bad "newline in DEVLEAD_REPOS" "DEVLEAD_REPOS $CTRL" DEVLEAD_WORKSPACE="$WS" $'DEVLEAD_REPOS=/home/me/Work/a=acme/a\nx'
bad "newline in DEVLEAD_WORKSPACE" "DEVLEAD_WORKSPACE $CTRL" $'DEVLEAD_WORKSPACE=/home/me/Work\n'
bad "newline in DEVLEAD_LOOP_REPO" "DEVLEAD_LOOP_REPO $CTRL" $'DEVLEAD_LOOP_REPO=/home/me/Work/a\n'

# Previous behaviour: with none of the F3 settings, the crontab and the F2
# limits are exactly what they were.
OUT="$SANDBOX/f2"
render "$OUT" >/dev/null
check "without F3 settings: the crontab is the F2 one" "$(grep -v '^#' "$OUT/crontab")" \
  "$(printf '30 6 * * 1-5 %s morning\n0 22 * * * %s loop\n30 22 * * * %s fleet\n0 5 * * 1 %s discover\n17 4 * * * %s --prune' "$RUN_JOB" "$RUN_JOB" "$RUN_JOB" "$RUN_JOB" "$RUN_JOB")"
check "without F3 settings: the F2 limits keep their values" "$(grep -E '^(TZ|MAX_SESSIONS_PER_DAY|SESSION_TIMEOUT|SESSION_KILL_AFTER|AUDIT_RETENTION_DAYS)=' "$OUT/runner.conf")" \
  "$(printf 'TZ=UTC\nMAX_SESSIONS_PER_DAY=8\nSESSION_TIMEOUT=60m\nSESSION_KILL_AFTER=30s\nAUDIT_RETENTION_DAYS=30')"

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
