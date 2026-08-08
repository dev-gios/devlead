#!/usr/bin/env bash
# branch.sh — DevLead deterministic branch creator
# Creates or reuses a branch based on issue number, title, and type.
# Structured stdout contract (KEY: value). Always exits 0.
# Operates on $PWD (the user's work repo).
#
# Usage: branch.sh <issue-number> "<issue-title>" <type> [<dep-num>] [<integration-branch>]
#   <type> ∈ {feat, fix, chore, docs, refactor, perf, test} (default: feat)
#   <dep-num>: optional predecessor issue number (stacked PR chain)
#   <integration-branch>: optional cut-point/PR-base branch (default: dev)
#
# Output:
#   BRANCH: <name>
#   BASE:   <tag-or-ref>
#   STATUS: created|reused|blocked
#   GAP:    <reason>        (only when STATUS=blocked)

set -uo pipefail

# ---------------------------------------------------------------------------
# GAPS accumulator (ADR-4: honest-gap, never abort)
# ---------------------------------------------------------------------------
GAPS=()

_gap() {
  GAPS+=("$1")
}

# ---------------------------------------------------------------------------
# Usage guard
# ---------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
  echo "Usage: branch.sh <issue-number> \"<issue-title>\" <type> [<dep-num>] [<integration-branch>]" >&2
  echo "  <type>: feat|fix|chore|docs|refactor|perf|test" >&2
  exit 1
fi

ISSUE_NUM="$1"
ISSUE_TITLE="$2"
TYPE="$3"
DEP_NUM="${4:-}"
INTEGRATION_BRANCH="${5:-dev}"

# Validate type — default to feat if unknown.
# Space-padded containment via `case`, NOT `[[ =~ ]]`: an unquoted right-hand
# side would treat $TYPE as a regex (so `f.at` or `feat|fix` would match), and
# a quoted one trips SC2076. `case` matches literally and is unambiguous.
_valid_types="feat fix chore docs refactor perf test"
case " $_valid_types " in
  *" $TYPE "*) ;;
  *) TYPE="feat" ;;
esac

# ---------------------------------------------------------------------------
# Guard: must be a git repo
# ---------------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  echo "BRANCH: "
  echo "BASE:   "
  echo "STATUS: blocked"
  echo "GAP:    not a git repo"
  exit 0
fi

# Guard: detached HEAD
_head_ref=$(git symbolic-ref HEAD 2>/dev/null) || _head_ref=""
if [[ -z "$_head_ref" ]]; then
  echo "BRANCH: "
  echo "BASE:   "
  echo "STATUS: blocked"
  echo "GAP:    detached HEAD — checkout a branch before dispatching"
  exit 0
fi

# Guard: dirty working tree (uncommitted changes)
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  echo "BRANCH: "
  echo "BASE:   "
  echo "STATUS: blocked"
  echo "GAP:    uncommitted changes — commit or stash before dispatching"
  exit 0
fi

# ---------------------------------------------------------------------------
# Branch name generation
# Slug: lowercase, spaces→hyphens, strip non-alphanumeric-hyphens, trim to 40 chars
# ---------------------------------------------------------------------------
_slug=$(printf '%s' "$ISSUE_TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' ' '-' \
  | tr -cd '[:alnum:]-' \
  | tr -s '-' \
  | cut -c1-40)
# Remove trailing dash
_slug="${_slug%-}"

if [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  BRANCH_NAME="${TYPE}/issue-${ISSUE_NUM}-${_slug}"
else
  BRANCH_NAME="${TYPE}/${ISSUE_NUM}-${_slug}"
fi

# ---------------------------------------------------------------------------
# Dependency resolution: predecessor branch (Depends-on 4th arg)
# ---------------------------------------------------------------------------
STACKED_BRANCH=""
BASE_REF=""
BASE_GAP=""
if [[ -n "$DEP_NUM" ]]; then
  # The predecessor's branch slug depends on what produced it. A GitHub issue
  # yields `issue-{N}-…`; a LOCAL-PLAN task yields `plan-{task-id}-…`. A purely
  # numeric dep is an issue number and keeps the historical `issue-` prefix;
  # anything else is already a full slug prefix and is used verbatim. Without
  # this, a plan task could never resolve its predecessor and LOCAL-PLAN could
  # not stack at all.
  if [[ "$DEP_NUM" =~ ^[0-9]+$ ]]; then
    _dep_slug="issue-${DEP_NUM}"
    _dep_label="#${DEP_NUM}"
  else
    _dep_slug="${DEP_NUM}"
    _dep_label="${DEP_NUM}"
  fi

  _dep_branch=$(git branch -a --list "*/${_dep_slug}-*" 2>/dev/null | head -n1)
  _dep_branch=$(printf '%s' "$_dep_branch" | sed 's/^[[:space:]]*[*]\?[[:space:]]*//')
  # _dep_ref: strip only "remotes/" — keeps "origin/" prefix for valid checkout start-point
  _dep_ref="${_dep_branch#remotes/}"
  # _dep_name: strip "remotes/origin/" — bare branch name for STACKED: output and PR --base
  _dep_name="${_dep_branch#remotes/origin/}"
  if [[ -n "$_dep_branch" ]]; then
    BASE_REF="$_dep_ref"; STACKED_BRANCH="$_dep_name"
  elif command -v gh &>/dev/null && gh auth status &>/dev/null && gh pr list --state merged --limit 200 --json headRefName -q '.[].headRefName' 2>/dev/null | grep -qF -- "${_dep_slug}-"; then
    : # merged: the integration branch already has the predecessor → fall through to tag block
  else
    echo "BRANCH: $BRANCH_NAME"; echo "BASE:   "; echo "STATUS: blocked"
    echo "GAP:    predecesor ${_dep_label} no encontrado y no mergeado"; exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Base ref resolution: nearest tag on $INTEGRATION_BRANCH (ADR-4 fallback chain)
# ---------------------------------------------------------------------------
if [[ -z "$BASE_REF" ]]; then
  BASE_REF=""
  BASE_GAP=""

  # Primary: nearest tag reachable from origin/$INTEGRATION_BRANCH
  _tag=$(git describe --tags --abbrev=0 "origin/$INTEGRATION_BRANCH" 2>/dev/null) || _tag=""

  if [[ -n "$_tag" ]]; then
    BASE_REF="$_tag"
  else
    # Fallback 1: git describe against local integration branch
    _tag=$(git describe --tags --abbrev=0 "$INTEGRATION_BRANCH" 2>/dev/null) || _tag=""
    if [[ -n "$_tag" ]]; then
      BASE_REF="$_tag"
      BASE_GAP="no tags on origin/$INTEGRATION_BRANCH, used local $INTEGRATION_BRANCH tag"
    else
      # Fallback 2: origin/$INTEGRATION_BRANCH HEAD (no tags at all)
      _dev_ref=$(git rev-parse --short "origin/$INTEGRATION_BRANCH" 2>/dev/null) || _dev_ref=""
      if [[ -n "$_dev_ref" ]]; then
        BASE_REF="origin/$INTEGRATION_BRANCH"
        BASE_GAP="no tags on $INTEGRATION_BRANCH, using HEAD of origin/$INTEGRATION_BRANCH"
      else
        # Honest-gap: integration branch not found — never guess the repo default branch
        echo "BRANCH: $BRANCH_NAME"
        echo "BASE:   "
        echo "STATUS: blocked"
        echo "GAP:    integration branch '$INTEGRATION_BRANCH' not found — declare base.integration_branch or create it (refusing to guess default branch)"
        exit 0
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Idempotency: create or reuse
# ---------------------------------------------------------------------------
if git rev-parse --verify "$BRANCH_NAME" &>/dev/null 2>&1; then
  # Branch already exists — check it out
  if ! git checkout "$BRANCH_NAME" 2>/dev/null; then
    echo "BRANCH: $BRANCH_NAME"
    echo "BASE:   $BASE_REF"
    echo "STATUS: blocked"
    echo "GAP:    branch exists but checkout failed"
    exit 0
  fi
  echo "BRANCH: $BRANCH_NAME"
  echo "BASE:   $BASE_REF"
  echo "STATUS: reused"
  [[ -n "$BASE_GAP" ]] && echo "GAP:    $BASE_GAP"
  [[ -n "$STACKED_BRANCH" ]] && echo "STACKED: $STACKED_BRANCH"
else
  # New branch — create from base ref
  if [[ -n "$STACKED_BRANCH" ]]; then _ck=(--no-track); else _ck=(); fi
  if ! git checkout -b "$BRANCH_NAME" "${_ck[@]}" "$BASE_REF" 2>/dev/null; then
    echo "BRANCH: $BRANCH_NAME"
    echo "BASE:   $BASE_REF"
    echo "STATUS: blocked"
    echo "GAP:    git checkout -b failed (check that base ref is valid)"
    exit 0
  fi
  echo "BRANCH: $BRANCH_NAME"
  echo "BASE:   $BASE_REF"
  echo "STATUS: created"
  [[ -n "$BASE_GAP" ]] && echo "GAP:    $BASE_GAP"
  [[ -n "$STACKED_BRANCH" ]] && echo "STACKED: $STACKED_BRANCH"
fi

exit 0
