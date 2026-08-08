#!/usr/bin/env bash
# unit-discover-command.sh — pins the shape and safety boundary of sweep-discover.md
#
#   bash test/unit-discover-command.sh
#
# sweep-discover.md is a SOLO-LECTURA-sobre-código / SOLO-ESCRITURA-sobre-issues
# command: it explores declared modules against their specs and files issues for
# gaps, but it must NEVER execute — no branches, no pull requests, no merges. This
# suite pins that boundary mechanically (grep, not trust) plus the load-bearing
# structural pieces: the A1-A4 mirror block, the §sweep-discover-profile pointer,
# the hard gap definition, and manifest registration.
#
# SAFETY: reads only. Runs nothing, publishes nothing, touches no $HOME.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CMD="$REPO_ROOT/.claude/commands/sweep-discover.md"
LIB="$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh"

PASS_COUNT=0
FAIL_COUNT=0

report() {
  local label="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "true" ]]; then
    echo "PASS  $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $label"
    [[ -n "$detail" ]] && echo "        $detail"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

if [[ ! -f "$CMD" ]]; then
  echo "FATAL: $CMD does not exist"
  exit 1
fi

content="$(cat "$CMD")"

# --- The prohibition: verifiable, not decorative ----------------------------
# sweep-discover NEVER executes. These four strings must not appear anywhere
# in the OPERATIONAL body — not in a step, not in an example, not in a "do not
# do this" illustration. This is the mechanical form of GOVERNANCE.md
# §sweep-discover-profile's "sin autoridad de ejecución" clause.
#
# The A1-A4 governance header is excluded from the scan, and deliberately so.
# Those four lines are a non-normative mirror of §Layer-0 (see
# §mapa-de-deferencia) and must stay copyable verbatim from the canonical text,
# which itself names `branch.sh` and `gh pr create` — as things DevLead does
# NOT do. Scanning the header would force this file's mirror to drift from
# every other command's, trading a real invariant for a grep artefact. What
# proves this command cannot execute is the absence of those verbs from the
# steps that run, which is exactly what the scan below covers.
body="$(awk '/^A4 · PARK SIEMPRE/{seen=1; next} seen' "$CMD")"
if [[ -z "$body" ]]; then
  report "prohibition scan: operational body located after the A1-A4 header" false \
    "A4 marker not found — the header boundary moved, and the scan below would be vacuous"
else
  report "prohibition scan: operational body located after the A1-A4 header" true
  for banned in "branch.sh" "gh pr create" "gh pr merge" "git merge"; do
    case "$body" in
      *"$banned"*) report "prohibition holds in the body: no occurrence of '$banned'" false "found in operational body" ;;
      *) report "prohibition holds in the body: no occurrence of '$banned'" true ;;
    esac
  done
fi

# --- A1-A4 mirror block ------------------------------------------------------
for marker in \
  "A1 · Autorización SIEMPRE antes de ejecutar" \
  "A2 · Estado SIEMPRE re-derivado en vivo" \
  "A3 · NUNCA ampliar la propia autoridad de merge" \
  "A4 · PARK SIEMPRE con razón exacta"
do
  case "$content" in
    *"$marker"*) report "A1-A4 mirror block: contains '$marker'" true ;;
    *) report "A1-A4 mirror block: contains '$marker'" false "not found" ;;
  esac
done

# --- §sweep-discover-profile pointer -----------------------------------------
case "$content" in
  *"§sweep-discover-profile"*) report "references §sweep-discover-profile" true ;;
  *) report "references §sweep-discover-profile" false "not found" ;;
esac

# --- The gap definition — distinctive phrase from the hard rule -------------
case "$content" in
  *"el spec declara X y el código no hace X"*)
    report "states the gap definition (spec declares X, code doesn't do X)" true ;;
  *)
    report "states the gap definition (spec declares X, code doesn't do X)" false "distinctive phrase not found" ;;
esac
case "$content" in
  *"NO es un gap"*) report "states the improvement-is-not-a-gap boundary" true ;;
  *) report "states the improvement-is-not-a-gap boundary" false "not found" ;;
esac

# --- Spec-citation rule -------------------------------------------------------
case "$content" in
  *"un issue que no puede citar el spec no se archiva"*)
    report "states the spec-citation filing rule" true ;;
  *)
    report "states the spec-citation filing rule" false "distinctive phrase not found" ;;
esac

# --- Label + dedup + cap are documented --------------------------------------
case "$content" in
  *"DISCOVER_LABEL"*) report "references DISCOVER_LABEL" true ;;
  *) report "references DISCOVER_LABEL" false "not found" ;;
esac
case "$content" in
  *"gh issue list --label"*) report "documents dedup via gh issue list --label" true ;;
  *) report "documents dedup via gh issue list --label" false "not found" ;;
esac
case "$content" in
  *"por corrida"*) report "documents a per-run cap" true ;;
  *) report "documents a per-run cap" false "not found" ;;
esac

# --- not-a-git-repo machine-readable contract line ---------------------------
case "$content" in
  *"STATUS: not-a-git-repo"*) report "emits the STATUS: not-a-git-repo contract line" true ;;
  *) report "emits the STATUS: not-a-git-repo contract line" false "not found" ;;
esac

# --- Distinct report destination, never collides with the other two ---------
case "$content" in
  *"YYYY-MM-DD-discover.md"*) report "writes to a distinct -discover.md report file" true ;;
  *) report "writes to a distinct -discover.md report file" false "not found" ;;
esac

# --- Registered in the publish manifest --------------------------------------
manifest="$(cat "$LIB")"
case "$manifest" in
  *"/.claude/commands/sweep-discover.md|"*)
    report "registered in bootstrap-lib.sh publish manifest" true ;;
  *)
    report "registered in bootstrap-lib.sh publish manifest" false "not found in _pairs table" ;;
esac

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
