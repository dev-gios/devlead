#!/usr/bin/env bash
# entrypoint.sh — the DevLead container's start (runs under tini, as root).
#
# Root is held only long enough to:
#   1. apply the egress firewall (S8). If it fails, the container does not
#      start: the command below never runs on an open network;
#   2. hand the ntfy settings to notify.sh, in the file it reads
#      (~/.devlead/notify.env, mode 600), and drop them from the environment;
#   3. switch to the devlead user for good — same UID/GID as the host user,
#      every capability gone, no way back through setuid binaries — and run
#      the command (S9).
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

cd "$DEVLEAD_HOME"
exec setpriv --reuid="$_uid" --regid="$_gid" --init-groups \
  --inh-caps=-all --bounding-set=-all --no-new-privs -- \
  env HOME="$DEVLEAD_HOME" USER="$DEVLEAD_USER" LOGNAME="$DEVLEAD_USER" SHELL=/bin/bash "$@"
