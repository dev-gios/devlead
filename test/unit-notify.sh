#!/usr/bin/env bash
# unit-notify.sh — coverage for .devlead/scripts/notify.sh
#
#   bash test/unit-notify.sh
#
# Pins the three things that matter about the channel: `need` reaches the
# phone and `info` never does; nothing leaves the machine unless the user
# configured it (and by default not the repository or the message); and `send`
# can never fail the run that called it.
#
# SAFETY: DEVLEAD_NOTIFY_DIR points at a sandbox, so the real inbox and the
# real notify.env are never read or written. `curl` is a fake on $PATH that
# only logs: no network request is ever made.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
NOTIFY="$REPO_ROOT/.devlead/scripts/notify.sh"
SANDBOX="$(mktemp -d /tmp/devlead-notify.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
export DEVLEAD_NOTIFY_DIR="$SANDBOX/state"
FAKEBIN="$SANDBOX/fakebin"
CURL_LOG="$SANDBOX/curl.log"
mkdir -p "$FAKEBIN" "$DEVLEAD_NOTIFY_DIR"

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

cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$CURL_LOG"
exit "${FAKE_CURL_RC:-0}"
EOF
chmod +x "$FAKEBIN/curl"
export CURL_LOG

REPO="$SANDBOX/secret-project"
git init -q "$REPO"
cd "$REPO" || exit 1

send() { PATH="$FAKEBIN:$PATH" bash "$NOTIFY" send "$@"; }
curl_calls() { if [[ -f "$CURL_LOG" ]]; then wc -l < "$CURL_LOG" | tr -d ' '; else echo 0; fi; }
reset() { rm -f "$CURL_LOG" "$DEVLEAD_NOTIFY_DIR"/inbox*.tsv; }
write_config() { printf '%s\n' "$@" > "$DEVLEAD_NOTIFY_DIR/notify.env"; chmod "${CONFIG_MODE:-600}" "$DEVLEAD_NOTIFY_DIR/notify.env"; }
last_field() { tail -n 1 "$DEVLEAD_NOTIFY_DIR/inbox.tsv" | cut -f"$1"; }

# ===========================================================================
# No configuration -> nothing leaves the machine, the inbox still records it
# ===========================================================================
reset; rm -f "$DEVLEAD_NOTIFY_DIR/notify.env"
send need loop-paused "the envelope says enabled: false"
check "unconfigured need: exit 0" "$?" "0"
check "unconfigured need: no network call" "$(curl_calls)" "0"
check "unconfigured need: level recorded" "$(last_field 2)" "need"
check "unconfigured need: code recorded" "$(last_field 3)" "loop-paused"
check "unconfigured need: push outcome recorded as off" "$(last_field 4)" "off"
check "unconfigured need: repo recorded locally" "$(last_field 5)" "$REPO"
check "unconfigured need: message recorded locally" "$(last_field 6)" "the envelope says enabled: false"

# ===========================================================================
# Configured -> need pushes exactly once, info never does
# ===========================================================================
reset; write_config "DEVLEAD_NTFY_URL=https://push.example/topic-abc"
send need loop-stuck "task alpha parked twice: tests red"
check "configured need: one network call" "$(curl_calls)" "1"
check "configured need: outcome sent" "$(last_field 4)" "sent"
log="$(cat "$CURL_LOG")"
contains "push goes to the configured URL" "$log" "https://push.example/topic-abc"
contains "push carries the code" "$log" "DevLead needs you: loop-stuck"
contains "push has a timeout" "$log" "--max-time"
lacks "push does NOT carry the repository name by default" "$log" "secret-project"
lacks "push does NOT carry the message by default" "$log" "tests red"
lacks "no Authorization header without a token" "$log" "Authorization"

reset
send info loop-done "every task in the plan is done"
check "info: never pushes" "$(curl_calls)" "0"
check "info: recorded in the inbox" "$(last_field 2)" "info"
check "info: push outcome none" "$(last_field 4)" "none"

reset; write_config "DEVLEAD_NTFY_URL=https://push.example/topic-abc" "DEVLEAD_NOTIFY_DETAIL=1" "DEVLEAD_NTFY_TOKEN=tk_123"
send need loop-stuck "tests red"
log="$(cat "$CURL_LOG")"
contains "detail opt-in: push carries the repo name" "$log" "secret-project"
contains "detail opt-in: push carries the message" "$log" "tests red"
lacks "detail opt-in: never the full local path" "$log" "$SANDBOX"
contains "token is sent as a Bearer header" "$log" "Authorization: Bearer tk_123"

# ===========================================================================
# Unsafe configuration -> no push, and the inbox says why
# ===========================================================================
reset; CONFIG_MODE=644 write_config "DEVLEAD_NTFY_URL=https://push.example/topic-abc"
send need x "m"
check "config not 600: no network call" "$(curl_calls)" "0"
check "config not 600: outcome says so" "$(last_field 4)" "skipped:config-not-600"

reset; write_config "DEVLEAD_NTFY_URL=http://push.example/topic-abc"
send need x "m"
check "http URL: no network call" "$(curl_calls)" "0"
check "http URL: outcome says so" "$(last_field 4)" "skipped:url-not-https"

reset; write_config "OTHER=1"
send need x "m"
check "no URL in config: no network call" "$(curl_calls)" "0"

# The config is parsed, never executed.
reset; write_config 'DEVLEAD_NTFY_URL=https://push.example/t' "touch $SANDBOX/pwned" '$(touch '"$SANDBOX"'/pwned2)'
send need x "m"
check "config file is never executed" "$(find "$SANDBOX" -maxdepth 1 -name "pwned*" | wc -l | tr -d " ")" "0"

# ===========================================================================
# send never fails its caller
# ===========================================================================
reset; write_config "DEVLEAD_NTFY_URL=https://push.example/topic-abc"
FAKE_CURL_RC=7 send need loop-paused "m"
check "push fails: exit 0" "$?" "0"
check "push fails: exactly one attempt" "$(curl_calls)" "1"
check "push fails: outcome failed, entry still in the inbox" "$(last_field 4)" "failed"

send bogus-level x "m" 2>/dev/null
check "bad level: exit 0" "$?" "0"
send need 2>/dev/null
check "missing code: exit 0" "$?" "0"
check "bad calls write nothing" "$(wc -l < "$DEVLEAD_NOTIFY_DIR/inbox.tsv" | tr -d ' ')" "1"

out="$(DEVLEAD_NOTIFY_DIR=/proc/nonexistent/x PATH="$FAKEBIN:$PATH" bash "$NOTIFY" send info c "kept on stderr" 2>&1)"
check "unwritable inbox: exit 0" "$?" "0"
contains "unwritable inbox: the message is not lost silently" "$out" "kept on stderr"

reset
send info c "$(printf 'line one\nline\ttwo')"
check "newlines and tabs are flattened: one inbox line" "$(wc -l < "$DEVLEAD_NOTIFY_DIR/inbox.tsv" | tr -d ' ')" "1"
check "flattened message keeps its words" "$(last_field 6)" "line one line two"

# ===========================================================================
# list / ack
# ===========================================================================
reset; rm -f "$DEVLEAD_NOTIFY_DIR/notify.env"
out="$(bash "$NOTIFY" list)"
check "empty inbox: STATUS: empty" "$out" "STATUS: empty"
send info first-info "i"
send need then-need "n"
out="$(bash "$NOTIFY" list)"
contains "list: STATUS: pending" "$out" "STATUS: pending"
contains "list: counts need" "$out" "COUNT_NEED: 1"
contains "list: counts info" "$out" "COUNT_INFO: 1"
check "list: need entries come first" "$(grep -n '^\[' <<<"$out" | head -n 1 | grep -c then-need)" "1"
check "list does not consume the inbox" "$(wc -l < "$DEVLEAD_NOTIFY_DIR/inbox.tsv" | tr -d ' ')" "2"

send agenda "1 repo(s), 2 issue(s) today" "proj: #1 a; #2 b"
out="$(bash "$NOTIFY" list)"
contains "list: counts agenda" "$out" "COUNT_AGENDA: 1"
check "list: agenda comes after need" "$(grep '^\[' <<<"$out" | sed -n 2p | grep -c '^\[agenda\]')" "1"
check "list: info comes last" "$(grep '^\[' <<<"$out" | sed -n 3p | grep -c '^\[info\]')" "1"
check "unconfigured agenda: push outcome off" "$(last_field 4)" "off"

out="$(bash "$NOTIFY" ack)"
contains "ack: STATUS: acked" "$out" "STATUS: acked"
contains "ack: reports how many" "$out" "COUNT: 3"
check "ack: inbox is empty afterwards" "$(bash "$NOTIFY" list)" "STATUS: empty"
check "ack: entries are archived, not deleted" "$(wc -l < "$DEVLEAD_NOTIFY_DIR/inbox.read.tsv" | tr -d ' ')" "3"

send bogus some-code "m"
check "unknown level: nothing recorded" "$(bash "$NOTIFY" list)" "STATUS: empty"

bash "$NOTIFY" 2>/dev/null
check "no subcommand: exit 1" "$?" "1"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
