#!/usr/bin/env bash
# doctor.sh — reports whether the artifacts published to this machine
# (~/.devlead/scripts, ~/.devlead/hooks, ~/.local/bin/devlead,
# ~/.claude/commands) match the repo's REVIEWED TRUNK — not merely "some
# prior publish ran successfully".
#
# WHY THIS EXISTS: the published artifacts include the code that enforces
# DevLead's own limits — gate-check.sh, envelope.sh's A3 guard, the
# governance mirrors in the command files. Running an unattended loop
# (sweep-loop.sh) against a stale or unreviewed copy of those is exactly the
# failure mode this whole project exists to avoid. Three times in one
# session the installed set silently diverged from the repo — once a month
# stale, once from an unmerged branch, once never re-published after a
# merge — and each time it was only caught by hand-diffing.
#
# Usage: doctor.sh
#
# Output (KEY: value, consistent with the rest of .devlead/scripts/*.sh):
#   STATUS: ok | drifted | unknown
#   TRUNK:  <branch> @ <short-sha>          — omitted if unresolvable
#   SOURCE: <repo path>                     — omitted if unresolvable
#   DRIFT:  <n> of <m> artifacts differ from the trunk
#   DIFF:   <installed path> (<reason>)     — one line per differing artifact
#   NOTE:   <stale-vs-branch classification> — only when cheaply determinable
#   GAP:    <reason>                        — only on STATUS: unknown
#
# Exit codes:
#   0  STATUS: ok
#   1  STATUS: drifted or STATUS: unknown — anything the caller (sweep-loop.sh)
#      must treat as "do not run unattended against this"
set -uo pipefail

# _unknown reason — the honest-failure exit. Never guess a SOURCE/TRUNK we
# could not actually resolve; print whatever WAS resolved (if anything) plus
# the gap, and exit non-zero.
_unknown() {
  echo "STATUS: unknown"
  [[ -n "${TRUNK_LABEL:-}" ]] && echo "TRUNK:  $TRUNK_LABEL"
  [[ -n "${SOURCE_LABEL:-}" ]] && echo "SOURCE: $SOURCE_LABEL"
  echo "GAP:    $1"
  exit 1
}

command -v git &>/dev/null || _unknown "git not found — cannot compare against the trunk"

# ---------------------------------------------------------------------------
# 1. Resolve SOURCE_REPO — the existing anchor (see bootstrap-lib.sh's
#    _bootstrap_source_repo ADR). Never guessed: absent or unreadable is
#    reported honestly, not defaulted to a readlink-based fallback — a
#    doctor that guesses its own patient's identity is worse than useless.
# ---------------------------------------------------------------------------
_anchor="$HOME/.devlead/SOURCE_REPO"
if [[ ! -f "$_anchor" ]]; then
  _unknown "no ~/.devlead/SOURCE_REPO anchor — run 'devlead init' or 'devlead upgrade' first"
fi
REPO_DIR="$(<"$_anchor")"
if [[ -z "$REPO_DIR" ]]; then
  _unknown "\$HOME/.devlead/SOURCE_REPO is empty"
fi
if [[ ! -d "$REPO_DIR/.git" ]]; then
  _unknown "\$HOME/.devlead/SOURCE_REPO ('$REPO_DIR') is not a readable git checkout"
fi
SOURCE_LABEL="$REPO_DIR"

# ---------------------------------------------------------------------------
# 2. Resolve the reviewed trunk — DUPLICATED from envelope.sh's
#    _resolve_default_branch, deliberately, not sourced: envelope.sh
#    dispatches unconditionally on $1 at the bottom of the file (see its
#    "Dispatch" section), so `source`-ing it here would execute one of its
#    subcommands (defaulting to `check`) as a side effect. Any change to
#    envelope.sh's _resolve_default_branch — the gh/timeout/symref
#    precedence, the DEVLEAD_GH_TIMEOUT_SECS validation — MUST be mirrored
#    here or these two copies diverge silently. envelope.sh is the
#    authoritative version; this is a deliberate, minimal, commented copy.
# ---------------------------------------------------------------------------
_GH_TIMEOUT_DEFAULT=10
GH_TIMEOUT_SECS="${DEVLEAD_GH_TIMEOUT_SECS:-$_GH_TIMEOUT_DEFAULT}"
if ! [[ "$GH_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
  echo "doctor: DEVLEAD_GH_TIMEOUT_SECS='$GH_TIMEOUT_SECS' is not a positive integer — using ${_GH_TIMEOUT_DEFAULT}s instead" >&2
  GH_TIMEOUT_SECS="$_GH_TIMEOUT_DEFAULT"
fi

_resolve_default_branch() {
  local repo_dir="$1"
  local _db _auth_rc _view_rc _gh_timeout=()
  if command -v timeout &>/dev/null; then
    _gh_timeout=(timeout "$GH_TIMEOUT_SECS")
  fi
  if command -v gh &>/dev/null; then
    ( cd "$repo_dir" && "${_gh_timeout[@]}" gh auth status ) &>/dev/null
    _auth_rc=$?
    if [[ ${#_gh_timeout[@]} -gt 0 && $_auth_rc -eq 124 ]]; then
      echo "doctor: gh auth status timed out after ${GH_TIMEOUT_SECS}s — falling back to local symref" >&2
    fi
    if [[ $_auth_rc -eq 0 ]]; then
      _db=$( cd "$repo_dir" && "${_gh_timeout[@]}" gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null )
      _view_rc=$?
      if [[ ${#_gh_timeout[@]} -gt 0 && $_view_rc -eq 124 ]]; then
        echo "doctor: gh repo view timed out after ${GH_TIMEOUT_SECS}s — falling back to local symref" >&2
      fi
      if [[ -n "$_db" ]]; then
        printf '%s' "$_db"
        return 0
      fi
    fi
  fi
  _db=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [[ -n "$_db" ]]; then
    printf '%s' "$_db"
    return 0
  fi
  return 1
}

TRUNK="$(_resolve_default_branch "$REPO_DIR")" || TRUNK=""
if [[ -z "$TRUNK" ]]; then
  _unknown "cannot resolve the reviewed trunk (gh repo view and git symbolic-ref refs/remotes/origin/HEAD both failed) for $REPO_DIR"
fi

TRUNK_SHA="$(git -C "$REPO_DIR" rev-parse --short "origin/$TRUNK" 2>/dev/null)"
if [[ -z "$TRUNK_SHA" ]]; then
  _unknown "resolved trunk '$TRUNK' but origin/$TRUNK does not exist in $REPO_DIR — fetch first"
fi
TRUNK_LABEL="$TRUNK @ $TRUNK_SHA"

# ---------------------------------------------------------------------------
# 3. Load the publish manifest — from origin/<trunk>'s copy of
#    bootstrap-lib.sh, NOT the working tree copy (the working tree may be on
#    any branch — see the header above). This makes the artifact LIST
#    itself trunk-derived, not just each artifact's content: a branch that
#    adds a new script to the manifest cannot make doctor.sh validate
#    against its own unreviewed addition.
#
#    Parsed textually (grep/sed on the raw source) rather than sourced —
#    bootstrap_symlinks/bootstrap_systemd build a LOCAL array and actually
#    publish files; there is no clean way to have them return their table
#    without running the copy side effects. This mirrors the textual
#    matching test/unit-publish-manifest.sh already does against the same
#    file. Any change to the `_pairs=( ... )` literal shape in
#    bootstrap-lib.sh must keep this parser in sync — this is the SAME
#    manifest, not a second hardcoded list.
# ---------------------------------------------------------------------------
_MANIFEST_CONTENT="$(git -C "$REPO_DIR" show "origin/$TRUNK:.devlead/scripts/bootstrap-lib.sh" 2>/dev/null)"
if [[ -z "$_MANIFEST_CONTENT" ]]; then
  _unknown "cannot read .devlead/scripts/bootstrap-lib.sh at origin/$TRUNK — cannot derive the artifact list"
fi

_symlinks_body="$(printf '%s\n' "$_MANIFEST_CONTENT" | sed -n '/^bootstrap_symlinks() {/,/^}/p')"
_systemd_body="$(printf '%s\n' "$_MANIFEST_CONTENT" | sed -n '/^bootstrap_systemd() {/,/^}/p')"

if [[ -z "$_symlinks_body" ]]; then
  _unknown "bootstrap_symlinks() not found in origin/$TRUNK's bootstrap-lib.sh — manifest shape changed, parser out of sync"
fi

# Destination base directories, read from bootstrap-lib.sh's OWN variable
# assignments (not re-derived independently), so a rename there cannot make
# this script silently check the wrong install location.
eval "$(printf '%s\n' "$_symlinks_body" | grep -E '^[[:space:]]*local (devlead_dir|local_bin|claude_commands)=' | sed 's/^[[:space:]]*local //')"
eval "$(printf '%s\n' "$_systemd_body" | grep -E '^[[:space:]]*local systemd_dir=' | sed 's/^[[:space:]]*local //')"

MANIFEST_SRC_REL=()
MANIFEST_DST=()

# _parse_pairs_into_manifest body — appends every "$repo_dir/...|$dst_var/...|mode"
# entry found in the given function body text to the global MANIFEST_* arrays.
_parse_pairs_into_manifest() {
  local _body="$1"
  local _entry _src_field _rest _dst_field _resolved_dst
  while IFS= read -r _entry; do
    [[ -n "$_entry" ]] || continue
    _src_field="${_entry%%|*}"
    _rest="${_entry#*|}"
    _dst_field="${_rest%%|*}"
    MANIFEST_SRC_REL+=("${_src_field#\$repo_dir/}")
    eval "_resolved_dst=\"$_dst_field\""
    MANIFEST_DST+=("$_resolved_dst")
  done < <(printf '%s\n' "$_body" | grep -oE '"\$repo_dir/[^"]*"' | tr -d '"')
}

_parse_pairs_into_manifest "$_symlinks_body"
_parse_pairs_into_manifest "$_systemd_body"

if [[ ${#MANIFEST_SRC_REL[@]} -eq 0 ]]; then
  _unknown "parsed zero artifacts out of bootstrap-lib.sh's manifest at origin/$TRUNK — parser out of sync"
fi

# ---------------------------------------------------------------------------
# 4. Compare each installed artifact against its content at origin/<trunk>.
#    Written to a temp file via direct redirection (not $(...)) so a
#    trailing-newline difference from command-substitution stripping can
#    never produce a false mismatch.
# ---------------------------------------------------------------------------
DIFF_LINES=()
_stale_src_rels=()
_stale_dst_paths=()

_total=${#MANIFEST_SRC_REL[@]}
for ((_i = 0; _i < _total; _i++)); do
  _src_rel="${MANIFEST_SRC_REL[$_i]}"
  _dst="${MANIFEST_DST[$_i]}"

  _trunk_tmp="$(mktemp)"
  if ! git -C "$REPO_DIR" show "origin/$TRUNK:$_src_rel" > "$_trunk_tmp" 2>/dev/null; then
    DIFF_LINES+=("$_dst (not found at origin/$TRUNK:$_src_rel)")
    rm -f "$_trunk_tmp"
    continue
  fi

  if [[ ! -f "$_dst" ]]; then
    DIFF_LINES+=("$_dst (missing — never installed, or removed since)")
  elif ! cmp -s "$_trunk_tmp" "$_dst"; then
    DIFF_LINES+=("$_dst (content differs from the trunk)")
    _stale_src_rels+=("$_src_rel")
    _stale_dst_paths+=("$_dst")
  fi
  rm -f "$_trunk_tmp"
done

DRIFT_COUNT=${#DIFF_LINES[@]}

if [[ "$DRIFT_COUNT" -eq 0 ]]; then
  echo "STATUS: ok"
  echo "TRUNK:  $TRUNK_LABEL"
  echo "SOURCE: $SOURCE_LABEL"
  echo "DRIFT:  0 of $_total artifacts differ from the trunk — installed set matches origin/$TRUNK"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Cheap stale-vs-branch classification, bounded to the last N trunk
#    commits per differing artifact (git plumbing only — no blob content is
#    ever materialized during the search, just ls-tree's blob SHA column).
#    "Stale" means every differing artifact's installed content matches SOME
#    earlier commit reachable from the trunk — a straightforward re-publish
#    fixes it. "Branch" means at least one does not match anything in that
#    bounded window — it likely came from an unreviewed/unmerged branch.
#    Missing artifacts are excluded (nothing to hash). Omitted entirely
#    (prints nothing) when there is nothing left to classify.
# ---------------------------------------------------------------------------
_classify_stale_or_branch() {
  local _limit=50
  local _checked_any=false _all_stale=true
  local _j _s _d _blob _hist _c _hist_blob _found
  for ((_j = 0; _j < ${#_stale_src_rels[@]}; _j++)); do
    _s="${_stale_src_rels[$_j]}"
    _d="${_stale_dst_paths[$_j]}"
    _blob="$(git hash-object "$_d" 2>/dev/null)" || continue
    _hist="$(git -C "$REPO_DIR" rev-list -n "$_limit" "origin/$TRUNK" -- "$_s" 2>/dev/null)"
    if [[ -z "$_hist" ]]; then
      _all_stale=false
      _checked_any=true
      continue
    fi
    _found=false
    while IFS= read -r _c; do
      [[ -n "$_c" ]] || continue
      _hist_blob="$(git -C "$REPO_DIR" ls-tree "$_c" -- "$_s" 2>/dev/null | awk '{print $3}')"
      if [[ -n "$_hist_blob" && "$_hist_blob" == "$_blob" ]]; then
        _found=true
        break
      fi
    done <<< "$_hist"
    _checked_any=true
    [[ "$_found" == "false" ]] && _all_stale=false
  done
  [[ "$_checked_any" == "false" ]] && return 0
  if [[ "$_all_stale" == "true" ]]; then
    printf '%s' "installed artifacts match an earlier commit on $TRUNK (within the last $_limit) — this looks STALE, not unreviewed: re-run 'devlead upgrade' (or bash install.sh)"
  else
    printf '%s' "installed artifacts do NOT match any of the last $_limit commits on $TRUNK — this does not look like simple staleness; check whether it came from an unmerged/unreviewed branch"
  fi
}

echo "STATUS: drifted"
echo "TRUNK:  $TRUNK_LABEL"
echo "SOURCE: $SOURCE_LABEL"
echo "DRIFT:  $DRIFT_COUNT of $_total artifacts differ from the trunk"
for _line in "${DIFF_LINES[@]}"; do
  echo "DIFF:   $_line"
done

_note="$(_classify_stale_or_branch)"
[[ -n "$_note" ]] && echo "NOTE:   $_note"

exit 1
