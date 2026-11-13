#!/usr/bin/env bash
# unit-journal.sh — coverage for .devlead/scripts/journal.sh
#
#   bash test/unit-journal.sh
#
# Pins the one promise of the script: closing a day never destroys the entry
# of the day before, and a save that cannot complete leaves the current entry
# untouched.
#
# SAFETY: DEVLEAD_JOURNAL_DIR points at a sandbox; the real journals are never
# read or written.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
JOURNAL="$REPO_ROOT/.devlead/scripts/journal.sh"
SANDBOX="$(mktemp -d /tmp/devlead-journal.XXXXXX)"
trap 'cd /tmp && chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
export DEVLEAD_JOURNAL_DIR="$SANDBOX/journals"

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

REPO="$SANDBOX/proj"
git init -q "$REPO"
cd "$REPO" || exit 1
REPO="$(git rev-parse --show-toplevel)"
CURRENT="$DEVLEAD_JOURNAL_DIR/${REPO//\//_}.md"
HISTORY="$DEVLEAD_JOURNAL_DIR/${REPO//\//_}.history.md"

entry() { printf '# DevLead Journal — %s\n\n## Qué avanzó\n%s\n' "$1" "$2"; }

# ===========================================================================
# path — the key the commands have always used
# ===========================================================================
check "path: same key as the commands" "$(bash "$JOURNAL" path)" "$CURRENT"

# ===========================================================================
# history before anything exists
# ===========================================================================
check "history: empty when nothing was archived" "$(bash "$JOURNAL" history)" "STATUS: empty"

# ===========================================================================
# first save — nothing to archive
# ===========================================================================
out="$(entry 2026-11-10 "day one" | bash "$JOURNAL" save)"; rc=$?
check "first save: exit 0" "$rc" "0"
contains "first save: reports saved" "$out" "STATUS: saved"
contains "first save: reports the path" "$out" "PATH: $CURRENT"
contains "first save: entry written" "$(cat "$CURRENT")" "day one"
check "first save: no history file yet" "$([[ -e "$HISTORY" ]] && echo yes || echo no)" "no"

# ===========================================================================
# second and third save — previous entries are archived, in order
# ===========================================================================
entry 2026-11-11 "day two" | bash "$JOURNAL" save >/dev/null
contains "second save: current is the new entry" "$(cat "$CURRENT")" "day two"
lacks    "second save: current no longer holds the old entry" "$(cat "$CURRENT")" "day one"
contains "second save: old entry archived" "$(cat "$HISTORY")" "day one"

entry 2026-11-12 "day three" | bash "$JOURNAL" save >/dev/null
hist="$(bash "$JOURNAL" history)"
contains "history: reports ok" "$hist" "STATUS: ok"
contains "history: counts archived entries" "$hist" "ENTRIES: 2"
contains "history: holds day one" "$hist" "day one"
contains "history: holds day two" "$hist" "day two"
lacks    "history: the current entry is not history yet" "$hist" "day three"

last="$(bash "$JOURNAL" history 1)"
contains "history 1: newest archived entry" "$last" "day two"
lacks    "history 1: older entry left out" "$last" "day one"
contains "history N larger than total: everything" "$(bash "$JOURNAL" history 50)" "day one"

# ===========================================================================
# refused saves leave everything as it was
# ===========================================================================
before_cur="$(cat "$CURRENT")"; before_hist="$(cat "$HISTORY")"
out="$(printf '   \n\n' | bash "$JOURNAL" save 2>&1)"; rc=$?
check    "empty entry: exit 1" "$rc" "1"
contains "empty entry: says why" "$out" "empty entry"
check    "empty entry: current untouched" "$(cat "$CURRENT")" "$before_cur"
check    "empty entry: history untouched" "$(cat "$HISTORY")" "$before_hist"

chmod a-w "$HISTORY"
out="$(entry 2026-11-13 "day four" | bash "$JOURNAL" save 2>&1)"; rc=$?
chmod u+w "$HISTORY"
if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP  unwritable history (running as root)"
else
  check    "unwritable history: exit 1" "$rc" "1"
  contains "unwritable history: says nothing was saved" "$out" "nothing saved"
  check    "unwritable history: current untouched" "$(cat "$CURRENT")" "$before_cur"
fi

# ===========================================================================
# misuse
# ===========================================================================
bash "$JOURNAL" history 0 >/dev/null 2>&1;   check "history 0: exit 1" "$?" "1"
bash "$JOURNAL" history abc >/dev/null 2>&1; check "history abc: exit 1" "$?" "1"
bash "$JOURNAL" bogus >/dev/null 2>&1;       check "unknown subcommand: exit 1" "$?" "1"
bash "$JOURNAL" >/dev/null 2>&1;             check "no subcommand: exit 1" "$?" "1"

# ===========================================================================
# two repositories never share a journal
# ===========================================================================
OTHER="$SANDBOX/other"
git init -q "$OTHER"
( cd "$OTHER" && entry 2026-11-12 "other repo" | bash "$JOURNAL" save >/dev/null )
lacks "isolation: this repo's journal holds no other repo's entry" "$(cat "$CURRENT")" "other repo"

echo
echo "unit-journal: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
