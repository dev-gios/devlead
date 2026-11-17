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
#   4. check the host's state is mounted (S14): the subdirectories of the
#      host's ~/.devlead the jobs share with the morning /devlead, and the
#      inbox — never gh-token, notify.env, loop.env or anything else of it.
#      Each must be a mount of the user's (same UID as on the host); learn/
#      read-only, since the unattended commands only read preferences;
#   4b. install the loop's plan (L21 A2): with DEVLEAD_LOOP_PLAN set, compose
#      binds the host's plan file read-only at /run/devlead/host-plan.yml
#      (otherwise docker/no-loop-plan.yml, never read). Root checks it parses as the loop
#      reads it (yq, .tasks[].id: at least one task, each with an id) and
#      installs a root-owned 0644 copy as ~/.devlead/plan.local.yml — the
#      loop's condition file. An invalid plan stops the start. With
#      DEVLEAD_LOOP_REPO set and no plan, a warning: the loop job is skipped;
#   5. prepare the workspace (S13): the clones volume, mounted by compose at
#      DEVLEAD_WORKSPACE — the host directory that holds the enrolled repos,
#      so each clone sits at the repo's host path and every piece of state
#      keyed by that path is the key the host's /devlead reads. Root owns the
#      workspace and every directory above a clone; each clone's own
#      directory is the user's. sync-repos.sh fills it before a job;
#   6. write ~/.devlead/autonomous-repos — the fleet list the jobs read — from
#      DEVLEAD_REPOS, root's and read-only to the user: no session can enroll
#      a repo (Inv 3);
#   7. prepare /var/lib/devlead, where the claude wrapper keeps its session
#      ledger and locks: root's directory, so the user can neither remove nor
#      replace them, and a volume of its own, so the day's session count
#      survives a recreated container (L18). Ledger lines older than two days
#      are dropped, and its first line is root's header: a ledger found
#      empty at the start of a run was emptied by someone (run-job.sh);
#   8. switch to the devlead user for good — same UID/GID as the host user,
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
FLEET_LIST="$DEVLEAD_HOME/.devlead/autonomous-repos"

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

_uid="$(id -u "$DEVLEAD_USER")"
_gid="$(id -g "$DEVLEAD_USER")"
[[ "$_uid" -ne 0 && "$_gid" -ne 0 ]] || die "the $DEVLEAD_USER user must not be root"

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


# _clone_dir <workspace> <repo path> <entry number> — root's directories down
# to the clone's, which is the user's. Nothing on the way may be a link or a
# directory someone else owns (a clone of an earlier DEVLEAD_REPOS, say):
# root would otherwise create or chown through it.
_clone_dir() {
  local ws="$1" path="$2" n="$3" cur="$1" part i last parts=()
  IFS=/ read -ra parts <<<"${path#"$ws"/}"
  last=$(( ${#parts[@]} - 1 ))
  for i in "${!parts[@]}"; do
    part="${parts[$i]}"
    cur="$cur/$part"
    if [[ -L "$cur" ]] || { [[ -e "$cur" ]] && [[ ! -d "$cur" ]]; }; then
      log "ERROR: the path of DEVLEAD_REPOS entry $n runs through something that is not a directory in the workspace volume"
      return 1
    fi
    if (( i < last )); then
      if [[ ! -d "$cur" ]]; then
        install -d -m 0755 -o root -g root "$cur" || return 1
      elif [[ "$(stat -c %u "$cur")" != 0 ]]; then
        log "ERROR: the path of DEVLEAD_REPOS entry $n runs through a clone of an earlier list (a directory of the user's in the workspace volume) — remove it from the volume, or enroll that repo again"
        return 1
      fi
    elif [[ ! -d "$cur" ]]; then
      install -d -m 0755 -o "$_uid" -g "$_gid" "$cur" || return 1
    elif [[ "$(stat -c %u "$cur")" == 0 && -z "$(ls -A "$cur")" ]]; then
      chown "$_uid:$_gid" "$cur" && chmod 0755 "$cur" || return 1
    elif [[ "$(stat -c %u "$cur")" != "$_uid" ]]; then
      log "ERROR: the clone directory of DEVLEAD_REPOS entry $n is not the user's"
      return 1
    fi
  done
}

# _is_mount <path> — something is mounted exactly there.
_is_mount() { awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo; }

# The host's state (S14): what compose mounts from DEVLEAD_STATE_DIR. A
# missing mount would leave the jobs writing state the host never sees.
_mount_opts() { awk -v p="$1" '$5 == p { o = $6 } END { print o }' /proc/self/mountinfo; }
# shellcheck disable=SC2088 # "~/.devlead/..." in the messages is display text
for _m in agenda audit decisions journals outcomes reports run-state learn inbox.tsv inbox.read.tsv; do
  _p="$DEVLEAD_HOME/.devlead/$_m"
  _is_mount "$_p" || die "~/.devlead/$_m is not mounted from the host's DEVLEAD_STATE_DIR — compose.yaml mounts it (create it on the host first, see docker/devlead.env.example); the container does not start"
  if [[ "$_m" == *.tsv ]]; then
    [[ -f "$_p" && ! -L "$_p" ]] || die "~/.devlead/$_m from the host is not a regular file"
  else
    [[ -d "$_p" && ! -L "$_p" ]] || die "~/.devlead/$_m from the host is not a directory"
  fi
  [[ "$(stat -c %u "$_p")" == "$_uid" ]] \
    || die "~/.devlead/$_m on the host is not owned by DEVLEAD_UID — the container writes the host's state as you"
  _ro=false; [[ ",$(_mount_opts "$_p")," == *,ro,* ]] && _ro=true
  if [[ "$_m" == learn ]]; then
    $_ro || die "~/.devlead/learn must be mounted read-only: the jobs only read preferences"
  else
    ! $_ro || die "~/.devlead/$_m is mounted read-only: the jobs write it"
  fi
done
unset _m _p _ro

# The loop's plan (L21 A2): read-only from the host, validated here, then
# root's, so no session can change what the next night's loop works on.
_staged=/run/devlead/host-plan.yml
_plan="$DEVLEAD_HOME/.devlead/plan.local.yml"
rm -f "$_plan"
if [[ -n "${DEVLEAD_LOOP_PLAN:-}" ]]; then
  [[ -f "$_staged" && ! -L "$_staged" ]] \
    || die "DEVLEAD_LOOP_PLAN is set, but no plan file reached the container — start it with docker compose, which binds that file"
  _ids="$(yq e '.tasks[].id' "$_staged" 2>/dev/null)" && [[ "$(yq e '.tasks | type' "$_staged" 2>/dev/null)" == "!!seq" ]] \
    && [[ -n "$_ids" ]] && ! grep -qxE 'null|[[:space:]]*' <<<"$_ids" \
    || die "DEVLEAD_LOOP_PLAN does not name a plan the loop can read (YAML with a tasks list, each task with an id), so the container does not start"
  install -m 0644 -o root -g root "$_staged" "$_plan" || die "cannot install the loop's plan"
  log "the loop's plan from DEVLEAD_LOOP_PLAN is installed ($(grep -c . <<<"$_ids") task(s)); restart the container after you change it"
fi
if [[ -n "${DEVLEAD_LOOP_REPO:-}" && ! -f "$_plan" ]]; then
  log "WARNING: DEVLEAD_LOOP_REPO is set but there is no plan: the loop job is skipped every night until DEVLEAD_LOOP_PLAN names your plan file (docker/devlead.env.example)"
fi
unset _staged _ids

# The workspace and the clones' directories (S13).
_ws="$(sed -n 's/^WORKSPACE=//p' /etc/devlead/runner.conf)"
mapfile -t _repo_paths < <(grep -v '^#' /etc/devlead/repos | cut -f1 | grep .)
if [[ -n "$_ws" ]] && _is_mount "$_ws"; then
  [[ -d "$_ws" && ! -L "$_ws" ]] || die "DEVLEAD_WORKSPACE is not a directory in the container"
  chown root:root "$_ws" && chmod 0755 "$_ws" || die "cannot take the workspace for root"
  for _i in "${!_repo_paths[@]}"; do
    _clone_dir "$_ws" "${_repo_paths[$_i]}" "$((_i + 1))" \
      || die "the clone directory of DEVLEAD_REPOS entry $((_i + 1)) cannot be prepared, so the container does not start"
  done
elif [[ ${#_repo_paths[@]} -gt 0 ]]; then
  die "DEVLEAD_REPOS lists repos, but nothing is mounted at DEVLEAD_WORKSPACE — compose.yaml mounts the clones volume there; start the container with docker compose"
fi
unset _i

# The fleet list (Inv 3): root's, from DEVLEAD_REPOS only. Without repos there
# is none, and the fleet and discover jobs are skipped.
rm -f "$FLEET_LIST"
if [[ ${#_repo_paths[@]} -gt 0 ]]; then
  printf '%s\n' "${_repo_paths[@]}" > "$FLEET_LIST.new" \
    && chown root:root "$FLEET_LIST.new" && chmod 0644 "$FLEET_LIST.new" \
    && mv -f "$FLEET_LIST.new" "$FLEET_LIST" \
    || die "cannot write the fleet list $FLEET_LIST"
fi

# The claude wrapper's ledger and locks (see docker/claude-wrapper.sh).
_state=/var/lib/devlead
_ledger="$_state/sessions.tsv"
_header="# DevLead session ledger: the claude wrapper appends one line per session start, end or refusal; root writes this line at container start"
install -d -m 0755 -o root -g root "$_state"
chown root:root "$_state" && chmod 0755 "$_state" || die "cannot take $_state for root"
for _lock in "$_state/session.lock" "$_state/job.lock"; do
  if [[ -L "$_lock" || ! -f "$_lock" ]]; then rm -f "$_lock"; install -m 0644 -o root -g root /dev/null "$_lock"; fi
  chown root:root "$_lock"; chmod 0644 "$_lock"
done
if [[ -L "$_ledger" || ! -f "$_ledger" ]]; then
  rm -f "$_ledger"
  install -m 0600 -o "$_uid" -g "$_gid" /dev/null "$_ledger"
fi
_cutoff="$(date -d '-2 days' +%F)"
_tmp="$(mktemp)"
{ printf '%s\n' "$_header"; awk -F'\t' -v c="$_cutoff" '!/^#/ && $1 >= c' "$_ledger"; } > "$_tmp" \
  && cat "$_tmp" > "$_ledger" || die "cannot prepare the session ledger $_ledger"
rm -f "$_tmp"
chown "$_uid:$_gid" "$_ledger"
chmod 0600 "$_ledger"

_as_devlead=(setpriv --reuid="$_uid" --regid="$_gid" --init-groups
             --inh-caps=-all --bounding-set=-all --no-new-privs --
             env HOME="$DEVLEAD_HOME" USER="$DEVLEAD_USER" LOGNAME="$DEVLEAD_USER" SHELL=/bin/bash)

cd "$DEVLEAD_HOME"
"${_as_devlead[@]}" /opt/devlead/docker/run-job.sh --prune >&2 \
  || log "pruning the run transcripts failed (see above); the container starts anyway"
exec "${_as_devlead[@]}" "$@"
