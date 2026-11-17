#!/usr/bin/env bash
# unit-claude-wrapper.sh — docker/claude-wrapper.sh, the only `claude` on PATH
# in the DevLead server image: its settings flags (F1) and the session limits
# it enforces (S17, F1 follow-up c).
#
#   bash test/unit-claude-wrapper.sh
#
# The wrapper's paths are fixed on purpose — nothing a caller passes, the
# environment included, may move its configuration or its ledger. So this
# suite runs a COPY whose fixed-paths block points into a sandbox: the real
# Claude Code binary is a fake that records how it was called, and the root
# owner the configuration must have is the current user. docker-smoke.sh runs
# the real one in the image.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="$REPO_ROOT/docker/claude-wrapper.sh"
SANDBOX="$(mktemp -d /tmp/devlead-claude-wrapper.XXXXXX)"
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$SANDBOX"' EXIT

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

FAKE_DIR="$SANDBOX/fake"
FAKE_LOG="$SANDBOX/fake.log"
FAKE_ENV_LOG="$SANDBOX/fake-env.log"
CONF="$SANDBOX/runner.conf"
LEDGER="$SANDBOX/state/sessions.tsv"
LOCK="$SANDBOX/state/session.lock"
PAUSE="$SANDBOX/PAUSE"
MARKS="$SANDBOX/state/accounts.tsv"
WRAPPER="$SANDBOX/claude"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude-config"
export FAKE_DIR FAKE_LOG FAKE_ENV_LOG
# The suite decides which Claude variables a session gets.
unset CLAUDE_CODE_OAUTH_TOKEN
while IFS= read -r _v; do unset "$_v"; done < <(compgen -e | grep '^DEVLEAD_CLAUDE_ACCOUNT_')
mkdir -p "$FAKE_DIR" "$SANDBOX/state"
: > "$LEDGER"; : > "$LOCK"

# The fake Claude Code: logs its arguments, the run id it sees and whether the
# wrapper's lock descriptor reached it; then does what files in $FAKE_DIR say.
cat > "$SANDBOX/real-claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGS'; for a in "$@"; do printf ' %s' "$a"; done
  printf '\tRUN=%s\tFD9=%s\n' "${DEVLEAD_RUN_ID:-}" "$([[ -e /proc/$$/fd/9 ]] && echo open || echo closed)"; } >> "$FAKE_LOG"
# The Claude token it was given and the pool variables it can still see.
printf 'OAUTH=%s\tPOOL=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-unset}" \
  "$(compgen -e | grep '^DEVLEAD_CLAUDE_ACCOUNT_' | sort | paste -sd, -)" >> "$FAKE_ENV_LOG"
[[ -f "$FAKE_DIR/spawn" ]] && { sleep 6 >/dev/null 2>&1 & }
[[ -f "$FAKE_DIR/stubborn" ]] && trap '' TERM
[[ -f "$FAKE_DIR/sleep" ]] && sleep "$(cat "$FAKE_DIR/sleep")"
# What the account's session ends with (S22): files named after the last part
# of its token (team, ultra, single) win over the plain ones. The transcript
# lands where Claude Code keeps it, under the session id the wrapper gave.
acct="${CLAUDE_CODE_OAUTH_TOKEN##*-}"
sid=""; prev=""
for a in "$@"; do [[ "$prev" == "--session-id" ]] && sid="$a"; prev="$a"; done
for f in "$FAKE_DIR/transcript.$acct" "$FAKE_DIR/transcript"; do
  if [[ -f "$f" && -n "$sid" ]]; then
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/-work-repo"
    cp "$f" "$CLAUDE_CONFIG_DIR/projects/-work-repo/$sid.jsonl"
    break
  fi
done
for f in "$FAKE_DIR/stdout.$acct" "$FAKE_DIR/stdout"; do [[ -f "$f" ]] && { cat "$f"; break; }; done
for f in "$FAKE_DIR/rc.$acct" "$FAKE_DIR/rc"; do [[ -f "$f" ]] && exit "$(cat "$f")"; done
exit 0
EOF
chmod +x "$SANDBOX/real-claude"

# The copy: only the fixed-paths block changes, and every line of it must be
# found — a renamed constant must fail here, not test the image's paths.
cp "$SRC" "$WRAPPER"
for kv in "REAL_CLAUDE=$SANDBOX/real-claude" "RUNNER_CONF=$CONF" "LEDGER=$LEDGER" \
          "SESSION_LOCK=$LOCK" "PAUSE_FILE=$PAUSE" "ACCOUNTS_FILE=$MARKS" "CONF_OWNER_UID=$(id -u)"; do
  key="${kv%%=*}"
  check "the wrapper has the fixed path $key" "$(grep -c "^$key=" "$WRAPPER")" "1"
  sed -i "s|^$key=.*|$kv|" "$WRAPPER"
done
chmod +x "$WRAPPER"

conf() { # conf [KEY=value...] — the defaults with these overrides
  local tz=UTC max=3 timeout=60m kill=30s accounts="" kv
  for kv in "$@"; do
    case "$kv" in
      TZ=*) tz="${kv#TZ=}" ;; MAX=*) max="${kv#MAX=}" ;;
      TIMEOUT=*) timeout="${kv#TIMEOUT=}" ;; KILL=*) kill="${kv#KILL=}" ;;
      ACCOUNTS=*) accounts="${kv#ACCOUNTS=}" ;;
    esac
  done
  printf '# test\nTZ=%s\nMAX_SESSIONS_PER_DAY=%s\nSESSION_TIMEOUT=%s\nSESSION_KILL_AFTER=%s\nAUDIT_RETENTION_DAYS=30\n' \
    "$tz" "$max" "$timeout" "$kill" > "$CONF"
  [[ -n "$accounts" ]] && printf 'CLAUDE_ACCOUNTS=%s\n' "$accounts" >> "$CONF"
  chmod 0644 "$CONF"
}
reset() { : > "$LEDGER"; : > "$FAKE_LOG"; : > "$FAKE_ENV_LOG"; : > "$MARKS"; rm -f "$FAKE_DIR"/* "$PAUSE"; rm -rf "$CLAUDE_CONFIG_DIR"; conf "$@"; }
# w <args...> — run the wrapper; OUT holds stderr+stdout, RC the exit code.
w() { OUT="$("$WRAPPER" "$@" </dev/null 2>&1)"; RC=$?; }
calls() { if [[ -s "$FAKE_LOG" ]]; then wc -l < "$FAKE_LOG" | tr -d ' '; else echo 0; fi; }
starts() { awk -F'\t' '$3 == "start"' "$LEDGER" | wc -l | tr -d ' '; }
ledger_events() { cut -f3 "$LEDGER" | paste -sd, -; }
today() { TZ="${1:-UTC}" date +%F; }

# ===========================================================================
# F1: settings flags stay refused, before anything else
# ===========================================================================
reset
for a in "--setting-sources project,local" "--setting-sources=user,project" "--settings {}" "--settings=/tmp/x.json"; do
  # shellcheck disable=SC2086 # split on purpose: flag and value
  w $a -p hi
  check "F1 refusal kept: $a exits 2" "$RC" "2"
  contains "F1 refusal kept: $a says why" "$OUT" "loads only the user and managed settings"
done
check "refused flags start nothing" "$(calls)" "0"
check "refused flags leave no ledger line" "$(ledger_events)" ""

# ===========================================================================
# Resuming, continuing, forking or detaching a session is refused
# ===========================================================================
for a in --resume --resume=abc -r --continue -c --fork-session --from-pr --from-pr=12 \
         --teleport --teleport=x --session-id --session-id=11111111-1111-1111-1111-111111111111 -pc -rp; do
  w -p hi "$a"
  check "refused: $a exits 2" "$RC" "2"
  contains "refused: $a says sessions start fresh" "$OUT" "every session starts fresh"
done
for a in --bg --background --cloud --cloud=x --remote-control --remote-control=n --no-session-persistence; do
  w -p hi "$a"
  check "refused: $a exits 2" "$RC" "2"
  contains "refused: $a says why" "$OUT" "would take the session out of the server's limits"
done
check "none of them started a session" "$(calls)" "0"

# ===========================================================================
# --version and --help: no limits, no configuration needed
# ===========================================================================
reset
rm -f "$CONF"
w --version
check "--version runs without a configuration" "$RC" "0"
check "--version goes to the real binary with user settings only" "$(cut -f1 "$FAKE_LOG")" "ARGS --setting-sources user --version"
w -h
check "-h runs too" "$RC" "0"
check "neither counts as a session" "$(ledger_events)" ""

# ===========================================================================
# A session: its own session id, user settings, ledger start and end
# ===========================================================================
reset
DEVLEAD_RUN_ID=20261116T220000Z-loop-abc123 w -p "hello world" --permission-mode acceptEdits
check "a session exits with the session's code" "$RC" "0"
line="$(head -n 1 "$FAKE_LOG")"
args="$(cut -f1 <<<"$line")"
sid="$(sed -n 's/.*--session-id \([0-9a-f-]*\)$/\1/p' <<<"$args")"
check "the session gets a fresh UUID session id" "$([[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && echo uuid || echo "[$sid]")" "uuid"
check "user settings first, the caller's arguments, then the session id" "$args" \
  "ARGS --setting-sources user -p hello world --permission-mode acceptEdits --session-id $sid"
contains "the run id reaches the session" "$line" "RUN=20261116T220000Z-loop-abc123"
contains "the lock descriptor does not reach the session" "$line" "FD9=closed"
check "ledger: start then end" "$(ledger_events)" "start,end"
check "ledger: both lines carry the session id" "$(cut -f4 "$LEDGER" | sort -u)" "$sid"
check "ledger: both lines carry the run id" "$(cut -f5 "$LEDGER" | sort -u)" "20261116T220000Z-loop-abc123"
check "ledger: the calendar day comes first" "$(cut -f1 "$LEDGER" | sort -u)" "$(today)"
check "ledger: the end line has the exit code and no timeout" "$(awk -F'\t' '$3 == "end" {print $6 "/" $7}' "$LEDGER")" "0/-"

reset
echo 7 > "$FAKE_DIR/rc"
w -p hi
check "the session's own exit code comes back" "$RC" "7"
check "and is recorded" "$(awk -F'\t' '$3 == "end" {print $6}' "$LEDGER")" "7"

reset
w -p hi -- --literal
check "the session id goes before a -- separator" "$(cut -f1 "$FAKE_LOG" | sed 's/--session-id [0-9a-f-]*/--session-id SID/')" \
  "ARGS --setting-sources user -p hi --session-id SID -- --literal"

reset
DEVLEAD_RUN_ID=$'bad\tid' w -p hi
check "a run id that is not a plain token is recorded as -" "$(awk -F'\t' '$3 == "start" {print $5}' "$LEDGER")" "-"
check "and the ledger keeps seven fields" "$(awk -F'\t' '{print NF}' "$LEDGER" | sort -u)" "7"

# ===========================================================================
# Never as root. `unshare -r` makes the caller UID 0 in a user namespace, so
# this is the wrapper's real check, unmodified.
# ===========================================================================
reset
OUT="$(unshare -r "$WRAPPER" -p hi </dev/null 2>&1)"; RC=$?
check "as root: a session is refused (75)" "$RC" "75"
contains "as root: says why" "$OUT" "never starts a claude session as root"
check "as root: nothing started" "$(calls)" "0"
check "as root: the refusal is in the ledger" "$(awk -F'\t' '{print $3 "/" $7}' "$LEDGER")" "refused/root"
OUT="$(unshare -r "$WRAPPER" --version </dev/null 2>&1)"; RC=$?
check "as root: --version still runs (the image build checks it)" "$RC" "0"
OUT="$(unshare -r "$WRAPPER" --help </dev/null 2>&1)"; RC=$?
check "as root: --help still runs" "$RC" "0"
reset
w -p hi
check "as the user: the session still runs" "$RC" "0"

# ===========================================================================
# Pause file (S17): no new session while it exists
# ===========================================================================
reset
touch "$PAUSE"
w -p hi
check "paused: exits 75" "$RC" "75"
contains "paused: says so and names the file" "$OUT" "DevLead is paused ($PAUSE exists)"
check "paused: nothing started" "$(calls)" "0"
check "paused: the refusal is in the ledger" "$(awk -F'\t' '{print $3 "/" $7}' "$LEDGER")" "refused/paused"
rm -f "$PAUSE"
w -p hi
check "unpaused: the next session runs" "$RC" "0"

# ===========================================================================
# One session at a time (S17): refused, never queued
# ===========================================================================
reset
flock "$LOCK" sleep 4 &
holder=$!
sleep 0.5
w -p hi
check "busy: exits 75" "$RC" "75"
contains "busy: says another session is running" "$OUT" "another claude session is running"
check "busy: nothing started" "$(calls)" "0"
check "busy: refusal recorded, not counted" "$(awk -F'\t' '{print $3 "/" $7}' "$LEDGER")" "refused/busy"
wait "$holder"
w -p hi
check "once the lock is free the session runs" "$RC" "0"
w -p hi
check "the lock is released when a session ends" "$RC" "0"

reset
touch "$FAKE_DIR/spawn"
w -p hi
rm -f "$FAKE_DIR/spawn"
w -p hi
check "a background process the session left does not hold the lock" "$RC" "0"
pkill -f 'sleep 6' 2>/dev/null

# ===========================================================================
# Sessions per calendar day (S17)
# ===========================================================================
reset MAX=3
for i in 1 2 3; do w -p "session $i"; done
check "three sessions under a cap of 3 run" "$(calls)" "3"
w -p "session 4"
check "the fourth is refused: exits 75" "$RC" "75"
contains "the refusal names the cap" "$OUT" "the daily limit of 3 claude sessions is reached"
check "the fourth never started" "$(calls)" "3"
check "the refusal is recorded" "$(awk -F'\t' '$3 == "refused" {print $7}' "$LEDGER")" "cap"
DEVLEAD_MAX_SESSIONS_PER_DAY=100 MAX_SESSIONS_PER_DAY=100 w -p "session 5"
check "the environment cannot raise the cap" "$RC" "75"
check "refusals are not counted as sessions" "$(starts)" "3"

reset MAX=2
yesterday="$(TZ=UTC date -d yesterday +%F)"
for i in 1 2 3 4 5; do printf '%s\t2026-01-01T00:00:00Z\tstart\tx\t-\t-\t-\n' "$yesterday" >> "$LEDGER"; done
w -p hi
check "yesterday's sessions do not count today" "$RC" "0"

reset MAX=0
w -p hi
check "a cap of 0 refuses every session" "$RC" "75"

reset TZ=Pacific/Kiritimati
TZ=Pacific/Pago_Pago w -p hi
check "the calendar day is the configured TZ's, not the caller's" "$(cut -f1 "$LEDGER" | sort -u)" "$(today Pacific/Kiritimati)"

# ===========================================================================
# Time limit per session (S17)
# ===========================================================================
reset TIMEOUT=2s KILL=1s
echo 30 > "$FAKE_DIR/sleep"
start=$(date +%s)
w -p hi
elapsed=$(( $(date +%s) - start ))
check "a session past its limit is stopped (exit 124)" "$RC" "124"
check "it is stopped on time" "$([[ $elapsed -lt 10 ]] && echo on-time || echo "took ${elapsed}s")" "on-time"
contains "the wrapper says why" "$OUT" "ran past the limit of 2s and was stopped"
check "the ledger records the timeout" "$(awk -F'\t' '$3 == "end" {print $6 "/" $7}' "$LEDGER")" "124/timeout"

reset TIMEOUT=2s KILL=1s
echo 30 > "$FAKE_DIR/sleep"; touch "$FAKE_DIR/stubborn"
start=$(date +%s)
w -p hi
elapsed=$(( $(date +%s) - start ))
check "a session that ignores TERM is killed (exit 137)" "$RC" "137"
check "killed right after the grace period" "$([[ $elapsed -lt 10 ]] && echo on-time || echo "took ${elapsed}s")" "on-time"
check "recorded as a timeout too" "$(awk -F'\t' '$3 == "end" {print $7}' "$LEDGER")" "timeout"

reset TIMEOUT=60m
echo 137 > "$FAKE_DIR/rc"
w -p hi
check "an exit 137 before the limit is not a timeout" "$(awk -F'\t' '$3 == "end" {print $6 "/" $7}' "$LEDGER")" "137/-"

# ===========================================================================
# Claude accounts (S21): one account per session, its token and no other
# ===========================================================================
POOL="team=DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN ultra=DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN"
TEAM_TOKEN=sk-ant-oat01-DUMMY-team
ULTRA_TOKEN=sk-ant-oat01-DUMMY-ultra
POOL_ENV=(DEVLEAD_CLAUDE_ACCOUNT_1=team "DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN=$TEAM_TOKEN" DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED=2026-11-01
          DEVLEAD_CLAUDE_ACCOUNT_2=ultra "DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN=$ULTRA_TOKEN" DEVLEAD_CLAUDE_ACCOUNT_2_ISSUED=2026-10-15)
# pw <args...> — the wrapper with the pool in its environment, as the jobs run it.
pw() { OUT="$(env "${POOL_ENV[@]}" "$WRAPPER" "$@" </dev/null 2>&1)"; RC=$?; }
start_account() { awk -F'\t' '$3 == "start" {print $7}' "$LEDGER" | paste -sd, -; }

reset ACCOUNTS="$POOL"
pw -p hi
check "pool: the session runs" "$RC" "0"
check "pool: the first account in priority order is used" "$(start_account)" "team"
check "pool: its token reaches the session as CLAUDE_CODE_OAUTH_TOKEN" "$(cut -f1 "$FAKE_ENV_LOG")" "OAUTH=$TEAM_TOKEN"
check "pool: no token variable of the pool reaches the session" "$(cut -f2 "$FAKE_ENV_LOG")" \
  "POOL=DEVLEAD_CLAUDE_ACCOUNT_1,DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED,DEVLEAD_CLAUDE_ACCOUNT_2,DEVLEAD_CLAUDE_ACCOUNT_2_ISSUED"
check "pool: the ledger names the account, never the token" "$(grep -c 'DUMMY' "$LEDGER")" "0"
lacks "pool: the wrapper prints no token" "$OUT" "DUMMY"

reset ACCOUNTS="ultra=DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN team=DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN"
pw -p hi
check "pool: the order is runner.conf's, not the numbering's" "$(start_account) $(cut -f1 "$FAKE_ENV_LOG")" "ultra OAUTH=$ULTRA_TOKEN"

reset ACCOUNTS="$POOL"
env "${POOL_ENV[@]}" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-DUMMY-caller DEVLEAD_CLAUDE_ACCOUNT_7_TOKEN=x \
  "$WRAPPER" -p hi </dev/null >/dev/null 2>&1
check "pool: a token the caller set is replaced by the account's" "$(cut -f1 "$FAKE_ENV_LOG")" "OAUTH=$TEAM_TOKEN"
check "pool: a stray pool token variable does not reach the session" "$(cut -f2 "$FAKE_ENV_LOG" | grep -c '_7_TOKEN')" "0"

reset ACCOUNTS="$POOL"
env -u DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN="$ULTRA_TOKEN" "$WRAPPER" -p hi </dev/null >/dev/null 2>&1
check "pool: an account whose token the caller removed gets no token (the caller's own auth, as before)" \
  "$(start_account) $(cut -f1 "$FAKE_ENV_LOG")" "team OAUTH=unset"

for bad_item in "team" "team=GH_TOKEN" "Team=DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN" "team=DEVLEAD_CLAUDE_ACCOUNT_0_TOKEN"; do
  reset ACCOUNTS="$bad_item"
  pw -p hi
  check "a CLAUDE_ACCOUNTS entry that is not name=token variable ($bad_item): refused as noconf" \
    "$RC $(calls) $(awk -F'\t' '{print $7}' "$LEDGER")" "75 0 noconf"
done

# Previous behaviour: the single token is a pool of one, "default", and the
# session gets it exactly as before; with no account line nothing changes.
reset ACCOUNTS="default=CLAUDE_CODE_OAUTH_TOKEN"
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-DUMMY-single w -p hi
check "single token: the session runs" "$RC" "0"
check "single token: the session gets the same token" "$(cut -f1 "$FAKE_ENV_LOG")" "OAUTH=sk-ant-oat01-DUMMY-single"
check "single token: the ledger names the account default" "$(start_account)" "default"
reset ACCOUNTS="default=CLAUDE_CODE_OAUTH_TOKEN"
w -p hi
check "single token removed by the caller (an API key session): still none" "$(cut -f1 "$FAKE_ENV_LOG")" "OAUTH=unset"
reset
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-DUMMY-single w -p hi
check "no account line: the caller's token is left as it was" "$(cut -f1 "$FAKE_ENV_LOG")" "OAUTH=sk-ant-oat01-DUMMY-single"
check "no account line: the start line's detail stays -" "$(start_account)" "-"

# ===========================================================================
# Usage limits and refused tokens (S22). The transcripts are the ones Claude
# Code 2.1.326 recorded against a local mock of the API (no real token, no
# real limit): test/fixtures/claude-2.1.326/<case>.transcript.jsonl, with
# the reset time moved to the test's clock where it matters.
# ===========================================================================
FIX="$REPO_ROOT/test/fixtures/claude-2.1.326"
# fixture <case> [resetsAt] — the recorded transcript, its reset replaced.
fixture() {
  if [[ -n "${2:-}" ]]; then
    jq -c --argjson r "$2" 'if .type == "assistant" and (.apiErrorParams.rate_limit_info.resetsAt? != null)
      then .apiErrorParams.rate_limit_info.resetsAt = $r else . end' "$FIX/$1.transcript.jsonl"
  else cat "$FIX/$1.transcript.jsonl"; fi
}
# limited_by <account> <case> [resetsAt] — that account's sessions end on it.
limited_by() { fixture "$2" "${3:-}" > "$FAKE_DIR/transcript.$1"; echo 1 > "$FAKE_DIR/rc.$1"; }
mark() { awk -F'\t' -v a="$1" '$1 == a {l = $0} END {print l}' "$MARKS"; }
mark_field() { mark "$1" | cut -f"$2"; }
now() { date +%s; }

# A 5-hour limit with its reset: the account rests until then, and the next
# session takes the next account (L28 clarification: Team first, Ultra the
# fallback while Team rests).
reset ACCOUNTS="$POOL"
reset_at=$(( $(now) + 3 * 3600 ))
limited_by team five_hour "$reset_at"
pw -p "iteration 1"
check "5-hour limit: the session's own exit code comes back" "$RC" "1"
check "5-hour limit: it ran on team" "$(start_account)" "team"
check "5-hour limit: team is marked until the reset Claude reported" \
  "$(mark_field team 2)/$(mark_field team 3)/$(mark_field team 7)" "$reset_at/five_hour/reported"
check "5-hour limit: the mark names the session and the run" "$(mark_field team 5)" "$(awk -F'\t' '$3 == "start" {print $4}' "$LEDGER")"
contains "5-hour limit: the wrapper says so and names the next account" "$OUT" \
  "the Claude account team rests until $(TZ=UTC date -d "@$reset_at" '+%Y-%m-%d %H:%M %Z') — its 5-hour limit; the next session uses ultra"
pw -p "iteration 2"
check "the next session runs on ultra" "$RC $(start_account | cut -d, -f2)" "0 ultra"
check "with ultra's token" "$(sed -n 2p "$FAKE_ENV_LOG" | cut -f1)" "OAUTH=$ULTRA_TOKEN"
check "no token in the marks or the ledger" "$(cat "$MARKS" "$LEDGER" | grep -c DUMMY)" "0"
lacks "no token in what the wrapper prints" "$OUT" "DUMMY"

# When the mark expires, sessions go back to the higher-priority account.
reset ACCOUNTS="$POOL"
limited_by team five_hour $(( $(now) + 2 ))
pw -p "iteration 1"
rm -f "$FAKE_DIR/transcript.team" "$FAKE_DIR/rc.team"
pw -p "iteration 2"
sleep 3
pw -p "iteration 3"
check "after team's reset the next session is team's again" "$(start_account)" "team,ultra,team"
check "with team's token" "$(sed -n 3p "$FAKE_ENV_LOG" | cut -f1)" "OAUTH=$TEAM_TOKEN"

# The weekly limit of the fallback, with its reset.
reset ACCOUNTS="$POOL"
printf 'team\t-\tauth\t2026-11-17T00:00:00Z\tsid\trun\tauth\n' > "$MARKS"
reset_at=$(( $(now) + 4 * 86400 ))
limited_by ultra seven_day "$reset_at"
pw -p hi
check "weekly limit: ultra is marked until its reset" "$(mark_field ultra 2)/$(mark_field ultra 3)" "$reset_at/seven_day"
contains "weekly limit: named as such; every account is resting now" "$OUT" "— its weekly limit; every account is resting now (team until its token is renewed, ultra until"

# No usable reset time: 5 hours.
for r in "" $(( $(now) - 60 )) $(( $(now) + 30 * 86400 )); do
  reset ACCOUNTS="$POOL"
  if [[ -z "$r" ]]; then fixture five_hour_noreset > "$FAKE_DIR/transcript.team"; label="no reset time"
  else fixture five_hour "$r" > "$FAKE_DIR/transcript.team"; label="reset $r not believable"; fi
  echo 1 > "$FAKE_DIR/rc.team"
  t0=$(now); pw -p hi
  u="$(mark_field team 2)"
  check "$label: team rests 5 hours" "$([[ "$u" =~ ^[0-9]+$ ]] && (( u >= t0 + 18000 && u <= $(now) + 18000 )) && echo 5h || echo "[$u]")" "5h"
  check "$label: the mark says the time is the default" "$(mark_field team 7)" "default"
  contains "$label: the wrapper says Claude gave no usable reset time" "$OUT" "Claude gave no usable reset time: it rests 5 hours"
done

# A token the API refused: the account rests until a restart.
for c in auth_expired auth_invalid auth_revoked; do
  reset ACCOUNTS="$POOL"
  fixture "$c" > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
  pw -p hi
  check "$c: team rests until its token is renewed" "$(mark_field team 2)/$(mark_field team 3)/$(mark_field team 7)" "-/auth/auth"
  contains "$c: the wrapper says so" "$OUT" "the Claude account team rests until its token is renewed — a refused token"
  pw -p hi
  check "$c: the next session is ultra's" "$(start_account | cut -d, -f2)" "ultra"
done

# Every account resting: no session, not counted, one machine-readable line.
reset ACCOUNTS="$POOL" MAX=5
early=$(( $(now) + 3600 )); late=$(( $(now) + 7200 ))
printf 'team\t%s\tfive_hour\tt\ts\tr\treported\nultra\t%s\tseven_day\tt\ts\tr\treported\n' "$late" "$early" > "$MARKS"
OUT_STDOUT="$(env "${POOL_ENV[@]}" "$WRAPPER" -p hi </dev/null 2>"$SANDBOX/stderr")"; RC=$?
check "all resting: refused (75)" "$RC" "75"
check "all resting: stdout says claude-limited, for the launchers" "$OUT_STDOUT" "STATUS: claude-limited"
contains "all resting: stderr names each account and the earliest reset" "$(cat "$SANDBOX/stderr")" \
  "every Claude account is resting (team until $(TZ=UTC date -d "@$late" '+%Y-%m-%d %H:%M %Z'), ultra until $(TZ=UTC date -d "@$early" '+%Y-%m-%d %H:%M %Z')) — no session starts until $(TZ=UTC date -d "@$early" '+%Y-%m-%d %H:%M %Z')"
check "all resting: nothing started" "$(calls)" "0"
check "all resting: the refusal is limited, and no start is counted" "$(awk -F'\t' '{print $3 "/" $7}' "$LEDGER")" "refused/limited"
printf 'team\t-\tauth\tt\ts\tr\tauth\n' > "$MARKS"
reset_keep() { : > "$LEDGER"; : > "$FAKE_LOG"; }
reset_keep
conf ACCOUNTS="default=CLAUDE_CODE_OAUTH_TOKEN"
printf 'default\t-\tauth\tt\ts\tr\tauth\n' > "$MARKS"
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-DUMMY-single w -p hi
check "single token refused: the pool of one rests, refused (75)" "$RC" "75"
contains "single token refused: until a token is renewed" "$OUT" "no session starts until a token is renewed and the container restarted"

# Fail safe: what is not a usage limit or a refused token rests nothing.
not_marked() { # not_marked <label> — the last session left no mark and the next one is team's again
  check "$1: no mark" "$(grep -c . "$MARKS")" "0"
  rm -f "$FAKE_DIR"/transcript.team "$FAKE_DIR"/rc.team
  pw -p hi
  check "$1: the next session is still team's" "$(start_account | awk -F, '{print $NF}')" "team"
}
reset ACCOUNTS="$POOL"; fixture five_hour "$(( $(now) + 3600 ))" | jq -c 'del(.apiError)' > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "a rate limit that is not the account's usage limit"
reset ACCOUNTS="$POOL"; fixture auth_expired | jq -c 'del(.apiErrorStatus)' > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "an authentication error with no 401 or 403 (a network error)"
reset ACCOUNTS="$POOL"; fixture overloaded > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "an overloaded API (529, recorded after Claude Code's retries)"
reset ACCOUNTS="$POOL"; fixture five_hour "$(( $(now) + 3600 ))" | jq -c 'if .type == "assistant" then .isSidechain = true else . end' > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "a limit inside a subagent only"
reset ACCOUNTS="$POOL"; { fixture five_hour "$(( $(now) + 3600 ))"; echo '{"type":"assistant","message":{"content":[{"type":"text","text":"later reply"}]}}'; } > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "a limit that is not the last message"
reset ACCOUNTS="$POOL"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "no transcript"
reset ACCOUNTS="$POOL"; printf 'not json\n{"type":"assistant"\n' > "$FAKE_DIR/transcript.team"; echo 1 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "a transcript that is not JSON"
reset ACCOUNTS="$POOL"; fixture five_hour "$(( $(now) + 3600 ))" > "$FAKE_DIR/transcript.team"; echo 0 > "$FAKE_DIR/rc.team"
pw -p hi; not_marked "a session that exited 0"
reset ACCOUNTS="$POOL" TIMEOUT=1s KILL=1s; fixture five_hour "$(( $(now) + 3600 ))" > "$FAKE_DIR/transcript.team"; echo 5 > "$FAKE_DIR/sleep"
pw -p hi; rm -f "$FAKE_DIR/sleep"; conf ACCOUNTS="$POOL"; not_marked "a session stopped at its time limit"

# The marks file is root's to prepare: without it no session starts.
reset ACCOUNTS="$POOL"; rm -f "$MARKS"
pw -p hi
check "no marks file: refused as nomarks" "$RC $(calls) $(awk -F'\t' '{print $7}' "$LEDGER")" "75 0 nomarks"
reset ACCOUNTS="$POOL"; rm -f "$MARKS"; ln -s /dev/null "$MARKS"
pw -p hi
check "a marks file that is a link: refused as nomarks" "$RC $(calls)" "75 0"
rm -f "$MARKS"; : > "$MARKS"

# Previous behaviour: without an account line nothing is marked or needed.
reset; rm -f "$MARKS"
fixture five_hour "$(( $(now) + 3600 ))" > "$FAKE_DIR/transcript"; echo 1 > "$FAKE_DIR/rc"
w -p hi
check "no account line: a limited session ends as before, with no marks file" "$RC $([[ -e "$MARKS" ]] && echo marks || echo none)" "1 none"
w -p hi
check "no account line: and the next one starts" "$(calls)" "2"
: > "$MARKS"

# ===========================================================================
# Fail closed: no trustworthy configuration or ledger, no session
# ===========================================================================
refused_conf() { # refused_conf <label>
  w -p hi
  check "$1: exits 75" "$RC" "75"
  contains "$1: says the configuration is unusable" "$OUT" "no usable runner configuration"
  check "$1: nothing started" "$(calls)" "0"
}
reset; rm -f "$CONF"; refused_conf "no runner.conf"
reset; chmod 0666 "$CONF"; refused_conf "runner.conf writable by others"
reset; chmod 0664 "$CONF"; refused_conf "runner.conf writable by its group"
reset MAX=lots; refused_conf "a cap that is not a number"
reset TIMEOUT=60; refused_conf "a timeout without a unit"
reset TZ=../../etc; refused_conf "a TZ that is not a zone name"
reset; rm -f "$LEDGER"
w -p hi
check "no ledger: exits 75" "$RC" "75"
contains "no ledger: says the sessions cannot be counted" "$OUT" "cannot count today's sessions"
check "no ledger: nothing started" "$(calls)" "0"
: > "$LEDGER"
reset; rm -f "$LOCK"
w -p hi
check "no lock file: exits 75" "$RC" "75"
check "no lock file: nothing started" "$(calls)" "0"
# A lock that cannot be opened is not another session running: the refusal
# says so, and run-job.sh tells the operator the lock is broken, not busy.
check "no lock file: refused as nolock, not busy" "$(awk -F'\t' '{print $3 "/" $7}' "$LEDGER")" "refused/nolock"
contains "no lock file: says the lock cannot be opened" "$OUT" "cannot open the session lock"
: > "$LOCK"
reset; ln -s /dev/null "$SANDBOX/lock-link"; mv "$LOCK" "$LOCK.real"; ln -s "$SANDBOX/lock-link" "$LOCK"
w -p hi
check "a lock that is a link: refused as nolock" "$RC $(awk -F'\t' '{print $7}' "$LEDGER")" "75 nolock"
rm -f "$LOCK"; mv "$LOCK.real" "$LOCK"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
