#!/usr/bin/env bash
# run-job.sh — runs the scheduled jobs of the DevLead server image (S11,
# S17-S19).
#
#   run-job.sh <job>     run one job of the table below. supercronic calls it at
#                        the times of /etc/devlead/crontab; the operator can too:
#                        docker compose exec -u devlead devlead /opt/devlead/docker/run-job.sh fleet
#                        A job never runs as root (--list does: runner-config.sh
#                        reads the table at container start).
#   run-job.sh --list    print the job table: name|schedule variable|default
#                        schedule (runner-config.sh builds the crontab from it)
#   run-job.sh --prune   delete the kept transcripts of runs older than
#                        AUDIT_RETENTION_DAYS (at container start, and daily)
#
# Each job mirrors one of the systemd units in .devlead/systemd/, which keep
# working for anyone not using Docker. A run, in order:
#
#   1. DEVLEAD_CLAUDE_BIN, if set, must name the claude wrapper; the job is
#      refused otherwise. The job itself runs without it, so the launchers use
#      the `claude` on PATH: the wrapper.
#   2. Nothing starts while the pause file exists (see claude-wrapper.sh).
#   3. A job whose condition file is missing is skipped, like systemd's
#      ConditionPathExists=.
#   4. One job at a time: a job that finds another one running waits for it,
#      as devlead-fleet.service waits for devlead-loop.service (After=), but
#      for JOB_LOCK_WAIT at most (DEVLEAD_JOB_LOCK_WAIT, default 4h); past it
#      the job does not run. A ledger that is empty, or lost the header root
#      writes at container start, was emptied by someone: today's session
#      count is unknown, so the job does not run either (audit-tampered).
#   5. The clones the job works on are brought to origin's default branch
#      (S13, docker/sync-repos.sh): every enrolled repo for morning, fleet,
#      discover and poll, DEVLEAD_LOOP_REPO for loop. It holds the session lock — no
#      claude session may be working in a clone it resets — and a job whose
#      repos cannot all be synced does not run.
#      From here the job holds the job lock for JOB_TIMEOUT at most
#      (DEVLEAD_JOB_TIMEOUT, default 4h): the sync and the job's command run
#      under that limit, then TERM, and KILL JOB_KILL_AFTER later. A step that
#      hangs — a gh call, a fetch — never keeps the next job waiting for good.
#   6. The job runs from ~/.devlead with a private TMPDIR, in a session of its
#      own, every process of it tagged DEVLEAD_RUN_ID=<run id>. Its output goes
#      to the container log and to the run's output.log.
#   7. Afterwards every process it left behind is stopped (TERM, then KILL):
#      its descendants, any process carrying its run id, and any orphan that
#      appeared during the run (one the container's init adopted). Its TMPDIR
#      and whatever it created at the top of /tmp are removed. Nothing a job
#      starts or writes there carries over to the next one. The /tmp sweep is
#      done holding the session lock, and skipped while a claude session runs
#      (one the operator started by hand): its files there are its own.
#   8. The claude sessions it started are read from the wrapper's ledger. Their
#      transcripts — Claude Code's own, found by session id; the launchers'
#      output format is left alone — are copied to
#      ~/.devlead/audit/runs/<run id>/, and one JSON line is appended to
#      ~/.devlead/audit/YYYY-MM.jsonl and printed to the container log.
#   9. A run that opened PRs sends one `need` pr-opened, its message the PR
#      links; one whose report parked work units sends one `need` park, its
#      message the issue numbers (S19). The push carries the message — so
#      the links — only with DEVLEAD_NOTIFY_DETAIL=1 (notify.sh).
#      A failed run sends one `need` (GOVERNANCE.md §escalation-channel):
#      job-failed (non-zero exit, a crash, a refused start, repos that could
#      not be synced), job-timeout (a session or the whole job stopped at its
#      time limit, or a job that waited past JOB_LOCK_WAIT), job-refused (a
#      session refused by the daily cap, because another was running, or
#      because its lock could not be opened). doctor.sh's Claude token
#      warning becomes a `need` token-expiring, once a day; like every notice it
#      carries no environment value (not even the token's issue date).
#
# The audit line: run_id, trigger, repos, started_at, ended_at, exit_code,
# timed_out, cap_refused (a session refused by the daily cap), refusals (the
# reason of every refused session: cap, busy, nolock, paused, noconf, noledger,
# root),
# paused, skipped (the reason, or null), synced [{repo, branch, commit}] (the
# clones as the job found them), sync_error (the repo and the reason, or
# null), sessions
# [{id, exit_code, timed_out}], session_ids, tool_uses {tool: count},
# files_changed, prs_opened, parked {count, issues}, transcripts_kept,
# outcome (ok, failed, timeout,
# refused, paused, skipped), notified, notify_codes, leftovers_killed,
# lock_wait_seconds, lock_timed_out (gave up waiting for the job lock),
# job_timed_out (stopped at JOB_TIMEOUT), audit_intact. Files changed are those the sessions'
# Write, Edit, MultiEdit and NotebookEdit calls name — a file a shell command
# changes is not seen. PRs opened are the pull request URLs printed by an
# open-pr.sh or gh pr create call. Parked work units are the rows the run's
# own report (the Write of ~/.devlead/reports/<date>-execute.md) gives a
# parked-* or escalated-* result; only their issue numbers are kept, never the
# reason or a title. No environment variable is ever recorded,
# and the env file never enters the container.
#
# What the user — and so a session — can still do. Everything here runs as the
# devlead user, like the sessions; no root process stays behind to keep
# records out of their reach:
#   - ~/.devlead/audit is the user's, so a session could rewrite earlier lines
#     or transcripts. A change to the bytes the month's audit file or the
#     ledger held when the run started is caught when it ends (audit_intact
#     false, `need` audit-tampered). Every audit line is also in the container
#     log, which Docker keeps outside the container, out of any session's
#     reach.
#   - The ledger (/var/lib/devlead/sessions.tsv, a volume: it outlives the
#     container) cannot be removed or replaced — root owns the directory — but
#     it can be truncated, which would reset the day's count. Truncated during
#     a run, the same check reports it; emptied before one, the run refuses
#     to start (above). A session could also run
#     the real Claude Code binary directly, outside the wrapper. So the caps
#     bound what the scheduler and the launchers start; containing a hostile
#     session is the job of guard.sh, the firewall and the narrow tokens.
set -uo pipefail

# --- Fixed paths (test/unit-run-job.sh rewrites these in a copy) ---------------
RUNNER_CONF=/etc/devlead/runner.conf
LEDGER=/var/lib/devlead/sessions.tsv
LEDGER_HEADER="# DevLead session ledger"
JOB_LOCK=/var/lib/devlead/job.lock
SESSION_LOCK=/var/lib/devlead/session.lock
PAUSE_FILE=/home/devlead/.devlead/PAUSE
SCRIPTS_DIR=/opt/devlead/scripts
SYNC_REPOS=/opt/devlead/docker/sync-repos.sh
WRAPPER=/usr/local/bin/claude
TMP_ROOT=/tmp
ORPHAN_PARENT=1
CONF_OWNER_UID=0
# --------------------------------------------------------------------------------

STATE_DIR="$HOME/.devlead"
AUDIT_DIR="$STATE_DIR/audit"
CLAUDE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
TOKEN_STAMP="$STATE_DIR/run/token-warned"

# --- The jobs ------------------------------------------------------------------
# One line per job. Adding a job is adding a line here: runner-config.sh gives
# it a crontab line scheduled by its variable (document the variable in
# docker/devlead.env.example).
#   name | schedule variable | default schedule
#   | condition: a file under ~/.devlead that must exist, or -
#   | repos for the audit: enrolled (~/.devlead/autonomous-repos),
#     loop (DEVLEAD_LOOP_REPO) or -
#   | command: a script of /opt/devlead/scripts and its arguments, split on
#     spaces (a leading ~/ is the home directory)
JOBS=(
  "morning|DEVLEAD_CRON_MORNING|30 6 * * 1-5|-|enrolled|sweep.sh"
  "loop|DEVLEAD_CRON_LOOP|0 22 * * *|plan.local.yml|loop|sweep-loop.sh --plan ~/.devlead/plan.local.yml"
  "fleet|DEVLEAD_CRON_FLEET|30 22 * * *|autonomous-repos|enrolled|sweep-loop.sh --max-iterations 1 -- --fleet"
  "discover|DEVLEAD_CRON_DISCOVER|0 5 * * 1|autonomous-repos|enrolled|discover-fleet.sh"
  "poll|DEVLEAD_CRON_POLL|*/30 7-19 * * *|autonomous-repos|enrolled|poll-issues.sh"
  "endofday|DEVLEAD_CRON_ENDOFDAY|30 18 * * 1-5|-|-|day-summary.sh"
)

_usage() { echo "usage: run-job.sh <job> | --list | --prune" >&2; }

_list() {
  local entry name var default
  for entry in "${JOBS[@]}"; do
    IFS='|' read -r name var default _ <<<"$entry"
    printf '%s|%s|%s\n' "$name" "$var" "$default"
  done
}

# --- Configuration (root's, written at container start) -----------------------
_conf_get() { sed -n "s/^$1=//p" "$RUNNER_CONF" 2>/dev/null | tail -n 1; }

_load_conf() {
  local mode
  [[ -f "$RUNNER_CONF" && ! -L "$RUNNER_CONF" ]] || return 1
  [[ "$(stat -c %u "$RUNNER_CONF" 2>/dev/null)" == "$CONF_OWNER_UID" ]] || return 1
  mode="$(stat -c %a "$RUNNER_CONF" 2>/dev/null)"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
  CONF_TZ="$(_conf_get TZ)"
  CONF_MAX="$(_conf_get MAX_SESSIONS_PER_DAY)"
  CONF_TIMEOUT="$(_conf_get SESSION_TIMEOUT)"
  CONF_RETENTION="$(_conf_get AUDIT_RETENTION_DAYS)"
  CONF_JOB_TIMEOUT="$(_conf_get JOB_TIMEOUT)"
  CONF_JOB_KILL_AFTER="$(_conf_get JOB_KILL_AFTER)"
  CONF_LOCK_WAIT="$(_conf_get JOB_LOCK_WAIT)"
  [[ "$CONF_TZ" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ "$CONF_MAX" =~ ^[0-9]{1,4}$ ]] || return 1
  [[ "$CONF_TIMEOUT" =~ ^[1-9][0-9]{0,4}[smh]$ ]] || return 1
  [[ "$CONF_RETENTION" =~ ^[1-9][0-9]{0,3}$ ]] || return 1
  JOB_TIMEOUT_SECS="$(_secs "$CONF_JOB_TIMEOUT")" || return 1
  _secs "$CONF_JOB_KILL_AFTER" >/dev/null || return 1
  LOCK_WAIT_SECS="$(_secs "$CONF_LOCK_WAIT")" || return 1
}

_secs() { # _secs <n><s|m|h> -> seconds, or returns 1
  [[ "$1" =~ ^([1-9][0-9]{0,4})([smh])$ ]] || return 1
  case "${BASH_REMATCH[2]}" in
    s) echo "${BASH_REMATCH[1]}" ;;
    m) echo $(( BASH_REMATCH[1] * 60 )) ;;
    h) echo $(( BASH_REMATCH[1] * 3600 )) ;;
  esac
}

# _ledger_sealed — the ledger still starts with the header root wrote at
# container start.
_ledger_sealed() {
  local first=""
  [[ -f "$LEDGER" && ! -L "$LEDGER" ]] || return 1
  IFS= read -r first < "$LEDGER" 2>/dev/null
  [[ "$first" == "$LEDGER_HEADER"* ]]
}

# --- Prune -----------------------------------------------------------------------
_prune() {
  local cutoff d name n=0
  if ! _load_conf; then
    echo "run-job: no usable runner configuration at $RUNNER_CONF — nothing pruned" >&2
    return 1
  fi
  cutoff="$(date -u -d "-$CONF_RETENTION days" +%Y%m%dT%H%M%SZ)" || return 1
  shopt -s nullglob
  for d in "$AUDIT_DIR"/runs/*; do
    name="${d##*/}"
    [[ -d "$d" && ! -L "$d" ]] || continue
    [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z- ]] || continue
    [[ "${name:0:16}" < "$cutoff" ]] || continue
    rm -rf -- "$d" && n=$((n + 1))
  done
  shopt -u nullglob
  echo "run-job: pruned $n run(s) older than $CONF_RETENTION days from $AUDIT_DIR/runs"
}

# --- Processes -------------------------------------------------------------------
# Read straight from /proc with builtins: a scan that forked would list its own
# helpers as the job's leftovers.
_MY_UID="$(id -u)"
declare -A _BEFORE=() _KEEP=()

# _proc <pid> — sets _P_UID, _P_PPID and _P_STATE; returns 1 if it is gone.
_proc() {
  local line rest k v
  _P_UID=""; _P_PPID=""; _P_STATE=""
  { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
  rest="${line##*) }"
  read -r _P_STATE _P_PPID _ <<<"$rest"
  while read -r k v _; do
    [[ "$k" == "Uid:" ]] && { _P_UID="$v"; break; }
  done < "/proc/$1/status" 2>/dev/null
  [[ -n "$_P_UID" && -n "$_P_PPID" ]]
}

# _mine — sets _PIDS to this user's live processes.
_mine() {
  local d p
  _PIDS=()
  for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    _proc "$p" || continue
    [[ "$_P_UID" == "$_MY_UID" && "$_P_STATE" != "Z" ]] && _PIDS+=("$p")
  done
}

_descends_from() { # _descends_from <pid> <ancestor>
  local p="$1" i
  for ((i = 0; i < 64; i++)); do
    _proc "$p" || return 1
    [[ "$_P_PPID" == "$2" ]] && return 0
    [[ "$_P_PPID" -le 1 ]] && return 1
    p="$_P_PPID"
  done
  return 1
}

_tagged() { # _tagged <pid> — carries this run's DEVLEAD_RUN_ID
  local kv
  while IFS= read -r -d '' kv; do
    [[ "$kv" == "DEVLEAD_RUN_ID=$RUN_ID" ]] && return 0
  done < "/proc/$1/environ" 2>/dev/null
  return 1
}

_leftovers() {
  local p
  _LEFT=()
  _mine
  for p in "${_PIDS[@]}"; do
    [[ -z "${_BEFORE[$p]+x}" && -z "${_KEEP[$p]+x}" ]] || continue
    if _descends_from "$p" "$$" || { _proc "$p" && [[ "$_P_PPID" == "$ORPHAN_PARENT" ]]; } || _tagged "$p"; then
      _LEFT+=("$p")
    fi
  done
}

_kill_leftovers() {
  local round sig p
  declare -A killed=()
  for round in 1 2 3; do
    _leftovers
    [[ ${#_LEFT[@]} -gt 0 ]] || break
    sig=TERM; [[ $round -gt 1 ]] && sig=KILL
    for p in "${_LEFT[@]}"; do
      kill -s "$sig" "$p" 2>/dev/null && killed[$p]=1
    done
    sleep 1
  done
  LEFTOVERS_KILLED=${#killed[@]}
  if (( LEFTOVERS_KILLED > 0 )); then
    echo "run-job: stopped $LEFTOVERS_KILLED process(es) the job left behind"
  fi
}

# --- /tmp --------------------------------------------------------------------------
_tmp_entries() {
  find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -user "$_MY_UID" -printf '%f\0' 2>/dev/null
}

# --- Tamper check ------------------------------------------------------------------
# _fingerprint <file> — "<size> <sha256>" of the file as it is now.
_fingerprint() {
  [[ -f "$1" ]] || { echo "0 -"; return 0; }
  printf '%s %s\n' "$(stat -c %s "$1")" "$(sha256sum < "$1" | cut -d' ' -f1)"
}
# _still_there <file> <fingerprint> — the bytes it held are still its first bytes.
_still_there() {
  local size sum
  read -r size sum <<<"$2"
  [[ "$size" == 0 ]] && return 0
  [[ -f "$1" ]] && (( $(stat -c %s "$1") >= size )) || return 1
  [[ "$(head -c "$size" "$1" | sha256sum | cut -d' ' -f1)" == "$sum" ]]
}

# --- Notices --------------------------------------------------------------------
NOTIFY_CODES=()
_need() {
  NOTIFY_CODES+=("$1")
  [[ -f "$SCRIPTS_DIR/notify.sh" ]] || return 0
  bash "$SCRIPTS_DIR/notify.sh" send need "$1" "$2" </dev/null >/dev/null 2>&1 || true
}

_token_check() {
  local out warn today
  [[ -f "$SCRIPTS_DIR/doctor.sh" ]] || return 0
  out="$(bash "$SCRIPTS_DIR/doctor.sh" </dev/null 2>/dev/null)"
  warn="$(grep -m1 '^WARN:' <<<"$out" | sed 's/^WARN:[[:space:]]*//')"
  [[ -n "$warn" ]] || return 0
  today="$(date +%F)"
  [[ "$(cat "$TOKEN_STAMP" 2>/dev/null)" == "$today" ]] && return 0
  # doctor's line names DEVLEAD_CLAUDE_TOKEN_ISSUED with its value: the notice
  # says what it means instead.
  if [[ "$warn" == *"not a valid issue date"* ]]; then
    _need token-expiring "DEVLEAD_CLAUDE_TOKEN_ISSUED in the env file is not a valid date, so the Claude token's age cannot be checked — set it to the day you ran claude setup-token (YYYY-MM-DD) and restart the container"
  else
    _need token-expiring "the Claude token was issued 11 or more months ago and lasts one year — renew it: run claude setup-token, put the new token in .env, update DEVLEAD_CLAUDE_TOKEN_ISSUED and restart the container"
  fi
  mkdir -p "${TOKEN_STAMP%/*}" 2>/dev/null
  printf '%s\n' "$today" > "$TOKEN_STAMP" 2>/dev/null || true
}

# --- The audit line ----------------------------------------------------------------
_repos_json() {
  case "$1" in
    enrolled)
      [[ -f "$STATE_DIR/autonomous-repos" ]] || { echo '[]'; return; }
      grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$STATE_DIR/autonomous-repos" | tr -d '\r' | jq -R . | jq -s -c 'unique'
      ;;
    loop)
      if [[ -n "${DEVLEAD_LOOP_REPO:-}" ]]; then jq -n -c --arg r "$DEVLEAD_LOOP_REPO" '[$r]'; else echo '[]'; fi
      ;;
    *) echo '[]' ;;
  esac
}

# _sessions_json — this run's lines of the ledger, as {sessions, refusals}.
_sessions_json() {
  awk -F'\t' -v r="$RUN_ID" '$5 == r' "$LEDGER" 2>/dev/null | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")) as $l
    | { sessions: [ $l[] | select(.[2] == "start") | .[3] as $id
          | ([ $l[] | select(.[2] == "end" and .[3] == $id) ] | .[0]) as $e
          | { id: $id,
              exit_code: (if $e then ($e[5] | tonumber? // null) else null end),
              timed_out: (($e // [])[6] == "timeout") } ],
        refusals: [ $l[] | select(.[2] == "refused") | .[6] ] }'
}

# _transcript_stats <dir> — {tool_uses, files_changed, prs_opened, parked}
# from the transcripts copied there (subagents included).
_NO_STATS='{"tool_uses":{},"files_changed":[],"prs_opened":[],"parked":{"count":0,"issues":[]}}'
_transcript_stats() {
  local files=()
  mapfile -d '' files < <(find "$1" -type f -name '*.jsonl' -print0 2>/dev/null)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "$_NO_STATS"
    return
  fi
  cat -- "${files[@]}" | jq -R -n -c '
    [ inputs | fromjson? | objects ] as $all
    | [ $all[] | select(.type == "assistant") | .message.content[]? | objects | select(.type == "tool_use") ] as $uses
    | ($uses | map(.name) | group_by(.) | map({ key: .[0], value: length }) | from_entries) as $counts
    | ($uses | map(select(.name | test("^(Write|Edit|MultiEdit|NotebookEdit)$"))
               | (.input.file_path // .input.notebook_path) | strings) | unique) as $changed
    | ($uses | map(select(.name == "Bash" and ((.input.command // "") | test("open-pr\\.sh|gh +pr +create"))) | .id)) as $pr_ids
    | ([ $all[] | select(.type == "user") | .message.content[]? | objects
         | select(.type == "tool_result" and ((.tool_use_id as $i | $pr_ids | index($i)) != null))
         | (.content | if type == "string" then . elif type == "array" then (map(.text? // "") | join("\n")) else "" end)
         | scan("https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+") ] | unique) as $prs
    | ([ $uses[] | select(.name == "Write"
           and ((.input.file_path // "") | strings | test("/reports/[0-9]{4}-[0-9]{2}-[0-9]{2}-execute\\.md$")))
         | .input.content | strings ] | last // "") as $report
    | [ $report | split("\n")[]
        | capture("^\\|[[:space:]]*(?<first>[^|]*[^|[:space:]])?[[:space:]]*\\|[[:space:]]*(parked|escalated)-")? ] as $rows
    | { tool_uses: $counts, files_changed: $changed, prs_opened: $prs,
        parked: { count: ($rows | length),
                  issues: ([ $rows[] | (.first // "") | capture("^#(?<n>[0-9]{1,9})$")? | .n | tonumber ] | unique) } }'
}

_audit() { # _audit <outcome> <exit code> [skipped reason]
  local outcome="$1" rc="$2" skipped="${3:-}" line month file
  local sessions="${SESSIONS_JSON:-}" stats="${STATS_JSON:-}" synced="${SYNCED_JSON:-[]}"
  [[ -n "$sessions" ]] || sessions='{"sessions":[],"refusals":[]}'
  [[ -n "$stats" ]] || stats="$_NO_STATS"
  line="$(jq -n -c \
    --arg run_id "$RUN_ID" --arg trigger "$JOB" --argjson repos "$(_repos_json "$JOB_REPOS")" \
    --arg started "$STARTED_AT" --arg ended "$(date -Is)" --argjson rc "$rc" \
    --argjson s "$sessions" --argjson stats "$stats" --arg outcome "$outcome" \
    --arg skipped "$skipped" --argjson paused "${PAUSED:-false}" \
    --argjson synced "$synced" --arg sync_error "${SYNC_ERROR:-}" \
    --argjson codes "$(printf '%s\n' "${NOTIFY_CODES[@]}" | jq -R . | jq -s -c 'map(select(length > 0))')" \
    --argjson killed "${LEFTOVERS_KILLED:-0}" --argjson waited "${LOCK_WAIT:-0}" \
    --argjson lock_timed_out "${LOCK_TIMED_OUT:-false}" --argjson job_timed_out "${JOB_TIMED_OUT:-false}" \
    --argjson transcripts "${TRANSCRIPTS_KEPT:-0}" --argjson intact "${AUDIT_INTACT:-true}" '
    { run_id: $run_id, trigger: $trigger, repos: $repos, started_at: $started, ended_at: $ended,
      exit_code: $rc,
      timed_out: ([$s.sessions[] | select(.timed_out)] | length > 0),
      cap_refused: ([$s.refusals[] | select(. == "cap")] | length > 0),
      refusals: $s.refusals,
      paused: $paused,
      skipped: (if $skipped == "" then null else $skipped end),
      synced: $synced, sync_error: (if $sync_error == "" then null else $sync_error end),
      sessions: $s.sessions, session_ids: [$s.sessions[].id],
      tool_uses: $stats.tool_uses, files_changed: $stats.files_changed, prs_opened: $stats.prs_opened,
      parked: $stats.parked,
      transcripts_kept: $transcripts, outcome: $outcome,
      notified: ($codes | length > 0), notify_codes: $codes,
      leftovers_killed: $killed, lock_wait_seconds: $waited, lock_timed_out: $lock_timed_out,
      job_timed_out: $job_timed_out, audit_intact: $intact }')" || {
    echo "run-job: cannot build the audit line for run $RUN_ID" >&2
    return 1
  }
  month="$(date -d "@$START_EPOCH" +%Y-%m)"
  file="$AUDIT_DIR/$month.jsonl"
  mkdir -p "$AUDIT_DIR" 2>/dev/null
  printf '%s\n' "$line" >> "$file" 2>/dev/null || echo "run-job: cannot append to $file" >&2
  printf 'devlead-audit %s\n' "$line"
}

# --- Main --------------------------------------------------------------------------
case "${1:-}" in
  --list) _list; exit 0 ;;
  --prune) _prune; exit $? ;;
  ""|-*) _usage; exit 2 ;;
esac
[[ $# -eq 1 ]] || { _usage; exit 2; }
# EUID is set by bash itself; the environment cannot change it. Nothing is
# written and nobody is notified: root's HOME is not the user's.
if (( EUID == 0 )); then
  echo "run-job: the DevLead server never runs a job as root — run it as the devlead user: docker compose exec -u devlead devlead /opt/devlead/docker/run-job.sh $1" >&2
  exit 1
fi

JOB="$1"
JOB_ENTRY=""
for _e in "${JOBS[@]}"; do
  [[ "${_e%%|*}" == "$JOB" ]] && JOB_ENTRY="$_e"
done
if [[ -z "$JOB_ENTRY" ]]; then
  echo "run-job: unknown job '$JOB' — the jobs are: $(_list | cut -d'|' -f1 | paste -sd' ' -)" >&2
  _usage
  exit 2
fi
IFS='|' read -r _ _ _ JOB_CONDITION JOB_REPOS JOB_COMMAND <<<"$JOB_ENTRY"
read -ra JOB_ARGV <<<"$JOB_COMMAND"
for _i in "${!JOB_ARGV[@]}"; do
  # shellcheck disable=SC2088 # a literal ~/ in the table, expanded here
  [[ "${JOB_ARGV[$_i]}" == "~/"* ]] && JOB_ARGV[$_i]="$HOME/${JOB_ARGV[$_i]#\~/}"
done

START_EPOCH="$(date +%s)"
RUN_ID="$(date -u -d "@$START_EPOCH" +%Y%m%dT%H%M%SZ)-$JOB-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
STARTED_AT="$(date -Is -d "@$START_EPOCH")"

if ! _load_conf; then
  echo "run-job: no usable runner configuration at $RUNNER_CONF (root writes it when the container starts) — $JOB not run" >&2
  _need job-failed "$JOB: not run — no usable runner configuration (run $RUN_ID)"
  _audit failed 1
  exit 1
fi
export TZ="$CONF_TZ"
STARTED_AT="$(date -Is -d "@$START_EPOCH")"

if [[ -n "${DEVLEAD_CLAUDE_BIN:-}" && "$DEVLEAD_CLAUDE_BIN" != "claude" && "$DEVLEAD_CLAUDE_BIN" != "$WRAPPER" ]]; then
  echo "run-job: DEVLEAD_CLAUDE_BIN names $DEVLEAD_CLAUDE_BIN, not the claude wrapper ($WRAPPER) — $JOB not run" >&2
  _need job-failed "$JOB: not run — DEVLEAD_CLAUDE_BIN is not the claude wrapper (run $RUN_ID)"
  _audit failed 1
  exit 1
fi

_token_check

PAUSED=false
if [[ -e "$PAUSE_FILE" ]]; then
  echo "run-job: DevLead is paused ($PAUSE_FILE exists) — $JOB not run"
  PAUSED=true
  _audit paused 0
  exit 0
fi

if [[ "$JOB_CONDITION" != "-" && ! -e "$STATE_DIR/$JOB_CONDITION" ]]; then
  echo "run-job: ~/.devlead/$JOB_CONDITION is missing — $JOB skipped"
  _audit skipped 0 "$JOB_CONDITION is missing"
  exit 0
fi

# One job at a time.
if ! { [[ -f "$JOB_LOCK" && ! -L "$JOB_LOCK" ]] && { exec 8<"$JOB_LOCK"; } 2>/dev/null; }; then
  echo "run-job: cannot open the job lock $JOB_LOCK — $JOB not run" >&2
  _need job-failed "$JOB: not run — the job lock cannot be opened (run $RUN_ID)"
  _audit failed 1
  exit 1
fi
_wait_start="$(date +%s)"
if ! flock -n 8; then
  echo "run-job: another job is running — $JOB waits for it (at most $CONF_LOCK_WAIT)"
  if ! flock -w "$LOCK_WAIT_SECS" 8; then
    LOCK_WAIT=$(( $(date +%s) - _wait_start ))
    LOCK_TIMED_OUT=true
    echo "run-job: another job held the job lock for more than $CONF_LOCK_WAIT (DEVLEAD_JOB_LOCK_WAIT) — $JOB not run" >&2
    _need job-timeout "$JOB: not run — another job held the job lock for more than $CONF_LOCK_WAIT (run $RUN_ID)"
    _audit timeout 1
    exit 1
  fi
fi
LOCK_WAIT=$(( $(date +%s) - _wait_start ))
# The job's time starts now (JOB_TIMEOUT).
_JOB_T0="$(date +%s)"
# _over — the job's time is up. _left — seconds left, at least 1 (`timeout 0`
# would mean no limit at all).
_over() { (( $(date +%s) - _JOB_T0 >= JOB_TIMEOUT_SECS )); }
_left() { local l=$(( JOB_TIMEOUT_SECS - ($(date +%s) - _JOB_T0) )); (( l > 0 )) || l=1; echo "$l"; }
JOB_TIMED_OUT=false
if [[ -e "$PAUSE_FILE" ]]; then
  echo "run-job: DevLead was paused while $JOB waited ($PAUSE_FILE exists) — not run"
  PAUSED=true
  _audit paused 0
  exit 0
fi
if ! _ledger_sealed; then
  AUDIT_INTACT=false
  echo "run-job: the session ledger $LEDGER was emptied or replaced since the container started — today's session count is unknown, $JOB not run" >&2
  _need audit-tampered "$JOB: not run — the session ledger was emptied since the container started, so today's session count is unknown (run $RUN_ID)"
  _audit failed 1
  exit 1
fi

RUN_DIR="$AUDIT_DIR/runs/$RUN_ID"
if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
  echo "run-job: cannot create $RUN_DIR — $JOB not run" >&2
  _need job-failed "$JOB: not run — the audit directory is not writable (run $RUN_ID)"
  _audit failed 1
  exit 1
fi
JOBTMP="$(mktemp -d "$TMP_ROOT/devlead-job.XXXXXX")" || {
  echo "run-job: cannot create a TMPDIR under $TMP_ROOT — $JOB not run" >&2
  _need job-failed "$JOB: not run — no private TMPDIR (run $RUN_ID)"
  _audit failed 1
  exit 1
}

# Before: what is already there, and the records the run must not rewrite.
_KEEP[$$]=1
_p=$$
while _proc "$_p" && [[ "$_P_PPID" -gt 0 ]]; do _KEEP[$_P_PPID]=1; _p="$_P_PPID"; done
declare -A _TMP_BEFORE=()
while IFS= read -r -d '' _n; do _TMP_BEFORE[$_n]=1; done < <(_tmp_entries)
_TMP_BEFORE[${JOBTMP##*/}]=1
_month_file="$AUDIT_DIR/$(date -d "@$START_EPOCH" +%Y-%m).jsonl"
_fp_ledger="$(_fingerprint "$LEDGER")"
_fp_audit="$(_fingerprint "$_month_file")"

exec 7> >(tee -a "$RUN_DIR/output.log")
_TEE_PID=$!
_KEEP[$_TEE_PID]=1
_mine
for _p in "${_PIDS[@]}"; do _BEFORE[$_p]=1; done

echo "run-job: $JOB started (run $RUN_ID)" >&7

# The clones it works on, at origin's default branch (S13).
SYNCED_JSON='[]'
SYNC_ERROR=""
_sync_args=()
case "$JOB_REPOS" in
  enrolled) _sync_args=(--all) ;;
  loop) [[ -n "${DEVLEAD_LOOP_REPO:-}" ]] && _sync_args=("$DEVLEAD_LOOP_REPO") ;;
esac
if [[ ${#_sync_args[@]} -gt 0 ]]; then
  if ! { [[ -f "$SESSION_LOCK" && ! -L "$SESSION_LOCK" ]] && { exec 5<"$SESSION_LOCK"; } 2>/dev/null && flock -n 5; }; then
    SYNC_ERROR="a claude session is running in the container"
  else
    _sync_out="$(cd "$STATE_DIR" 2>/dev/null || cd "$HOME" || exit 1
      timeout --kill-after="$CONF_JOB_KILL_AFTER" "$(_left)s" "$SYNC_REPOS" "${_sync_args[@]}" </dev/null 2>&7 5<&- 7>&- 8<&-)"
    _sync_rc=$?
    if (( _sync_rc == 124 || _sync_rc == 137 )) && _over; then
      JOB_TIMED_OUT=true
      SYNC_ERROR="the sync ran past the job's time limit"
    fi
    while IFS=$'\t' read -r _kind _path _f3 _f4; do
      case "$_kind" in
        SYNCED) SYNCED_JSON="$(jq -c --arg r "$_path" --arg b "$_f3" --arg c "$_f4" '. + [{repo: $r, branch: $b, commit: $c}]' <<<"$SYNCED_JSON")" ;;
        FAILED) SYNC_ERROR="$_path: $_f3" ;;
      esac
    done <<<"$_sync_out"
    [[ $_sync_rc -eq 0 || -n "$SYNC_ERROR" ]] || SYNC_ERROR="sync-repos.sh exited $_sync_rc"
  fi
  exec 5<&- 2>/dev/null
fi

if [[ -n "$SYNC_ERROR" ]]; then
  echo "run-job: the repos could not be synced from origin ($SYNC_ERROR) — $JOB not run" >&7
  RC=1
elif _over; then
  JOB_TIMED_OUT=true
  echo "run-job: no time left of the $CONF_JOB_TIMEOUT job limit — $JOB not run" >&7
  RC=1
else
  (
    cd "$STATE_DIR" 2>/dev/null || cd "$HOME" || exit 1
    exec env -u DEVLEAD_CLAUDE_BIN TMPDIR="$JOBTMP" DEVLEAD_RUN_ID="$RUN_ID" \
      timeout --kill-after="$CONF_JOB_KILL_AFTER" "$(_left)s" \
      setsid "$SCRIPTS_DIR/${JOB_ARGV[0]}" "${JOB_ARGV[@]:1}"
  ) </dev/null >&7 2>&7 7>&- 8<&-
  RC=$?
  if (( RC == 124 || RC == 137 )) && _over; then
    JOB_TIMED_OUT=true
    echo "run-job: $JOB ran past the $CONF_JOB_TIMEOUT job limit (DEVLEAD_JOB_TIMEOUT) and was stopped" >&7
  fi
  echo "run-job: $JOB exited $RC (run $RUN_ID)" >&7
fi

# After: nothing of the job outlives it.
LEFTOVERS_KILLED=0
_kill_leftovers >&7 2>&1
exec 7>&-
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$_TEE_PID" 2>/dev/null || break; sleep 0.2; done
kill "$_TEE_PID" 2>/dev/null
rm -rf -- "$JOBTMP"
if [[ -f "$SESSION_LOCK" && ! -L "$SESSION_LOCK" ]] && { exec 6<"$SESSION_LOCK"; } 2>/dev/null && flock -n 6; then
  while IFS= read -r -d '' _n; do
    [[ -n "${_TMP_BEFORE[$_n]+x}" ]] || rm -rf -- "${TMP_ROOT:?}/$_n"
  done < <(_tmp_entries)
  exec 6<&-
else
  exec 6<&- 2>/dev/null
  echo "run-job: a claude session is running, so what appeared in $TMP_ROOT during the run stays (the job's own TMPDIR is removed)"
fi

# What the sessions did.
SESSIONS_JSON="$(_sessions_json)"
[[ -n "$SESSIONS_JSON" ]] || SESSIONS_JSON='{"sessions":[],"refusals":[]}'
TRANSCRIPTS_KEPT=0
shopt -s nullglob
while IFS= read -r _sid; do
  [[ "$_sid" =~ ^[0-9a-f-]{36}$ ]] || continue
  for _f in "$CLAUDE_PROJECTS"/*/"$_sid.jsonl"; do
    [[ -f "$_f" && ! -L "$_f" ]] && cp -- "$_f" "$RUN_DIR/" && TRANSCRIPTS_KEPT=$((TRANSCRIPTS_KEPT + 1))
  done
  for _d in "$CLAUDE_PROJECTS"/*/"$_sid"; do
    [[ -d "$_d" && ! -L "$_d" ]] && cp -RP -- "$_d" "$RUN_DIR/$_sid"
  done
done < <(jq -r '.sessions[].id' <<<"$SESSIONS_JSON")
shopt -u nullglob
STATS_JSON="$(_transcript_stats "$RUN_DIR")"

AUDIT_INTACT=true
if ! _still_there "$LEDGER" "$_fp_ledger" || ! _still_there "$_month_file" "$_fp_audit"; then
  AUDIT_INTACT=false
  echo "run-job: the session ledger or the audit log was rewritten during the run" >&2
  _need audit-tampered "$JOB: the audit log or the session ledger was rewritten during the run (run $RUN_ID)"
fi

# What it delivered (S19): one notice for the PRs it opened, one for the work
# units its report parked. Links and issue numbers only: the URLs are matched
# to github.com's pull URL shape above, the numbers are digits.
_prs="$(jq -r '.prs_opened[]' <<<"$STATS_JSON" 2>/dev/null)"
if [[ -n "$_prs" ]]; then
  _need pr-opened "$JOB: $(grep -c . <<<"$_prs") PR(s) opened, waiting for you: $(paste -sd' ' - <<<"$_prs") (run $RUN_ID)"
fi
_parked="$(jq -r '.parked.count' <<<"$STATS_JSON" 2>/dev/null)"
if [[ "$_parked" =~ ^[1-9][0-9]*$ ]]; then
  _issues="$(jq -r '.parked.issues | map("#\(.)") | join(" ")' <<<"$STATS_JSON" 2>/dev/null)"
  _need park "$JOB: $_parked work unit(s) parked${_issues:+ ($_issues)} — the reasons are in ~/.devlead/reports/$(date +%F)-execute.md (run $RUN_ID)"
fi

# Outcome.
_timed_out="$(jq '[.sessions[] | select(.timed_out)] | length > 0' <<<"$SESSIONS_JSON")"
_refusal="$(jq -r '[.refusals[] | select(. != "paused")] | .[0] // ""' <<<"$SESSIONS_JSON")"
_paused_refusal="$(jq '[.refusals[] | select(. == "paused")] | length > 0' <<<"$SESSIONS_JSON")"
OUTCOME=ok
if [[ "$JOB_TIMED_OUT" == "true" ]]; then
  OUTCOME=timeout
  _need job-timeout "$JOB: ran past the $CONF_JOB_TIMEOUT job limit and was stopped (run $RUN_ID)"
elif [[ -n "$SYNC_ERROR" ]]; then
  OUTCOME=failed
  _need job-failed "$JOB: not run — its repos could not be synced from origin: ${SYNC_ERROR##*: } (run $RUN_ID)"
elif [[ "$_timed_out" == "true" ]]; then
  OUTCOME=timeout
  _need job-timeout "$JOB: a claude session ran past the $CONF_TIMEOUT limit and was stopped (run $RUN_ID)"
elif [[ -n "$_refusal" ]]; then
  OUTCOME=refused
  case "$_refusal" in
    cap)  _why="the daily limit of $CONF_MAX claude sessions is reached" ;;
    busy) _why="another claude session was running" ;;
    nolock) _why="the session lock could not be opened" ;;
    *)    _why="the session limits could not be read" ;;
  esac
  _need job-refused "$JOB: a claude session was refused — $_why (run $RUN_ID)"
elif [[ "$RC" -ne 0 ]]; then
  OUTCOME=failed
  _need job-failed "$JOB: exited $RC (run $RUN_ID)"
elif [[ "$_paused_refusal" == "true" ]]; then
  OUTCOME=paused
  PAUSED=true
fi

_audit "$OUTCOME" "$RC"
case "$OUTCOME" in
  ok|paused) exit 0 ;;
  *) [[ "$RC" -ne 0 ]] && exit "$RC"; exit 1 ;;
esac
