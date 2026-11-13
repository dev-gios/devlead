#!/usr/bin/env bash
# unit-discover-fleet.sh — coverage for .devlead/scripts/discover-fleet.sh and
# the devlead-discover units.
#
#   bash test/unit-discover-fleet.sh
#
# Pins what the scheduled discovery may start: one headless /sweep-discover in
# each enrolled repo that enabled discovery, with permission flags someone
# chose, on verified artifacts — and nothing anywhere else.
#
# SAFETY: the launcher is copied into a sandbox beside a fixture envelope.sh;
# $HOME, the notifier state and the `claude` binary are sandboxed fakes, so no
# session starts and the real ~/.devlead is never read or written.
# shellcheck disable=SC2016 # grep patterns name shell variables literally
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SCRIPTS="$REPO_ROOT/.devlead/scripts"
UNITS="$REPO_ROOT/.devlead/systemd"
SANDBOX="$(mktemp -d /tmp/devlead-discover-fleet.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/home/.devlead/scripts"
CLAUDE_LOG="$SANDBOX/claude.log"
export CLAUDE_LOG
mkdir -p "$BIN" "$SANDBOX/repos" "$SANDBOX/fakebin"
# The launcher must not inherit a developer's knobs.
unset DEVLEAD_LOOP_DRYRUN DEVLEAD_LOOP_CLAUDE_ARGS DEVLEAD_DISCOVER_CLAUDE_ARGS \
      DEVLEAD_CLAUDE_BIN DEVLEAD_ALLOW_DRIFT DEVLEAD_DOCTOR_BIN DEVLEAD_LOOP_REPO

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

cp "$SCRIPTS/discover-fleet.sh" "$SCRIPTS/notify.sh" "$BIN/"
# Fixture envelope: `show` answers from a `.show` file in the repo.
cat > "$BIN/envelope.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "show" ]] || exit 1
if [[ -f .show ]]; then cat .show; else echo "STATUS: blocked"; echo "GAP:    no envelope.yml — repo not enrolled"; fi
EOF
# Fake claude: records where it ran, its arguments and the launcher knobs it
# can see; exits with the code in `.claude-rc` when the repo has one.
cat > "$SANDBOX/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'CWD=%s' "$PWD"; for a in "$@"; do printf '\t%s' "$a"; done
  printf '\tLEAK=%s%s%s\n' "${DEVLEAD_LOOP_CLAUDE_ARGS:-}" "${DEVLEAD_DISCOVER_CLAUDE_ARGS:-}" "${DEVLEAD_ALLOW_DRIFT:-}"; } >> "$CLAUDE_LOG"
[[ -f .claude-rc ]] && exit "$(cat .claude-rc)"
exit 0
EOF
doctor() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$*" > "$SANDBOX/doctor.sh"; }
chmod +x "$BIN"/*.sh "$SANDBOX/fakebin/claude"

# mk_repo <name> <enabled> <discover> — a repo whose envelope shows those values.
mk_repo() {
  local d="$SANDBOX/repos/$1"
  mkdir -p "$d"
  if [[ "$2" != "none" ]]; then
    { echo "STATUS: ok"; echo "ENABLED:           $2"; echo "DISCOVER_ENABLED:  $3"; } > "$d/.show"
  fi
  printf '%s\n' "$d"
}
enroll() { printf '%s\n' "$@" > "$SANDBOX/home/.devlead/autonomous-repos"; }
run() {
  rm -f "$CLAUDE_LOG"
  ( cd "$SANDBOX" && HOME="$SANDBOX/home" DEVLEAD_NOTIFY_DIR="$SANDBOX/home/.devlead" \
      DEVLEAD_CLAUDE_BIN="$SANDBOX/fakebin/claude" DEVLEAD_DOCTOR_BIN="$SANDBOX/doctor.sh" \
      "$@" bash "$BIN/discover-fleet.sh" 2>&1 )
}
calls() { if [[ -f "$CLAUDE_LOG" ]]; then wc -l < "$CLAUDE_LOG" | tr -d ' '; else echo 0; fi; }
inbox() { cat "$SANDBOX/home/.devlead/inbox.tsv" 2>/dev/null; }
clear_inbox() { rm -f "$SANDBOX/home/.devlead/inbox.tsv"; }

ON="$(mk_repo on true true)"
ON2="$(mk_repo on2 true true)"
NODISC="$(mk_repo nodisc true false)"
DISABLED="$(mk_repo disabled false true)"
UNENROLLED="$(mk_repo unenrolled none none)"
FLAGS="--permission-mode default --allowedTools Bash,Read"
doctor '"STATUS: ok"'

# ===========================================================================
# no fleet list -> nothing to do
# ===========================================================================
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"; rc=$?
check "no fleet list: exit 0" "$rc" "0"
check "no fleet list: no session" "$(calls)" "0"

# ===========================================================================
# only repos that enabled discovery are entered
# ===========================================================================
printf '# fleet\n\n%s\r\n%s\n%s\n%s\n%s\n%s\n%s\n' "$ON" "$NODISC" "$DISABLED" "$UNENROLLED" \
  "$SANDBOX/repos/missing" "$ON" "$ON2" > "$SANDBOX/home/.devlead/autonomous-repos"
clear_inbox
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"; rc=$?
check "pass: exit 0" "$rc" "0"
check "pass: one session per opted-in repo, a duplicate entry counted once" "$(calls)" "2"
log="$(cat "$CLAUDE_LOG")"
check "pass: first session runs inside the first repo" "$(sed -n 1p <<<"$log" | cut -f1)" "CWD=$ON"
check "pass: second session runs inside the second repo" "$(sed -n 2p <<<"$log" | cut -f1)" "CWD=$ON2"
check "pass: the command is /sweep-discover and nothing else" "$(sed -n 1p <<<"$log" | cut -f2,3)" "-p"$'\t'"/sweep-discover"
contains "pass: the chosen permission flags are passed" "$log" "--permission-mode"$'\t'"default"$'\t'"--allowedTools"$'\t'"Bash,Read"
check "pass: launcher knobs do not reach the session" "$(grep -c 'LEAK=$' <<<"$log")" "2"
lacks "pass: never enters a repo without discover.enabled" "$log" "CWD=$NODISC"
lacks "pass: never enters a disabled repo" "$log" "CWD=$DISABLED"
lacks "pass: never enters a repo without an envelope" "$log" "CWD=$UNENROLLED"
contains "pass: says why the disabled repo was skipped" "$out" "skipped $DISABLED — envelope is not enabled"
contains "pass: says why the no-discover repo was skipped" "$out" "skipped $NODISC — discover.enabled is not true"
contains "pass: says why the unenrolled repo was skipped" "$out" "skipped $UNENROLLED — envelope not usable"
contains "pass: says why the missing path was skipped" "$out" "missing — not a directory"
contains "pass: summary" "$out" "2 repo(s) explored, 0 failed"
check "pass: one info entry, never a push-level one" "$(inbox | cut -f2,3)" "info"$'\t'"discover-done"

# ===========================================================================
# one session per repository, however the list spells it
# ===========================================================================
git init -q "$ON2"
mkdir -p "$ON2/sub"
ln -s "$ON2" "$SANDBOX/repos/on2-link"
enroll "$ON2" "$ON2/" "$SANDBOX/repos/on2-link" "$ON2/sub" "$SANDBOX/repos/../repos/on2"
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"
check "aliases of one repo: a single session" "$(calls)" "1"
check "aliases of one repo: it runs at the repository root" "$(cut -f1 "$CLAUDE_LOG")" "CWD=$(cd "$ON2" && pwd -P)"

# ===========================================================================
# the real envelope.sh speaks the dialect the launcher reads
# ===========================================================================
if command -v yq &>/dev/null; then
  REAL="$SANDBOX/real/.devlead/scripts"
  mkdir -p "$REAL"
  cp "$SCRIPTS/discover-fleet.sh" "$SCRIPTS/envelope.sh" "$SCRIPTS/bootstrap-lib.sh" "$SCRIPTS/notify.sh" "$REAL/"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/fakebin/gh"; chmod +x "$SANDBOX/fakebin/gh"
  # real_repo <name> <enabled> <discover block or empty>
  real_repo() {
    local d="$SANDBOX/repos/real-$1"
    git init -q "$d"; mkdir -p "$d/.devlead"
    { echo "version: 1"; echo "enabled: $2"
      echo "select:"; echo "  bucket: nuevo-entrante"; echo "  exclude_labels: [blocked, discuss]"; echo "  require_readiness: true"
      echo "order:"; echo "  by: [priority-label, created-asc]"
      echo "budget:"; echo "  max_issues: 3"; echo "  stop_at: null"
      echo "base:"; echo "  strategy: nearest-tag"
      [[ -n "$3" ]] && printf '%s\n' "$3"
      echo "forbidden_zones: inherit"
      echo "on_failure:"; echo "  policy: park-and-continue"; echo "  skip_dependents: true"
      echo "merge:"; echo "  mode: never"
      echo "report:"; echo "  to: journal-per-repo"; } > "$d/.devlead/envelope.yml"
    (cd "$d" && pwd -P)
  }
  DISC=$'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src/auth\n      spec: docs/auth.md'
  R_ON="$(real_repo on true "$DISC")"
  R_OFF="$(real_repo off true $'discover:\n  enabled: false')"
  R_NONE="$(real_repo none true "")"
  R_DISABLED="$(real_repo disabled false "$DISC")"
  enroll "$R_OFF" "$R_NONE" "$R_DISABLED" "$R_ON"
  rm -f "$CLAUDE_LOG"
  out="$( cd "$SANDBOX" && HOME="$SANDBOX/home" DEVLEAD_NOTIFY_DIR="$SANDBOX/home/.devlead" PATH="$SANDBOX/fakebin:$PATH" \
      DEVLEAD_CLAUDE_BIN="$SANDBOX/fakebin/claude" DEVLEAD_DOCTOR_BIN="$SANDBOX/doctor.sh" \
      DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS" bash "$REAL/discover-fleet.sh" 2>&1 )"
  check "real envelope: only the opted-in repo gets a session" "$(cut -f1 "$CLAUDE_LOG" 2>/dev/null)" "CWD=$R_ON"
  contains "real envelope: discover off is skipped" "$out" "skipped $R_OFF — discover.enabled is not true"
  contains "real envelope: no discover block is skipped" "$out" "skipped $R_NONE — discover.enabled is not true"
  contains "real envelope: a disabled envelope is skipped" "$out" "skipped $R_DISABLED — envelope is not enabled"
else
  echo "SKIP  yq not available — real envelope dialect not exercised"
fi

# ===========================================================================
# the narrower discover flags win over the loop's
# ===========================================================================
enroll "$ON"
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="--loop-flag" DEVLEAD_DISCOVER_CLAUDE_ARGS="--discover-flag")"
log="$(cat "$CLAUDE_LOG")"
contains "discover flags: used" "$log" "--discover-flag"
lacks "discover flags: the loop's are not added" "$log" "--loop-flag"

# ===========================================================================
# no permission flags -> refuses, and says so
# ===========================================================================
clear_inbox
out="$(run)"; rc=$?
check "no flags: exit 1" "$rc" "1"
check "no flags: no session" "$(calls)" "0"
contains "no flags: explains" "$out" "refusing to invoke"
check "no flags: reaches the human" "$(inbox | cut -f2,3)" "need"$'\t'"discover-no-permissions"

# A machine where nobody opted in is not nagged about flags it does not need.
enroll "$NODISC" "$DISABLED"
clear_inbox
out="$(run)"; rc=$?
check "nobody opted in, no flags: exit 0" "$rc" "0"
check "nobody opted in, no flags: nothing in the inbox" "$(inbox | wc -l | tr -d ' ')" "0"
check "nobody opted in: no session" "$(calls)" "0"

# ===========================================================================
# artifacts that do not verify as the trunk -> refuses
# ===========================================================================
enroll "$ON"
for case in '"STATUS: drifted"' '"STATUS: unknown"' '"STATUS: ok" "NOTE: matches a branch, not the trunk"' '"garbage"'; do
  doctor "$case"
  clear_inbox
  out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"; rc=$?
  check "doctor $case: exit 1" "$rc" "1"
  check "doctor $case: no session" "$(calls)" "0"
  check "doctor $case: reaches the human" "$(inbox | cut -f2,3)" "need"$'\t'"discover-drift"
done
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS" DEVLEAD_ALLOW_DRIFT=1)"; rc=$?
check "drift override: runs" "$(calls)" "1"
contains "drift override: is loud about it" "$out" "DEVLEAD_ALLOW_DRIFT=1 — PROCEEDING"
doctor '"STATUS: ok"'

# ===========================================================================
# a failing session is reported, not retried, and does not stop the pass
# ===========================================================================
echo 3 > "$ON/.claude-rc"
enroll "$ON" "$ON2"
clear_inbox
out="$(run env DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"; rc=$?
check "failing session: the pass still exits 0" "$rc" "0"
check "failing session: one attempt per repo, the next repo still runs" "$(calls)" "2"
contains "failing session: reported with its exit code" "$out" "$ON — session exited 3 (not retried)"
contains "failing session: summary counts it" "$out" "2 repo(s) explored, 1 failed"
check "failing session: inbox says so" "$(inbox | cut -f2,3)" "info"$'\t'"discover-failed"
rm -f "$ON/.claude-rc"

# ===========================================================================
# dry run -> shows the command, starts nothing, tells nobody
# ===========================================================================
clear_inbox
out="$(run env DEVLEAD_LOOP_DRYRUN=1 DEVLEAD_LOOP_CLAUDE_ARGS="$FLAGS")"; rc=$?
check "dry run: exit 0" "$rc" "0"
check "dry run: no session" "$(calls)" "0"
contains "dry run: names the repo" "$out" "in $ON would run:"
contains "dry run: shows the command and flags" "$out" "-p \"/sweep-discover\" $FLAGS"
check "dry run: nothing in the inbox" "$(inbox | wc -l | tr -d ' ')" "0"
out="$(run env DEVLEAD_LOOP_DRYRUN=1)"
contains "dry run without flags: says a real run would refuse" "$out" "a real run refuses to start"

# ===========================================================================
# the launcher itself has no way to change a repo or GitHub
# ===========================================================================
src="$(grep -v '^[[:space:]]*#' "$SCRIPTS/discover-fleet.sh")"
check "launcher runs no gh" "$(grep -cE '(^|[^[:alnum:]_.-])gh[[:space:]]' <<<"$src")" "0"
check "launcher runs no mutating git verb" "$(grep -cE 'git[[:space:]]+(commit|push|checkout|switch|merge|branch|reset|add)' <<<"$src")" "0"
check "launcher has exactly one place that starts a session" "$(grep -c -- '"\$CLAUDE_BIN" -p ' <<<"$src")" "1"
check "that place dispatches /sweep-discover" "$(grep -c -- '"\$CLAUDE_BIN" -p "/sweep-discover" ' <<<"$src")" "1"
check "no other slash command is named anywhere in the launcher" "$(grep -oE '/sweep-[a-z]+|/batch|/arranquemos' <<<"$src" | sort -u)" "/sweep-discover"
check "launcher never writes the envelope or the fleet list" \
  "$(grep -cE '(>|>>|tee|sed -i|rm|mv|cp)[^|]*(envelope\.yml|autonomous-repos|REPOS_FILE)' <<<"$src")" "0"

# ===========================================================================
# the units
# ===========================================================================
svc="$(grep -v '^[[:space:]]*#' "$UNITS/devlead-discover.service")"
tmr="$(grep -v '^[[:space:]]*#' "$UNITS/devlead-discover.timer")"
if command -v systemd-analyze &>/dev/null; then
  HOME="$SANDBOX/home" systemd-analyze verify "$UNITS/devlead-discover.service" >"$SANDBOX/svc.log" 2>&1
  check "systemd-analyze verify passes on the service" "$?" "0"
  [[ -s "$SANDBOX/svc.log" ]] && cat "$SANDBOX/svc.log"
  HOME="$SANDBOX/home" systemd-analyze verify "$UNITS/devlead-discover.timer" >"$SANDBOX/tmr.log" 2>&1
  check "systemd-analyze verify passes on the timer" "$?" "0"
  [[ -s "$SANDBOX/tmr.log" ]] && cat "$SANDBOX/tmr.log"
else
  echo "SKIP  systemd-analyze not available — unit syntax not verified"
fi
check "service: runs the launcher and nothing else" "$(grep '^ExecStart=' <<<"$svc")" "ExecStart=%h/.devlead/scripts/discover-fleet.sh"
contains "service: skipped without a fleet list" "$svc" "ConditionPathExists=%h/.devlead/autonomous-repos"
contains "service: waits for an unattended run still working the repos" "$svc" "After=devlead-loop.service devlead-fleet.service"
for other in devlead-loop.service devlead-fleet.service; do
  lacks "no ordering cycle: $other does not wait for discovery" "$(grep -v '^[[:space:]]*#' "$UNITS/$other")" "devlead-discover"
done
contains "service: flags come from the documented env file" "$svc" "EnvironmentFile=-%h/.devlead/loop.env"
contains "timer: weekly" "$tmr" "OnCalendar=Mon "
contains "timer: does not catch up missed runs" "$tmr" "Persistent=false"
contains "timer: drives the discover service" "$tmr" "Unit=devlead-discover.service"

lib="$(cat "$SCRIPTS/bootstrap-lib.sh")"
contains "the launcher is published" "$lib" "discover-fleet.sh|"
contains "the service is published" "$lib" "devlead-discover.service|"
contains "the timer is published" "$lib" "devlead-discover.timer|"
check "nothing but the interactive menu enables the timer" \
  "$(grep -lE 'enable.*devlead-discover' "$SCRIPTS"/*.sh "$REPO_ROOT/install.sh" | wc -l | tr -d ' ')" "0"
contains "devlead config offers the timer" "$(cat "$SCRIPTS/config.sh")" "_machine_toggle_timer devlead-discover.timer"
contains "uninstall disables the timer" "$(cat "$REPO_ROOT/uninstall.sh")" "disable --now devlead-discover.timer"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
