#!/usr/bin/env bash
# merge.sh — the single door through which the pipeline merges a PR.
#
# Usage: merge.sh <pr-number | pr-url>
#
# DevLead's merge authority is whatever `merge.mode` in the repo's envelope
# grants, and the envelope is written by the user (GOVERNANCE.md §A3). This
# script READS it through `envelope.sh show` and never writes it. It merges
# only when ALL of these hold:
#   1. `envelope.sh show` reports STATUS: ok (which already proves that
#      base.integration_branch is not the remote's default branch)
#   2. MERGE_MODE is exactly `integration-branch`
#   3. the PR is OPEN and its base is exactly base.integration_branch
#
# Until now the merge was a `gh pr merge` line in the command prose, guarded by
# preconditions the model was told to check. Here they are checked in code, so
# a run with `merge.mode: never` cannot merge whatever the prompt does.
#
# The interface is closed on purpose: one PR reference and nothing else. The
# door builds the `gh` call itself (`gh pr merge <n> --merge`), so there is no
# way to pass `--admin`, another repository or another merge strategy.
#
# Output contract: on refusal or failure, stdout carries the exact reason,
# every line prefixed with `PARK_REASON: ` (A4 — recorded verbatim).
#
# Exit codes:
#   0  — merged
#   1  — misuse (not exactly one PR number or PR URL)
#   2  — refused; `gh pr merge` was NOT invoked
#   N  — `gh pr merge` itself failed with exit code N (one attempt, no retry)

set -uo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_park() {
  local _line
  while IFS= read -r _line; do
    printf 'PARK_REASON: %s\n' "$_line"
  done <<<"$1"
}

_usage() {
  _park "merge: expected exactly one PR number or PR URL"
  echo "Usage: merge.sh <pr-number | pr-url>" >&2
  exit 1
}

[[ $# -eq 1 ]] || _usage
_pr=""
if [[ "$1" =~ ^[0-9]+$ ]]; then
  _pr="$1"
elif [[ "$1" =~ ^https://[^/[:space:]]+/[^/[:space:]]+/[^/[:space:]]+/pull/([0-9]+)/?$ ]]; then
  _pr="${BASH_REMATCH[1]}"
else
  _usage
fi

if ! _toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$_toplevel" ]] \
   || ! cd "$_toplevel"; then
  _park "merge refused: not inside a git repository"
  exit 2
fi

# `gh` honours these to target another repository or host. The authority read
# below is for THIS repository, so they are dropped for every gh call here.
unset GH_REPO GH_HOST

# ---------------------------------------------------------------------------
# 1 + 2: authority, read from the envelope. Anything but STATUS: ok refuses.
# ---------------------------------------------------------------------------
_envelope="$_script_dir/envelope.sh"
if [[ ! -f "$_envelope" ]]; then
  _park "merge refused: envelope.sh not found next to this script — cannot read merge authority"
  exit 2
fi
_show="$(bash "$_envelope" show </dev/null 2>/dev/null)"
_status="$(sed -n 's/^STATUS:[[:space:]]*//p' <<<"$_show" | head -n 1)"
if [[ "$_status" != "ok" ]]; then
  _gap="$(sed -n 's/^GAP:[[:space:]]*//p' <<<"$_show" | head -n 1)"
  _park "merge refused: envelope blocked — ${_gap:-envelope.sh show did not report STATUS: ok}"
  exit 2
fi
_mode="$(sed -n 's/^MERGE_MODE:[[:space:]]*//p' <<<"$_show" | head -n 1)"
_ib="$(sed -n 's/^INTEGRATION_BRANCH:[[:space:]]*//p' <<<"$_show" | head -n 1)"
if [[ "$_mode" != "integration-branch" ]]; then
  _park "merge refused: merge.mode is '${_mode:-unset}' — the envelope does not grant merging"
  exit 2
fi
if [[ -z "$_ib" ]]; then
  _park "merge refused: the envelope declares no integration branch"
  exit 2
fi

# ---------------------------------------------------------------------------
# 3: the PR itself, asked of the remote — not assumed from what the caller
# believes it opened.
# ---------------------------------------------------------------------------
if ! _view="$(gh pr view "$_pr" --json baseRefName,state \
      -q '"\(.baseRefName)\t\(.state)"' 2>&1)"; then
  _park "merge refused: cannot read PR #$_pr:
$_view"
  exit 2
fi
_pr_base="${_view%%$'\t'*}"
_pr_state="${_view#*$'\t'}"
if [[ "$_pr_state" != "OPEN" ]]; then
  _park "merge refused: PR #$_pr is ${_pr_state:-in an unknown state}, not OPEN"
  exit 2
fi
if [[ "$_pr_base" != "$_ib" ]]; then
  _park "merge refused: PR #$_pr targets '$_pr_base', not the integration branch '$_ib'"
  exit 2
fi

# ---------------------------------------------------------------------------
# Merge. One attempt; never forced, never retried.
# ---------------------------------------------------------------------------
_merge_out="$(gh pr merge "$_pr" --merge 2>&1)"
_rc=$?
if [[ $_rc -ne 0 ]]; then
  _park "${_merge_out:-gh pr merge failed}"
  _park "gh pr merge failed (exit $_rc)"
  exit "$_rc"
fi
[[ -n "$_merge_out" ]] && printf '%s\n' "$_merge_out"
exit 0
