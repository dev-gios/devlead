#!/usr/bin/env bash
# state.sh — DevLead deterministic state assembler
# Emits DEVLEAD STATE v1 format to stdout. Always exits 0.
# Operates on $PWD (the user's work repo).
# No file writes, no env mutations, no side effects.

set -uo pipefail

# ---------------------------------------------------------------------------
# WARNINGS accumulator
# ---------------------------------------------------------------------------
WARNINGS=()

_warn() {
  WARNINGS+=("$1")
}

# ---------------------------------------------------------------------------
# Dependency detection
# ---------------------------------------------------------------------------
HAS_GH=false
HAS_JQ=false
GH_AUTH_STATUS="gh_missing"
REPO_NAME="unknown"
DEFAULT_BRANCH="main"

if command -v gh &>/dev/null; then
  HAS_GH=true
fi

if command -v jq &>/dev/null; then
  HAS_JQ=true
else
  _warn "jq not found — GitHub sections that require JSON parsing will be skipped"
fi

# ---------------------------------------------------------------------------
# Git repo detection
# ---------------------------------------------------------------------------
IS_GIT_REPO=false
HAS_REMOTE=false

if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  IS_GIT_REPO=true
  if git remote get-url origin &>/dev/null 2>&1; then
    HAS_REMOTE=true
  fi
fi

# ---------------------------------------------------------------------------
# Repo identity and default branch (only when git + remote available)
# ---------------------------------------------------------------------------
if [[ "$IS_GIT_REPO" == "true" && "$HAS_REMOTE" == "true" ]]; then
  if [[ "$HAS_GH" == "true" && "$HAS_JQ" == "true" ]]; then
    _repo_name_raw=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || _repo_name_raw=""
    if [[ -n "$_repo_name_raw" ]]; then
      REPO_NAME="$_repo_name_raw"
    else
      # fallback: parse remote URL
      _remote_url=$(git remote get-url origin 2>/dev/null) || _remote_url=""
      if [[ "$_remote_url" =~ github\.com[:/](.+/.+)(\.git)$ ]]; then
        REPO_NAME="${BASH_REMATCH[1]}"
      elif [[ "$_remote_url" =~ github\.com[:/](.+/.+)$ ]]; then
        REPO_NAME="${BASH_REMATCH[1]}"
      fi
    fi

    _default_branch_raw=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) || _default_branch_raw=""
    if [[ -n "$_default_branch_raw" ]]; then
      DEFAULT_BRANCH="$_default_branch_raw"
    else
      _symbolic=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || _symbolic=""
      if [[ -n "$_symbolic" ]]; then
        DEFAULT_BRANCH="${_symbolic##*/}"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# gh auth detection
# ---------------------------------------------------------------------------
if [[ "$HAS_GH" != "true" ]]; then
  GH_AUTH_STATUS="gh_missing"
elif [[ "$IS_GIT_REPO" != "true" ]]; then
  GH_AUTH_STATUS="n/a"
elif [[ "$HAS_REMOTE" != "true" ]]; then
  GH_AUTH_STATUS="n/a"
else
  if gh auth status &>/dev/null 2>&1; then
    GH_AUTH_STATUS="ok"
  else
    GH_AUTH_STATUS="unauthenticated"
    _warn "gh not authenticated — run 'gh auth login' to enable GitHub sections"
  fi
fi

# ---------------------------------------------------------------------------
# HEADER
# ---------------------------------------------------------------------------
if [[ "$IS_GIT_REPO" != "true" ]]; then
  _repo_field="NOT_A_GIT_REPO"
elif [[ "$HAS_REMOTE" != "true" ]]; then
  _repo_field="NO_REMOTE"
else
  _repo_field="$REPO_NAME"
fi

echo "=== DEVLEAD STATE v1 ==="
echo "REPO: ${_repo_field}"
echo "GH_AUTH: ${GH_AUTH_STATUS}"
echo "GENERATED_AT: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ---------------------------------------------------------------------------
# Section: BRANCHES
# ---------------------------------------------------------------------------
echo "--- BRANCHES ---"

if [[ "$IS_GIT_REPO" != "true" ]]; then
  echo "# UNAVAILABLE: not a git repo"
else
  (
    set +e
    while IFS=$'\t' read -r branch last_commit; do
      # skip empty
      [[ -z "$branch" ]] && continue

      # ahead/behind vs default branch
      if git rev-parse --verify "origin/${DEFAULT_BRANCH}" &>/dev/null 2>&1; then
        compare_ref="origin/${DEFAULT_BRANCH}"
      elif git rev-parse --verify "${DEFAULT_BRANCH}" &>/dev/null 2>&1; then
        compare_ref="${DEFAULT_BRANCH}"
      else
        compare_ref=""
      fi

      if [[ -n "$compare_ref" && "$branch" != "$DEFAULT_BRANCH" ]]; then
        counts=$(git rev-list --left-right --count "${compare_ref}...${branch}" 2>/dev/null) || counts="? ?"
        ahead=$(echo "$counts" | awk '{print $2}')
        behind=$(echo "$counts" | awk '{print $1}')
      else
        ahead="0"
        behind="0"
      fi

      printf '%s\t%s\t%s\t%s\n' "$branch" "$last_commit" "$ahead" "$behind"
    done < <(git for-each-ref --sort=-committerdate refs/heads \
      --format=$'%(refname:short)\t%(committerdate:iso8601)' 2>/dev/null)
  )
fi

echo ""

# ---------------------------------------------------------------------------
# Section: OPEN_PRS
# ---------------------------------------------------------------------------
echo "--- OPEN_PRS ---"

_pr_numbers=()

if [[ "$GH_AUTH_STATUS" != "ok" ]]; then
  echo "# UNAVAILABLE: GH_AUTH=${GH_AUTH_STATUS}"
elif [[ "$HAS_JQ" != "true" ]]; then
  echo "# UNAVAILABLE: jq not found"
else
  (
    set +e
    _pr_json=$(gh pr list --state open \
      --json number,title,state,reviewDecision,headRefName,updatedAt \
      --limit 50 2>/dev/null) || _pr_json="[]"

    if [[ -z "$_pr_json" || "$_pr_json" == "[]" ]]; then
      : # empty section — not an error
    else
      echo "$_pr_json" | jq -r '.[] |
        [
          ("#" + (.number | tostring)),
          .title,
          .state,
          (if .reviewDecision == null then "NONE" else .reviewDecision end),
          .updatedAt,
          .headRefName
        ] | @tsv' 2>/dev/null
    fi
  )
  # collect PR numbers for CI section (outside subshell)
  # shellcheck disable=SC2207
  _pr_numbers=($(gh pr list --state open --json number -q '.[].number' --limit 50 2>/dev/null || true))
fi

echo ""

# ---------------------------------------------------------------------------
# Section: CI_STATUS
# ---------------------------------------------------------------------------
echo "--- CI_STATUS ---"

if [[ "$GH_AUTH_STATUS" != "ok" ]]; then
  echo "# UNAVAILABLE: GH_AUTH=${GH_AUTH_STATUS}"
elif [[ "$HAS_JQ" != "true" ]]; then
  echo "# UNAVAILABLE: jq not found"
elif [[ ${#_pr_numbers[@]} -eq 0 ]]; then
  : # empty section — no open PRs
else
  for _pr_num in "${_pr_numbers[@]}"; do
    (
      set +e
      _gh_output=$(gh pr checks "$_pr_num" 2>&1)
      _exit_code=$?
      # gh pr checks exits 1 for both "real failures" and "no checks reported" —
      # distinguish by output text so we don't show false red on PRs with no CI yet.
      if echo "$_gh_output" | grep -q "no checks reported"; then
        _ci_status="no-checks"
      else
        case $_exit_code in
          0) _ci_status="green" ;;
          8) _ci_status="yellow" ;;
          1) _ci_status="red" ;;
          4) _ci_status="no-checks" ;;
          *)
            _ci_status="unknown"
            ;;
        esac
      fi
      printf '#%s\t%s\n' "$_pr_num" "$_ci_status"
    )
    # capture CI status — one PR failure must not abort the loop
    _subshell_exit=$?
    if [[ $_subshell_exit -ne 0 ]]; then
      printf '#%s\tunknown\n' "$_pr_num"
      _warn "Could not determine CI status for PR #${_pr_num}"
    fi
  done
fi

echo ""

# ---------------------------------------------------------------------------
# Section: ASSIGNED_ISSUES
# ---------------------------------------------------------------------------
echo "--- ASSIGNED_ISSUES ---"

if [[ "$GH_AUTH_STATUS" != "ok" ]]; then
  echo "# UNAVAILABLE: GH_AUTH=${GH_AUTH_STATUS}"
elif [[ "$HAS_JQ" != "true" ]]; then
  echo "# UNAVAILABLE: jq not found"
else
  (
    set +e
    _issues_json=$(gh issue list --assignee @me --state open \
      --json number,title,labels,updatedAt \
      --limit 50 2>/dev/null) || _issues_json="[]"

    if [[ -z "$_issues_json" || "$_issues_json" == "[]" ]]; then
      : # empty section — not an error
    else
      echo "$_issues_json" | jq -r '.[] |
        [
          ("#" + (.number | tostring)),
          .title,
          (if (.labels | length) == 0 then "" else [.labels[].name] | join(",") end),
          .updatedAt
        ] | @tsv' 2>/dev/null
    fi
  )
fi

echo ""

# ---------------------------------------------------------------------------
# Section: WARNINGS
# ---------------------------------------------------------------------------
echo "--- WARNINGS ---"
for _w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
  echo "$_w"
done

echo ""
echo "=== END ==="
exit 0
