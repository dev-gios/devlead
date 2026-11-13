#!/usr/bin/env bash
# unit-decisions.sh — coverage for .devlead/scripts/decisions.sh
#
#   bash test/unit-decisions.sh
#
# Pins the record of what DevLead decided without asking: a decision needs its
# reason, the user is shown each one once, a correction is kept until the
# profile has read it, one repository never sees another's decisions, and the
# log stays bounded without losing anything the user has not seen.
#
# SAFETY: DEVLEAD_DECISIONS_DIR is a sandbox; the real state is never touched.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
D="$REPO_ROOT/.devlead/scripts/decisions.sh"
SANDBOX="$(mktemp -d /tmp/devlead-decisions.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
export DEVLEAD_DECISIONS_DIR="$SANDBOX/state"
export DEVLEAD_DECISIONS_NOW="2026-11-13 09:30"
A="$SANDBOX/repo-a"; B="$SANDBOX/repo-b"
mkdir -p "$A/src" "$B"
git -C "$A" init -q; git -C "$B" init -q

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if grep -qF -- "$3" <<<"$2"; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected to contain: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
not_contains() {
  if grep -qF -- "$3" <<<"$2"; then echo "FAIL  $1"; echo "        must not contain: [$3]"; FAIL_COUNT=$((FAIL_COUNT + 1))
  else echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); fi
}
field() { grep -m1 "^$2: " <<<"$1" | sed "s/^$2: //"; }
a() { ( cd "$A" && bash "$D" "$@" ); }
b() { ( cd "$B" && bash "$D" "$@" ); }

echo "=== record ==="
check "empty log: list says none" "$(field "$(a list)" STATUS)" "none"
out="$(a record "issue #42" "fix directo, sin SDD" "es un cambio de dos líneas en un solo archivo")"
check "record: status" "$(field "$out" STATUS)" "recorded"
check "record: first id" "$(field "$out" ID)" "d1"
out="$(cd "$A/src" && bash "$D" record "plan de hoy" "empiezo por el PR 17" "tiene cambios pedidos hace cinco días")"
check "record from a subdirectory: same repository log" "$(field "$out" ID)" "d2"
out="$(a record "issue #42" "sin razón" "" 2>&1)"; rc=$?
check "a decision without its reason is refused" "$rc" "1"
out="$(a record "" "algo" "porque sí" 2>&1)"; rc=$?
check "a decision without its task is refused" "$rc" "1"
check "nothing refused was written" "$(wc -l < "$DEVLEAD_DECISIONS_DIR"/*/log.tsv)" "2"
a record "t" "$(printf 'línea uno\nlínea dos\tcon tab')" "$(printf 'x%.0s' {1..400})" >/dev/null
row="$(tail -1 "$DEVLEAD_DECISIONS_DIR"/*/log.tsv)"
check "tabs and newlines cannot forge columns" "$(awk -F'\t' '{print NF}' <<<"$row")" "8"
check "a field is bounded" "$(awk -F'\t' '{print length($6)}' <<<"$row")" "300"

echo "=== list / shown ==="
out="$(a list --new)"
check "list --new: all three" "$(field "$out" COUNT)" "3"
contains "list: the decision"   "$out" "decided: fix directo, sin SDD"
contains "list: its reason"     "$out" "because: es un cambio de dos líneas"
contains "list: task and time"  "$out" "[d1] 2026-11-13 09:30 · issue #42"
out="$(a shown)"
check "shown: marks them" "$(field "$out" STATUS):$(field "$out" COUNT)" "shown:3"
check "after shown, nothing is new" "$(field "$(a list --new)" STATUS)" "none"
check "…but the log still lists them" "$(field "$(a list)" COUNT)" "3"
check "shown again: none" "$(field "$(a shown)" STATUS)" "none"

echo "=== one repository never sees another's decisions ==="
check "the other repository starts empty" "$(field "$(b list)" STATUS)" "none"
b record "issue #7" "uso pnpm" "es lo que usa el repo" >/dev/null
check "the other repository has its own ids" "$(field "$(b list)" COUNT)" "1"
not_contains "its log does not carry the first repository's decisions" "$(b list)" "issue #42"
not_contains "and the first does not carry its decisions" "$(a list)" "pnpm"
out="$(cd "$SANDBOX" && bash "$D" list)"
check "outside a repository" "$(field "$out" STATUS)" "not-a-repo"

echo "=== correct / corrections / digested ==="
a record "issue #50" "abro un PR por cada módulo" "son cambios independientes" >/dev/null
out="$(a correct d4 "prefería un solo PR: los tres módulos se revisan juntos")"
check "correct: status" "$(field "$out" STATUS)" "corrected"
check "a corrected decision counts as shown" "$(field "$(a list --new)" STATUS)" "none"
out="$(a corrections)"
check "corrections: one pending" "$(field "$out" STATUS):$(field "$out" COUNT)" "pending:1"
contains "corrections: what was decided" "$out" "decided: abro un PR por cada módulo"
contains "corrections: what the user wanted" "$out" "you said: prefería un solo PR"
contains "the correction also shows in the log" "$(a list)" "you said: prefería un solo PR"
out="$(a digested)"
check "digested: marks it" "$(field "$out" STATUS):$(field "$out" COUNT)" "digested:1"
check "after digested, no correction is pending" "$(field "$(a corrections)" STATUS)" "none"
contains "…and the correction stays in the log" "$(a list)" "you said: prefería un solo PR"
out="$(a correct d99 "no existe")"; rc=$?
check "correct of an unknown id" "$(field "$out" STATUS):$rc" "not-found:1"
out="$(a correct 4 "id mal escrito" 2>&1)"; rc=$?
check "a malformed id is misuse" "$rc" "1"
out="$(a correct d1 "" 2>&1)"; rc=$?
check "a correction without text is misuse" "$rc" "1"
a record "issue #51" "uso la librería estándar" "evita una dependencia" >/dev/null
a correct d5 'prefería C:\temp\nuevo y no \t ni \n literales' >/dev/null
row="$(grep "^d5$(printf '\t')" "$DEVLEAD_DECISIONS_DIR"/*/log.tsv)"
check "backslash sequences in a correction do not forge columns" "$(awk -F'\t' '{print NF}' <<<"$row")" "8"
contains "…and are kept as typed" "$row" 'C:\temp\nuevo y no \t ni \n literales'
check "the log still has one line per decision" "$(wc -l < "$(grep -l 'issue #51' "$DEVLEAD_DECISIONS_DIR"/*/log.tsv)")" "5"
a digested >/dev/null
out="$(a list --all 2>&1)"; rc=$?
check "an unknown option to list is misuse, not silently ignored" "$rc" "1"
check "corrections do not cross repositories" "$(field "$(b corrections)" STATUS)" "none"

echo "=== bounded, without losing what the user has not seen ==="
export DEVLEAD_DECISIONS_DIR="$SANDBOX/state-bound"
export DEVLEAD_DECISIONS_MAX_ROWS=5
a record "t1" "primera" "razón" >/dev/null
a record "t2" "segunda" "razón" >/dev/null
a shown >/dev/null
a record "t3" "tercera, corregida" "razón" >/dev/null
a correct d3 "otra cosa" >/dev/null
for i in 4 5 6 7 8 9; do a record "t$i" "decisión $i" "razón" >/dev/null; a shown >/dev/null; done
a record "t10" "la más nueva, sin mostrar" "razón" >/dev/null
log="$(cat "$DEVLEAD_DECISIONS_DIR"/*/log.tsv)"
not_contains "the oldest shown rows fall off" "$log" "primera"
contains "a correction the profile has not read is kept" "$log" "tercera, corregida"
contains "a decision not shown yet is kept" "$log" "la más nueva, sin mostrar"
check "ids keep growing after the trim" "$(field "$(a record "t11" "otra" "razón")" ID)" "d11"
unset DEVLEAD_DECISIONS_MAX_ROWS
export DEVLEAD_DECISIONS_DIR="$SANDBOX/state"

echo "=== the commands record, show and take corrections ==="
CMDS="$REPO_ROOT/.claude/commands"
contains "the interactive command records each decision" "$(cat "$CMDS/arranquemos.md")" 'decisions.sh record "{tarea'
contains "…shows the unseen ones in the standup"          "$(cat "$CMDS/arranquemos.md")" 'decisions.sh list --new'
contains "…marks them shown only after showing"           "$(cat "$CMDS/arranquemos.md")" 'decisions.sh shown'
contains "…turns corrections into profile entries"        "$(cat "$CMDS/arranquemos.md")" 'decisions.sh corrections'
contains "/devlead shows decisions when asked how it goes" "$(cat "$CMDS/devlead.md")" 'decisions.sh list --new'
contains "/devlead records a correction on a change of course" "$(cat "$CMDS/devlead.md")" 'decisions.sh correct {id}'
contains "the unattended command records its decisions"   "$(cat "$CMDS/sweep-execute.md")" 'decisions.sh record "{tarea}"'
for f in arranquemos.md devlead.md sweep-execute.md; do
  check "$f has balanced code fences" "$(( $(grep -c '^[[:space:]]*```' "$CMDS/$f") % 2 ))" "0"
done

echo "=== it is only a record ==="
for f in .devlead/scripts/open-pr.sh .devlead/scripts/merge.sh .devlead/scripts/envelope.sh \
         .devlead/scripts/forbidden-check.sh .claude/hooks/gate-check.sh .claude/hooks/guard.sh; do
  check "$f does not read decisions.sh or its state" "$(grep -cE 'decisions\.sh|devlead/decisions' "$REPO_ROOT/$f")" "0"
done
out="$(a 2>&1)"; rc=$?
check "no subcommand is misuse" "$rc" "1"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ $FAIL_COUNT -eq 0 ]]
