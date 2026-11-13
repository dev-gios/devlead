#!/usr/bin/env bash
# unit-loop-units.sh — the headless loop's systemd units
#
#   bash test/unit-loop-units.sh
#
# systemd-analyze expands %h from $HOME, so the units are verified against a
# throwaway /tmp home holding a stand-in sweep-loop.sh. That checks the unit
# itself rather than whether this machine happens to have run install.sh.
#
# SAFETY: no unit is installed, enabled or started. Nothing under the real
# ~/.config/systemd or ~/.devlead is read or written.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
UNITS="$REPO_ROOT/.devlead/systemd"
SANDBOX="$(mktemp -d /tmp/devlead-loopunits.XXXXXX)"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected substring: [$3]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

lacks() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        unexpected substring: [$3]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

svc="$(cat "$UNITS/devlead-loop.service")"
tmr="$(cat "$UNITS/devlead-loop.timer")"

# --- systemd-analyze verify, against a home where the script exists --------
if command -v systemd-analyze &>/dev/null; then
  mkdir -p "$SANDBOX/.devlead/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/.devlead/scripts/sweep-loop.sh"
  chmod +x "$SANDBOX/.devlead/scripts/sweep-loop.sh"
  touch "$SANDBOX/.devlead/plan.local.yml"

  HOME="$SANDBOX" systemd-analyze verify "$UNITS/devlead-loop.service" >"$SANDBOX/svc.log" 2>&1
  check "systemd-analyze verify passes on the service" "$?" "0"
  [[ -s "$SANDBOX/svc.log" ]] && cat "$SANDBOX/svc.log"

  HOME="$SANDBOX" systemd-analyze verify "$UNITS/devlead-loop.timer" >"$SANDBOX/tmr.log" 2>&1
  check "systemd-analyze verify passes on the timer" "$?" "0"
  [[ -s "$SANDBOX/tmr.log" ]] && cat "$SANDBOX/tmr.log"
else
  echo "SKIP  systemd-analyze not available — unit syntax not verified"
fi

# --- The service points at the loop, not at anything else ------------------
contains "ExecStart runs sweep-loop.sh" "$svc" "sweep-loop.sh"
contains "ExecStart passes a plan" "$svc" "--plan"
contains "no plan means the unit is skipped, not failed" "$svc" "ConditionPathExists"
contains "the loop is not killed by the oneshot timeout" "$svc" "TimeoutStartSec=infinity"

# --- FIX 7: an explicit WorkingDirectory replaces the implicit $HOME default,
# and the real target repo comes from a documented, user-controlled env file
# (never silently from $HOME) ------------------------------------------------
contains "the service declares an explicit WorkingDirectory" "$svc" "WorkingDirectory="
contains "the target repo is sourced from a documented env file" "$svc" "EnvironmentFile=-%h/.devlead/loop.env"
contains "the env file documents DEVLEAD_LOOP_REPO" "$svc" "DEVLEAD_LOOP_REPO"

# --- The timer must NOT catch up a missed night ----------------------------
# devlead-sweep.timer is plan-only and read-only, so Persistent=true is free
# there. This one creates branches, commits and PRs: firing a missed run the
# moment the laptop opens is exactly the surprise the design avoids.
contains "timer declares Persistent explicitly" "$tmr" "Persistent="
lacks "timer does NOT catch up missed runs" "$tmr" "Persistent=true"
contains "timer drives the loop service" "$tmr" "Unit=devlead-loop.service"

# --- The pre-existing plan-only sweep unit is untouched --------------------
sweep_svc="$(cat "$UNITS/devlead-sweep.service")"
contains "devlead-sweep.service is still plan-only" "$sweep_svc" "plan-only"
contains "devlead-sweep.service still runs sweep.sh" "$sweep_svc" "sweep.sh"
lacks "devlead-sweep.service was not repointed at the loop" "$sweep_svc" "sweep-loop.sh"

# --- Both units are published by bootstrap_systemd -------------------------
lib="$(cat "$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh")"
contains "the loop service is in the publish table" "$lib" "devlead-loop.service|"
contains "the loop timer is in the publish table" "$lib" "devlead-loop.timer|"

# ===========================================================================
# devlead-fleet — the plan-driven run over every enrolled repo
# ===========================================================================
fsvc="$(cat "$UNITS/devlead-fleet.service")"
ftmr="$(cat "$UNITS/devlead-fleet.timer")"
# Directives only: the comments explain alternatives the unit must not use.
fsvc_code="$(grep -v '^[[:space:]]*#' <<<"$fsvc")"
ftmr_code="$(grep -v '^[[:space:]]*#' <<<"$ftmr")"

if command -v systemd-analyze &>/dev/null; then
  touch "$SANDBOX/.devlead/autonomous-repos"
  HOME="$SANDBOX" systemd-analyze verify "$UNITS/devlead-fleet.service" >"$SANDBOX/fsvc.log" 2>&1
  check "systemd-analyze verify passes on the fleet service" "$?" "0"
  [[ -s "$SANDBOX/fsvc.log" ]] && cat "$SANDBOX/fsvc.log"
  HOME="$SANDBOX" systemd-analyze verify "$UNITS/devlead-fleet.timer" >"$SANDBOX/ftmr.log" 2>&1
  check "systemd-analyze verify passes on the fleet timer" "$?" "0"
  [[ -s "$SANDBOX/ftmr.log" ]] && cat "$SANDBOX/ftmr.log"
fi

check "fleet: exactly one ExecStart" "$(grep -c '^ExecStart=' <<<"$fsvc_code")" "1"
check "fleet: runs the loop in fleet mode, one pass" "$(grep '^ExecStart=' <<<"$fsvc_code")" \
  "ExecStart=%h/.devlead/scripts/sweep-loop.sh --max-iterations 1 -- --fleet"
lacks "fleet: takes no plan file" "$fsvc_code" "--plan"
contains "fleet: no fleet list means the unit is skipped, not failed" "$fsvc_code" \
  "ConditionPathExists=%h/.devlead/autonomous-repos"
contains "fleet: waits for a plan loop that is still running" "$fsvc_code" "After=devlead-loop.service"
lacks "fleet: the plan loop does not wait back (no ordering cycle)" \
  "$(grep -v '^[[:space:]]*#' "$UNITS/devlead-loop.service")" "devlead-fleet"
contains "fleet: not killed by the oneshot timeout" "$fsvc_code" "TimeoutStartSec=infinity"
contains "fleet: permission flags come from the documented env file" "$fsvc_code" "EnvironmentFile=-%h/.devlead/loop.env"
contains "fleet: explicit WorkingDirectory" "$fsvc_code" "WorkingDirectory=%h/.devlead"
contains "fleet timer: Persistent declared" "$ftmr_code" "Persistent=false"
lacks "fleet timer: does NOT catch up missed runs" "$ftmr_code" "Persistent=true"
contains "fleet timer: drives the fleet service" "$ftmr_code" "Unit=devlead-fleet.service"
# String comparison is enough: both are zero-padded HH:MM:SS.
loop_at="$(sed -n 's/^OnCalendar=\*-\*-\* //p' "$UNITS/devlead-loop.timer")"
fleet_at="$(sed -n 's/^OnCalendar=\*-\*-\* //p' <<<"$ftmr_code")"
check "fleet timer: fires after the plan loop, as After= assumes" "$([[ "$fleet_at" > "$loop_at" ]] && echo later)" "later"

# The dry run shows what the unit would invoke, without invoking it.
dry="$(cd "$SANDBOX" && DEVLEAD_LOOP_DRYRUN=1 bash "$REPO_ROOT/.devlead/scripts/sweep-loop.sh" --max-iterations 1 -- --fleet 2>&1)"; rc=$?
check "fleet dry run: exit 0 outside any repo" "$rc" "0"
contains "fleet dry run: dispatches /sweep-execute --fleet" "$dry" '-p "/sweep-execute --fleet"'
check "fleet dry run: a single iteration" "$(grep -c 'would run' <<<"$dry")" "1"

contains "the fleet service is in the publish table" "$lib" "devlead-fleet.service|"
contains "the fleet timer is in the publish table" "$lib" "devlead-fleet.timer|"

# Publishing never enables: only the human does, through `devlead config`.
check "bootstrap never enables the fleet timer" \
  "$(grep -cE 'systemctl.*enable.*devlead-fleet' "$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/.devlead/scripts/envelope.sh" | awk -F: '{ n += $2 } END { print n + 0 }')" "0"
cfg="$(cat "$REPO_ROOT/.devlead/scripts/config.sh")"
contains "devlead config offers the fleet timer" "$cfg" "_machine_toggle_timer devlead-fleet.timer"
check "the fleet timer is toggled from the interactive menu only" \
  "$(grep -lE 'enable.*devlead-fleet' "$REPO_ROOT"/.devlead/scripts/*.sh | wc -l | tr -d ' ')" "0"
contains "uninstall disables the fleet timer" "$(cat "$REPO_ROOT/uninstall.sh")" "disable --now devlead-fleet.timer"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
