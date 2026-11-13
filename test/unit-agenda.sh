#!/usr/bin/env bash
# unit-agenda.sh — coverage for .devlead/scripts/agenda.sh
#
#   bash test/unit-agenda.sh
#
# Pins the promise of the script: the human can reorder or skip what DevLead
# planned for the day, and no adjustment can ever put an issue in front of a
# run that the envelope policy did not put in its queue.
#
# SAFETY: DEVLEAD_AGENDA_DIR points at a sandbox; the real agenda is never
# read or written.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
AGENDA="$REPO_ROOT/.devlead/scripts/agenda.sh"
SANDBOX="$(mktemp -d /tmp/devlead-agenda.XXXXXX)"
trap 'cd /tmp && chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
export DEVLEAD_AGENDA_DIR="$SANDBOX/agenda"
export DEVLEAD_AGENDA_DATE="2026-11-13"

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
STATE="$DEVLEAD_AGENDA_DIR/$(printf '%s' "$REPO" | sha256sum | cut -c1-20)"

# plan <included lines...> — an `envelope.sh plan` result with that queue.
plan() {
  echo "=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ==="
  echo "ORDER: priority,created  MAX_ISSUES: 5  EXCLUDE_LABELS: blocked  READINESS: false"
  echo ""
  echo "--- INCLUDED (queue order) ---"
  if [[ $# -eq 0 ]]; then echo "(none)"; fi
  local i=1 line
  for line in "$@"; do
    printf '%d. %s\n' "$i" "$line"
    echo "   basis: tier=none, created=2026-11-01, nuevo-entrante  [zone-check: pre-check only, labels-based]"
    i=$((i + 1))
  done
  echo ""
  echo "--- EXCLUDED ---"
  echo "#99  Left out   reason: label blocked"
  echo ""
  echo "=== END PLAN ==="
}
queue_of() { sed -n 's/^QUEUE: //p' <<<"$1"; }
skipped_of() { sed -n 's/^SKIPPED: //p' <<<"$1"; }
state_hash() { find "$STATE" -type f ! -name '.tmp-*' -exec sha256sum {} + 2>/dev/null | sort | sha256sum; }

# ===========================================================================
# before anything is published
# ===========================================================================
check "show: nothing published yet" "$(bash "$AGENDA" show)" "STATUS: none"
out="$(printf '12\n15\n' | bash "$AGENDA" apply)"; rc=$?
check "apply without an agenda: exit 0" "$rc" "0"
contains "apply without an agenda: unchanged" "$out" "STATUS: unchanged"
check "apply without an agenda: queue is the input" "$(queue_of "$out")" "12 15"
out="$(bash "$AGENDA" skip 12 2>&1)"; rc=$?
check "skip without an agenda: exit 1" "$rc" "1"
contains "skip without an agenda: says why" "$out" "STATUS: not-on-agenda"

# ===========================================================================
# publish
# ===========================================================================
out="$(plan '#12  Fix login' '#15  "Docs: update guide"' '#20  Add export' | bash "$AGENDA" publish)"; rc=$?
check "publish: exit 0" "$rc" "0"
contains "publish: reports published" "$out" "STATUS: published"
contains "publish: reports the day" "$out" "DATE: 2026-11-13"
contains "publish: counts the queue" "$out" "COUNT: 3"
check "publish: one line per included issue" "$(wc -l < "$STATE/agenda.tsv" | tr -d ' ')" "3"
check "publish: stores number and title" "$(sed -n 1p "$STATE/agenda.tsv")" "2026-11-13"$'\t'"12"$'\t'"Fix login"
check "publish: a quoted title is stored without its quotes" "$(sed -n 2p "$STATE/agenda.tsv" | cut -f3)" "Docs: update guide"
lacks "publish: an excluded issue is not on the agenda" "$(cat "$STATE/agenda.tsv")" "99"
check "publish: records which repo the key stands for" "$(cat "$STATE/repo")" "$REPO"

out="$(bash "$AGENDA" show)"
contains "show: ok" "$out" "STATUS: ok"
contains "show: first position" "$out" "1. #12  Fix login"
contains "show: third position" "$out" "3. #20  Add export"
lacks "show: nothing skipped" "$out" "SKIPPED"

# ===========================================================================
# publish refuses what is not a plan, and changes nothing
# ===========================================================================
before="$(state_hash)"
out="$(echo "STATUS: blocked" | bash "$AGENDA" publish 2>&1)"; rc=$?
check "publish (not a plan): exit 1" "$rc" "1"
contains "publish (not a plan): reports no-plan" "$out" "STATUS: no-plan"
check "publish (not a plan): state untouched" "$(state_hash)" "$before"
out="$(: | bash "$AGENDA" publish 2>&1)"; rc=$?
check "publish (empty stdin): exit 1" "$rc" "1"
check "publish (empty stdin): state untouched" "$(state_hash)" "$before"

# ===========================================================================
# first / skip — recorded only for issues on the agenda
# ===========================================================================
out="$(bash "$AGENDA" first 20)"; rc=$?
check "first: exit 0" "$rc" "0"
contains "first: recorded" "$out" "STATUS: recorded"
contains "first: names the issue" "$out" "ISSUE: 20"
out="$(bash "$AGENDA" skip '#12')"; rc=$?
check "skip: accepts #N" "$rc" "0"
contains "skip: recorded" "$out" "ADJUSTMENT: skip"

before="$(state_hash)"
out="$(bash "$AGENDA" first 77 2>&1)"; rc=$?
check "first (not on the agenda): exit 1" "$rc" "1"
contains "first (not on the agenda): says why" "$out" "STATUS: not-on-agenda"
check "first (not on the agenda): state untouched" "$(state_hash)" "$before"
out="$(bash "$AGENDA" skip abc 2>&1)"; rc=$?
check "skip (not a number): exit 1" "$rc" "1"
check "skip (not a number): state untouched" "$(state_hash)" "$before"
out="$(bash "$AGENDA" first 2>&1)"; rc=$?
check "first (no argument): exit 1" "$rc" "1"
out="$(bash "$AGENDA" skip '12; rm -rf x' 2>&1)"; rc=$?
check "skip (shell text): exit 1" "$rc" "1"
check "skip (shell text): state untouched" "$(state_hash)" "$before"

out="$(bash "$AGENDA" show)"
contains "show: the prioritised issue leads" "$out" "1. #20  Add export"
contains "show: the rest keeps its order" "$out" "2. #15  Docs: update guide"
contains "show: the skipped issue is listed apart" "$out" "SKIPPED: #12  Fix login"
lacks "show: the skipped issue has no position" "$out" ". #12"

# ===========================================================================
# apply — over a LIVE queue, which may differ from the published one
# ===========================================================================
out="$(printf '12\n15\n20\n' | bash "$AGENDA" apply)"
contains "apply: adjusted" "$out" "STATUS: adjusted"
check "apply: prioritised first, skipped gone" "$(queue_of "$out")" "20 15"
check "apply: reports what was skipped" "$(skipped_of "$out")" "12"

# The live queue lost #20 (closed during the day) and gained #31.
out="$(printf '12\n15\n31\n' | bash "$AGENDA" apply)"
check "apply: an issue that left the queue is not brought back" "$(queue_of "$out")" "15 31"
lacks "apply: #20 is not emitted when the live queue lacks it" "$(queue_of "$out") " "20 "

# Narrowing only: whatever is stored, the output is a subset of the input.
printf '2026-11-13T00:00:00Z\tfirst\t500\n2026-11-13T00:00:01Z\tskip\t600\n' >> "$STATE/adjust.tsv"
out="$(printf '15\n31\n' | bash "$AGENDA" apply)"
check "apply: a stored number absent from the input is never emitted" "$(queue_of "$out")" "15 31"
check "apply: nor reported as skipped" "$(skipped_of "$out")" ""
contains "apply: an untouched queue comes back unchanged" "$out" "STATUS: unchanged"

# Hostile lines in the adjustment file cannot add work either.
printf 'x\tfirst\t15 999\nx\tfirst\t\nx\tadd\t31\ngarbage\n' >> "$STATE/adjust.tsv"
out="$(printf '15\n31\n' | bash "$AGENDA" apply)"
for n in $(queue_of "$out") $(skipped_of "$out"); do
  case "$n" in 15|31) ;; *) check "apply: emitted a number that was not on stdin" "$n" "15 or 31" ;; esac
done
check "apply: a damaged line makes no issue disappear" "$(queue_of "$out")|$(skipped_of "$out")" "15 31|"

# Input hygiene: duplicates collapse; `#N`, CRLF, blanks and leading zeros are read.
out="$(printf '15\n15\n#31\r\n\n031\n' | bash "$AGENDA" apply)"
check "apply: duplicates collapse, #N / CRLF / leading zeros are normalised" "$(queue_of "$out")" "15 31"

# A line that is not one issue number is refused, never silently dropped.
for bad in 'abc' '20 21' '-5' '12;rm' '18446744073709551628'; do
  out="$(printf '15\n%s\n31\n' "$bad" | bash "$AGENDA" apply 2>/dev/null)"; rc=$?
  check "apply (bad line '$bad'): exit 1" "$rc" "1"
  check "apply (bad line '$bad'): no queue is offered" "$out" "STATUS: bad-input"
done
out="$(bash "$AGENDA" skip 18446744073709551628 2>&1)"; rc=$?
check "skip (number too large to be an issue): exit 1" "$rc" "1"

# Adjustments that cannot be read are an error, not "no adjustments".
cp "$STATE/adjust.tsv" "$STATE/adjust.keep"
rm -f "$STATE/adjust.tsv"; mkdir "$STATE/adjust.tsv"
out="$(printf '15\n31\n' | bash "$AGENDA" apply 2>/dev/null)"; rc=$?
check "apply (unreadable adjustments): exit 1" "$rc" "1"
check "apply (unreadable adjustments): no queue is offered" "$out" "STATUS: unreadable"
rmdir "$STATE/adjust.tsv"; mv "$STATE/adjust.keep" "$STATE/adjust.tsv"
out="$(: | bash "$AGENDA" apply)"; rc=$?
check "apply (empty queue): exit 0" "$rc" "0"
check "apply (empty queue): empty queue back" "$(queue_of "$out")" ""

# ===========================================================================
# the latest adjustment of an issue wins; the latest `first` leads
# ===========================================================================
bash "$AGENDA" reset >/dev/null
bash "$AGENDA" first 15 >/dev/null
bash "$AGENDA" first 20 >/dev/null
out="$(printf '12\n15\n20\n' | bash "$AGENDA" apply)"
check "two firsts: the latest one leads" "$(queue_of "$out")" "20 15 12"
bash "$AGENDA" skip 20 >/dev/null
out="$(printf '12\n15\n20\n' | bash "$AGENDA" apply)"
check "skip after first: the skip wins" "$(queue_of "$out")" "15 12"
bash "$AGENDA" first 20 >/dev/null
out="$(printf '12\n15\n20\n' | bash "$AGENDA" apply)"
check "first after skip: the issue is back, leading" "$(queue_of "$out")" "20 15 12"

# ===========================================================================
# reset
# ===========================================================================
out="$(bash "$AGENDA" reset)"
contains "reset: reports reset" "$out" "STATUS: reset"
out="$(printf '12\n15\n20\n' | bash "$AGENDA" apply)"
contains "after reset: unchanged" "$out" "STATUS: unchanged"
check "after reset: identity" "$(queue_of "$out")" "12 15 20"
check "reset twice: still exit 0" "$(bash "$AGENDA" reset >/dev/null; echo $?)" "0"

# ===========================================================================
# adjustments belong to one day's agenda
# ===========================================================================
bash "$AGENDA" skip 15 >/dev/null
plan '#12  Fix login' '#15  "Docs: update guide"' | bash "$AGENDA" publish >/dev/null
out="$(printf '12\n15\n' | bash "$AGENDA" apply)"
check "republishing the same day keeps the adjustments" "$(queue_of "$out")" "12"

out="$(plan '#12  Fix login' '#15  "Docs: update guide"' | DEVLEAD_AGENDA_DATE=2026-11-14 bash "$AGENDA" publish)"
contains "new day: published" "$out" "DATE: 2026-11-14"
out="$(printf '12\n15\n' | bash "$AGENDA" apply)"
check "new day: yesterday's adjustments are gone" "$(queue_of "$out")" "12 15"

out="$(plan '#012  Zero padded' | DEVLEAD_AGENDA_DATE=2026-11-14 bash "$AGENDA" publish)"
check "publish: a zero-padded number is stored plain" "$(cut -f2 "$STATE/agenda.tsv")" "12"
contains "publish: and can then be adjusted" "$(bash "$AGENDA" skip 12)" "STATUS: recorded"

# ===========================================================================
# an empty queue is a valid agenda
# ===========================================================================
out="$(plan | DEVLEAD_AGENDA_DATE=2026-11-15 bash "$AGENDA" publish)"; rc=$?
check "publish (no issues): exit 0" "$rc" "0"
contains "publish (no issues): reports empty" "$out" "STATUS: empty"
contains "publish (no issues): count zero" "$out" "COUNT: 0"
contains "show (no issues): empty" "$(bash "$AGENDA" show)" "STATUS: empty"

# ===========================================================================
# a write that cannot complete leaves the agenda as it was
# ===========================================================================
plan '#12  Fix login' | DEVLEAD_AGENDA_DATE=2026-11-16 bash "$AGENDA" publish >/dev/null
kept="$(cat "$STATE/agenda.tsv")"
chmod a-w "$STATE"
out="$(plan '#40  Other' | DEVLEAD_AGENDA_DATE=2026-11-16 bash "$AGENDA" publish 2>&1)"; rc=$?
check "publish (unwritable state): exit 1" "$rc" "1"
check "publish (unwritable state): agenda untouched" "$(cat "$STATE/agenda.tsv")" "$kept"
chmod u+w "$STATE"

# ===========================================================================
# misuse and location
# ===========================================================================
out="$(bash "$AGENDA" nonsense 2>&1)"; rc=$?
check "unknown subcommand: exit 1" "$rc" "1"
contains "unknown subcommand: usage" "$out" "Usage: agenda.sh"
out="$(cd "$SANDBOX" && bash "$AGENDA" show)"; rc=$?
check "outside a repo: exit 1" "$rc" "1"
check "outside a repo: says so" "$out" "STATUS: not-a-repo"

# Two repositories never share an agenda.
OTHER="$SANDBOX/other"
git init -q "$OTHER"
check "another repo: has no agenda" "$(cd "$OTHER" && bash "$AGENDA" show)" "STATUS: none"

# ===========================================================================
# A1/A3 — nothing that grants or gates authority reads the agenda
# ===========================================================================
for f in .devlead/scripts/open-pr.sh .devlead/scripts/merge.sh .devlead/scripts/envelope.sh \
         .devlead/scripts/envelope-auth.sh .devlead/scripts/forbidden-check.sh \
         .claude/hooks/gate-check.sh .claude/hooks/post-edit.sh; do
  if [[ ! -f "$REPO_ROOT/$f" ]]; then
    check "authority file exists: $f" "missing" "present"
    continue
  fi
  check "never reads the agenda: $f" "$(grep -c 'agenda' "$REPO_ROOT/$f")" "0"
done
# The script itself calls no tool that could change a repository or GitHub.
check "agenda.sh runs no gh" "$(grep -cE '(^|[^[:alnum:]_.-])gh[[:space:]]' "$AGENDA")" "0"
check "agenda.sh runs no mutating git verb" \
  "$(grep -cE 'git[[:space:]]+(commit|push|checkout|switch|merge|branch|reset|add)' "$AGENDA")" "0"

echo ""
echo "unit-agenda: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
