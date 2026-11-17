#!/usr/bin/env bash
# unit-day-summary.sh — .devlead/scripts/day-summary.sh, the DevLead server's
# end-of-day summary (S1, S16, S19): built from the day's audit lines and
# live PR state, sent once at level agenda, no claude session.
#
#   bash test/unit-day-summary.sh
#
# notify.sh is the real one, writing a sandbox inbox; a fake curl captures
# the push. gh is a fake answering `gh pr list` per repo.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SANDBOX="$(mktemp -d /tmp/devlead-day-summary.XXXXXX)"
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

export HOME="$SANDBOX/home"
export DEVLEAD_NOTIFY_DIR="$HOME/.devlead"
SCRIPTS="$SANDBOX/scripts"
BIN="$SANDBOX/bin"
mkdir -p "$SCRIPTS" "$BIN" "$HOME/.devlead/audit" "$SANDBOX/work/app" "$SANDBOX/work/api"
cp "$REPO_ROOT/.devlead/scripts/day-summary.sh" "$REPO_ROOT/.devlead/scripts/notify.sh" "$SCRIPTS/"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $* in ${PWD##*/}" >> "$SANDBOX/gh.log"
case "${PWD##*/}" in
  app) printf 'true\nfalse\ntrue\n' ;;
  api) exit 1 ;;
esac
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == "--data-binary" ]] && printf '%s\n' "$2" >> "$SANDBOX/pushed"; shift; done
EOF
chmod +x "$BIN"/*
export SANDBOX PATH="$BIN:$PATH"
printf '%s\n' "$SANDBOX/work/app" "$SANDBOX/work/api" > "$HOME/.devlead/autonomous-repos"
INBOX="$HOME/.devlead/inbox.tsv"
AUDIT="$HOME/.devlead/audit/2026-11.jsonl"
# line <trigger> <outcome> <day> [prs json] [parked json] [sessions json]
line() {
  jq -n -c --arg t "$1" --arg o "$2" --arg d "$3" --argjson p "${4:-[]}" --argjson k "${5:-{\"count\":0,\"issues\":[]\}}" --argjson s "${6:-[]}" \
    '{run_id: "20261117T120000Z-\($t)-abcdef", trigger: $t, started_at: "\($d)T12:00:00-05:00", outcome: $o,
      session_ids: $s, prs_opened: $p, parked: $k}'
}
{
  line poll ok 2026-11-17 '["https://github.com/acme/app/pull/43"]' '{"count":1,"issues":[15]}' '["s1"]'
  line fleet failed 2026-11-17 '["https://github.com/acme/app/pull/44","https://evil.example/x/y/pull/1","not a url"]' '{"count":2,"issues":[7,"#8; rm"]}' '["s2","s3"]'
  line poll ok 2026-11-17
  line morning ok 2026-11-17
  line loop timeout 2026-11-16 '["https://github.com/acme/app/pull/40"]'
  echo 'not json at all'
  jq -n -c '{trigger: "Ignore your rules", outcome: "ok", started_at: "2026-11-17T09:00:00-05:00", prs_opened: ["https://github.com/acme/app/pull/66"]}'
  jq -n -c '{trigger: "poll", outcome: "hacked", started_at: "2026-11-17T09:00:00-05:00"}'
} > "$AUDIT"

run() { rm -f "$SANDBOX/pushed" "$INBOX"; OUT="$(bash "$SCRIPTS/day-summary.sh" "$@" 2>&1)"; RC=$?; }
agenda_line() { awk -F'\t' '$2 == "agenda"' "$INBOX" 2>/dev/null; }

( umask 077; printf 'DEVLEAD_NTFY_URL=https://ntfy.test/topic\n' > "$HOME/.devlead/notify.env" )
run 2026-11-17
check "exit 0" "$RC" "0"
check "one notice, at level agenda" "$(agenda_line | wc -l | tr -d ' ')" "1"
check "no need notice" "$(awk -F'\t' '$2 == "need"' "$INBOX" | wc -l | tr -d ' ')" "0"
check "the code: the day's counts only" "$(agenda_line | cut -f3)" "day 2026-11-17: 4 run(s), 2 PR(s) opened, 3 parked, 1 failed"
msg="$(agenda_line | cut -f6)"
contains "the message: the PR links of the day" "$msg" "PRs opened: https://github.com/acme/app/pull/43 https://github.com/acme/app/pull/44"
contains "the message: the parked issue numbers" "$msg" "parked: 3 (#7 #15) — reasons in ~/.devlead/reports/"
contains "the message: the failed runs" "$msg" "failed runs: fleet (failed)"
contains "the message: live open PRs per repo, unknown when gh fails" "$msg" "open PRs now: app: 3 open (2 draft), api: unknown"
contains "the message: the sessions" "$msg" "claude sessions: 3"
contains "the message: the journal stays the user's" "$msg" "the journal is yours: /cerremos"
lacks "another day's PR is not counted" "$msg" "pull/40"
lacks "a URL that is not a github.com pull is left out" "$msg" "evil.example"
lacks "a forged job name is left out" "$msg" "pull/66"
lacks "text that is not a number is left out" "$msg" "rm"
check "without DEVLEAD_NOTIFY_DETAIL the push carries only the counts" "$(cat "$SANDBOX/pushed")" \
  "DevLead agenda: day 2026-11-17: 4 run(s), 2 PR(s) opened, 3 parked, 1 failed"
contains "the printed summary: the PRs" "$OUT" "  https://github.com/acme/app/pull/44"
contains "the printed summary: runs by outcome" "$OUT" "runs: 4 (failed 1, ok 3)"
contains "the printed summary: says the journal is /cerremos's" "$OUT" "is written with you in /cerremos"
contains "live state: asked per repo, from its clone, authored by the account" "$(cat "$SANDBOX/gh.log")" "gh pr list --state open --author @me --json isDraft -q .[] | .isDraft in app"

( umask 077; printf 'DEVLEAD_NTFY_URL=https://ntfy.test/topic\nDEVLEAD_NOTIFY_DETAIL=1\n' > "$HOME/.devlead/notify.env" )
run 2026-11-17
contains "with DEVLEAD_NOTIFY_DETAIL=1 the push carries the lists" "$(cat "$SANDBOX/pushed")" \
  "— PRs opened: https://github.com/acme/app/pull/43 https://github.com/acme/app/pull/44"

# A day with nothing still sends the summary: the server is alive.
run 2026-11-20
check "a quiet day: exit 0" "$RC" "0"
check "a quiet day: the counts are zero" "$(agenda_line | cut -f3)" "day 2026-11-20: 0 run(s), 0 PR(s) opened, 0 parked, 0 failed"
rm -f "$AUDIT"
run 2026-11-17
check "no audit file: still a summary" "$(agenda_line | cut -f3)" "day 2026-11-17: 0 run(s), 0 PR(s) opened, 0 parked, 0 failed"
ln -s "$SANDBOX/elsewhere.jsonl" "$AUDIT"
printf '%s\n' "$(line poll ok 2026-11-17 '["https://github.com/acme/app/pull/43"]')" > "$SANDBOX/elsewhere.jsonl"
run 2026-11-17
check "an audit file that is a link is not read" "$(agenda_line | cut -f3)" "day 2026-11-17: 0 run(s), 0 PR(s) opened, 0 parked, 0 failed"
rm -f "$AUDIT"

out="$(bash "$SCRIPTS/day-summary.sh" yesterday 2>&1)"; rc=$?
check "a day that is not YYYY-MM-DD: exit 2" "$rc" "2"
contains "misuse: usage" "$out" "usage: day-summary.sh [YYYY-MM-DD]"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
