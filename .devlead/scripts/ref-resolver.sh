#!/usr/bin/env bash
# ref-resolver.sh — DevLead per-issue spec resolver
# Fetches issue body, parses Spec: and Design: references, writes spec to a
# temp file and prints the path. Always exits 0 (honest-gap pattern).
# Operates on $PWD (the user's work repo).
#
# Usage: ref-resolver.sh <issue-number>
#
# Output:
#   SPEC:   <abs-temp-path> | none
#   SOURCE: <relative-doc-path>   (when SPEC found)
#   DESIGN: <path>                (when Design: line found)
#   GAP:    <reason>              (when none or blocked)

set -uo pipefail

# ---------------------------------------------------------------------------
# Usage guard
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: ref-resolver.sh <issue-number>" >&2
  exit 1
fi

ISSUE_NUM="$1"

# ---------------------------------------------------------------------------
# Dependency: gh must be present and authenticated
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
  echo "SPEC:   none"
  echo "GAP:    gh not found — install GitHub CLI to enable spec resolution"
  exit 0
fi

if ! gh auth status &>/dev/null 2>&1; then
  echo "SPEC:   none"
  echo "GAP:    gh unavailable — run 'gh auth login' to enable spec resolution"
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch issue body
# ---------------------------------------------------------------------------
_body=$(gh issue view "$ISSUE_NUM" --json body -q .body 2>/dev/null) || _body=""

if [[ -z "$_body" ]]; then
  echo "SPEC:   none"
  echo "GAP:    issue #${ISSUE_NUM} not found or has empty body"
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse Spec: line (case-insensitive, trim whitespace)
# ---------------------------------------------------------------------------
_spec_path=""
_spec_line=$(printf '%s' "$_body" | grep -i '^[[:space:]]*Spec:[[:space:]]*' | head -n1) || _spec_line=""

if [[ -n "$_spec_line" ]]; then
  # Extract the path after "Spec:" — strip leading/trailing whitespace
  _spec_path=$(printf '%s' "$_spec_line" \
    | sed 's/^[[:space:]]*[Ss]pec:[[:space:]]*//' \
    | sed 's/[[:space:]]*$//')
fi

# ---------------------------------------------------------------------------
# Parse Design: line
# ---------------------------------------------------------------------------
_design_path=""
_design_line=$(printf '%s' "$_body" | grep -i '^[[:space:]]*Design:[[:space:]]*' | head -n1) || _design_line=""

if [[ -n "$_design_line" ]]; then
  _design_path=$(printf '%s' "$_design_line" \
    | sed 's/^[[:space:]]*[Dd]esign:[[:space:]]*//' \
    | sed 's/[[:space:]]*$//')
fi

# ---------------------------------------------------------------------------
# Emit Design: line (path only — prose layer handles PDF ingestion per ADR-3)
# ---------------------------------------------------------------------------
if [[ -n "$_design_path" ]]; then
  echo "DESIGN: ${_design_path}"
fi

# ---------------------------------------------------------------------------
# Parse Depends-on: — canonical ONE line ONE issue
# ---------------------------------------------------------------------------
_dep_count=$(printf '%s' "$_body" | grep -ic '^[[:space:]]*Depends-on:') || _dep_count=0
_dep_line=$(printf '%s' "$_body" | grep -i '^[[:space:]]*Depends-on:[[:space:]]*' | head -n1) || _dep_line=""
if [[ -n "$_dep_line" ]]; then
  _dep_val=$(printf '%s' "$_dep_line" | sed 's/^[[:space:]]*depends-on:[[:space:]]*//I' | sed 's/[[:space:]]*$//')
  if [[ "$_dep_count" -gt 1 || "$_dep_val" == *,* ]]; then
    echo "GAP:    multi-predecesor no soportado en v1"
  else
    _dep_num="${_dep_val#\#}"
    if [[ "$_dep_num" =~ ^[0-9]+$ ]]; then
      echo "DEPENDS-ON: ${_dep_num}"
    else
      echo "GAP:    Depends-on valor no reconocido"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Handle missing Spec: line
# ---------------------------------------------------------------------------
if [[ -z "$_spec_path" ]]; then
  echo "SPEC:   none"
  echo "GAP:    no Spec: line found in issue #${ISSUE_NUM} body"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve path relative to $PWD (work repo root)
# ---------------------------------------------------------------------------
_abs_path="${PWD}/${_spec_path}"
# Normalize — remove double slashes
_abs_path=$(printf '%s' "$_abs_path" | sed 's|//|/|g')

if [[ ! -f "$_abs_path" ]]; then
  echo "SPEC:   none"
  echo "SOURCE: ${_spec_path}"
  echo "GAP:    file not found at ${_abs_path}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Write spec content to temp file for SDD handoff (ADR-3/ADR-6)
# markdown: write content; PDF: emit path only, don't inline
# ---------------------------------------------------------------------------
_run_dir="${HOME}/.devlead/run"
mkdir -p "$_run_dir"
_temp_path="${_run_dir}/issue-${ISSUE_NUM}-spec.md"

_ext="${_spec_path##*.}"
_ext_lower=$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')

if [[ "$_ext_lower" == "pdf" ]]; then
  # PDF: emit path directly — let the prose layer read it via pdf-reading skill
  echo "SPEC:   ${_abs_path}"
  echo "SOURCE: ${_spec_path}"
else
  # Markdown (and all other text formats): copy to temp file
  if cp "$_abs_path" "$_temp_path" 2>/dev/null; then
    echo "SPEC:   ${_temp_path}"
    echo "SOURCE: ${_spec_path}"
  else
    echo "SPEC:   none"
    echo "SOURCE: ${_spec_path}"
    echo "GAP:    failed to write spec to ${_temp_path}"
  fi
fi

exit 0
