#!/bin/bash
# claude — the only `claude` on PATH in the DevLead server image (installed as
# /usr/local/bin/claude, root-owned). Every session started here, by the
# launchers or by hand, loads only the user and managed settings:
#
#   - the user settings live in CLAUDE_CONFIG_DIR, which root owns, so no
#     session can change them;
#   - the project and local settings of a repository live in the clone, which
#     the session can write. Loaded, a file planted by one session would run
#     in the next — an apiKeyHelper at start, an env block that reaches every
#     command — outside every hook. So they are never loaded.
#
# --setting-sources user is always passed. A caller's own --setting-sources is
# refused rather than merged: Claude Code takes the last one given, so it would
# win. --settings is refused too: it loads settings on top of the user's
# (an apiKeyHelper or env included) whatever --setting-sources says.
#
# It is also where the server's session limits hold (S17), for every session —
# the ones run-job.sh's jobs start, each iteration of sweep-loop.sh, one typed
# by hand. They are read from /etc/devlead/runner.conf, which root writes at
# container start from the env file, never from the caller's environment:
#
#   - pause: while /home/devlead/.devlead/PAUSE exists no session starts. Root
#     owns that directory, so only the operator creates or removes the file
#     (docker compose exec -u root devlead touch /home/devlead/.devlead/PAUSE);
#   - one at a time: a session started while another runs is refused, not
#     queued — one started from inside another would wait for its own parent;
#   - MAX_SESSIONS_PER_DAY sessions per calendar day, in the configured TZ;
#   - SESSION_TIMEOUT per session: then TERM, and KILL SESSION_KILL_AFTER later.
#
# Every start, end and refusal is one line of /var/lib/devlead/sessions.tsv,
# the ledger that run-job.sh reads to audit a run:
#   day TAB utc time TAB start|end|refused TAB session id TAB run id TAB exit
#   code TAB detail (timeout on an end line; paused, busy, cap or noconf on a
#   refusal)
# Root owns /var/lib/devlead, so the ledger cannot be removed or replaced; see
# run-job.sh for what the user can still do to it.
#
# Each session gets its own --session-id, so its transcript can be found and
# kept (S18). A caller may not pick one, nor resume, continue or fork an
# earlier session (--resume, --continue, ...), nor take a session out of these
# limits (--bg, --cloud, --remote-control, --no-session-persistence).
#
# Exit codes: the session's own; 2 for a refused flag; 75 when the limits
# refuse the session. --version and --help skip the limits.
#
# Not a sandbox: the real binary is executable by the user, so a session that
# runs it directly is outside these limits. They bound what the scheduler and
# DevLead's launchers start.
set -uo pipefail

# --- Fixed paths (test/unit-claude-wrapper.sh rewrites these in a copy) -------
REAL_CLAUDE=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
RUNNER_CONF=/etc/devlead/runner.conf
LEDGER=/var/lib/devlead/sessions.tsv
SESSION_LOCK=/var/lib/devlead/session.lock
PAUSE_FILE=/home/devlead/.devlead/PAUSE
CONF_OWNER_UID=0
# ------------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --setting-sources|--setting-sources=*|--settings|--settings=*)
      echo "claude: ${arg%%=*} is not accepted here: in the DevLead server image every session loads only the user and managed settings (--setting-sources user), which root owns" >&2
      exit 2
      ;;
    --resume|--resume=*|-r|--continue|-c|--fork-session|--from-pr|--from-pr=*|--teleport|--teleport=*|--session-id|--session-id=*)
      echo "claude: ${arg%%=*} is not accepted here: in the DevLead server image every session starts fresh with its own session id; none resumes, continues or forks an earlier one" >&2
      exit 2
      ;;
    --bg|--background|--cloud|--cloud=*|--remote-control|--remote-control=*|--no-session-persistence)
      echo "claude: ${arg%%=*} is not accepted here: it would take the session out of the server's limits (one at a time, a time limit, its transcript kept)" >&2
      exit 2
      ;;
  esac
  # Short flags written together, as in -pc.
  if [[ "$arg" =~ ^-[A-Za-z]{2,}$ && "$arg" == *[cr]* ]]; then
    echo "claude: $arg is not accepted here: it holds -c or -r; in the DevLead server image every session starts fresh with its own session id; none resumes, continues or forks an earlier one" >&2
    exit 2
  fi
done

case "${1:-}" in
  --version|-v|--help|-h) exec "$REAL_CLAUDE" --setting-sources user "$@" ;;
esac

# --- Limits ----------------------------------------------------------------------
_TZ=UTC
_RUN_ID="${DEVLEAD_RUN_ID:-}"
[[ "$_RUN_ID" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || _RUN_ID="-"

# _ledger <event> <session id> <exit code> <detail>
_ledger() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(TZ="$_TZ" date +%F)" "$(date -u +%FT%TZ)" \
    "$1" "$2" "$_RUN_ID" "$3" "$4" >> "$LEDGER" 2>/dev/null
}

# _refuse <detail> <message>
_refuse() {
  echo "claude: $2" >&2
  _ledger refused - - "$1"
  exit 75
}

_conf_get() { sed -n "s/^$1=//p" "$RUNNER_CONF" 2>/dev/null | tail -n 1; }

_secs() { # _secs <n><s|m|h> -> seconds, or returns 1
  [[ "$1" =~ ^([1-9][0-9]{0,4})([smh])$ ]] || return 1
  case "${BASH_REMATCH[2]}" in
    s) echo "${BASH_REMATCH[1]}" ;;
    m) echo $(( BASH_REMATCH[1] * 60 )) ;;
    h) echo $(( BASH_REMATCH[1] * 3600 )) ;;
  esac
}

_noconf="no usable runner configuration at $RUNNER_CONF (it is written by root when the container starts) — no session can start"
[[ -f "$RUNNER_CONF" && ! -L "$RUNNER_CONF" ]] || _refuse noconf "$_noconf"
[[ "$(stat -c %u "$RUNNER_CONF" 2>/dev/null)" == "$CONF_OWNER_UID" ]] || _refuse noconf "$_noconf"
_mode="$(stat -c %a "$RUNNER_CONF" 2>/dev/null)"
[[ "$_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$_mode & 8#022) == 0 )) || _refuse noconf "$_noconf"

_tz="$(_conf_get TZ)"
_max="$(_conf_get MAX_SESSIONS_PER_DAY)"
_timeout="$(_conf_get SESSION_TIMEOUT)"
_kill_after="$(_conf_get SESSION_KILL_AFTER)"
[[ "$_tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || _refuse noconf "$_noconf"
_TZ="$_tz"
[[ "$_max" =~ ^[0-9]{1,4}$ ]] || _refuse noconf "$_noconf"
_timeout_secs="$(_secs "$_timeout")" || _refuse noconf "$_noconf"
_secs "$_kill_after" >/dev/null || _refuse noconf "$_noconf"

[[ -e "$PAUSE_FILE" ]] \
  && _refuse paused "DevLead is paused ($PAUSE_FILE exists): no claude session starts until the operator removes it"

[[ -f "$SESSION_LOCK" && ! -L "$SESSION_LOCK" ]] && { exec 9<"$SESSION_LOCK"; } 2>/dev/null \
  || _refuse busy "cannot open the session lock $SESSION_LOCK — no session can start"
flock -n 9 \
  || _refuse busy "another claude session is running in this container; sessions run one at a time — try again when it ends"

_today="$(TZ="$_TZ" date +%F)"
[[ -f "$LEDGER" && -r "$LEDGER" && -w "$LEDGER" ]] \
  || _refuse noledger "cannot count today's sessions: the ledger $LEDGER is missing or not writable — no session can start"
_count="$(awk -F'\t' -v d="$_today" '$1 == d && $3 == "start" { n++ } END { print n + 0 }' "$LEDGER" 2>/dev/null)"
[[ "$_count" =~ ^[0-9]+$ ]] \
  || _refuse noledger "cannot count today's sessions: the ledger $LEDGER cannot be read — no session can start"
(( _count < 10#$_max )) \
  || _refuse cap "the daily limit of $_max claude sessions is reached ($_today, $_TZ); the next one can start tomorrow"

# --- The session ---------------------------------------------------------------
_sid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
[[ "$_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _refuse noconf "cannot generate a session id — no session can start"

# The session id goes last, or right before a `--` that ends the options.
_args=(--setting-sources user)
_placed=0
for arg in "$@"; do
  if [[ "$arg" == "--" && $_placed -eq 0 ]]; then
    _args+=(--session-id "$_sid")
    _placed=1
  fi
  _args+=("$arg")
done
[[ $_placed -eq 1 ]] || _args+=(--session-id "$_sid")

# Interactive: timeout must leave the terminal to the session.
_fg=()
[[ -t 0 ]] && _fg=(--foreground)

_ledger start "$_sid" - -
_start="$(date +%s)"
# 9<&- : the lock stays with this process; a background process the session
# leaves behind must not hold it.
timeout "${_fg[@]}" --kill-after="$_kill_after" "$_timeout" "$REAL_CLAUDE" "${_args[@]}" 9<&-
_rc=$?
_elapsed=$(( $(date +%s) - _start ))

_detail="-"
if (( (_rc == 124 || _rc == 137) && _elapsed >= _timeout_secs )); then
  _detail="timeout"
  echo "claude: the session ran past the limit of $_timeout and was stopped" >&2
fi
_ledger end "$_sid" "$_rc" "$_detail"
exit "$_rc"
