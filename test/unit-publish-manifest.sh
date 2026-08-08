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

# --- test/smoke-pinned-release.sh carries its OWN independent hardcoded --
# --- publish manifest (two heredocs) — keep it in sync with bootstrap- ----
# --- lib.sh's _pairs tables, in both directions. -------------------------
#
# smoke-pinned-release.sh deliberately pins its own expected set rather than
# deriving it from bootstrap-lib.sh (that is its whole value as an
# independent check) — so unlike the manifest checks above, this cannot be
# a textual "is it present" scan against bootstrap-lib.sh; it has to compare
# two DIFFERENT path shapes (destination-relative-to-$HOME vs
# source-relative-to-repo-root) entry-for-entry against bootstrap-lib.sh's
# own tables. run-state.sh, sweep-loop.sh, doctor.sh and the
# devlead-loop.service/.timer units were added to bootstrap-lib.sh but
# missed in both smoke heredocs — this section is what would have caught
# that.
SMOKE="$REPO_ROOT/test/smoke-pinned-release.sh"

# Pulls the body of a `<<'EOF' ... EOF` heredoc that follows a
# `<fn>() {` line, without sourcing smoke-pinned-release.sh (which has real
# side effects — mktemp, git clone — at its top level).
_extract_heredoc() {
  local fn="$1" start end
  start="$(grep -n "^${fn}() {" "$SMOKE" | head -1 | cut -d: -f1)"
  start=$((start + 2))
  end="$(awk -v s="$start" 'NR>=s && /^EOF$/{print NR; exit}' "$SMOKE")"
  sed -n "${start},$((end - 1))p" "$SMOKE"
}

smoke_targets="$(_extract_heredoc all_publish_targets)"
smoke_sources="$(_extract_heredoc all_source_paths)"

# Every `"$repo_dir/SRC|$VAR/DST|mode"` entry across BOTH _pairs tables in
# bootstrap-lib.sh (bootstrap_symlinks and bootstrap_systemd share this exact
# textual shape, so one grep walks both tables in file order), normalized to
# the same two path shapes the smoke heredocs use.
pairs_src=""
pairs_dst=""
while IFS= read -r raw; do
  [[ -n "$raw" ]] || continue
  entry="${raw%\"}"; entry="${entry#\"}"
  src_field="${entry%%|*}"
  rest="${entry#*|}"
  dst_field="${rest%%|*}"

  src_rel="${src_field#'$repo_dir/'}"
  case "$dst_field" in
    '$devlead_dir/'*)     dst_rel=".devlead/${dst_field#'$devlead_dir/'}" ;;
    '$local_bin/'*)       dst_rel=".local/bin/${dst_field#'$local_bin/'}" ;;
    '$claude_commands/'*) dst_rel=".claude/commands/${dst_field#'$claude_commands/'}" ;;
    '$systemd_dir/'*)     dst_rel=".config/systemd/user/${dst_field#'$systemd_dir/'}" ;;
    *)                    dst_rel="UNRECOGNIZED-DEST-VAR:$dst_field" ;;
  esac

  pairs_src+="$src_rel"$'\n'
  pairs_dst+="$dst_rel"$'\n'
done < <(grep -oE '"\$repo_dir/[^"]*"' "$LIB")

missing=""
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  grep -qxF "$s" <<< "$smoke_sources" \
    || missing+="$s (in bootstrap-lib.sh _pairs, absent from smoke-pinned-release.sh all_source_paths)"$'\n'
done <<< "$pairs_src"
report "every bootstrap-lib.sh _pairs source is in smoke-pinned-release.sh all_source_paths" "$missing"

missing=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  grep -qxF "$d" <<< "$smoke_targets" \
    || missing+="$d (in bootstrap-lib.sh _pairs, absent from smoke-pinned-release.sh all_publish_targets)"$'\n'
done <<< "$pairs_dst"
report "every bootstrap-lib.sh _pairs destination is in smoke-pinned-release.sh all_publish_targets" "$missing"

missing=""
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  grep -qxF "$s" <<< "$pairs_src" \
    || missing+="$s (in smoke-pinned-release.sh all_source_paths, absent from bootstrap-lib.sh _pairs)"$'\n'
done <<< "$smoke_sources"
report "smoke-pinned-release.sh all_source_paths names nothing absent from bootstrap-lib.sh _pairs" "$missing"

missing=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  grep -qxF "$d" <<< "$pairs_dst" \
    || missing+="$d (in smoke-pinned-release.sh all_publish_targets, absent from bootstrap-lib.sh _pairs)"$'\n'
done <<< "$smoke_targets"
report "smoke-pinned-release.sh all_publish_targets names nothing absent from bootstrap-lib.sh _pairs" "$missing"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
