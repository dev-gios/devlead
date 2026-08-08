#!/usr/bin/env bash
# unit-publish-manifest.sh — every shippable artifact is in the publish manifest
#
#   bash test/unit-publish-manifest.sh
#
# bootstrap_symlinks publishes a HARDCODED table of src|dst pairs. Adding a new
# script to .devlead/scripts/ (or a new command to .claude/commands/) without
# adding it to that table means it is never installed — install.sh keeps
# reporting success, and the omission only surfaces when something tries to run
# the missing file. run-state.sh shipped that way and stayed unpublished across
# several install runs.
#
# This test makes the omission loud: it compares what exists in the repo against
# what the manifest names.
#
# SAFETY: reads only. Runs nothing, publishes nothing, touches no $HOME.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LIB="$REPO_ROOT/.devlead/scripts/bootstrap-lib.sh"

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
      [[ -n "$m" ]] && echo "        not in the publish manifest: $m"
    done <<< "$missing"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# The manifest is a bash array literal; matching its src paths textually is
# enough and avoids sourcing the library (which has side effects).
manifest="$(cat "$LIB")"

# --- Every executable script under .devlead/scripts/ -----------------------
missing=""
for f in "$REPO_ROOT"/.devlead/scripts/*.sh; do
  name="$(basename "$f")"
  case "$manifest" in
    *"/.devlead/scripts/$name|"*) ;;
    *) missing+="$name"$'\n' ;;
  esac
done
report "every .devlead/scripts/*.sh is published" "$missing"

# --- Every command file ----------------------------------------------------
missing=""
for f in "$REPO_ROOT"/.claude/commands/*.md; do
  name="$(basename "$f")"
  case "$manifest" in
    *"/.claude/commands/$name|"*) ;;
    *) missing+="$name"$'\n' ;;
  esac
done
report "every .claude/commands/*.md is published" "$missing"

# --- Every hook ------------------------------------------------------------
missing=""
for f in "$REPO_ROOT"/.claude/hooks/*.sh; do
  name="$(basename "$f")"
  case "$manifest" in
    *"/.claude/hooks/$name|"*) ;;
    *) missing+="$name"$'\n' ;;
  esac
done
report "every .claude/hooks/*.sh is published" "$missing"

# --- Every systemd unit ----------------------------------------------------
# bootstrap_systemd keeps its OWN hardcoded table, separate from the one
# bootstrap_symlinks uses. A unit added to only one of them is just as invisible.
missing=""
for f in "$REPO_ROOT"/.devlead/systemd/*; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  case "$manifest" in
    *"/.devlead/systemd/$name|"*) ;;
    *) missing+="$name"$'\n' ;;
  esac
done
report "every .devlead/systemd/* unit is published" "$missing"

# --- The reverse direction: the manifest names nothing that has vanished ----
missing=""
while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  [[ -e "$REPO_ROOT/$src" ]] || missing+="$src (named in manifest, absent from repo)"$'\n'
done < <(printf '%s\n' "$manifest" \
  | grep -o '\$repo_dir/[^|]*' \
  | sed 's|^\$repo_dir/||' \
  | sort -u)
report "the manifest names no file that has vanished" "$missing"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
