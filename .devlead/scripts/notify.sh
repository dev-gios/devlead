#!/usr/bin/env bash
# notify.sh — DevLead's way of reaching the human: a local inbox, plus a push
# to their phone for the few things that cannot wait.
#
# Usage:
#   notify.sh send <need|info> <code> <message>
#   notify.sh list          pending entries, `need` first
#   notify.sh ack           archive everything pending
#
# Two levels, on purpose:
#   need  — an unattended run cannot continue on its own. Written to the inbox
#           AND pushed to the phone (when a push URL is configured).
#   info  — worth knowing, not worth interrupting for. Inbox only.
#
# Notifying grants nothing: this script runs no pipeline step and writes
# nothing but its own inbox. `send` always exits 0 — a dead network or a
# missing config must never change the outcome of the run that called it.
#
# Push backend: any ntfy-compatible server. Configure it in
# ~/.devlead/notify.env (chmod 600 — the URL carries the topic, which is the
# only secret protecting the channel):
#   DEVLEAD_NTFY_URL=https://ntfy.example/your-private-topic
#   DEVLEAD_NTFY_TOKEN=...          optional, sent as a Bearer token
#   DEVLEAD_NOTIFY_DETAIL=1         optional, see below
# No file, wrong permissions, or a non-https URL -> nothing leaves the machine.
#
# Privacy: the push travels through a third-party service. By default its body
# is only the code ("DevLead needs you: loop-paused"); the repository and the
# message stay in the local inbox. DEVLEAD_NOTIFY_DETAIL=1 adds them.
#
# Inbox format (~/.devlead/inbox.tsv, append-only, one entry per line):
#   <utc timestamp> TAB <level> TAB <code> TAB <push outcome> TAB <repo> TAB <message>
#
# Environment:
#   DEVLEAD_NOTIFY_DIR   state root holding inbox.tsv, inbox.read.tsv and
#                        notify.env (default: ~/.devlead). Tests point it at a
#                        sandbox so they never touch the real inbox or config.

set -uo pipefail

STATE_DIR="${DEVLEAD_NOTIFY_DIR:-$HOME/.devlead}"
INBOX="$STATE_DIR/inbox.tsv"
ARCHIVE="$STATE_DIR/inbox.read.tsv"
CONFIG="$STATE_DIR/notify.env"
PUSH_TIMEOUT_SECS=10

# _flat <text> — one line, no tabs: the inbox is line- and tab-delimited.
_flat() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# _config_get <KEY> — value of KEY=... in the config file. The file is parsed,
# never sourced: it must not be able to run anything.
_config_get() {
  [[ -f "$CONFIG" ]] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$CONFIG" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# _push <code> <repo> <message> — echoes the outcome word recorded in the inbox.
_push() {
  local code="$1" repo="$2" message="$3" url token detail perms body
  if [[ ! -f "$CONFIG" ]]; then echo "off"; return; fi
  perms="$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG" 2>/dev/null || echo unknown)"
  if [[ "$perms" != "600" ]]; then echo "skipped:config-not-600"; return; fi
  url="$(_config_get DEVLEAD_NTFY_URL)"
  if [[ -z "$url" ]]; then echo "off"; return; fi
  if [[ "$url" != https://* ]]; then echo "skipped:url-not-https"; return; fi
  if ! command -v curl &>/dev/null; then echo "skipped:no-curl"; return; fi

  body="DevLead needs you: $code"
  detail="$(_config_get DEVLEAD_NOTIFY_DETAIL)"
  if [[ "$detail" == "1" ]]; then
    body="$body — $repo: $message"
  fi
  token="$(_config_get DEVLEAD_NTFY_TOKEN)"
  local -a args=(-fsS --max-time "$PUSH_TIMEOUT_SECS" -o /dev/null
                 -H "Title: DevLead" -H "Priority: high" --data-binary "$body")
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  if curl "${args[@]}" "$url" 2>/dev/null; then echo "sent"; else echo "failed"; fi
}

_send() {
  local level="${1:-}" code="${2:-}" message="${3:-}" repo outcome
  if [[ "$level" != "need" && "$level" != "info" ]] || [[ -z "$code" ]]; then
    echo "notify: usage: notify.sh send <need|info> <code> <message>" >&2
    return 0
  fi
  code="$(_flat "$code")"
  message="$(_flat "$message")"
  repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  repo="$(_flat "${repo:--}")"

  outcome="none"
  [[ "$level" == "need" ]] && outcome="$(_push "$code" "${repo##*/}" "$message")"

  if ! mkdir -p "$STATE_DIR" 2>/dev/null \
     || ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$level" "$code" \
          "$outcome" "$repo" "$message" >> "$INBOX" 2>/dev/null; then
    echo "notify: could not write $INBOX — [$level] $code: $message" >&2
  fi
  return 0
}

_list() {
  if [[ ! -s "$INBOX" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  echo "STATUS: pending"
  echo "COUNT_NEED: $(grep -c $'^[^\t]*\tneed\t' "$INBOX")"
  echo "COUNT_INFO: $(grep -c $'^[^\t]*\tinfo\t' "$INBOX")"
  local level ts lvl code outcome repo message
  for level in need info; do
    while IFS=$'\t' read -r ts lvl code outcome repo message; do
      [[ "$lvl" == "$level" ]] || continue
      printf '[%s] %s  %s  (%s)  push=%s\n    %s\n' "$lvl" "$ts" "$code" "$repo" "$outcome" "$message"
    done < "$INBOX"
  done
}

_ack() {
  if [[ ! -s "$INBOX" ]]; then
    echo "STATUS: empty"
    return 0
  fi
  local n
  n="$(wc -l < "$INBOX" | tr -d ' ')"
  # Append-then-truncate: an entry is never in neither file.
  if cat "$INBOX" >> "$ARCHIVE" && : > "$INBOX"; then
    echo "STATUS: acked"
    echo "COUNT: $n"
  else
    echo "STATUS: error"
    return 1
  fi
}

case "${1:-}" in
  send) shift; _send "$@" ;;
  list) _list ;;
  ack)  _ack ;;
  *)
    echo "Usage: notify.sh send <need|info> <code> <message> | list | ack" >&2
    exit 1 ;;
esac
