#!/usr/bin/env bash
# sweep.sh — DevLead Nivel 2: plan-only autonomous multi-repo sweep.
# Reads ~/.devlead/autonomous-repos (one absolute path per line; # = comment).
# Per enrolled+enabled repo: resolves auth, runs envelope.sh check+plan (read-only).
# ONLY filesystem write: ~/.devlead/reports/YYYY-MM-DD.md (OVERWRITE each run).
# ZERO mutation verbs: no branch creation, no PRs, no commits, no pushes.
set -uo pipefail

ENVELOPE_BIN="$HOME/.devlead/scripts/envelope.sh"
REPOS_FILE="$HOME/.devlead/autonomous-repos"
REPORTS_DIR="$HOME/.devlead/reports"
TOKEN_FILE="$HOME/.devlead/gh-token"
TODAY="$(date +%F)"
DIGEST_FILE="$REPORTS_DIR/${TODAY}.md"

# ---------------------------------------------------------------------------
# _ensure_auth — 4-step chain; sets _auth_token or returns 1 (auth unavailable)
# ---------------------------------------------------------------------------
_ensure_auth() {
  # Step 1: $GH_TOKEN env var
  if [[ -n "${GH_TOKEN:-}" ]]; then
    _auth_token="$GH_TOKEN"
    return 0
  fi

  # Step 2: ~/.devlead/gh-token file — require chmod 600 AND non-empty (FIX 3)
  if [[ -f "$TOKEN_FILE" ]]; then
    local perm
    perm=$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo "")
    if [[ "$perm" == "600" ]]; then
      local _tok_content
      _tok_content="$(cat "$TOKEN_FILE")"
      if [[ -n "$_tok_content" ]]; then
        _auth_token="$_tok_content"
        return 0
      else
        echo "sweep: WARNING: $TOKEN_FILE is 600 but empty — not used" >&2
        # fall through to step 3
      fi
    else
      echo "sweep: WARNING: $TOKEN_FILE has permissions $perm (not 600) — not used (security gate)" >&2
    fi
  fi

  # Step 3: gh auth token CLI
  local gh_tok
  if command -v gh &>/dev/null; then
    gh_tok="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$gh_tok" ]]; then
      _auth_token="$gh_tok"
      return 0
    fi
  fi

  # Step 4: auth unavailable
  return 1
}

# ---------------------------------------------------------------------------
# _sweep_repo <repo_path> — runs in a subshell; appends to digest via fd 3
# ---------------------------------------------------------------------------
_sweep_repo() {
  local repo_path="$1"

  # Gate: cd into repo
  if ! cd "$repo_path" 2>/dev/null; then
    echo "### $repo_path"
    echo "**STATUS: cannot-cd** — path does not exist or is not accessible"
    echo ""
    return
  fi

  # Gate 1: envelope check — ENROLLED?
  local check_out
  check_out=$(bash "$ENVELOPE_BIN" check 2>/dev/null)
  local enrolled
  enrolled=$(echo "$check_out" | grep "^ENROLLED:" | awk '{print $2}')
  if [[ "$enrolled" != "true" ]]; then
    echo "### $repo_path"
    echo "**STATUS: skipped** — reason: not enrolled (ENROLLED: ${enrolled:-false})"
    echo ""
    return
  fi

  # Gate 2: envelope check — ENABLED?
  local enabled
  enabled=$(echo "$check_out" | grep "^ENABLED:" | awk '{print $2}')
  if [[ "$enabled" != "true" ]]; then
    echo "### $repo_path"
    echo "**STATUS: skipped** — reason: ENABLED: ${enabled:-false}"
    echo ""
    return
  fi

  # Gate 3: auth chain
  local _auth_token=""
  if ! _ensure_auth; then
    echo "### $repo_path"
    echo "**STATUS: auth-unavailable** — no GitHub token resolved; plan not run"
    echo ""
    return
  fi

  # All gates passed — run plan (read-only)
  local plan_out
  plan_out=$(GH_TOKEN="${_auth_token}" bash "$ENVELOPE_BIN" plan 2>/dev/null)

  # FIX 1: Classify by POSITIVE success shape, not by absence of "blocked".
  # Genuine success: envelope.sh plan emits "=== DEVLEAD ENVELOPE PLAN" header,
  # no STATUS: line. Everything else is an explicit failure category.
  echo "### $repo_path"
  if echo "$plan_out" | grep -q "^STATUS: blocked"; then
    local gap
    gap=$(echo "$plan_out" | grep "^GAP:" | head -1 | sed 's/^GAP:[[:space:]]*//')
    echo "**STATUS: plan-blocked** — GAP: ${gap}"
    echo ""
  elif echo "$plan_out" | grep -q "^STATUS: paused"; then
    echo "**STATUS: plan-paused** — kill-switch active; plan not included"
    echo ""
  elif echo "$plan_out" | grep -q "^=== DEVLEAD ENVELOPE PLAN"; then
    echo "**STATUS: included** — plan ran successfully"
    echo ""
    # FIX 2: Use ~~~ fence; sanitize any ~~~ lines in plan output (extremely
    # unlikely, but defensive). Also neutralize any backtick-fence lines inside
    # the output to prevent Markdown structure break.
    echo "~~~"
    # shellcheck disable=SC2016
    echo "$plan_out" | sed 's/^~~~/~~~ /; s/^```/``` /'
    echo "~~~"
    echo ""
  else
    # Empty, crashed, or unknown output — honest error, NOT "success"
    echo "**STATUS: plan-error** — empty or unrecognized plan output (possible crash)"
    echo ""
    if [[ -n "$plan_out" ]]; then
      echo "~~~"
      # shellcheck disable=SC2016
      echo "$plan_out" | sed 's/^~~~/~~~ /; s/^```/``` /'
      echo "~~~"
      echo ""
    fi
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# Ensure reports dir exists
mkdir -p "$REPORTS_DIR"

# Check autonomous-repos file
if [[ ! -f "$REPOS_FILE" ]]; then
  {
    echo "# DevLead Sweep — ${TODAY}"
    echo ""
    echo "**No repos enrolled** — $REPOS_FILE does not exist."
    echo ""
    echo "Add repos with: echo /path/to/repo >> $REPOS_FILE"
  } > "$DIGEST_FILE"
  echo "sweep: no repos enrolled ($REPOS_FILE missing)" >&2
  exit 0
fi

# Collect processable lines — FIX 4: CRLF strip, whitespace-only skip, dedup
mapfile -t _all_lines < "$REPOS_FILE"

_repos=()
declare -A _seen_repos=()
for _line in "${_all_lines[@]}"; do
  # Strip trailing CR (CRLF support)
  _line="${_line%$'\r'}"
  # Skip blank, whitespace-only, and comment lines
  [[ -z "${_line//[[:space:]]/}" || "$_line" == \#* ]] && continue
  # Deduplicate: skip if this absolute path was already added
  if [[ -n "${_seen_repos[$_line]+_}" ]]; then
    continue
  fi
  _seen_repos["$_line"]=1
  _repos+=("$_line")
done

if [[ ${#_repos[@]} -eq 0 ]]; then
  {
    echo "# DevLead Sweep — ${TODAY}"
    echo ""
    echo "**No repos enrolled** — $REPOS_FILE exists but has no processable entries."
    echo ""
    echo "Add repos with: echo /path/to/repo >> $REPOS_FILE"
  } > "$DIGEST_FILE"
  echo "sweep: no repos enrolled (file empty or only comments)" >&2
  exit 0
fi

# Process repos — collect digest in a variable (OVERWRITE, not append)
_total=${#_repos[@]}
_included=0
_excluded=0
_digest_body=""

for _repo in "${_repos[@]}"; do
  _section="$( (
    # Subshell so cd does not affect our loop
    _sweep_repo "$_repo"
  ) )"

  # FIX 1: Only genuine "included" increments the included counter.
  if echo "$_section" | grep -q "^\*\*STATUS: included\*\*"; then
    (( _included++ )) || true
  else
    (( _excluded++ )) || true
  fi

  _digest_body+="$_section"$'\n'
done

# FIX 5: Atomic digest write via temp file + mv
_tmp="$(mktemp "$REPORTS_DIR/.sweep-XXXXXX.md")"
_write_ok=0
{
  echo "# DevLead Sweep — ${TODAY}"
  echo ""
  echo "**Repos processed:** ${_total} | **Included:** ${_included} | **Excluded/Skipped:** ${_excluded}"
  echo ""
  echo "---"
  echo ""
  printf '%s' "$_digest_body"
} > "$_tmp" && _write_ok=1

if [[ "$_write_ok" -eq 1 ]]; then
  mv -f "$_tmp" "$DIGEST_FILE"
  echo "sweep: digest written → $DIGEST_FILE (included: ${_included}/${_total})"
else
  rm -f "$_tmp"
  echo "sweep: ERROR: failed to write digest to temp file" >&2
  exit 1
fi

exit 0
