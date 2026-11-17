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
# A session never starts as root: the sessions are the devlead user's, like
# the files they leave and the ledger that counts them.
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
# The Claude account (S12, S21). runner.conf's CLAUDE_ACCOUNTS lists the
# accounts in priority order, each name with the variable that holds its
# token (DEVLEAD_CLAUDE_ACCOUNT_<N>_TOKEN, or CLAUDE_CODE_OAUTH_TOKEN for the
# single-token setup, a pool of one named "default"). Every session runs with
# one account: the wrapper takes the highest-priority one, and the session's
# environment gets that account's token as CLAUDE_CODE_OAUTH_TOKEN and no
# other. A pool's tokens are read from /etc/devlead/claude-tokens, which root
# writes at start (root's, group-readable by the user, nobody else); the
# entrypoint takes them out of the environment, so the scheduler, the jobs
# and the launchers never carry them. A caller that still has them (a
# `docker compose exec` carries the env file) makes the wrapper start again
# without them first, so no process of the session's ancestry holds a token
# it does not use: every process of the user's runs as the session's uid, and
# its environment is readable at /proc/<pid>/environ — guard.sh is the only
# net there, not a sandbox. Every DEVLEAD_CLAUDE_ACCOUNT_* variable (names and
# dates too) is removed from the session's environment. Without
# CLAUDE_ACCOUNTS (no token in the env file) CLAUDE_CODE_OAUTH_TOKEN is left as
# the caller gave it. A token never reaches the ledger, a message or a log:
# only the account's name does.
#
# Usage limits (S22). The highest-priority account is the first one that is
# not resting. When a session ends with an error (not at its time limit), the
# last message of its transcript says why — Claude Code 2.1.326 records it
# there whatever the output format (test/fixtures/claude-2.1.326/):
#   - a usage limit: an assistant message with isApiErrorMessage true, error
#     "rate_limit", apiError "usage_limit_reached" and
#     apiErrorParams.rate_limit_info {rateLimitType (five_hour, seven_day,
#     ...), resetsAt (epoch seconds, when it resets; absent when the API sent
#     none)}. The account rests until resetsAt — DEFAULT_REST (5 hours) when
#     it is missing or not believable (in the past, or more than MAX_REST
#     ahead);
#   - a token the API refused: error "authentication_failed" with
#     apiErrorStatus 401 or 403 (invalid, expired or revoked). The account
#     rests until the operator renews the token and restarts the container:
#     the entrypoint drops these marks at start.
# Anything else — another rate limit, an overloaded API, a network error, no
# transcript — is an ordinary failure and rests nothing. A mark is one line
# appended to /var/lib/devlead/accounts.tsv (root's directory, like the
# ledger): account TAB until (epoch seconds, or - until a restart) TAB kind
# (the rateLimitType, or auth) TAB utc time TAB session id TAB run id TAB
# source (reported, default or auth); an account's last line is its mark.
# The next session takes the next account; when a mark expires, its account
# is the highest-priority one again. With every account resting no session
# starts: the refusal is "limited", it does not count toward the daily cap,
# and stdout gets the line `STATUS: claude-limited`, which the launchers
# read to stop instead of trying again. run-job.sh sends the one notice.
#
# Every start, end and refusal is one line of /var/lib/devlead/sessions.tsv,
# the ledger that run-job.sh reads to audit a run:
#   day TAB utc time TAB start|end|refused TAB session id TAB run id TAB exit
#   code TAB detail (the account's name, or -, on a start line; timeout on an
#   end line; root, paused, busy, nolock, cap, noconf, noledger, nomarks or
#   limited on a refusal). busy is another session holding the lock; nolock,
#   a lock file that cannot be opened; nomarks, an account marks file that
#   cannot be read; limited, every account resting.
# Its first line is a header root writes at container start (a ledger that is
# empty at the start of a run was emptied). Root owns /var/lib/devlead — a
# volume, so the day's count survives a recreated container — and the ledger
# cannot be removed or replaced; see run-job.sh for what the user can still do
# to it.
#
# Each session gets its own --session-id, so its transcript can be found and
# kept (S18). A caller may not pick one, nor resume, continue or fork an
# earlier session (--resume, --continue, ...), nor take a session out of these
# limits (--bg, --cloud, --remote-control, --no-session-persistence).
#
# Exit codes: the session's own; 2 for a refused flag; 75 when the limits,
# or a root caller, refuse the session. --version and --help skip the limits
# and run as root too (the image build checks the version).
#
# Not a sandbox: the real binary is executable by the user, so a session that
# runs it directly is outside these limits. They bound what the scheduler and
# DevLead's launchers start.
set -uo pipefail

# A pool token in this process's environment would stay readable at
# /proc/<pid>/environ for the whole session: start again without them.
_strip=()
for _v in $(compgen -e); do
  [[ "$_v" == DEVLEAD_CLAUDE_ACCOUNT_*TOKEN* ]] && _strip+=(-u "$_v")
done
(( ${#_strip[@]} == 0 )) || exec env "${_strip[@]}" "${BASH_SOURCE[0]}" "$@"
unset _strip _v

# --- Fixed paths (test/unit-claude-wrapper.sh rewrites these in a copy) -------
REAL_CLAUDE=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
RUNNER_CONF=/etc/devlead/runner.conf
LEDGER=/var/lib/devlead/sessions.tsv
SESSION_LOCK=/var/lib/devlead/session.lock
PAUSE_FILE=/home/devlead/.devlead/PAUSE
ACCOUNTS_FILE=/var/lib/devlead/accounts.tsv
TOKENS_FILE=/etc/devlead/claude-tokens
CONF_OWNER_UID=0
# ------------------------------------------------------------------------------
# An account whose usage limit Claude reported without a reset time rests this
# long; a reported reset further ahead than MAX_REST is not believed either.
DEFAULT_REST=18000
MAX_REST=$((8 * 86400))

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

# EUID is set by bash itself; the environment cannot change it.
(( EUID != 0 )) \
  || _refuse root "the DevLead server never starts a claude session as root — run it as the devlead user: docker compose exec -u devlead devlead claude ..."

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
  || _refuse nolock "cannot open the session lock $SESSION_LOCK — no session can start"
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

# --- The account -----------------------------------------------------------------
_names=(); _vars=(); _items=()
read -ra _items <<<"$(_conf_get CLAUDE_ACCOUNTS)"
for _item in "${_items[@]}"; do
  [[ "$_item" =~ ^([a-z][a-z0-9-]{0,23})=(CLAUDE_CODE_OAUTH_TOKEN|DEVLEAD_CLAUDE_ACCOUNT_[1-9]_TOKEN)$ ]] \
    || _refuse noconf "$_noconf"
  _names+=("${BASH_REMATCH[1]}"); _vars+=("${BASH_REMATCH[2]}")
done
# _at <epoch> — the time in the configured TZ, for messages.
_at() { TZ="$_TZ" date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null; }

# _resting — reads the marks into _rest (account -> epoch, or - until a
# restart); _available <index> — that account is not resting now.
declare -A _rest=()
_resting() {
  local a u
  _rest=()
  while IFS=$'\t' read -r a u _; do
    [[ "$a" =~ ^[a-z][a-z0-9-]{0,23}$ && "$u" =~ ^(-|[0-9]{1,12})$ ]] && _rest[$a]="$u"
  done < "$ACCOUNTS_FILE"
}
_available() {
  local u="${_rest[${_names[$1]}]:-0}"
  [[ "$u" != "-" ]] && (( 10#$u <= $(date +%s) ))
}
# _resting_list — "team until <time>, ultra until its token is renewed".
_resting_list() {
  local i u out=""
  for i in "${!_names[@]}"; do
    u="${_rest[${_names[$i]}]:-0}"
    if [[ "$u" == "-" ]]; then out+="${out:+, }${_names[$i]} until its token is renewed"
    else out+="${out:+, }${_names[$i]} until $(_at "$u")"; fi
  done
  printf '%s' "$out"
}

_account="-"
_token=""
_sel=-1
if (( ${#_names[@]} > 0 )); then
  [[ -f "$ACCOUNTS_FILE" && ! -L "$ACCOUNTS_FILE" && -r "$ACCOUNTS_FILE" && -w "$ACCOUNTS_FILE" ]] \
    || _refuse nomarks "cannot read the Claude account marks $ACCOUNTS_FILE (root prepares it when the container starts) — no session can start"
  _resting
  for _i in "${!_names[@]}"; do
    _available "$_i" && { _sel=$_i; break; }
  done
  if (( _sel < 0 )); then
    _earliest=""
    for _n in "${_names[@]}"; do
      _u="${_rest[$_n]}"
      [[ "$_u" != "-" ]] && { [[ -z "$_earliest" ]] || (( 10#$_u < 10#$_earliest )); } && _earliest="$_u"
    done
    _when="a token is renewed and the container restarted"
    [[ -n "$_earliest" ]] && _when="$(_at "$_earliest")"
    echo "STATUS: claude-limited"
    _refuse limited "every Claude account is resting ($(_resting_list)) — no session starts until $_when"
  fi
  _account="${_names[$_sel]}"
  if [[ "${_vars[$_sel]}" == CLAUDE_CODE_OAUTH_TOKEN ]]; then
    _token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  else
    _notokens="cannot read the Claude account tokens $TOKENS_FILE (root writes it when the container starts) — no session can start"
    [[ -f "$TOKENS_FILE" && ! -L "$TOKENS_FILE" && -r "$TOKENS_FILE" ]] || _refuse noconf "$_notokens"
    [[ "$(stat -c %u "$TOKENS_FILE" 2>/dev/null)" == "$CONF_OWNER_UID" ]] || _refuse noconf "$_notokens"
    _mode="$(stat -c %a "$TOKENS_FILE" 2>/dev/null)"
    [[ "$_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$_mode & 8#022) == 0 )) || _refuse noconf "$_notokens"
    _token="$(sed -n "s/^${_vars[$_sel]}=//p" "$TOKENS_FILE" 2>/dev/null | tail -n 1)"
    [[ "$_token" =~ ^[A-Za-z0-9._~+/=-]{1,1024}$ ]] || _refuse noconf "$_notokens"
  fi
fi
# The session sees one token at most, its account's, and nothing of the pool.
for _v in $(compgen -e); do
  [[ "$_v" == DEVLEAD_CLAUDE_ACCOUNT_* ]] && unset "$_v"
done
if (( ${#_names[@]} > 0 )); then
  unset CLAUDE_CODE_OAUTH_TOKEN
  [[ -n "$_token" ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_token"
fi
unset _token _v _item _items

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

_ledger start "$_sid" - "$_account"
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

# --- Usage limit or refused token (S22) -----------------------------------------
# _limit_of <session id> — "limit <rateLimitType> <resetsAt>" or "auth - -"
# from the last main-chain assistant message of the session's transcript, or
# nothing. The transcript is the session's file, so it is read as data: the
# last lines only, size-bounded, parsed by jq, every field checked again here.
_limit_of() {
  local t f=""
  for t in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$1.jsonl"; do
    [[ -f "$t" && ! -L "$t" ]] && { f="$t"; break; }
  done
  [[ -n "$f" ]] || return 0
  tail -n 64 -- "$f" 2>/dev/null | head -c 8388608 | jq -R -r -n '
    [ inputs | fromjson? | objects | select(.type == "assistant" and (.isSidechain != true)) ] | last // {}
    | if .isApiErrorMessage != true then empty
      elif .error == "rate_limit" and .apiError == "usage_limit_reached" then
        (.apiErrorParams.rate_limit_info // {}) as $i
        | "limit \(($i.rateLimitType // "") | tostring | if test("^[a-z0-9_]{1,40}$") then . else "unknown" end) \(($i.resetsAt // "-") | tostring)"
      elif .error == "authentication_failed" and (.apiErrorStatus == 401 or .apiErrorStatus == 403) then "auth - -"
      else empty end' 2>/dev/null | head -n 1
}
_limit_name() {
  case "$1" in
    five_hour) echo "5-hour limit" ;; seven_day) echo "weekly limit" ;;
    seven_day_opus) echo "weekly Opus limit" ;; seven_day_sonnet) echo "weekly Sonnet limit" ;;
    *) echo "usage limit" ;;
  esac
}
if (( _sel >= 0 && _rc != 0 )) && [[ "$_detail" != "timeout" ]]; then
  read -r _kind _type _reset <<<"$(_limit_of "$_sid")"
  _now="$(date +%s)"
  _until=""
  case "${_kind:-}" in
    limit)
      if [[ "$_reset" =~ ^[0-9]{9,11}$ ]] && (( 10#$_reset > _now && 10#$_reset <= _now + MAX_REST )); then
        _until=$((10#$_reset)); _src=reported
        _why="its $(_limit_name "$_type")"
      else
        _until=$((_now + DEFAULT_REST)); _src=default
        _why="its $(_limit_name "$_type") (Claude gave no usable reset time: it rests $((DEFAULT_REST / 3600)) hours)"
      fi
      ;;
    auth)
      _until="-"; _type=auth; _src=auth
      _why="a refused token (invalid, expired or revoked): renew it and restart the container"
      ;;
  esac
  if [[ -n "$_until" ]]; then
    if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_account" "$_until" "$_type" "$(date -u +%FT%TZ)" \
         "$_sid" "$_RUN_ID" "$_src" >> "$ACCOUNTS_FILE" 2>/dev/null; then
      _resting
      _next=""
      for _i in "${!_names[@]}"; do _available "$_i" && { _next="${_names[$_i]}"; break; }; done
      _rested="until $(_at "$_until")"; [[ "$_until" == "-" ]] && _rested="until its token is renewed"
      if [[ -n "$_next" ]]; then
        echo "claude: the Claude account $_account rests $_rested — $_why; the next session uses $_next" >&2
      else
        echo "claude: the Claude account $_account rests $_rested — $_why; every account is resting now ($(_resting_list))" >&2
      fi
    else
      echo "claude: the Claude account $_account reached $_why, but $ACCOUNTS_FILE cannot be written — the next session may try it again" >&2
    fi
  fi
fi
exit "$_rc"
