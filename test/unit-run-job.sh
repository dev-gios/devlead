#!/usr/bin/env bash
# unit-run-job.sh — docker/run-job.sh, the runner of the DevLead server's
# scheduled jobs: pause, conditions, one job at a time, private TMPDIR,
# leftover processes, audit line and transcripts, failure notices (S11,
# S17-S19, F1 follow-ups b and d).
#
#   bash test/unit-run-job.sh
#
# Like the claude wrapper, run-job.sh has fixed paths. This suite runs a COPY
# whose fixed-paths block points into a sandbox. The jobs are stubs that act
# out what a real job and its claude sessions would leave behind — ledger
# lines, Claude Code transcripts, background processes — so every effect is
# checked without Claude Code, Docker or root. notify.sh is the real one,
# writing a sandbox inbox with no push configured. docker-smoke.sh runs the
# real thing in the image.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="$REPO_ROOT/docker/run-job.sh"
SANDBOX="$(mktemp -d /tmp/devlead-run-job.XXXXXX)"
cleanup() {
  pkill -f "devlead-run-job-test-$$" 2>/dev/null
  jobs -p | xargs -r kill 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

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

unset DEVLEAD_CLAUDE_BIN DEVLEAD_LOOP_REPO DEVLEAD_RUN_ID
export HOME="$SANDBOX/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export DEVLEAD_NOTIFY_DIR="$HOME/.devlead"
export TAG="devlead-run-job-test-$$"     # marks every process the stubs start
SCRIPTS="$SANDBOX/scripts"
CONF="$SANDBOX/runner.conf"
LEDGER="$SANDBOX/state/sessions.tsv"
TMPROOT="$SANDBOX/tmp"
PAUSE="$SANDBOX/PAUSE"
RUNJOB="$SANDBOX/run-job.sh"
export LEDGER TMPROOT
mkdir -p "$SCRIPTS" "$SANDBOX/state" "$TMPROOT" "$HOME/.devlead/run" "$CLAUDE_CONFIG_DIR/projects/-home-x"
printf '%s\n' "# DevLead session ledger (root writes this line at container start)" > "$LEDGER"
: > "$SANDBOX/state/job.lock"; : > "$SANDBOX/state/session.lock"
HEADER="# DevLead session ledger (root writes this line at container start)"
printf 'TZ=UTC\nMAX_SESSIONS_PER_DAY=8\nSESSION_TIMEOUT=60m\nSESSION_KILL_AFTER=30s\nAUDIT_RETENTION_DAYS=30\nJOB_TIMEOUT=60m\nJOB_KILL_AFTER=30s\nJOB_LOCK_WAIT=60m\n' > "$CONF"
# setconf <KEY> <value> — one limit of runner.conf, as root would render it.
setconf() { sed -i "s|^$1=.*|$1=$2|" "$CONF"; }
chmod 0644 "$CONF"

cp "$SRC" "$RUNJOB"
for kv in "RUNNER_CONF=$CONF" "LEDGER=$LEDGER" "JOB_LOCK=$SANDBOX/state/job.lock" "SESSION_LOCK=$SANDBOX/state/session.lock" "PAUSE_FILE=$PAUSE" \
          "SCRIPTS_DIR=$SCRIPTS" "SYNC_REPOS=$SANDBOX/sync-repos.sh" "TMP_ROOT=$TMPROOT" "ORPHAN_PARENT=-1" "CONF_OWNER_UID=$(id -u)"; do
  key="${kv%%=*}"
  check "run-job.sh has the fixed path $key" "$(grep -c "^$key=" "$RUNJOB")" "1"
  sed -i "s|^$key=.*|$kv|" "$RUNJOB"
done

# --- Stub jobs ------------------------------------------------------------------
# Every job script is the same stub: it logs what it was given, then runs the
# scenario in $SANDBOX/behaviour (if any) with the job's environment.
cat > "$SCRIPTS/stub-job.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\tARGS=%s\tCWD=%s\tTMPDIR=%s\tRUN=%s\tBIN=%s\tSTART=%s\n' "${0##*/}" "$*" "$PWD" "${TMPDIR:-}" \
  "${DEVLEAD_RUN_ID:-}" "${DEVLEAD_CLAUDE_BIN:-unset}" "$(date +%s.%N)" >> "$SANDBOX_LOG"
echo "stub ${0##*/} says hello"
rc=0
[[ -f "$SANDBOX_BEHAVIOUR" ]] && { source "$SANDBOX_BEHAVIOUR"; }
printf 'END=%s\n' "$(date +%s.%N)" >> "$SANDBOX_LOG"
exit "$rc"
EOF
for s in sweep.sh sweep-loop.sh discover-fleet.sh; do cp "$SCRIPTS/stub-job.sh" "$SCRIPTS/$s"; done
chmod +x "$SCRIPTS"/*.sh
cp "$REPO_ROOT/.devlead/scripts/notify.sh" "$SCRIPTS/notify.sh"
cat > "$SCRIPTS/doctor.sh" <<'EOF'
#!/usr/bin/env bash
echo "STATUS: ok"
[[ -f "$SANDBOX_WARN" ]] && cat "$SANDBOX_WARN"
exit 0
EOF
export SANDBOX_LOG="$SANDBOX/jobs.log" SANDBOX_BEHAVIOUR="$SANDBOX/behaviour" SANDBOX_WARN="$SANDBOX/warn"
# The repo sync (docker/sync-repos.sh, tested on its own in unit-sync-repos.sh):
# a stub that logs its call and reports every repo synced, or the failure
# written in $SANDBOX/sync-fail. --all stands for the two enrolled repos.
cat > "$SANDBOX/sync-repos.sh" <<'EOF'
#!/usr/bin/env bash
held=no; flock -n "$SESSION_LOCK" true 2>/dev/null || held=yes
printf 'SYNC\tARGS=%s\tSESSION_LOCK_HELD=%s\tSTART=%s\n' "$*" "$held" "$(date +%s.%N)" >> "$SANDBOX_LOG"
echo "stub sync says hello" >&2
repos=("$@"); [[ "${1:-}" == "--all" ]] && repos=(/work/repo-a /work/repo-b)
for r in "${repos[@]}"; do
  if [[ -f "$SANDBOX_SYNC_FAIL" ]]; then printf 'FAILED\t%s\t%s\n' "$r" "$(cat "$SANDBOX_SYNC_FAIL")"; exit 1; fi
  printf 'SYNCED\t%s\tmain\t%s\n' "$r" "0123456789abcdef0123456789abcdef01234567"
done
EOF
chmod +x "$SANDBOX/sync-repos.sh"
export SANDBOX_SYNC_FAIL="$SANDBOX/sync-fail" SESSION_LOCK="$SANDBOX/state/session.lock"

# session <sid> [end detail] [rc] — what the wrapper writes for one session of
# this run; used inside behaviours.
cat > "$SANDBOX/lib.sh" <<'EOF'
session() {
  local d; d="$(TZ=UTC date +%F)"
  printf '%s\t%s\tstart\t%s\t%s\t-\t-\n' "$d" "$(date -u +%FT%TZ)" "$1" "$DEVLEAD_RUN_ID" >> "$LEDGER"
  printf '%s\t%s\tend\t%s\t%s\t%s\t%s\n' "$d" "$(date -u +%FT%TZ)" "$1" "$DEVLEAD_RUN_ID" "${3:-0}" "${2:--}" >> "$LEDGER"
}
refused() { printf '%s\t%s\trefused\t-\t%s\t-\t%s\n' "$(TZ=UTC date +%F)" "$(date -u +%FT%TZ)" "$DEVLEAD_RUN_ID" "$1" >> "$LEDGER"; }
EOF
behaviour() { { echo "source '$SANDBOX/lib.sh'"; cat; } > "$SANDBOX/behaviour"; }

MONTH_FILE() { echo "$HOME/.devlead/audit/$(TZ=UTC date +%Y-%m).jsonl"; }
INBOX="$HOME/.devlead/inbox.tsv"
# run <job> [env...] — runs the copy; OUT and RC.
run() {
  local job="$1"; shift
  : > "$SANDBOX_LOG"
  OUT="$(env "$@" bash "$RUNJOB" "$job" 2>&1)"; RC=$?
  LAST="$(tail -n 1 "$(MONTH_FILE)" 2>/dev/null)"
}
field() { jq -c "$1" <<<"$LAST" 2>/dev/null; }
fresh() { rm -f "$SANDBOX/behaviour" "$SANDBOX/warn" "$SANDBOX_SYNC_FAIL" "$PAUSE" "$INBOX" "$(MONTH_FILE)" "$HOME/.devlead/run/token-warned"; printf '%s\n' "$HEADER" > "$LEDGER"; }
joblog() { grep -v '^SYNC' "$SANDBOX_LOG"; }
synclog() { grep '^SYNC' "$SANDBOX_LOG"; }
need_codes() { if [[ -f "$INBOX" ]]; then awk -F'\t' '$2 == "need" {print $3}' "$INBOX" | paste -sd, -; fi; }

printf '%s\n' "/work/repo-a" "# a comment" "" "/work/repo-b" > "$HOME/.devlead/autonomous-repos"

# ===========================================================================
# A normal run: sessions, transcripts, audit line
# ===========================================================================
fresh
SID=11111111-2222-4333-8444-555555555555
cat > "$CLAUDE_CONFIG_DIR/projects/-home-x/$SID.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"/sweep-execute --fleet"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash ~/.devlead/scripts/open-pr.sh --base dev --title x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"https://github.com/acme/widgets/pull/42\n"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/work/repo-a/a.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Write","input":{"file_path":"/work/repo-a/b.md"}},{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"echo https://github.com/acme/widgets/pull/99"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":[{"type":"text","text":"https://github.com/acme/widgets/pull/99"}]}]}}
not a json line
EOF
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-x/$SID/subagents"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"Read","input":{"file_path":"/work/repo-a/c"}}]}}' \
  > "$CLAUDE_CONFIG_DIR/projects/-home-x/$SID/subagents/agent-1.jsonl"
behaviour <<EOF
session $SID
echo "scratch" > "\$TMPDIR/scratch"
EOF
run fleet GH_TOKEN=ghp_PROBEVALUE123 SECRET_PROBE=probe-secret-xyz
check "ok run: exit 0" "$RC" "0"
check "ok run: one audit line" "$(wc -l < "$(MONTH_FILE)" | tr -d ' ')" "1"
RUN_ID="$(jq -r .run_id <<<"$LAST")"
check "run id: UTC time, job, random suffix" "$([[ "$RUN_ID" =~ ^[0-9]{8}T[0-9]{6}Z-fleet-[0-9a-f]{6}$ ]] && echo ok || echo "[$RUN_ID]")" "ok"
check "trigger is the job name" "$(field .trigger)" '"fleet"'
check "repos: the enrolled list" "$(field .repos)" '["/work/repo-a","/work/repo-b"]'
check "start and end are ISO 8601 with offset" \
  "$(field '[.started_at, .ended_at] | map(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$")) | all')" "true"
check "exit code" "$(field .exit_code)" "0"
check "flags: no timeout, no cap refusal, not paused, not skipped" "$(field '[.timed_out, .cap_refused, .paused, .skipped]')" '[false,false,false,null]'
check "no session was refused" "$(field .refusals)" "[]"
check "the session id" "$(field .session_ids)" "[\"$SID\"]"
check "sessions with their exit codes" "$(field .sessions)" "[{\"id\":\"$SID\",\"exit_code\":0,\"timed_out\":false}]"
check "tool uses, subagents included" "$(field '.tool_uses')" '{"Bash":2,"Edit":1,"Read":1,"Write":1}'
check "files changed through file tools" "$(field .files_changed)" '["/work/repo-a/a.sh","/work/repo-a/b.md"]'
check "PRs opened by open-pr.sh or gh pr create only" "$(field .prs_opened)" '["https://github.com/acme/widgets/pull/42"]'
check "outcome ok, nothing notified" "$(field '[.outcome, .notified, .notify_codes]')" '["ok",false,[]]'
check "the audit and the ledger were not touched" "$(field .audit_intact)" "true"
check "the transcript is kept" "$(cmp -s "$CLAUDE_CONFIG_DIR/projects/-home-x/$SID.jsonl" "$HOME/.devlead/audit/runs/$RUN_ID/$SID.jsonl" && echo same || echo missing)" "same"
check "subagent transcripts are kept" "$([[ -f "$HOME/.devlead/audit/runs/$RUN_ID/$SID/subagents/agent-1.jsonl" ]] && echo yes || echo no)" "yes"
check "the transcript count" "$(field .transcripts_kept)" "1"
contains "the job's output is kept" "$(cat "$HOME/.devlead/audit/runs/$RUN_ID/output.log" 2>/dev/null)" "stub sweep-loop.sh says hello"
contains "the job's output reaches the container log" "$OUT" "stub sweep-loop.sh says hello"
contains "the audit line reaches the container log" "$OUT" "devlead-audit {\"run_id\":\"$RUN_ID\""
log="$(joblog | head -n 1)"
contains "the job runs the table's command" "$log" $'sweep-loop.sh\tARGS=--max-iterations 1 -- --fleet'
contains "from ~/.devlead" "$log" "CWD=$HOME/.devlead"
contains "tagged with the run id" "$log" "RUN=$RUN_ID"
contains "with DEVLEAD_CLAUDE_BIN unset: claude on PATH is the wrapper" "$log" "BIN=unset"
jobtmp="$(sed -n 's/.*TMPDIR=\([^\t]*\).*/\1/p' <<<"$log")"
check "a private TMPDIR under the tmp root" "$([[ "$jobtmp" == "$TMPROOT"/devlead-job.* ]] && echo private || echo "[$jobtmp]")" "private"
check "the TMPDIR is removed afterwards" "$([[ -e "$jobtmp" ]] && echo left || echo removed)" "removed"
audit_all="$(cat "$(MONTH_FILE)" "$HOME/.devlead/audit/runs/$RUN_ID/output.log")"
lacks "no environment value in the audit (GH_TOKEN)" "$audit_all" "ghp_PROBEVALUE123"
lacks "no environment value in the audit (other)" "$audit_all" "probe-secret-xyz"
check "nothing in the inbox" "$(need_codes)" ""

# ===========================================================================
# Table: commands, conditions, repos
# ===========================================================================
fresh
run morning
check "morning: runs sweep.sh with no arguments" "$(joblog | cut -f1,2 | head -n 1)" $'sweep.sh\tARGS='
fresh
run loop
check "loop without ~/.devlead/plan.local.yml: exit 0" "$RC" "0"
check "loop without its plan: nothing ran" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "loop without its plan: audited as skipped" "$(field '[.outcome, .skipped, .session_ids]')" '["skipped","plan.local.yml is missing",[]]'
touch "$HOME/.devlead/plan.local.yml"
fresh
run loop DEVLEAD_LOOP_REPO=/work/repo-a
contains "loop with its plan: sweep-loop.sh --plan ~/.devlead/plan.local.yml" "$(joblog | head -n 1)" "ARGS=--plan $HOME/.devlead/plan.local.yml"
check "loop: repos is DEVLEAD_LOOP_REPO" "$(field .repos)" '["/work/repo-a"]'
rm -f "$HOME/.devlead/plan.local.yml"
fresh
run discover
contains "discover: discover-fleet.sh" "$(joblog | head -n 1)" $'discover-fleet.sh\tARGS='
fresh
run nosuchjob
check "an unknown job: exit 2" "$RC" "2"
contains "an unknown job: usage" "$OUT" "usage: run-job.sh"
check "an unknown job: no audit line" "$([[ -s "$(MONTH_FILE)" ]] && echo written || echo none)" "none"

# ===========================================================================
# The clones are synced from origin before the job, never during a session
# (S13)
# ===========================================================================
fresh
run fleet
check "fleet: every enrolled repo is synced (--all)" "$(synclog | cut -f2)" "ARGS=--all"
check "fleet: the sync holds the session lock" "$(synclog | cut -f3)" "SESSION_LOCK_HELD=yes"
check "fleet: the sync runs before the job" "$(head -n 1 "$SANDBOX_LOG" | cut -f1)" "SYNC"
check "fleet: the synced clones are audited" "$(field '[.synced[] | [.repo, .branch]]')" '[["/work/repo-a","main"],["/work/repo-b","main"]]'
check "fleet: no sync error" "$(field .sync_error)" "null"
contains "the sync's messages reach the run's log" "$(cat "$HOME/.devlead/audit/runs/$(jq -r .run_id <<<"$LAST")/output.log")" "stub sync says hello"
lacks "the sync's report lines stay out of the log" "$OUT" $'SYNCED\t'
for j in morning discover; do
  fresh; run "$j"
  check "$j: every enrolled repo is synced" "$(synclog | cut -f2)" "ARGS=--all"
done
touch "$HOME/.devlead/plan.local.yml"
fresh; run loop DEVLEAD_LOOP_REPO=/work/repo-a
check "loop: only DEVLEAD_LOOP_REPO is synced" "$(synclog | cut -f2)" "ARGS=/work/repo-a"
fresh; run loop
check "loop without DEVLEAD_LOOP_REPO: nothing to sync" "$(synclog | wc -l | tr -d ' ')" "0"
contains "loop without DEVLEAD_LOOP_REPO: the job still runs (as in F2)" "$(joblog | head -n 1)" "sweep-loop.sh"
rm -f "$HOME/.devlead/plan.local.yml"

fresh
echo "fetch failed" > "$SANDBOX_SYNC_FAIL"
run fleet
check "sync failed: run-job exits 1" "$RC" "1"
check "sync failed: the job does not run" "$(joblog | wc -l | tr -d ' ')" "0"
check "sync failed: audited" "$(field '[.outcome, .exit_code, .sync_error, .notify_codes]')" '["failed",1,"/work/repo-a: fetch failed",["job-failed"]]'
check "sync failed: need job-failed, with the reason and no path" "$(cut -f6 "$INBOX")" \
  "fleet: not run — its repos could not be synced from origin: fetch failed (run $(jq -r .run_id <<<"$LAST"))"

fresh
flock -o "$SANDBOX/state/session.lock" sleep 5 & holder=$!
sleep 0.3
run fleet
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "a session running by hand: no sync" "$(synclog | wc -l | tr -d ' ')" "0"
check "a session running by hand: the job does not run" "$(joblog | wc -l | tr -d ' ')" "0"
check "a session running by hand: audited, job-failed" "$(field '[.outcome, .sync_error, .notify_codes]')" \
  '["failed","a claude session is running in the container",["job-failed"]]'

# ===========================================================================
# Failures send one `need` each (S19)
# ===========================================================================
fresh
behaviour <<<'rc=3'
run fleet
check "failed job: run-job exits with its code" "$RC" "3"
check "failed job: outcome failed, notified" "$(field '[.outcome, .exit_code, .notified, .notify_codes]')" '["failed",3,true,["job-failed"]]'
check "failed job: need job-failed" "$(need_codes)" "job-failed"
contains "failed job: the message names the job, the code and the run" "$(cut -f6 "$INBOX")" "fleet: exited 3 (run $(jq -r .run_id <<<"$LAST"))"

fresh
behaviour <<<'session 22222222-2222-4222-8222-222222222222 timeout 124'
run fleet
check "timeout: outcome timeout, flagged, notified" "$(field '[.outcome, .timed_out, .notify_codes]')" '["timeout",true,["job-timeout"]]'
check "timeout: run-job exits 1 even though the job exited 0" "$RC" "1"
check "timeout: the session is marked" "$(field '.sessions[0].timed_out')" "true"
check "timeout: a session's limit, not the job's (as in F2)" "$(field '[.job_timed_out, .lock_timed_out]')" "[false,false]"
contains "timeout: the message names the limit" "$(cut -f6 "$INBOX")" "fleet: a claude session ran past the 60m limit and was stopped"

fresh
behaviour <<<'refused cap'
run fleet
check "cap refusal: outcome refused, flagged, notified" "$(field '[.outcome, .cap_refused, .notify_codes]')" '["refused",true,["job-refused"]]'
check "cap refusal: the reason is recorded" "$(field .refusals)" '["cap"]'
contains "cap refusal: the message names the cap" "$(cut -f6 "$INBOX")" "the daily limit of 8 claude sessions is reached"
fresh
behaviour <<<'refused busy'
run fleet
contains "busy refusal: the message says another session ran" "$(cut -f6 "$INBOX")" "another claude session was running"
check "busy refusal: job-refused" "$(need_codes)" "job-refused"
check "busy refusal: not a cap refusal; the reason is recorded" "$(field '[.cap_refused, .refusals]')" '[false,["busy"]]'

fresh
behaviour <<<'refused paused'
run fleet
check "a session refused by the pause: outcome paused, no need" "$(field '[.outcome, .paused, .notified]')" '["paused",true,false]'
check "a session refused by the pause: not a cap refusal; the reason is recorded" "$(field '[.cap_refused, .refusals]')" '[false,["paused"]]'

fresh
behaviour <<<'kill -9 $$'
run fleet
check "a crash (killed by a signal) is a failure" "$(field '[.outcome, .exit_code]')" '["failed",137]'
check "a crash sends job-failed" "$(need_codes)" "job-failed"

fresh
behaviour <<<'refused nolock'
run fleet
contains "nolock refusal: the message says the lock could not be opened" "$(cut -f6 "$INBOX")" "the session lock could not be opened"
check "nolock refusal: recorded as such, job-refused" "$(field '[.refusals, .notify_codes]')" '[["nolock"],["job-refused"]]'

# ===========================================================================
# A job holds the job lock for JOB_TIMEOUT at most; a job waits for the lock
# for JOB_LOCK_WAIT at most (L18)
# ===========================================================================
fresh
setconf JOB_TIMEOUT 2s; setconf JOB_KILL_AFTER 1s
behaviour <<<'( exec -a "sleep-$TAG-hung" sleep 30 ) & wait'
t0="$(date +%s)"
run fleet
elapsed=$(( $(date +%s) - t0 ))
check "a hung job is stopped at the job limit" "$([[ $elapsed -lt 10 ]] && echo stopped || echo "ran ${elapsed}s")" "stopped"
check "a hung job: run-job exits with timeout's 124" "$RC" "124"
check "a hung job: audited as a job timeout" "$(field '[.outcome, .job_timed_out, .timed_out, .notify_codes]')" '["timeout",true,false,["job-timeout"]]'
check "a hung job: need job-timeout names the limit" "$(cut -f6 "$INBOX")" "fleet: ran past the 2s job limit and was stopped (run $(jq -r .run_id <<<"$LAST"))"
check "a hung job: nothing of it survives" "$(pgrep -fc "sleep-$TAG-hung" || true)" "0"
fresh
behaviour <<<'trap "" TERM; ( exec -a "sleep-$TAG-stubborn" sleep 30 ) & while :; do sleep 0.2; done'
t0="$(date +%s)"
run fleet
elapsed=$(( $(date +%s) - t0 ))
check "a job that ignores TERM is killed after JOB_KILL_AFTER" "$([[ $elapsed -lt 10 ]] && echo killed || echo "ran ${elapsed}s")" "killed"
check "a job that ignores TERM: a job timeout" "$(field '[.outcome, .job_timed_out]')" '["timeout",true]'
fresh
printf '#!/bin/sh\nexec sleep 30\n' > "$SANDBOX/sync-hang.sh"; chmod +x "$SANDBOX/sync-hang.sh"
cp "$SANDBOX/sync-repos.sh" "$SANDBOX/sync-repos.keep"; cp "$SANDBOX/sync-hang.sh" "$SANDBOX/sync-repos.sh"
t0="$(date +%s)"
run fleet
elapsed=$(( $(date +%s) - t0 ))
cp "$SANDBOX/sync-repos.keep" "$SANDBOX/sync-repos.sh"
check "a hung sync is stopped at the job limit" "$([[ $elapsed -lt 10 ]] && echo stopped || echo "ran ${elapsed}s")" "stopped"
check "a hung sync: the job does not run" "$(joblog | wc -l | tr -d ' ')" "0"
check "a hung sync: a job timeout, with the reason" "$(field '[.outcome, .job_timed_out, .sync_error, .notify_codes]')" \
  '["timeout",true,"the sync ran past the job'"'"'s time limit",["job-timeout"]]'
setconf JOB_TIMEOUT 60m; setconf JOB_KILL_AFTER 30s

fresh
setconf JOB_LOCK_WAIT 1s
flock -o "$SANDBOX/state/job.lock" sleep 5 & holder=$!
sleep 0.3
t0="$(date +%s)"
run fleet
elapsed=$(( $(date +%s) - t0 ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "a job lock held past JOB_LOCK_WAIT: run-job gives up" "$([[ $elapsed -lt 4 ]] && echo "gave up" || echo "waited ${elapsed}s")" "gave up"
check "a job lock held past JOB_LOCK_WAIT: exit 1" "$RC" "1"
check "a job lock held past JOB_LOCK_WAIT: nothing ran, nothing synced" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "a job lock held past JOB_LOCK_WAIT: audited" "$(field '[.outcome, .lock_timed_out, .job_timed_out, .notify_codes]')" '["timeout",true,false,["job-timeout"]]'
check "a job lock held past JOB_LOCK_WAIT: need job-timeout says why" "$(cut -f6 "$INBOX")" \
  "fleet: not run — another job held the job lock for more than 1s (run $(jq -r .run_id <<<"$LAST"))"
setconf JOB_LOCK_WAIT 60m

# ===========================================================================
# A ledger emptied before the run: today's count is unknown, nothing runs
# (R3-empty-ledger-tamper)
# ===========================================================================
fresh
: > "$LEDGER"
run fleet
check "an emptied ledger: run-job exits 1" "$RC" "1"
check "an emptied ledger: nothing ran, nothing synced" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "an emptied ledger: audited as tampered" "$(field '[.outcome, .audit_intact, .notify_codes]')" '["failed",false,["audit-tampered"]]'
contains "an emptied ledger: need audit-tampered says why" "$(cut -f6 "$INBOX")" "the session ledger was emptied since the container started"
fresh
printf '%s\t2026-01-01T00:00:00Z\tstart\tx\t-\t-\t-\n' "$(date +%F)" > "$LEDGER"
run fleet
check "a ledger without root's header: refused the same way" "$(field '[.outcome, .audit_intact]')" '["failed",false]'
fresh
run fleet
check "a ledger with its header: runs as before" "$(field '[.outcome, .audit_intact]')" '["ok",true]'

# ===========================================================================
# Never as root: `unshare -r` makes the caller UID 0 in a user namespace.
# runner-config.sh reads the job table as root, so --list still works.
# ===========================================================================
fresh
: > "$SANDBOX_LOG"
OUT="$(unshare -r bash "$RUNJOB" fleet 2>&1)"; RC=$?
check "as root: a job is refused (exit 1)" "$RC" "1"
contains "as root: says why" "$OUT" "never runs a job as root"
check "as root: nothing ran" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "as root: no audit line, no file written" "$([[ -e "$(MONTH_FILE)" ]] && echo written || echo none)" "none"
check "as root: no notice" "$(need_codes)" ""
check "as root: --list still prints the table" "$(unshare -r bash "$RUNJOB" --list 2>/dev/null | wc -l | tr -d ' ')" "4"

# ===========================================================================
# The pause file and DEVLEAD_CLAUDE_BIN stop the job before it starts
# ===========================================================================
fresh
touch "$PAUSE"
run fleet
check "paused: exit 0" "$RC" "0"
check "paused: nothing ran" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "paused: audited, not notified" "$(field '[.outcome, .paused, .notified]')" '["paused",true,false]'
contains "paused: says so" "$OUT" "paused"
rm -f "$PAUSE"

fresh
run fleet DEVLEAD_CLAUDE_BIN=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
check "DEVLEAD_CLAUDE_BIN not the wrapper: refused, exit 1" "$RC" "1"
check "DEVLEAD_CLAUDE_BIN not the wrapper: nothing ran" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "DEVLEAD_CLAUDE_BIN not the wrapper: job-failed" "$(field '[.outcome, .notify_codes]')" '["failed",["job-failed"]]'
contains "DEVLEAD_CLAUDE_BIN not the wrapper: says why" "$OUT" "DEVLEAD_CLAUDE_BIN"
fresh
run fleet DEVLEAD_CLAUDE_BIN=claude
check "DEVLEAD_CLAUDE_BIN=claude is the wrapper on PATH: runs" "$(field .outcome)" '"ok"'

fresh
mv "$CONF" "$CONF.away"
run fleet
check "no runner configuration: exit 1" "$RC" "1"
check "no runner configuration: nothing ran" "$(wc -l < "$SANDBOX_LOG" | tr -d ' ')" "0"
check "no runner configuration: job-failed" "$(need_codes)" "job-failed"
mv "$CONF.away" "$CONF"

# ===========================================================================
# Nothing a job leaves behind survives it (F1 follow-up d)
# ===========================================================================
fresh
bash -c "exec -a before-$TAG sleep 300" >/dev/null 2>&1 &   # not the job's: must survive
before_pid=$!
behaviour <<'EOF'
( exec -a "sleep-$TAG-child" sleep 300 ) >/dev/null 2>&1 &
setsid bash -c "exec -a sleep-$TAG-setsid sleep 300" >/dev/null 2>&1 &
nohup bash -c "trap '' TERM; exec -a sleep-$TAG-stubborn sleep 300" >/dev/null 2>&1 &
mkdir -p "$TMPROOT/made-by-the-job" && touch "$TMPROOT/made-by-the-job/x" "$TMPROOT/.hidden-by-the-job"
sleep 0.3
EOF
mkdir -p "$TMPROOT/there-before"
run fleet
sleep 0.5
check "the job's background processes are gone" "$(pgrep -fc "sleep-$TAG-" || true)" "0"
check "the count is recorded" "$(field '.leftovers_killed >= 3')" "true"
check "a process that was there before the job survives" "$(kill -0 "$before_pid" 2>/dev/null && echo alive || echo killed)" "alive"
kill "$before_pid" 2>/dev/null
check "what the job created at the top of the tmp root is removed" \
  "$(find "$TMPROOT" -mindepth 1 -maxdepth 1 -name '*by-the-job*' | wc -l | tr -d ' ')" "0"
check "what was there before stays" "$([[ -d "$TMPROOT/there-before" ]] && echo kept || echo removed)" "kept"
check "a run with leftovers still ends ok" "$(field .outcome)" '"ok"'

# A claude session someone else is running (the operator, by hand) keeps its
# /tmp files: while the session lock is held, only the job's own TMPDIR goes.
fresh
behaviour <<<'mkdir -p "$TMPROOT/made-during-a-session"'
flock -o "$SANDBOX/state/session.lock" sleep 6 &   # -o: killing flock frees the lock
holder=$!
sleep 0.3
touch "$HOME/.devlead/plan.local.yml"
run loop
rm -f "$HOME/.devlead/plan.local.yml"
check "a session running elsewhere: what appeared in the tmp root stays" \
  "$([[ -d "$TMPROOT/made-during-a-session" ]] && echo kept || echo removed)" "kept"
check "a session running elsewhere: the job's TMPDIR still goes" \
  "$(find "$TMPROOT" -maxdepth 1 -name 'devlead-job.*' | wc -l | tr -d ' ')" "0"
contains "a session running elsewhere: says why the tmp root was left" "$OUT" "a claude session is running"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -rf "$TMPROOT/made-during-a-session"

# ===========================================================================
# One job at a time: the second waits for the first (S17, After=)
# ===========================================================================
fresh
behaviour <<<'[[ "${0##*/}" == sweep-loop.sh ]] && sleep 2'
: > "$SANDBOX_LOG"
( env bash "$RUNJOB" fleet >/dev/null 2>&1 ) &
first=$!
for _ in $(seq 1 50); do [[ -s "$SANDBOX_LOG" ]] && break; sleep 0.1; done
bash "$RUNJOB" discover >/dev/null 2>&1
wait "$first"
first_end="$(sed -n 's/^END=//p' "$SANDBOX_LOG" | head -n 1)"
second_start="$(awk -F'\t' '$1 == "discover-fleet.sh" {sub("START=", "", $7); print $7}' "$SANDBOX_LOG")"
check "the second job started after the first ended" \
  "$(awk -v a="$first_end" -v b="$second_start" 'BEGIN { print (b >= a) ? "after" : "overlapped" }')" "after"
check "the wait is recorded" "$(tail -n 1 "$(MONTH_FILE)" | jq '.lock_wait_seconds >= 1')" "true"
check "both runs are audited" "$(jq -r .trigger "$(MONTH_FILE)" | sort | paste -sd, -)" "discover,fleet"

# ===========================================================================
# Claude token warning: one `need` a day (S19)
# ===========================================================================
fresh
echo "WARN:   the Claude token (DEVLEAD_CLAUDE_TOKEN_ISSUED=2025-12-01) is 11 months old and expires one year after it was issued" > "$SANDBOX_WARN"
run morning
check "token warning: need token-expiring" "$(need_codes)" "token-expiring"
msg="$(cut -f6 "$INBOX")"
contains "token warning: says the token is 11 or more months old" "$msg" "the Claude token was issued 11 or more months ago"
contains "token warning: says how to renew it" "$msg" "claude setup-token"
lacks "token warning: the issue date (an environment value) is not in the notice" "$msg" "2025-12-01"
lacks "token warning: no environment assignment in the notice" "$msg" "DEVLEAD_CLAUDE_TOKEN_ISSUED="
check "token warning: recorded on the run" "$(field .notify_codes)" '["token-expiring"]'
run morning
check "token warning: not again the same day" "$(need_codes)" "token-expiring"
echo "2000-01-01" > "$HOME/.devlead/run/token-warned"
run morning
check "token warning: again on another day" "$(need_codes)" "token-expiring,token-expiring"
fresh
echo "WARN:   DEVLEAD_CLAUDE_TOKEN_ISSUED is not a valid issue date (YYYY-MM-DD, not in the future), so the Claude token's age cannot be checked" > "$SANDBOX_WARN"
run morning
msg="$(cut -f6 "$INBOX")"
check "unreadable issue date: need token-expiring" "$(need_codes)" "token-expiring"
contains "unreadable issue date: says the age cannot be checked" "$msg" "is not a valid date, so the Claude token's age cannot be checked"
contains "unreadable issue date: says how to fix it" "$msg" "claude setup-token"
rm -f "$SANDBOX_WARN"

# ===========================================================================
# A run that rewrites the audit or the ledger is reported (S18)
# ===========================================================================
fresh
behaviour <<<'session 33333333-3333-4333-8333-333333333333'
run fleet
behaviour <<<': > "$LEDGER"'
run fleet
check "truncated ledger: audit_intact false" "$(field .audit_intact)" "false"
check "truncated ledger: need audit-tampered" "$(need_codes)" "audit-tampered"
fresh
run fleet
behaviour <<'EOF'
f="$HOME/.devlead/audit/$(TZ=UTC date +%Y-%m).jsonl"
sed -i 's/"outcome":"ok"/"outcome":"fine"/' "$f"
EOF
run fleet
check "rewritten audit line: need audit-tampered" "$(need_codes)" "audit-tampered"

# ===========================================================================
# Transcript retention (S18)
# ===========================================================================
fresh
RUNS="$HOME/.devlead/audit/runs"
old="$(date -u -d '-31 days' +%Y%m%dT%H%M%SZ)-fleet-aaaaaa"
recent="$(date -u -d '-29 days' +%Y%m%dT%H%M%SZ)-fleet-bbbbbb"
mkdir -p "$RUNS/$old" "$RUNS/$recent" "$RUNS/not-a-run" "$SANDBOX/outside"
touch "$RUNS/$old/x.jsonl" "$SANDBOX/outside/keep"
ln -s "$SANDBOX/outside" "$RUNS/$(date -u -d '-40 days' +%Y%m%dT%H%M%SZ)-fleet-cccccc"
OUT="$(bash "$RUNJOB" --prune 2>&1)"; RC=$?
check "prune: exit 0" "$RC" "0"
check "prune: a run older than 30 days is removed" "$([[ -e "$RUNS/$old" ]] && echo kept || echo removed)" "removed"
check "prune: a 29-day-old run stays" "$([[ -d "$RUNS/$recent" ]] && echo kept || echo removed)" "kept"
check "prune: a name that is not a run id stays" "$([[ -d "$RUNS/not-a-run" ]] && echo kept || echo removed)" "kept"
check "prune: a link is never followed" "$([[ -f "$SANDBOX/outside/keep" ]] && echo intact || echo deleted)" "intact"
contains "prune: says what it did" "$OUT" "pruned 1 run(s) older than 30 days"
mv "$CONF" "$CONF.away"
mkdir -p "$RUNS/$old"
OUT="$(bash "$RUNJOB" --prune 2>&1)"; RC=$?
check "prune without a configuration: refused" "$RC" "1"
check "prune without a configuration: deletes nothing" "$([[ -d "$RUNS/$old" ]] && echo kept || echo removed)" "kept"
mv "$CONF.away" "$CONF"

# ===========================================================================
# Every `need` code run-job.sh sends is in GOVERNANCE.md's closed list
# ===========================================================================
gov="$(sed -n '/^## §escalation-channel/,/^## §learned-preferences/p' "$REPO_ROOT/.claude/GOVERNANCE.md")"
codes="$(grep -oE '_need [a-z-]+' "$SRC" | awk '{print $2}' | sort -u)"
check "run-job.sh sends the five server codes" "$(paste -sd, - <<<"$codes")" "audit-tampered,job-failed,job-refused,job-timeout,token-expiring"
while IFS= read -r c; do
  contains "GOVERNANCE §escalation-channel lists need code $c" "$gov" "(\`$c\`)"
done <<<"$codes"
contains "GOVERNANCE keeps: a parked issue is not a trigger" "$gov" "Una issue aparcada por un gate rojo NO es un disparador"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
