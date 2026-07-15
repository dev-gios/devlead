#!/usr/bin/env bash
# ref-resolver.sh — DevLead per-issue spec resolver
# Fetches issue body, parses Spec: and Design: references, writes spec to a
# temp file and prints the path. Always exits 0 (honest-gap pattern).
# Operates on $PWD (the user's work repo).
#
# Usage: ref-resolver.sh <issue-number>
#
# Output:
#   DESIGN: <path>                (when Design: line found)
#   SPEC:   <abs-temp-path> | none
#   SOURCE: <relative-doc-path>   (when SPEC found)
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
# NOTE: ISSUE_NUM is assigned before the --task-spec guard below. The guard
# exits before ISSUE_NUM is ever used, so this ordering is safe — but do NOT
# move the ISSUE_NUM assignment to after the guard without also verifying that
# every code path in the normal (non-task-spec) branch still receives $1 as
# the issue number before any arg-shifting occurs.

# ---------------------------------------------------------------------------
# --task-spec mode: short-circuit for LOCAL-PLAN (no gh dependency)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--task-spec" ]]; then
  # Step 1: Parse _spec_path ($2), _task_id ($3), scan for --task-design → _design_path
  _spec_path="${2:-}"
  _task_id="${3:-}"          # optional; used to name temp file; falls back to slug of path
  _design_path=""
  # Scan remaining args for --task-design <path> (fixed shift: consume $1/$2 for
  # --task-spec first, then $3 for task_id, leaving only extra args for the scan)
  shift 2 || true
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--task-design" ]]; then
      _design_path="${2:-}"; shift; [[ $# -gt 0 ]] && shift
    else
      shift
    fi
  done

  # Step 2: Empty-spec guard
  if [[ -z "$_spec_path" ]]; then
    echo "SPEC:   none"
    echo "GAP:    no spec path provided (--task-spec requires a path)"
    exit 0
  fi

  # Step 3: task_id fallback slug
  if [[ -z "$_task_id" ]]; then
    _task_id=$(printf '%s' "$_spec_path" \
      | tr '[:upper:]' '[:lower:]' | tr ' /' '-' \
      | tr -cd '[:alnum:]-' | tr -s '-' | cut -c1-40)
    _task_id="${_task_id%-}"
  fi

  # Step 4: Absolute-SPEC guard — plan spec: must be repo-relative (ADR-3
  # convention). Fail with a clear message instead of silently stripping the
  # leading '/' and reporting a misleading resolved path.
  if [[ "$_spec_path" == /* ]]; then
    echo "SPEC:   none"
    echo "SOURCE: ${_spec_path}"
    echo "GAP:    path debe ser repo-relativo, no absoluto: ${_spec_path}"
    exit 0
  fi

  # Step 5: Resolve spec path relative to $PWD (work repo root)
  _spec_path_resolved="${PWD}/${_spec_path}"
  _spec_path_resolved=$(printf '%s' "$_spec_path_resolved" | sed 's|//|/|g')
  if [[ ! -f "$_spec_path_resolved" ]]; then
    echo "SPEC:   none"
    echo "SOURCE: ${_spec_path}"
    echo "GAP:    file not found at ${_spec_path_resolved}"
    exit 0
  fi

  # Step 6: Spec is valid — now handle design.
  # An absolute design path is NOT emitted on stdout (avoids a bare GAP: that
  # would falsely PARK a task whose spec is perfectly valid). The advisory goes
  # to STDERR only so it cannot pollute the parsed stdout contract.
  if [[ -n "$_design_path" ]]; then
    if [[ "$_design_path" == /* ]]; then
      echo "WARN: design path absoluto ignorado (debe ser repo-relativo): ${_design_path}" >&2
      # _design_path intentionally left non-empty internally but NOT emitted
      _design_path=""
    else
      echo "DESIGN: ${_design_path}"
    fi
  fi

  # Step 7: Emit the spec result
  _run_dir="${HOME}/.devlead/run"
  mkdir -p "$_run_dir"
  _temp_path="${_run_dir}/plan-${_task_id}-spec.md"
  _ext="${_spec_path##*.}"
  _ext_lower=$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')
  if [[ "$_ext_lower" == "pdf" ]]; then
    # PDF: emit path directly — let the prose layer read it via pdf-reading skill
    echo "SPEC:   ${_spec_path_resolved}"
    echo "SOURCE: ${_spec_path}"
  else
    # Markdown (and all other text formats): copy to temp file
    if cp "$_spec_path_resolved" "$_temp_path" 2>/dev/null; then
      echo "SPEC:   ${_temp_path}"
      echo "SOURCE: ${_spec_path}"
    else
      echo "SPEC:   none"
      echo "SOURCE: ${_spec_path}"
      echo "GAP:    failed to write spec to ${_temp_path}"
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Dependency: gh must be present and authenticated
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
  echo "SPEC:   none"
  echo "GAP:    gh not found — install GitHub CLI to enable spec resolution"
  echo "DEP-CHECK: unavailable"
  exit 0
fi

if ! gh auth status &>/dev/null 2>&1; then
  echo "SPEC:   none"
  echo "GAP:    gh unavailable — run 'gh auth login' to enable spec resolution"
  echo "DEP-CHECK: unavailable"
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch issue body
# ---------------------------------------------------------------------------
_body=$(gh issue view "$ISSUE_NUM" --json body -q .body 2>/dev/null) || _body=""

if [[ -z "$_body" ]]; then
  echo "SPEC:   none"
  echo "GAP:    issue #${ISSUE_NUM} not found or has empty body"
  echo "DEP-CHECK: unavailable"
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
