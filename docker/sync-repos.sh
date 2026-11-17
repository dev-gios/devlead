#!/usr/bin/env bash
# sync-repos.sh — brings the DevLead server's clones of the enrolled repos to
# their default branch as fetched from origin (S13). run-job.sh runs it, as
# the devlead user, before every job that works on them.
#
#   sync-repos.sh --all        every repo of /etc/devlead/repos
#   sync-repos.sh <path>...    these clones; each must be enrolled
#
# One line per repo on stdout, in order:
#   SYNCED TAB <path> TAB <default branch> TAB <commit>
#   FAILED TAB <path> TAB <reason>      and nothing after it: exit 1
# Git's own messages go to stderr.
#
# Where the clones are: root reads DEVLEAD_REPOS at container start
# (runner-config.sh) and writes /etc/devlead/repos, one `<host path> TAB
# <owner>/<repo>` per line. Each clone sits in the container at the path the
# repo has on the host, inside the workspace volume, so every piece of state
# keyed by the repo's path (agenda, decisions, journals, outcomes, ...) is the
# same key the host's /devlead reads. Root creates the clone's directory; the
# first sync clones into it.
#
# A previous session could have left anything in a clone: it works there. So
# before git reads anything from it, every run:
#   - checks .git is a real directory (its objects, refs and HEAD no links)
#     and not shallow (these clones never are); otherwise the clone is wiped
#     and cloned again;
#   - rewrites .git/config from scratch — the origin URL and refspec, nothing
#     else: no core.fsmonitor, hooksPath, alias, include, filter or sshCommand
#     survives — and removes what else git would read or act on later (see
#     _reset_gitdir): hooks, info/, worktrees, submodule repos, legacy remote
#     files, alternates, the index, commit-graph and pack indexes, operation
#     state (rebase, merge, cherry-pick, sequencer, bisect, rerere's rr-cache)
#     and stale locks. Every git command here also runs with
#     core.fsmonitor=false and core.hooksPath=/dev/null, and ignores replace
#     objects;
#   - fetches origin's branches and tags with force and prune — every tag is
#     origin's, none only the clone has — drops replace refs and the refs of
#     any other remote, finds origin's default branch (its HEAD), points
#     refs/remotes/origin/HEAD at it (guard.sh reads it to keep pushes off the
#     default branch), and checks it out with --force over a fresh index,
#     resetting the local branch of that name to it — never a branch someone
#     else pushed; then `git clean -ffdx` removes every untracked or ignored
#     file (CLAUDE.local.md, node_modules, a nested repo);
#   - checks the files on disk are that commit's: the commit object hashes to
#     its name, the index writes its tree, and every file hashes to its index
#     entry, as it is or through the repo's own end-of-line rules. A planted
#     object or a file the checkout left alone fails this; the clone is then
#     wiped and cloned again, once.
# What a session leaves behind in a clone is therefore what origin's default
# branch holds, nothing more: its CLAUDE.md and .claude/ are the repository's
# own, as trusted as its code and its envelope. Claude Code reads no project
# or local settings here anyway (the claude wrapper's --setting-sources user).
# Local branches, their reflogs and the stash stay: they are the sessions' own
# work, and nothing here starts from them.
#
# Not a sandbox: a session can still change a clone while it runs; this only
# keeps what it changed from reaching the next run.
set -uo pipefail

# --- Fixed paths (test/unit-sync-repos.sh rewrites these in a copy) -----------
REPOS_CONF=/etc/devlead/repos
GITHUB_URL=https://github.com
CONF_OWNER_UID=0
# ------------------------------------------------------------------------------

# Nothing from the caller's environment steers git here.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
      GIT_ATTR_SOURCE GIT_SSH GIT_SSH_COMMAND GIT_EXTERNAL_DIFF GIT_ASKPASS SSH_ASKPASS
export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
# A transfer that stalls below 1 KB/s for a minute is given up.
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

_usage() { echo "usage: sync-repos.sh --all | <enrolled repo path>..." >&2; }

declare -A SLUG=()
ORDER=()
_load_conf() {
  local mode path slug
  [[ -f "$REPOS_CONF" && ! -L "$REPOS_CONF" ]] || return 1
  [[ "$(stat -c %u "$REPOS_CONF" 2>/dev/null)" == "$CONF_OWNER_UID" ]] || return 1
  mode="$(stat -c %a "$REPOS_CONF" 2>/dev/null)"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 )) || return 1
  while IFS=$'\t' read -r path slug; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    [[ "$path" =~ ^(/[A-Za-z0-9._@+-]+)+$ && "$slug" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || return 1
    SLUG[$path]="$slug"
    ORDER+=("$path")
  done < "$REPOS_CONF"
}

REPO=""
# No hooks, no fsmonitor, and no background gc or maintenance that would
# outlive this script.
_GIT_SAFE=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false)
_git() { git -C "$REPO" "${_GIT_SAFE[@]}" "$@"; }

_fail() { # _fail <path> <reason>
  printf 'FAILED\t%s\t%s\n' "$1" "$2"
  echo "sync-repos: $1: $2" >&2
  exit 1
}

# _structure_ok — .git is a real directory, and what git finds through it is
# not a link to somewhere else.
_structure_ok() {
  local p
  [[ -d "$REPO/.git" && ! -L "$REPO/.git" ]] || return 1
  for p in objects objects/info objects/pack refs HEAD; do
    [[ -L "$REPO/.git/$p" ]] && return 1
  done
  [[ ! -e "$REPO/.git/shallow" && ! -L "$REPO/.git/shallow" ]] || return 1
  [[ -d "$REPO/.git/objects" && -f "$REPO/.git/HEAD" ]]
}

_wipe() { find "$REPO" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ; }

_clone() { # _clone <url>
  git "${_GIT_SAFE[@]}" clone --quiet --no-checkout --origin origin -- "$1" "$REPO" >&2
}

# _reset_gitdir <url> — rewrites .git/config, and removes every other file
# under .git that git reads as configuration, as a place to find objects, or
# as an operation to resume: config.worktree, hooks/, info/ (attributes,
# exclude, grafts, sparse-checkout), worktrees/, modules/, commondir,
# branches/ and remotes/ (legacy remote definitions), the index and its
# shared parts, object alternates, commit-graph, multi-pack-index, bitmaps
# and reverse indexes, the state of a rebase, merge, cherry-pick, revert,
# sequencer or bisect, rerere's rr-cache (which turns rerere on by existing),
# and stale lock files. What it keeps: objects (checked by _content_matches),
# refs (fetched over, or the sessions' own branches), logs and FETCH_HEAD.
_reset_gitdir() {
  local g="$REPO/.git"
  rm -rf -- "$g/config" "$g/config.worktree" "$g/hooks" "$g/info" "$g/worktrees" "$g/modules" \
            "$g/commondir" "$g/branches" "$g/remotes" "$g/index" "$g"/sharedindex.* \
            "$g/objects/info/alternates" "$g/objects/info/http-alternates" \
            "$g/objects/info/commit-graph" "$g/objects/info/commit-graphs" \
            "$g/objects/pack/multi-pack-index"* "$g"/objects/pack/*.bitmap "$g"/objects/pack/*.rev \
            "$g/rebase-merge" "$g/rebase-apply" "$g/sequencer" "$g/rr-cache" "$g"/BISECT_* \
            "$g/MERGE_HEAD" "$g/MERGE_MSG" "$g/MERGE_MODE" "$g/MERGE_RR" "$g/MERGE_AUTOSTASH" "$g/AUTO_MERGE" \
            "$g/CHERRY_PICK_HEAD" "$g/REVERT_HEAD" "$g/ORIG_HEAD" "$g"/*.lock || return 1
  find "$g/refs" -name '*.lock' -type f -delete 2>/dev/null || return 1
  printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n' \
    "$1" > "$g/config"
}

# _content_matches <commit> — the files on disk are exactly that commit's.
_content_matches() {
  local sha="$1" tree rec meta path mode obj _stage got i
  local paths=() want=() again=() again_want=()
  [[ "$(_git cat-file commit "$sha" 2>/dev/null | _git hash-object -t commit --stdin 2>/dev/null)" == "$sha" ]] || return 1
  tree="$(_git cat-file commit "$sha" | sed -n '1s/^tree //p')"
  [[ -n "$tree" && "$(_git write-tree 2>/dev/null)" == "$tree" ]] || return 1
  while IFS= read -r -d '' rec; do
    meta="${rec%%$'\t'*}"
    path="${rec#*$'\t'}"
    read -r mode obj _stage <<<"$meta"
    case "$mode" in
      160000) ;;                                   # a submodule: not checked out
      120000)
        [[ -L "$REPO/$path" ]] || return 1
        [[ "$(printf '%s' "$(readlink -- "$REPO/$path")" | _git hash-object --stdin)" == "$obj" ]] || return 1
        ;;
      *)
        [[ -f "$REPO/$path" && ! -L "$REPO/$path" && "$path" != *$'\n'* ]] || return 1
        paths+=("$path"); want+=("$obj")
        ;;
    esac
  done < <(_git ls-files -s -z)
  (( ${#paths[@]} > 0 )) || return 0
  i=0
  while IFS= read -r got; do
    if [[ "$got" != "${want[$i]}" ]]; then again+=("${paths[$i]}"); again_want+=("${want[$i]}"); fi
    i=$((i + 1))
  done < <(printf '%s\n' "${paths[@]}" | _git hash-object --no-filters --stdin-paths)
  (( i == ${#paths[@]} )) || return 1
  (( ${#again[@]} > 0 )) || return 0
  # The repo's own end-of-line rules may have converted these on checkout.
  i=0
  while IFS= read -r got; do
    [[ "$got" == "${again_want[$i]}" ]] || return 1
    i=$((i + 1))
  done < <(printf '%s\n' "${again[@]}" | _git hash-object --stdin-paths)
  (( i == ${#again[@]} ))
}

# _sync <path> — prints its SYNCED line, or fails.
_sync() {
  REPO="$1"
  local url="$GITHUB_URL/${SLUG[$REPO]}.git" attempt head branch sha ref
  [[ -d "$REPO" && ! -L "$REPO" ]] || _fail "$REPO" "the clone directory is missing (root creates it at container start)"
  [[ -O "$REPO" ]] || _fail "$REPO" "the clone directory is not this user's"
  for attempt in 1 2; do
    if [[ -e "$REPO/.git" || -L "$REPO/.git" ]] && ! _structure_ok; then
      echo "sync-repos: $REPO: .git is not a plain repository — cloning it again" >&2
      _wipe
    fi
    if [[ ! -e "$REPO/.git" ]]; then
      _wipe
      _clone "$url" || _fail "$REPO" "clone failed"
    fi
    _reset_gitdir "$url" || _fail "$REPO" "cannot reset .git"
    head="$(_git ls-remote --symref origin HEAD)" || _fail "$REPO" "origin cannot be reached"
    branch="$(sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]HEAD$|\1|p' <<<"$head" | head -n 1)"
    [[ -n "$branch" ]] && git check-ref-format --branch "$branch" >/dev/null 2>&1 \
      || _fail "$REPO" "origin has no default branch"
    _git fetch --quiet --prune --no-tags --no-recurse-submodules origin \
      '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' >&2 || _fail "$REPO" "fetch failed"
    sha="$(_git rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}")" \
      || _fail "$REPO" "the default branch was not fetched"
    while IFS= read -r ref; do
      _git update-ref -d "$ref" || _fail "$REPO" "cannot remove a replace ref or another remote's ref"
    done < <(_git for-each-ref --format='%(refname)' refs/replace/ refs/remotes/ | grep -v '^refs/remotes/origin/')
    _git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$branch" \
      || _fail "$REPO" "cannot point origin/HEAD at the default branch"
    _git checkout --quiet --force -B "$branch" "refs/remotes/origin/$branch" >&2 \
      || _fail "$REPO" "checkout failed"
    _git clean -ffdxq >&2 || _fail "$REPO" "clean failed"
    if [[ "$(_git rev-parse HEAD)" == "$sha" ]] && _content_matches "$sha"; then
      printf 'SYNCED\t%s\t%s\t%s\n' "$REPO" "$branch" "$sha"
      return 0
    fi
    if (( attempt == 1 )); then
      echo "sync-repos: $REPO: the files checked out are not origin's — cloning it again" >&2
      _wipe
    fi
  done
  _fail "$REPO" "the files checked out do not match origin"
}

[[ $# -gt 0 ]] || { _usage; exit 2; }
if ! _load_conf; then
  echo "sync-repos: no usable list of enrolled repos at $REPOS_CONF (root writes it when the container starts)" >&2
  exit 1
fi
targets=()
if [[ "$1" == "--all" ]]; then
  [[ $# -eq 1 ]] || { _usage; exit 2; }
  targets=("${ORDER[@]}")
else
  for p in "$@"; do
    [[ -n "${SLUG[$p]+x}" ]] || _fail "$p" "not an enrolled repo (DEVLEAD_REPOS)"
    targets+=("$p")
  done
fi
for p in "${targets[@]}"; do _sync "$p"; done
exit 0
