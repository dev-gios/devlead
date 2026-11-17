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
CONF="$SANDBOX/runner.conf"
LEDGER="$SANDBOX/state/sessions.tsv"
LOCK="$SANDBOX/state/session.lock"
PAUSE="$SANDBOX/PAUSE"
WRAPPER="$SANDBOX/claude"
export FAKE_DIR FAKE_LOG
mkdir -p "$FAKE_DIR" "$SANDBOX/state"
: > "$LEDGER"; : > "$LOCK"

# The fake Claude Code: logs its arguments, the run id it sees and whether the
# wrapper's lock descriptor reached it; then does what files in $FAKE_DIR say.
cat > "$SANDBOX/real-claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGS'; for a in "$@"; do printf ' %s' "$a"; done
  printf '\tRUN=%s\tFD9=%s\n' "${DEVLEAD_RUN_ID:-}" "$([[ -e /proc/$$/fd/9 ]] && echo open || echo closed)"; } >> "$FAKE_LOG"
[[ -f "$FAKE_DIR/spawn" ]] && { sleep 6 >/dev/null 2>&1 & }
[[ -f "$FAKE_DIR/stubborn" ]] && trap '' TERM
[[ -f "$FAKE_DIR/sleep" ]] && sleep "$(cat "$FAKE_DIR/sleep")"
exit "$(cat "$FAKE_DIR/rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/real-claude"

# The copy: only the fixed-paths block changes, and every line of it must be
# found — a renamed constant must fail here, not test the image's paths.
cp "$SRC" "$WRAPPER"
for kv in "REAL_CLAUDE=$SANDBOX/real-claude" "RUNNER_CONF=$CONF" "LEDGER=$LEDGER" \
          "SESSION_LOCK=$LOCK" "PAUSE_FILE=$PAUSE" "CONF_OWNER_UID=$(id -u)"; do
  key="${kv%%=*}"
  check "the wrapper has the fixed path $key" "$(grep -c "^$key=" "$WRAPPER")" "1"
  sed -i "s|^$key=.*|$kv|" "$WRAPPER"
done
chmod +x "$WRAPPER"

conf() { # conf [KEY=value...] — the defaults with these overrides
  local tz=UTC max=3 timeout=60m kill=30s kv
  for kv in "$@"; do
    case "$kv" in
      TZ=*) tz="${kv#TZ=}" ;; MAX=*) max="${kv#MAX=}" ;;
      TIMEOUT=*) timeout="${kv#TIMEOUT=}" ;; KILL=*) kill="${kv#KILL=}" ;;
    esac
  done
  printf '# test\nTZ=%s\nMAX_SESSIONS_PER_DAY=%s\nSESSION_TIMEOUT=%s\nSESSION_KILL_AFTER=%s\nAUDIT_RETENTION_DAYS=30\n' \
    "$tz" "$max" "$timeout" "$kill" > "$CONF"
  chmod 0644 "$CONF"
}
reset() { : > "$LEDGER"; : > "$FAKE_LOG"; rm -f "$FAKE_DIR"/* "$PAUSE"; conf "$@"; }
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
