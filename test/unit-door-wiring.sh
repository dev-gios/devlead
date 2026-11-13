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

for f in devlead.md arranquemos.md batch.md sweep-execute.md; do
  hits="$(fenced_lines "$CMD_DIR/$f" \
    | grep -E '^[0-9]+:[[:space:]]*(.*(&&|;|\|)[[:space:]]*)?gh[[:space:]]+pr[[:space:]]+(create|merge)\b' || true)"
  report "$f: no direct gh pr create / gh pr merge in a code block" "$hits"
done

# The fenced lines are captured first and then searched. Piping them into
# `grep -q` under pipefail is a race: grep exits at the first match, the
# producer dies of SIGPIPE, and the check fails although the line is there.
for f in arranquemos.md sweep-execute.md; do
  if grep -q 'scripts/open-pr\.sh --base' <<<"$(fenced_lines "$CMD_DIR/$f")"; then
    report "$f: opens PRs through open-pr.sh" ""
  else
    report "$f: opens PRs through open-pr.sh" "no fenced open-pr.sh --base invocation found"
  fi
done

if grep -q 'scripts/merge\.sh {PR_URL}' <<<"$(fenced_lines "$CMD_DIR/sweep-execute.md")"; then
  report "sweep-execute.md: merges through merge.sh" ""
else
  report "sweep-execute.md: merges through merge.sh" "no fenced merge.sh invocation found"
fi

# The interactive command starts on its own and merges only through the door.
if grep -q 'scripts/merge\.sh {PR_URL}' <<<"$(fenced_lines "$CMD_DIR/arranquemos.md")"; then
  report "arranquemos.md: merges through merge.sh" ""
else
  report "arranquemos.md: merges through merge.sh" "no fenced merge.sh invocation found"
fi
waits="$(grep -nE '[Ee]sperá decisión|Pedí instrucción|hasta recibir instrucción explícita|hasta que el usuario resuelva|esperá confirmación explícita|No despacharás el pipeline hasta recibir un OK|¿Cuántas horas tenés disponibles|¿Aprobás este spec' "$CMD_DIR/arranquemos.md" || true)"
report "arranquemos.md: no step waits for a per-issue or per-approach OK" "$waits"
if grep -q 'sin esperar respuesta' "$CMD_DIR/arranquemos.md" && grep -q 'guard.sh' "$CMD_DIR/arranquemos.md"; then
  report "arranquemos.md: shows the plan and starts; the limits are guard.sh" ""
else
  report "arranquemos.md: shows the plan and starts; the limits are guard.sh" "the start rule or the guard reference is missing"
fi
gov="$CMD_DIR/../GOVERNANCE.md"
stale_profile="$(grep -rnE 'manual-profile|[Mm]odo manual|perfil manual' "$CMD_DIR" "$gov" "$CMD_DIR/../CLAUDE.md" || true)"
report "no file still points at the retired manual profile" "$stale_profile"
for anchor in '### §assistant-profile' '## §hard-limits' 'Autorizar no es aprobar cada paso'; do
  if grep -qF "$anchor" "$gov"; then report "GOVERNANCE.md has: $anchor" ""
  else report "GOVERNANCE.md has: $anchor" "missing"; fi
done

# /devlead is the one entry: it routes by intent and never opens or merges a
# PR itself — it hands over to the procedures, which go through the doors.
entry="$CMD_DIR/devlead.md"
for needle in '$ARGUMENTS' '~/.claude/commands/arranquemos.md' '~/.claude/commands/cerremos.md' \
              'guard.sh' 'GOVERNANCE.md §assistant-profile' 'registro neutro'; do
  if grep -qF -- "$needle" "$entry"; then report "devlead.md has: $needle" ""
  else report "devlead.md has: $needle" "missing"; fi
done
for intent in 'Empezar' 'Continuar' 'Una tarea concreta' 'Saber cómo va' 'Cambiar de rumbo' 'Cerrar'; do
  if grep -qF "**$intent**" "$entry"; then report "devlead.md routes: $intent" ""
  else report "devlead.md routes: $intent" "intent missing from the table"; fi
done
# devlead.md names steps of the procedures it hands over to; they must exist.
for step in '## Paso 0 ' '## Paso 1 ' '## Paso 2 ' '## Paso 6 ' '## Paso 7 ' '## Paso 8 '; do
  if grep -q "^$step" "$CMD_DIR/arranquemos.md"; then report "arranquemos.md still has the step devlead.md points at: $step" ""
  else report "arranquemos.md still has the step devlead.md points at: $step" "heading not found"; fi
done
destructive="$(grep -nE 'descarta lo que|o descarta|cambios descartados' "$entry" "$CMD_DIR/arranquemos.md" || true)"
report "devlead.md: changing course never discards uncommitted work" "$destructive"
if grep -qF 'Nunca descartes cambios sin commit' "$entry"; then report "devlead.md: says so explicitly" ""
else report "devlead.md: says so explicitly" "the rule is missing"; fi
asks="$(grep -nE '¿(Empezamos|Arrancamos|Seguimos|Procedo|Te parece)' "$entry" || true)"
report "devlead.md: no confirmation question before starting" "$asks"
# Explicit word boundaries: \b does not see an accented letter as a word
# character in every locale, and then this check would match nothing.
regional="$(grep -nE '(^|[^[:alpha:]áéíóúñ])(tenés|querés|podés|hacé|decí|seguí|andá|mostrá|leé|usá|corré|fijate|vos)($|[^[:alpha:]áéíóúñ])' "$entry" || true)"
probe="$(printf 'si tenés tiempo\n' | grep -cE '(^|[^[:alpha:]áéíóúñ])(tenés|vos)($|[^[:alpha:]áéíóúñ])' || true)"
if [[ "$probe" == "1" ]]; then report "the register check can match (not vacuous)" ""
else report "the register check can match (not vacuous)" "the pattern did not match a known regional form"; fi
report "devlead.md: written in a neutral register" "$regional"

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
