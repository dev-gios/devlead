#!/usr/bin/env bash
# PostToolUse hook — runs shellcheck on .sh file edits, custom linter on others
# Input: JSON via stdin {"tool_name": "...", "tool_input": {"file_path": "..."}, "tool_response": {"filePath": "..."}}
# Exit semantics: non-zero surfaces linter output back to the model for self-correction.
# Graceful degradation: exits 0 when shellcheck/linter is absent.

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse file path from stdin JSON (primary: tool_input.file_path,
# fallback: tool_response.filePath — documented in Claude Code hooks schema)
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  FILE="$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"
else
  # Degrade: log warning and exit cleanly — hook must not crash the main flow
  echo "post-edit.sh: jq not found — cannot parse hook payload, skipping linter" >&2
  exit 0
fi

# Nothing to lint if no file path resolved
if [[ -z "$FILE" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Dispatch by file extension
# ---------------------------------------------------------------------------
EXT="${FILE##*.}"

if [[ "$EXT" == "sh" ]]; then
  # Shell file — run shellcheck
  if ! command -v shellcheck &>/dev/null; then
    echo "post-edit.sh: shellcheck not found — skipping (install shellcheck for gate enforcement)" >&2
    exit 0
  fi
  if ! shellcheck -S warning "$FILE" >&2; then
    # Non-zero exit surfaces findings to the model for self-correction (ADR-5)
    exit 1
  fi
else
  # Non-shell file — run project linter if configured
  if [[ -f "$PWD/.devlead/lint.sh" ]]; then
    if ! bash "$PWD/.devlead/lint.sh" "$FILE" >&2; then
      exit 1
    fi
  fi
  # No project linter configured — honest no-op (don't spam stderr)
fi

exit 0
