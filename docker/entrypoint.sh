#!/usr/bin/env bash
# entrypoint.sh — the DevLead container's start (runs under tini, as root).
#
# Root is held only long enough to:
#   1. turn the schedule and the session limits of the env file into
#      /etc/devlead/crontab and /etc/devlead/runner.conf, root's (S11, S16,
#      S17; docker/runner-config.sh). An invalid value — a cron expression, a
#      time zone, a limit, a DEVLEAD_CLAUDE_BIN that is not the wrapper — stops
#      the start, named;
#   2. apply the egress firewall (S8). If it fails, the container does not
#      start: the command below never runs on an open network;
#   3. hand the ntfy settings to notify.sh, in the file it reads
#      (~/.devlead/notify.env, mode 600), and drop them from the environment;
#   4. prepare /var/lib/devlead, where the claude wrapper keeps its session
#      ledger and locks: root's directory, so the user can neither remove nor
#      replace them. Ledger lines older than two days are dropped;
#   5. switch to the devlead user for good — same UID/GID as the host user,
#      every capability gone, no way back through setuid binaries —, prune the
#      run transcripts past their retention, and run the command (S9): by
#      default supercronic with that crontab.
#
# Secrets come from the env file compose passes in (.env, outside git). This
# script reports which ones are missing, by name, and never prints a value.
set -euo pipefail

DEVLEAD_USER=devlead
DEVLEAD_HOME=/home/devlead
NOTIFY_ENV="$DEVLEAD_HOME/.devlead/notify.env"

log() { printf 'devlead-entrypoint: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] \
  || die "started as UID $(id -u), not root: the egress firewall cannot be applied, so the container does not start"
[[ $# -gt 0 ]] || die "no command to run"

/opt/devlead/docker/runner-config.sh render /etc/devlead \
  || die "the schedule or the limits in the env file are not valid (see above), so the container does not start"
chown root:root /etc/devlead/crontab /etc/devlead/runner.conf
if ! _sc_out="$(/usr/local/bin/supercronic -test /etc/devlead/crontab 2>&1)"; then
  printf '%s\n' "$_sc_out" >&2
  die "supercronic does not accept /etc/devlead/crontab, so the container does not start"
fi
# The scheduler and the jobs run in the time zone the limits were written for.
TZ="$(sed -n 's/^TZ=//p' /etc/devlead/runner.conf)"
export TZ

/opt/devlead/docker/init-firewall.sh \
  || die "the egress firewall could not be applied, so the container does not start"

# notify.sh reads its push settings from a 600 file owned by the user who runs
# it, never from the environment. Written on every start, so a value removed
# from .env does not linger from an earlier one.
rm -f "$NOTIFY_ENV"
if [[ -n "${DEVLEAD_NTFY_URL:-}" ]]; then
  (
    umask 077
    {
      printf 'DEVLEAD_NTFY_URL=%s\n' "$DEVLEAD_NTFY_URL"
      if [[ -n "${DEVLEAD_NTFY_TOKEN:-}" ]]; then printf 'DEVLEAD_NTFY_TOKEN=%s\n' "$DEVLEAD_NTFY_TOKEN"; fi
      if [[ -n "${DEVLEAD_NOTIFY_DETAIL:-}" ]]; then printf 'DEVLEAD_NOTIFY_DETAIL=%s\n' "$DEVLEAD_NOTIFY_DETAIL"; fi
    } > "$NOTIFY_ENV"
  )
  chown "$DEVLEAD_USER:" "$NOTIFY_ENV"
  chmod 600 "$NOTIFY_ENV"
fi
unset DEVLEAD_NTFY_URL DEVLEAD_NTFY_TOKEN DEVLEAD_NOTIFY_DETAIL

for _v in CLAUDE_CODE_OAUTH_TOKEN DEVLEAD_CLAUDE_TOKEN_ISSUED GH_TOKEN DEVLEAD_LOOP_CLAUDE_ARGS; do
  [[ -n "${!_v:-}" ]] || log "$_v is not set in the env file — unattended runs will not work until it is"
done
unset _v

_uid="$(id -u "$DEVLEAD_USER")"
_gid="$(id -g "$DEVLEAD_USER")"
[[ "$_uid" -ne 0 && "$_gid" -ne 0 ]] || die "the $DEVLEAD_USER user must not be root"

# The claude wrapper's ledger and locks (see docker/claude-wrapper.sh).
_state=/var/lib/devlead
_ledger="$_state/sessions.tsv"
install -d -m 0755 -o root -g root "$_state"
for _lock in "$_state/session.lock" "$_state/job.lock"; do
  if [[ -L "$_lock" || ! -f "$_lock" ]]; then rm -f "$_lock"; install -m 0644 -o root -g root /dev/null "$_lock"; fi
  chown root:root "$_lock"; chmod 0644 "$_lock"
done
if [[ -L "$_ledger" || ! -f "$_ledger" ]]; then
  rm -f "$_ledger"
  install -m 0600 -o "$_uid" -g "$_gid" /dev/null "$_ledger"
else
  _cutoff="$(date -d '-2 days' +%F)"
  _tmp="$(mktemp)"
  awk -F'\t' -v c="$_cutoff" '$1 >= c' "$_ledger" > "$_tmp" && cat "$_tmp" > "$_ledger"
  rm -f "$_tmp"
fi
chown "$_uid:$_gid" "$_ledger"
chmod 0600 "$_ledger"

_as_devlead=(setpriv --reuid="$_uid" --regid="$_gid" --init-groups
             --inh-caps=-all --bounding-set=-all --no-new-privs --
             env HOME="$DEVLEAD_HOME" USER="$DEVLEAD_USER" LOGNAME="$DEVLEAD_USER" SHELL=/bin/bash)

cd "$DEVLEAD_HOME"
"${_as_devlead[@]}" /opt/devlead/docker/run-job.sh --prune >&2 \
  || log "pruning the run transcripts failed (see above); the container starts anyway"
exec "${_as_devlead[@]}" "$@"
