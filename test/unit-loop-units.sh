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

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
