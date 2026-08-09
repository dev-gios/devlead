#!/usr/bin/env bash
# unit-envelope-schema.sh — envelope.sh schema is honest about the real schema
#
#   bash test/unit-envelope-schema.sh
#
# `envelope.sh schema` exists so a future config menu (and anything else that
# needs to render/explain envelope fields) has ONE source to render from,
# instead of growing a fourth hand-maintained field list — this repo already
# has three (bootstrap_symlinks, bootstrap_systemd,
# smoke-pinned-release.sh — see test/unit-publish-manifest.sh) that drifted
# from each other, one silently for weeks. A descriptor nobody cross-checks
# against the real schema would just be a slower way to grow a fifth.
#
# This test derives BOTH sides mechanically from envelope.sh's own source —
# it does not hand-list expected fields (that would be the fourth manifest
# moved into the test file):
#
#   REAL side  — every field the schema/validation logic actually declares
#                or reads, built from three independent extractions:
#                  (a) _TOP_REQUIRED / _TOP_OPTIONAL literals
#                  (b) every `_assert_keys '.path' 'label' k1 k2 ...` call
#                  (c) every `yq e '<query>'` path expression used inside
#                      `_do_show` (covers both validation reads AND every
#                      value `show` emits, since both live in that function)
#
#   DESCRIPTOR side — every `FIELD:` value emitted by `envelope.sh schema`
#
# Both directions are checked: REAL \ DESCRIPTOR (schema/show reads a field
# the descriptor never mentions) and DESCRIPTOR \ REAL (the descriptor
# names a field that does not exist). Failures name the exact field and
# the exact direction — never a bare count.
#
# SAFETY: reads only. Runs `envelope.sh schema` (no envelope file needed —
# schema describes the schema, not an instance) and does static text
# extraction on envelope.sh. Touches no $HOME, no git state, no network.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ENVELOPE_SH="$REPO_ROOT/.devlead/scripts/envelope.sh"

PASS_COUNT=0
FAIL_COUNT=0

report() {
  local label="$1" missing="$2"
  if [[ -z "$missing" ]]; then
    echo "PASS  $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $label"
    while IFS= read -r m; do
      [[ -n "$m" ]] && echo "        $m"
    done <<< "$missing"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Normalizes a raw yq query-path expression (the argument before the first
# `|` or `//`) into the same dotted-path convention the descriptor uses:
#   - strips a leading '.'
#   - strips one layer of enclosing '[' ']' (used by `[.x[].y] | join(",")`)
#   - collapses a bash-variable list index (e.g. `[$dm_idx]`) to `[]`
#   - drops a bare trailing `[]` (a plain list, not a list-of-objects child)
# Returns empty for expressions that are not a real field path (root `.`,
# `keys | .[]`, etc).
_normalize_path() {
  local raw="$1" expr
  expr="${raw%%|*}"
  expr="${expr%%//*}"
  # trim surrounding whitespace
  expr="${expr#"${expr%%[![:space:]]*}"}"
  expr="${expr%"${expr##*[![:space:]]}"}"
  if [[ "$expr" == \[*\] ]]; then
    expr="${expr#\[}"
    expr="${expr%\]}"
  fi
  [[ "$expr" == .* ]] || { printf ''; return; }
  expr="${expr#.}"
  [[ -z "$expr" ]] && { printf ''; return; }
  expr="${expr//\[\$dm_idx\]/[]}"
  if [[ "$expr" == *'[]' ]]; then
    expr="${expr%[]}"
  fi
  printf '%s' "$expr"
}

# --- REAL side (a): _TOP_REQUIRED / _TOP_OPTIONAL --------------------------
real_fields=""
top_all="$(sed -n "s/^_TOP_REQUIRED=\"\\(.*\\)\"\$/\\1/p; s/^_TOP_OPTIONAL=\"\\(.*\\)\"\$/\\1/p" "$ENVELOPE_SH")"
for w in $top_all; do
  real_fields+="$w"$'\n'
done

# --- REAL side (b): every _assert_keys call ---------------------------------
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  body="${line#*_assert_keys }"
  # shellcheck disable=SC2206 # deliberate whitespace tokenization of a
  # controlled, quote-delimited source line — no globbing risk here.
  tok=($body)
  parent="${tok[0]//\'/}"
  parent="${parent#.}"
  for ((i = 2; i < ${#tok[@]}; i++)); do
    key="${tok[$i]//\'/}"
    [[ -n "$key" ]] && real_fields+="${parent}.${key}"$'\n'
  done
done < <(grep -E "^\s*_assert_keys " "$ENVELOPE_SH")

# --- REAL side (c): every yq path expression read inside _do_show ----------
# _do_show is the one function that both validates the envelope AND emits
# `show`'s KEY: value output, so this single extraction covers "every field
# validation checks" and "every field show emits" at once.
show_body="$(sed -n '/^_do_show() {/,/^}/p' "$ENVELOPE_SH")"

while IFS= read -r q; do
  q="${q#yq e \'}"; q="${q%\'}"
  p="$(_normalize_path "$q")"
  [[ -n "$p" ]] && real_fields+="$p"$'\n'
done < <(grep -oE "yq e '[^']*'" <<< "$show_body")

while IFS= read -r q; do
  q="${q#yq e \"}"; q="${q%\"}"
  p="$(_normalize_path "$q")"
  [[ -n "$p" ]] && real_fields+="$p"$'\n'
done < <(grep -oE 'yq e "[^"]*"' <<< "$show_body")

real_fields="$(printf '%s\n' "$real_fields" | sed '/^$/d' | sort -u)"

# --- DESCRIPTOR side: every FIELD: value envelope.sh schema emits ----------
schema_out="$(bash "$ENVELOPE_SH" schema 2>&1)"
descriptor_fields="$(printf '%s\n' "$schema_out" | sed -n 's/^FIELD: //p' | sed '/^$/d' | sort -u)"

# --- schema runs without an envelope file (this is the whole point) --------
report "schema runs with STATUS: ok and no envelope.yml required" \
  "$([[ "$schema_out" == "STATUS: ok"* ]] || echo "schema did not report STATUS: ok — got: $(head -1 <<< "$schema_out")")"

# --- direction 1: every REAL field is described -----------------------------
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qxF "$f" <<< "$descriptor_fields" \
    || missing+="'$f' is read/declared by envelope.sh (_TOP_*, _assert_keys, or show's yq reads) but is NOT described by 'envelope.sh schema'"$'\n'
done <<< "$real_fields"
report "every field envelope.sh's schema/validation logic touches is described" "$missing"

# --- direction 2: the descriptor names nothing that isn't real -------------
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qxF "$f" <<< "$real_fields" \
    || missing+="'$f' is described by 'envelope.sh schema' but envelope.sh's _TOP_*/_assert_keys/show never reads or declares it"$'\n'
done <<< "$descriptor_fields"
report "the descriptor names no field absent from envelope.sh's real schema" "$missing"

# --- every FIELD: block is complete (TYPE/DEFAULT/REQUIRED/HELP present) ---
missing=""
block=""
field=""
check_block() {
  [[ -z "$field" ]] && return
  local k
  for k in TYPE DEFAULT REQUIRED HELP; do
    grep -q "^${k}: " <<< "$block" \
      || missing+="field '$field' is missing its $k: line"$'\n'
  done
}
while IFS= read -r line; do
  if [[ "$line" == FIELD:\ * ]]; then
    check_block
    field="${line#FIELD: }"
    block="$line"$'\n'
  elif [[ -n "$field" ]]; then
    block+="$line"$'\n'
  fi
done <<< "$schema_out"
check_block
report "every FIELD: block carries TYPE/DEFAULT/REQUIRED/HELP" "$missing"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
