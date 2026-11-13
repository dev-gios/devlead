#!/usr/bin/env bash
# discover-fleet.sh — headless /sweep-discover over every enrolled repo that
# asked for it.
#
# Usage: discover-fleet.sh
#
# /sweep-discover works on ONE repo, the one it is started in. This is the
# outer loop a timer needs: for each repo listed in ~/.devlead/autonomous-repos
# whose envelope says `enabled: true` AND `discover.enabled: true`, it starts
# one headless session there. A repo that did not opt in is never entered.
#
# What a discover run can do is decided by the command, not here: it explores
# the modules the envelope declares and files issues carrying
# `discover.label`. It creates no branch and opens no PR, and the label keeps
# those issues out of every work queue until a human reviews them
# (GOVERNANCE.md §sweep-discover-profile, the two-night cycle). This script
# adds no authority: it reads the envelope and starts the command.
#
# One attempt per repo, never a retry: a second pass over the same module
# could file the same gap twice. A repo whose session fails is reported and
# the run goes on with the next one.
#
# Like sweep-loop.sh, it refuses to start a session
#   - without permission flags someone chose (no ambient permissions), and
#   - when the installed DevLead artifacts do not verify as the reviewed trunk
#     (doctor.sh: STATUS ok with no provenance NOTE).
# Both refusals reach the human through notify.sh.
#
# Environment:
#   DEVLEAD_LOOP_DRYRUN=1          print what would run per repo; invoke nothing
#   DEVLEAD_DISCOVER_CLAUDE_ARGS   permission flags for the headless session,
#                                  whitespace-separated. Discover only reads
#                                  the repo and files issues, so this can be
#                                  narrower than the loop's flags, e.g.
#                                  "--permission-mode default --allowedTools Bash,Read,Glob,Grep"
#   DEVLEAD_LOOP_CLAUDE_ARGS       used when the variable above is not set
#   DEVLEAD_CLAUDE_BIN             claude binary (default: claude)
#   DEVLEAD_ALLOW_DRIFT=1          supervised development only: run despite a
#                                  failed doctor check
#   DEVLEAD_DOCTOR_BIN             doctor script (default: doctor.sh beside this one)
#
# Exit codes: 0 the pass ran (per-repo failures are reported, not fatal), or
# there was nothing to do · 1 refused to start (no permission flags, drift).

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$HOME/.devlead/autonomous-repos"
ENVELOPE_SH="$_SCRIPT_DIR/envelope.sh"
DOCTOR_BIN="${DEVLEAD_DOCTOR_BIN:-$_SCRIPT_DIR/doctor.sh}"
CLAUDE_BIN="${DEVLEAD_CLAUDE_BIN:-claude}"
DRYRUN="${DEVLEAD_LOOP_DRYRUN:-0}"

_CLAUDE_ARGS=()
read -ra _CLAUDE_ARGS <<<"${DEVLEAD_DISCOVER_CLAUDE_ARGS:-${DEVLEAD_LOOP_CLAUDE_ARGS:-}}"

# Launcher-only knobs: the session and everything it runs must not inherit
# them (same reasoning as sweep-loop.sh's _LAUNCHER_ONLY_VARS).
_ENV_STRIP=()
for _v in DEVLEAD_LOOP_DRYRUN DEVLEAD_LOOP_MAX DEVLEAD_LOOP_SLEEP DEVLEAD_LOOP_STALL \
          DEVLEAD_CLAUDE_BIN DEVLEAD_LOOP_CLAUDE_ARGS DEVLEAD_DISCOVER_CLAUDE_ARGS \
          DEVLEAD_LOOP_REPO DEVLEAD_ALLOW_DRIFT DEVLEAD_DOCTOR_BIN; do
  _ENV_STRIP+=(-u "$_v")
done
unset _v

# Never in a dry run (nothing happened), and never able to change this
# script's outcome: a missing or failing notify.sh is ignored.
_notify() {
  [[ "$DRYRUN" == "1" ]] && return 0
  [[ -f "$_SCRIPT_DIR/notify.sh" ]] || return 0
  bash "$_SCRIPT_DIR/notify.sh" send "$1" "$2" "$3" >/dev/null 2>&1 || true
  return 0
}

if [[ ! -f "$REPOS_FILE" ]]; then
  echo "discover-fleet: no repos enrolled ($REPOS_FILE missing) — nothing to do"
  exit 0
fi

# --- Which repos asked for discovery ---------------------------------------
# Read-only: `envelope.sh show` never writes. Decided before any refusal
# below, so a machine where no repo opted in stays silent instead of
# complaining every week about flags it does not need.
_targets=()
declare -A _seen=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  _line="${_line%$'\r'}"
  [[ -z "${_line//[[:space:]]/}" || "$_line" == \#* ]] && continue
  if [[ ! -d "$_line" ]]; then
    echo "discover-fleet: skipped $_line — not a directory"
    continue
  fi
  # One session per REPOSITORY, however the list spells it: a trailing slash,
  # a symlink, a relative path or a subdirectory of an entry already seen all
  # name the same repo, and exploring it twice could file the same gap twice.
  _root="$(cd "$_line" && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })"
  if [[ -z "$_root" || ! -d "$_root" ]]; then
    echo "discover-fleet: skipped $_line — cannot resolve its location"
    continue
  fi
  [[ -n "${_seen[$_root]+_}" ]] && continue
  _seen["$_root"]=1
  _line="$_root"
  _show="$(cd "$_line" && bash "$ENVELOPE_SH" show 2>/dev/null </dev/null)"
  if ! grep -q '^STATUS: ok' <<<"$_show"; then
    echo "discover-fleet: skipped $_line — envelope not usable ($(grep -m1 '^GAP:' <<<"$_show" | sed 's/^GAP:[[:space:]]*//' || true))"
    continue
  fi
  if ! grep -q '^ENABLED:[[:space:]]*true$' <<<"$_show"; then
    echo "discover-fleet: skipped $_line — envelope is not enabled"
    continue
  fi
  if ! grep -q '^DISCOVER_ENABLED:[[:space:]]*true$' <<<"$_show"; then
    echo "discover-fleet: skipped $_line — discover.enabled is not true"
    continue
  fi
  _targets+=("$_line")
done < "$REPOS_FILE"

if [[ ${#_targets[@]} -eq 0 ]]; then
  echo "discover-fleet: no enrolled repo has discovery enabled — nothing to do"
  exit 0
fi

if [[ "$DRYRUN" == "1" ]]; then
  for _repo in "${_targets[@]}"; do
    echo "discover-fleet: [dry-run] in $_repo would run:"
    if [[ ${#_CLAUDE_ARGS[@]} -gt 0 ]]; then
      echo "  $CLAUDE_BIN -p \"/sweep-discover\" ${_CLAUDE_ARGS[*]}"
    else
      echo "  $CLAUDE_BIN -p \"/sweep-discover\" <no permission flags set: a real run refuses to start>"
    fi
  done
  echo "discover-fleet: [dry-run] nothing was invoked"
  exit 0
fi

# --- Explicit permissions ---------------------------------------------------
if [[ ${#_CLAUDE_ARGS[@]} -eq 0 ]]; then
  {
    echo "discover-fleet: no permission flags set — refusing to invoke $CLAUDE_BIN with ambient permissions"
    echo "discover-fleet: set DEVLEAD_DISCOVER_CLAUDE_ARGS (or DEVLEAD_LOOP_CLAUDE_ARGS) in ~/.devlead/loop.env"
    echo "discover-fleet: preview the exact command with DEVLEAD_LOOP_DRYRUN=1"
  } >&2
  _notify need discover-no-permissions "no permission flags in ~/.devlead/loop.env — the scheduled discovery did not run"
  exit 1
fi

# --- Drift guard ------------------------------------------------------------
# Same bar as sweep-loop.sh: doctor.sh must match the installed artifacts to
# the trunk itself — STATUS ok and no provenance NOTE.
_doctor_out="$(bash "$DOCTOR_BIN" 2>&1)"
_doctor_status="$(grep -m1 '^STATUS: ' <<<"$_doctor_out" | sed 's/^STATUS: //')"
if [[ "$_doctor_status" != "ok" ]] || grep -q '^NOTE:' <<<"$_doctor_out"; then
  if [[ "${DEVLEAD_ALLOW_DRIFT:-0}" == "1" ]]; then
    {
      echo "discover-fleet: DEVLEAD_ALLOW_DRIFT=1 — PROCEEDING with artifacts that do not verify as the reviewed trunk:"
      echo "$_doctor_out"
    } >&2
  else
    _reason="the installed DevLead artifacts do not verify as the reviewed trunk (doctor.sh STATUS: ${_doctor_status:-unreadable}) — refusing to run unattended"
    {
      echo "discover-fleet: $_reason"
      echo "$_doctor_out"
      echo "discover-fleet: remedy: bring the DevLead checkout to its trunk and run install.sh again"
    } >&2
    _notify need discover-drift "$_reason"
    exit 1
  fi
fi

# --- One session per repo ---------------------------------------------------
_ran=0
_failed=0
for _repo in "${_targets[@]}"; do
  echo "discover-fleet: $_repo — invoking $CLAUDE_BIN"
  ( cd "$_repo" && env "${_ENV_STRIP[@]}" "$CLAUDE_BIN" -p "/sweep-discover" "${_CLAUDE_ARGS[@]}" </dev/null )
  _rc=$?
  _ran=$((_ran + 1))
  if [[ "$_rc" -ne 0 ]]; then
    _failed=$((_failed + 1))
    echo "discover-fleet: $_repo — session exited $_rc (not retried)" >&2
  fi
done

echo "discover-fleet: done — $_ran repo(s) explored, $_failed failed"
if [[ "$_failed" -gt 0 ]]; then
  _notify info discover-failed "$_failed of $_ran discovery session(s) exited non-zero — see the unit's journal"
else
  _notify info discover-done "$_ran repo(s) explored — new issues carry the discover label and wait for your review"
fi
exit 0
