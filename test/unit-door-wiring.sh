#!/usr/bin/env bash
# unit-door-wiring.sh — the commands reach GitHub only through the two doors
#
#   bash test/unit-door-wiring.sh
#
# open-pr.sh and merge.sh enforce the gates and the envelope in code. That is
# worth nothing if a command file still tells the model to run `gh pr create`
# or `gh pr merge` itself. This suite fails when an executable invocation of
# either reappears in a pipeline command, i.e. a line inside a fenced code
# block that starts with it. Prose that merely names the commands is fine.
#
# SAFETY: reads only.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CMD_DIR="$REPO_ROOT/.claude/commands"
PASS_COUNT=0
FAIL_COUNT=0

report() {
  if [[ -z "$2" ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "$2" | sed 's/^/        /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# fenced_lines <file> — "<lineno>:<text>" for every line inside a ``` block.
fenced_lines() {
  awk '/^[[:space:]]*```/ { inside = !inside; next } inside { print NR ":" $0 }' "$1"
}

for f in arranquemos.md batch.md sweep-execute.md; do
  hits="$(fenced_lines "$CMD_DIR/$f" \
    | grep -E '^[0-9]+:[[:space:]]*(.*(&&|;|\|)[[:space:]]*)?gh[[:space:]]+pr[[:space:]]+(create|merge)\b' || true)"
  report "$f: no direct gh pr create / gh pr merge in a code block" "$hits"
done

for f in arranquemos.md sweep-execute.md; do
  if fenced_lines "$CMD_DIR/$f" | grep -q 'scripts/open-pr\.sh --base'; then
    report "$f: opens PRs through open-pr.sh" ""
  else
    report "$f: opens PRs through open-pr.sh" "no fenced open-pr.sh --base invocation found"
  fi
done

if fenced_lines "$CMD_DIR/sweep-execute.md" | grep -q 'scripts/merge\.sh {PR_URL}'; then
  report "sweep-execute.md: merges through merge.sh" ""
else
  report "sweep-execute.md: merges through merge.sh" "no fenced merge.sh invocation found"
fi

# The interactive command starts on its own and merges only through the door.
if fenced_lines "$CMD_DIR/arranquemos.md" | grep -q 'scripts/merge\.sh {PR_URL}'; then
  report "arranquemos.md: merges through merge.sh" ""
else
  report "arranquemos.md: merges through merge.sh" "no fenced merge.sh invocation found"
fi
waits="$(grep -nE 'esperá confirmación explícita|No despacharás el pipeline hasta recibir un OK|¿Cuántas horas tenés disponibles|¿Aprobás este spec' "$CMD_DIR/arranquemos.md" || true)"
report "arranquemos.md: no step waits for a per-issue or per-approach OK" "$waits"
if grep -q 'sin esperar respuesta' "$CMD_DIR/arranquemos.md" && grep -q 'guard.sh' "$CMD_DIR/arranquemos.md"; then
  report "arranquemos.md: shows the plan and starts; the limits are guard.sh" ""
else
  report "arranquemos.md: shows the plan and starts; the limits are guard.sh" "the start rule or the guard reference is missing"
fi
gov="$CMD_DIR/../GOVERNANCE.md"
stale_profile="$(grep -rn 'manual-profile' "$CMD_DIR" "$gov" "$CMD_DIR/../CLAUDE.md" || true)"
report "no file still points at the retired manual profile" "$stale_profile"
for anchor in '### §assistant-profile' '## §hard-limits' 'Autorizar no es aprobar cada paso'; do
  if grep -qF "$anchor" "$gov"; then report "GOVERNANCE.md has: $anchor" ""
  else report "GOVERNANCE.md has: $anchor" "missing"; fi
done

# The old contradiction: previews promising "never merges" while Delta 6 merges.
stale="$(grep -n 'MERGE: NUNCA' "$CMD_DIR/sweep-execute.md" || true)"
report "sweep-execute.md: no preview claims an unconditional 'MERGE: NUNCA'" "$stale"

# A door refusal must reach the report and run-state verbatim.
for f in batch.md sweep-execute.md arranquemos.md; do
  if grep -q 'PARK_REASON:' "$CMD_DIR/$f"; then
    report "$f: tells the model what to do with PARK_REASON lines" ""
  else
    report "$f: tells the model what to do with PARK_REASON lines" "PARK_REASON: is never mentioned"
  fi
done

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
