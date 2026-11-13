#!/usr/bin/env bash
# open-pr.sh — the single door through which the pipeline opens a PR.
#
# Usage: open-pr.sh --base <branch> --title <title> [--body <body>]
#                   [--label <label>]... [--draft]
#
# Runs, in order and WITHOUT short-circuiting:
#   1. gate-check.sh, the explicit full gate (clean tree + tests + shellcheck)
#   2. forbidden-check.sh over the files this work unit changes against <base>
# and only when both pass does it run `gh pr create` with the arguments it was
# given, exactly once.
#
# The door owns its interface instead of forwarding arguments to `gh`: it
# accepts only the options above (as `--opt value` or `--opt=value`) and builds
# the `gh pr create` call itself, always with `--head <checked-out branch>`.
# `gh` has many spellings for the flags that would point a PR elsewhere
# (`-R owner/repo`, `-Rowner/repo`, `-H`, a second `-B`); refusing everything
# outside a closed list is the only way to be sure none of them gets through.
#
# Why this exists: until now the gates were steps the command prose told the
# model to run before `gh pr create`. In an unattended run nothing checked that
# it did. Putting the gates and the PR creation behind one script makes "no PR
# with a red gate" a property of the code instead of a property of the prompt.
#
# Output contract:
#   - All green: stdout is exactly what `gh pr create` printed (the PR URL).
#     The gates' own chatter goes to stderr.
#   - Refused:   stdout carries the exact reason, every line prefixed with
#     `PARK_REASON: `. The gate's text is passed through verbatim (A4), so the
#     caller records it as-is instead of paraphrasing.
#
# Exit codes:
#   0  — PR created
#   1  — misuse (no --base or no --title)
#   2  — refused: a gate is red, the diff touches a forbidden zone, there is
#        nothing to ship, or the checks could not be run. `gh` was NOT invoked.
#   N  — `gh pr create` itself failed with exit code N (one attempt, no retry)
#
# This door has no escape hatch. DEVLEAD_FORCE_CLOSE is the gate's manual
# override for a human closing a session; it is stripped here so it can never
# turn a red gate into a PR.

set -uo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_reasons=()
# _refuse <text> — record a refusal reason; multi-line text is kept verbatim.
_refuse() { _reasons+=("$1"); }

_emit_reasons() {
  local _r _line
  for _r in "${_reasons[@]}"; do
    while IFS= read -r _line; do
      printf 'PARK_REASON: %s\n' "$_line"
    done <<<"$_r"
  done
}

# ---------------------------------------------------------------------------
# --base is required: it is both the PR target and what the forbidden-zone
# check measures against. Letting `gh` resolve the base implicitly would point
# the PR at the default branch and leave this script unable to say what the
# work unit changed.
# ---------------------------------------------------------------------------
_base=""
_title=""
_body=""
_labels=()
_draft=0
_bad_args=()
while [[ $# -gt 0 ]]; do
  _opt="$1"
  _val=""
  case "$_opt" in
    --draft) _draft=1; shift; continue ;;
    --base=*|--title=*|--body=*|--label=*)
      _val="${_opt#*=}"; _opt="${_opt%%=*}"; shift ;;
    --base|--title|--body|--label)
      if [[ $# -lt 2 ]]; then
        _bad_args+=("$_opt (missing value)"); shift; continue
      fi
      _val="$2"; shift 2 ;;
    *) _bad_args+=("$_opt"); shift; continue ;;
  esac
  case "$_opt" in
    --base)  _base="$_val" ;;
    --title) _title="$_val" ;;
    --body)  _body="$_val" ;;
    --label) _labels+=("$_val") ;;
  esac
done

if [[ -z "$_base" || -z "$_title" ]]; then
  _refuse "open-pr: --base <branch> and --title <title> are required"
  _emit_reasons
  echo "Usage: open-pr.sh --base <branch> --title <title> [--body <body>] [--label <label>]... [--draft]" >&2
  exit 1
fi

if ! _toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$_toplevel" ]]; then
  _refuse "open-pr: not inside a git repository"
  _emit_reasons
  exit 2
fi

# The gate looks for the test runner and resolves changed paths relative to
# the current directory. Judged from a subdirectory it finds neither and
# passes, so the checks always run from the repo root.
if ! cd "$_toplevel"; then
  _refuse "open-pr: cannot enter the repository root ($_toplevel)"
  _emit_reasons
  exit 2
fi

# ---------------------------------------------------------------------------
# The checks below judge the checked-out branch, so that is the branch the PR
# is opened for: the door names it to `gh` itself and takes no other head.
# ---------------------------------------------------------------------------
for _bad in "${_bad_args[@]}"; do
  _refuse "open-pr: unsupported argument: $_bad"
done
_head="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ -z "$_head" ]]; then
  _refuse "open-pr: HEAD is detached — there is no branch to open a PR for"
fi

# ---------------------------------------------------------------------------
# Locate the gate. Installed layout: ~/.devlead/scripts/open-pr.sh next to
# ~/.devlead/hooks/gate-check.sh. Repo layout: .devlead/scripts/ and
# .claude/hooks/. Deliberately no environment override: a variable that could
# repoint the gate would be a way around it.
# ---------------------------------------------------------------------------
_gate=""
for _cand in \
  "$_script_dir/../hooks/gate-check.sh" \
  "$_script_dir/../../.claude/hooks/gate-check.sh"; do
  if [[ -f "$_cand" ]]; then
    _gate="$_cand"
    break
  fi
done
_forbidden="$_script_dir/forbidden-check.sh"

# ---------------------------------------------------------------------------
# Check 1: the full gate. Empty stdin selects the explicit path (a hook
# delivery carries event JSON and is opt-in per session; this is not one).
# ---------------------------------------------------------------------------
if [[ -z "$_gate" ]]; then
  _refuse "open-pr: gate-check.sh not found next to this script — cannot verify the work unit"
else
  _gate_out="$(env -u DEVLEAD_FORCE_CLOSE bash "$_gate" </dev/null 2>&1)"
  _gate_rc=$?
  if [[ $_gate_rc -ne 0 ]]; then
    _refuse "gate-check failed (exit $_gate_rc):
$_gate_out"
  else
    [[ -n "$_gate_out" ]] && printf '%s\n' "$_gate_out" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Check 2: forbidden zones over what this work unit changes against the base.
# Prefer the remote-tracking ref (what the PR will actually be compared to);
# fall back to the local branch. No resolvable base -> refuse.
# ---------------------------------------------------------------------------
_base_ref=""
for _cand in "origin/$_base" "$_base"; do
  if git rev-parse --verify --quiet "${_cand}^{commit}" >/dev/null 2>&1; then
    _base_ref="$_cand"
    break
  fi
done

if [[ -z "$_base_ref" ]]; then
  _refuse "open-pr: cannot resolve base branch '$_base' (tried origin/$_base and $_base)"
elif [[ ! -f "$_forbidden" ]]; then
  _refuse "open-pr: forbidden-check.sh not found next to this script — cannot verify the diff"
else
  # Every path the branch touches, exactly as it is on disk:
  #   --no-renames  a file moved OUT of a zone still lists its old path
  #                 (rename detection would report only the destination)
  #   -z            NUL-separated and unquoted; without it git C-quotes
  #                 non-ASCII and control characters, and the trailing quote
  #                 hides the extension from the zone patterns
  _changed_paths=()
  _diff_ok=1
  if ! _diff_err="$(git diff --no-renames --name-only -z "$_base_ref...HEAD" 2>&1 >/dev/null)"; then
    _diff_ok=0
  else
    while IFS= read -r -d '' _path; do
      _changed_paths+=("$_path")
    done < <(git diff --no-renames --name-only -z "$_base_ref...HEAD" 2>/dev/null)
  fi

  if [[ $_diff_ok -eq 0 ]]; then
    _refuse "open-pr: cannot compute the diff against $_base_ref:
$_diff_err"
  else
    if [[ ${#_changed_paths[@]} -eq 0 ]]; then
      # No arguments + non-TTY stdin is forbidden-check's fail-closed
      # empty-diff case.
      _zone_out="$(bash "$_forbidden" </dev/null 2>&1)"
    else
      _zone_out="$(bash "$_forbidden" "${_changed_paths[@]}" </dev/null 2>&1)"
    fi
    _zone_status="$(sed -n 's/^STATUS:[[:space:]]*//p' <<<"$_zone_out" | head -n 1)"
    case "$_zone_status" in
      clear) ;;
      blocked)
        _zone="$(sed -n 's/^ZONE:[[:space:]]*//p' <<<"$_zone_out" | head -n 1)"
        _zone_path="$(sed -n 's/^PATH:[[:space:]]*//p' <<<"$_zone_out" | head -n 1)"
        _refuse "forbidden-zone: $_zone ($_zone_path)"
        ;;
      empty-diff)
        _refuse "empty-diff: nothing changed against $_base_ref — no work unit to open a PR for"
        ;;
      *)
        # Anything else is a contract we do not recognise: fail closed.
        _refuse "open-pr: forbidden-check returned no recognised STATUS:
$_zone_out"
        ;;
    esac
  fi
fi

if [[ ${#_reasons[@]} -gt 0 ]]; then
  _emit_reasons
  exit 2
fi

# ---------------------------------------------------------------------------
# Both checks passed: open the PR. One attempt; a failure is reported, never
# retried (a retry could open a duplicate).
# ---------------------------------------------------------------------------
_gh_args=(--base "$_base" --head "$_head" --title "$_title" --body "$_body")
for _label in "${_labels[@]}"; do
  _gh_args+=(--label "$_label")
done
[[ $_draft -eq 1 ]] && _gh_args+=(--draft)
gh pr create "${_gh_args[@]}"
_gh_rc=$?
if [[ $_gh_rc -ne 0 ]]; then
  _refuse "gh pr create failed (exit $_gh_rc)"
  _emit_reasons
  exit "$_gh_rc"
fi
exit 0
