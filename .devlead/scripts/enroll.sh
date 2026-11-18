#!/usr/bin/env bash
# enroll.sh — `devlead enroll <folder> [--dry-run]` (S24): enroll every git
# repo directly under a folder in one go. The user answers the envelope
# questions once; each repo gets one PR that adds .devlead/envelope.yml to its
# default branch; the output ends with the DEVLEAD_REPOS line for the
# server's .env.
#
# GOVERNANCE.md §A3 ("Quién escribe el envelope"): the envelope is written
# only by the user. This command is the user writing it, for many repos at
# once, and it holds the same two requirements as `devlead config`, plus more:
#
#   1. It refuses to run without a TTY on stdin — the gate below runs before
#      anything else is read, asked or written.
#   2. It is out of every session's reach: it refuses inside a Claude Code
#      session (CLAUDECODE), under a Claude Code ancestor process (the walk
#      below, which needs no help from the environment), in an unattended run
#      (DEVLEAD_GUARD=1) and in the DevLead server (its root-owned marker);
#      guard.sh blocks a session that names it; and no autonomous path
#      invokes it (test/unit-enroll.sh E10). What still escapes is a process
#      started outside the session's tree (GOVERNANCE.md §A3 lists it); the
#      user's own merge of each PR stays the last gate.
#
# It carries no menu of its own: the questions are config.sh's envelope
# editor, run on a draft envelope in a scratch repo (DEVLEAD_CONFIG_ENVELOPE_ONLY),
# starting from the scaffold `envelope.sh template` prints. The answers are
# then checked per repo with `envelope.sh show`, so every rule that file
# enforces — base.integration_branch must not be that repo's default branch,
# among them — refuses the repos it applies to and only those.
#
# The user's working copies are never touched: no checkout, no worktree, no
# change to the current branch, the index or the stash. Per repo, it fetches
# origin's default branch, builds the commit with git plumbing in a private
# index, and pushes it to a new branch. In the user's repo exactly three refs
# change (test/unit-enroll.sh E15): refs/remotes/origin/<default> and
# FETCH_HEAD, written by the fetch, and refs/remotes/origin/devlead/enroll,
# written by the push; plus the new commit's objects. No hook of the repo
# runs: nothing here commits or checks out in the user's tree.
set -uo pipefail

# ---------------------------------------------------------------------------
# TTY gate — FIRST, before any other statement (GOVERNANCE.md §A3).
# ---------------------------------------------------------------------------
if [[ ! -t 0 ]]; then
  echo "enroll: refusing to run — stdin is not a TTY." >&2
  echo "enroll: GOVERNANCE.md §A3: the envelope is written only by the user." >&2
  echo "        Without an interactive terminal there is nobody to answer its" >&2
  echo "        questions, so this command reads and writes nothing." >&2
  echo "enroll: run it from your own terminal." >&2
  exit 1
fi
# Out of every session's reach (GOVERNANCE.md §A3). Claude Code sets
# CLAUDECODE in the environment of the commands it runs; the unattended
# launchers export DEVLEAD_GUARD=1; the server image carries a root-owned
# marker. A pty does not make any of them a human at a terminal.
if [[ -n "${CLAUDECODE:-}" ]]; then
  echo "enroll: refusing to run inside a Claude Code session (GOVERNANCE.md §A3):" >&2
  echo "        only you enroll repos. Run devlead enroll from your own terminal," >&2
  echo "        not through Claude Code's ! prefix." >&2
  exit 1
fi
# >>> _claude_code_ancestor — kept identical in config.sh and enroll.sh
# (test/unit-enroll.sh E12 compares the two copies).
# Is any ancestor of this process Claude Code? Walks the parent chain through
# /proc (the ppid field of /proc/<pid>/stat) and looks at each process's comm,
# exe and argv[0]: the claude binary (claude, claude.exe, or an exe under
# .../claude/versions/), or node, bun or deno running Claude Code's CLI
# (@anthropic-ai/claude-code in its argv). CLAUDECODE and guard.sh's text
# rules can be got around from inside a session (env -u, a pty tool, setsid);
# the session's own process tree cannot.
# Prints "<pid> <comm>" and returns 0 on a match. Returns 1 when no ancestor
# is Claude Code, and on a system without /proc (not Linux), where the other
# checks still apply. Returns 2 when /proc cannot be read on Linux: the
# caller fails closed.
_claude_code_ancestor() {
  local pid="$$" ppid stat comm exe argv0 cmd n=0
  if [[ ! -r "/proc/$$/stat" ]]; then
    [[ "$(uname -s 2>/dev/null)" == Linux ]] && return 2
    return 1
  fi
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && n < 512 )); do
    n=$((n + 1))
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 2
    [[ -n "$stat" ]] || return 2
    # comm sits in parentheses and may hold spaces or ')': the state and the
    # ppid are the first two fields after the LAST ') '.
    read -r _ ppid _ <<<"${stat##*) }"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
    exe="${exe% (deleted)}"
    cmd="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)"
    argv0="${cmd%%$'\n'*}"
    case "$comm" in claude|claude.exe) printf '%s %s\n' "$pid" "$comm"; return 0 ;; esac
    case "${exe##*/}" in claude|claude.exe) printf '%s %s\n' "$pid" "$comm"; return 0 ;; esac
    case "${argv0##*/}" in claude|claude.exe) printf '%s %s\n' "$pid" "$comm"; return 0 ;; esac
    case "$exe" in */claude/versions/*) printf '%s %s\n' "$pid" "$comm"; return 0 ;; esac
    case "$comm|${exe##*/}" in
      node\|*|nodejs\|*|bun\|*|deno\|*|*\|node|*\|nodejs|*\|bun|*\|deno)
        if [[ "$cmd" == *@anthropic-ai/claude-code* ]]; then
          printf '%s %s\n' "$pid" "$comm"; return 0
        fi ;;
    esac
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 2
    pid="$ppid"
  done
  return 1
}
# <<< _claude_code_ancestor
_cc="$(_claude_code_ancestor)"
case $? in
  0)
    echo "enroll: refusing to run under Claude Code (process ${_cc}) — GOVERNANCE.md §A3:" >&2
    echo "        only you enroll repos. Run devlead enroll from your own terminal," >&2
    echo "        not through Claude Code's ! prefix or a session." >&2
    exit 1 ;;
  2)
    echo "enroll: cannot read /proc to check what started this command — refusing" >&2
    echo "        (fail closed, GOVERNANCE.md §A3)." >&2
    exit 1 ;;
esac
if [[ "${DEVLEAD_GUARD:-}" == "1" ]]; then
  echo "enroll: refusing to run in an unattended DevLead run (DEVLEAD_GUARD=1) — GOVERNANCE.md §A3." >&2
  exit 1
fi
if [[ -e /etc/devlead/server-mode ]]; then
  echo "enroll: refusing to run in the DevLead server — run it on your machine, from your own terminal." >&2
  exit 1
fi

_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ENVELOPE_BIN="$_SELF_DIR/envelope.sh"
CONFIG_BIN="$_SELF_DIR/config.sh"

BRANCH="devlead/enroll"
ENVELOPE_PATH=".devlead/envelope.yml"
COMMIT_SUBJECT="chore(devlead): add the DevLead envelope"

# The server's rules for DEVLEAD_WORKSPACE and the paths of DEVLEAD_REPOS,
# copied from docker/runner-config.sh (_valid_path, _within, IMAGE_PATHS):
# that file is not installed on the host. test/unit-enroll.sh keeps the two
# image-path lists equal.
_IMAGE_PATHS=(/bin /boot /dev /etc /home/devlead /lib /lib32 /lib64 /libx32 /opt /proc /root /run /sbin /sys /tmp /usr /var)
_valid_path() {
  local part parts=()
  [[ ${#1} -le 1024 && "$1" =~ ^(/[A-Za-z0-9._@+-]+)+$ ]] || return 1
  IFS=/ read -ra parts <<<"${1#/}"
  for part in "${parts[@]}"; do [[ "$part" == "." || "$part" == ".." ]] && return 1; done
  return 0
}
_within() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

_usage() {
  cat <<'EOF'
usage: devlead enroll <folder> [--dry-run] [--publish]

Enrolls every git repository directly under <folder> in DevLead, in one go:
  1. lists them, with the reason for each one it leaves out
  2. asks the envelope questions once, with the same editor as
     `devlead config`; they start from the scaffold's safe defaults
     (merge.mode never: draft PRs only; budget.max_issues 3; enabled false)
  3. checks the answers against each repo with envelope.sh
  4. shows what will happen to each repo and asks before writing anything
  5. per repo: writes the envelope to your own store, outside the repo:
     ~/.devlead/envelopes/<the repo's path>/envelope.yml
  6. prints the DEVLEAD_WORKSPACE and DEVLEAD_REPOS lines for the server's
     .env

Nothing is added to your repos and nothing is pushed: the envelope is your
tool's configuration, not the project's. DevLead on this machine and the
server (which gets the store as a read-only mount) both read it from there.
A repo that already has an envelope in the store is left as it is; change it
with `devlead config` in that repo.

  --dry-run   ask the questions and show the plan; write, push and open nothing
  --publish   commit the envelope to each repo instead of the store: per repo,
              .devlead/envelope.yml on a new branch, devlead/enroll, made from
              origin's default branch, pushed, with one PR to that default
              branch. Your working copies, current branches, index and stashes
              are never touched; only three refs change per repo:
              refs/remotes/origin/<default branch> and FETCH_HEAD (the fetch)
              and refs/remotes/origin/devlead/enroll (the push). A repo that
              already has the file on its default branch is left as it is, and
              a repo counts as enrolled for the server once its PR is merged.

Terminal only: it refuses without a TTY, inside a Claude Code session, when
Claude Code is among its parent processes, and in unattended runs
(GOVERNANCE.md §A3). Run it from your own terminal, not with Claude Code's
! prefix.
EOF
}

# --- Arguments -------------------------------------------------------------------
DRY_RUN=0
PUBLISH=0
FOLDER=""
for _a in "$@"; do
  case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    -h|--help) _usage; exit 0 ;;
    -*) echo "enroll: unknown option '$_a'" >&2; _usage >&2; exit 2 ;;
    *)
      if [[ -n "$FOLDER" ]]; then
        echo "enroll: one folder at a time" >&2; _usage >&2; exit 2
      fi
      FOLDER="$_a" ;;
  esac
done
if [[ -z "$FOLDER" ]]; then _usage >&2; exit 2; fi
if [[ ! -d "$FOLDER" ]]; then echo "enroll: '$FOLDER' is not a directory" >&2; exit 2; fi
FOLDER="$(cd -- "$FOLDER" && pwd -P)" || { echo "enroll: cannot enter '$FOLDER'" >&2; exit 2; }

for _t in git gh yq; do
  command -v "$_t" >/dev/null 2>&1 || { echo "enroll: $_t is not installed" >&2; exit 1; }
done
gh auth status </dev/null >/dev/null 2>&1 \
  || { echo "enroll: gh is not logged in — run gh auth login first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devlead-enroll.XXXXXX")" \
  || { echo "enroll: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

# The envelope store (S25): one file per repo, outside the repos, keyed by the
# repo's absolute path. envelope.sh reads it from the same place.
STORE="$HOME/.devlead/envelopes"
_store_file() { printf '%s%s/envelope.yml' "$STORE" "$1"; }

# --- Per-repo records --------------------------------------------------------------
# R_STATE: skip | error | refused | has-envelope | pending | ready | opened | written
#   has-envelope and pending still go into DEVLEAD_REPOS: the envelope is in
#   the store, or is (or will be once an open PR merges) on the default branch.
R_NAME=() R_PATH=() R_SLUG=() R_DEF=() R_BASE=() R_STATE=() R_NOTE=() R_PR=()
# R_WARN: a local .devlead/envelope.yml in the user's copy that the merged PR
# will collide with (A5); shown under the repo's line.
R_WARN=()
_set() { R_STATE[$1]="$2"; R_NOTE[$1]="$3"; }
_line() { printf '  %-28s %s\n' "$1" "$2"; }

# git in a user's repo, with none of the repo's hooks.
_g() { local p="$1"; shift; git -C "$p" -c core.hooksPath=/dev/null "$@"; }

# _github_slug <origin url> — owner/repo for a github.com URL, or fail.
# Never prints the URL: an https origin can carry a token.
_github_slug() {
  local u="$1" rest
  case "$u" in
    *://github.com/*)   rest="${u#*://github.com/}" ;;
    *://*@github.com/*) rest="${u#*@github.com/}" ;;
    *@github.com:*)     rest="${u#*@github.com:}" ;;
    github.com:*)       rest="${u#github.com:}" ;;
    *) return 1 ;;
  esac
  rest="${rest%/}"; rest="${rest%.git}"
  [[ "$rest" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] || return 1
  [[ "${rest#*/}" != "." && "${rest#*/}" != ".." ]] || return 1
  printf '%s' "$rest"
}

# _remote_state <i> — fetch origin's default branch and decide what the repo
# needs: has-envelope, pending (the enrollment branch is already on origin),
# ready, or error.
_remote_state() {
  local i="$1" p="${R_PATH[$1]}" d="${R_DEF[$1]}" base rc
  if ! _g "$p" -c fetch.prune=false fetch --quiet --no-tags --no-recurse-submodules origin \
       "+refs/heads/$d:refs/remotes/origin/$d" </dev/null >/dev/null 2>&1; then
    _set "$i" error "error: cannot fetch origin's default branch '$d' (git -C $p fetch origin shows why)"
    return
  fi
  base="$(_g "$p" rev-parse --verify --quiet "refs/remotes/origin/$d^{commit}" 2>/dev/null)" \
    || { _set "$i" error "error: origin's default branch '$d' has no commit"; return; }
  R_BASE[i]="$base"
  if _g "$p" --no-replace-objects cat-file -e "$base:$ENVELOPE_PATH" 2>/dev/null; then
    _set "$i" has-envelope "skip: already has $ENVELOPE_PATH on $d — left as is (change it with devlead config in that repo)"
    return
  fi
  _g "$p" ls-remote --exit-code --heads origin "refs/heads/$BRANCH" </dev/null >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) _set "$i" pending "skip: branch $BRANCH is already on origin — an earlier enrollment PR may be open; merge it, or close it and delete the branch, then run this again" ;;
    2) _set "$i" ready "" ;;
    *) _set "$i" error "error: cannot list origin's branches" ;;
  esac
}

# _store_state <i> — without --publish: the repo already has an entry in the
# store (left as is), or it is ready for one.
_store_state() {
  local i="$1" f
  f="$(_store_file "${R_PATH[$1]}")"
  if [[ -e "$f" || -L "$f" ]]; then
    _set "$i" has-envelope "skip: already has an envelope in your store ($f) — left as is (change it with devlead config in that repo)"
  else
    _set "$i" ready ""
  fi
}

# _local_envelope <i> — the user's copy holds its own .devlead/envelope.yml
# (untracked, ignored or changed): once the PR merges, `git pull` collides
# with it. Read-only: --no-optional-locks keeps status from rewriting the
# index.
_local_envelope() {
  local i="$1" st
  st="$(_g "${R_PATH[$i]}" --no-optional-locks status --porcelain=v1 --untracked-files=all \
        --ignored=matching -- "$ENVELOPE_PATH" </dev/null 2>/dev/null | head -n 1)"
  case "${st:0:2}" in
    "") return 0 ;;
    "??") R_WARN[i]="note: your copy has an untracked $ENVELOPE_PATH — after the PR merges, git pull conflicts on it: move or delete your local file before you pull" ;;
    "!!") R_WARN[i]="note: your copy has an ignored $ENVELOPE_PATH — after the PR merges, git pull replaces it: move your local file first if you want to keep it" ;;
    *)    R_WARN[i]="note: your copy has local changes to $ENVELOPE_PATH — after the PR merges, git pull conflicts on it: move or delete your local file before you pull" ;;
  esac
}

# --- 1. Discover -------------------------------------------------------------------
_discover() {
  local d name i url slug info canon def
  local -a entries=()
  shopt -s nullglob dotglob
  entries=("$FOLDER"/*/)
  shopt -u nullglob dotglob
  for d in "${entries[@]}"; do
    d="${d%/}"; name="${d##*/}"
    i=${#R_NAME[@]}
    R_NAME[i]="$name"; R_PATH[i]="$d"; R_SLUG[i]=""; R_DEF[i]=""; R_BASE[i]=""; R_PR[i]=""; R_WARN[i]=""
    if [[ "$name" == .* ]]; then _set "$i" skip "skip: hidden directory"; continue; fi
    if [[ -L "$d" ]]; then _set "$i" skip "skip: symbolic link — enroll the directory it points to"; continue; fi
    if [[ -f "$d/.git" ]]; then _set "$i" skip "skip: linked worktree or submodule (.git is a file)"; continue; fi
    if [[ ! -d "$d/.git" ]]; then _set "$i" skip "skip: not a git repository"; continue; fi
    url="$(git -C "$d" config --get remote.origin.url 2>/dev/null)"
    if [[ -z "$url" ]]; then _set "$i" skip "skip: no origin remote"; continue; fi
    if ! slug="$(_github_slug "$url")"; then _set "$i" skip "skip: origin is not a GitHub repository"; continue; fi
    if ! _valid_path "$d"; then
      _set "$i" skip "skip: the server accepts only letters, digits and . _ @ + - in a repo's path"; continue
    fi
    info="$(gh repo view "$slug" --json nameWithOwner,defaultBranchRef \
      --jq '.nameWithOwner + " " + .defaultBranchRef.name' </dev/null 2>/dev/null)"
    canon="" def=""
    read -r canon def <<<"$info"
    if [[ -z "$canon" || -z "$def" ]]; then
      _set "$i" skip "skip: GitHub does not answer for $slug (gh repo view failed)"; continue
    fi
    R_SLUG[i]="$canon"
    if ! [[ "$def" =~ ^[A-Za-z0-9._/-]+$ && "$def" != *..* && "$def" != -* ]]; then
      _set "$i" skip "skip: GitHub names a default branch DevLead does not read"; continue
    fi
    R_DEF[i]="$def"
    if [[ "$PUBLISH" == "1" ]]; then
      _local_envelope "$i"
      _remote_state "$i"
    else
      _store_state "$i"
    fi
  done
}

_count() { local s="$1" n=0 i; for i in "${!R_STATE[@]}"; do [[ "${R_STATE[$i]}" == "$s" ]] && n=$((n + 1)); done; echo "$n"; }

# _show_list [plan] — one line per directory. Before the questions a ready
# repo is only a candidate; in the plan it is what will happen to it.
_show_list() {
  local i what
  for i in "${!R_NAME[@]}"; do
    case "${R_STATE[$i]}" in
      ready)
        if [[ "${1:-}" == plan && "$PUBLISH" != "1" ]]; then
          what="${R_SLUG[$i]} — write $(_store_file "${R_PATH[$i]}")"
        elif [[ "${1:-}" == plan ]]; then
          what="${R_SLUG[$i]} — open a PR to ${R_DEF[$i]} adding $ENVELOPE_PATH (branch $BRANCH)"
        else
          what="${R_SLUG[$i]} — default branch ${R_DEF[$i]}, gets the answers below"
        fi ;;
      opened) what="${R_SLUG[$i]} — PR opened: ${R_PR[$i]}" ;;
      written) what="${R_SLUG[$i]} — envelope written: $(_store_file "${R_PATH[$i]}")" ;;
      *)      what="${R_NOTE[$i]}" ;;
    esac
    _line "${R_NAME[$i]}" "$what"
    case "${R_STATE[$i]}" in
      ready|pending|opened) [[ -n "${R_WARN[$i]}" ]] && _line "${R_NAME[$i]}" "${R_WARN[$i]}" ;;
    esac
  done
}

# _show_kv <show output> <KEY> — one value of `envelope.sh show`.
_show_kv() { printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1; }

# --- 6. The .env lines -------------------------------------------------------------
_ws_problem() {
  local r
  _valid_path "$1" || { echo "its path has characters the server does not accept"; return 0; }
  for r in "${_IMAGE_PATHS[@]}"; do
    if _within "$1" "$r" || _within "$r" "$1"; then echo "it overlaps $r, which the server image uses"; return 0; fi
  done
}

_env_lines() {
  local i repos_line="" listed=("$@") s parent problem
  for i in "${!R_NAME[@]}"; do
    for s in "${listed[@]}"; do
      if [[ "${R_STATE[$i]}" == "$s" ]]; then
        repos_line+="${repos_line:+,}${R_PATH[$i]}=${R_SLUG[$i]}"
      fi
    done
  done
  echo ""
  if [[ -z "$repos_line" ]]; then
    echo "No repo to add to DEVLEAD_REPOS."
    return 0
  fi
  echo "For the server's .env (see docker/devlead.env.example):"
  echo ""
  echo "DEVLEAD_WORKSPACE=$FOLDER"
  echo "DEVLEAD_REPOS=$repos_line"
  echo ""
  problem="$(_ws_problem "$FOLDER")"
  if [[ -n "$problem" ]]; then
    echo "Warning: $FOLDER cannot be the server's workspace: $problem."
    echo "         Keep the repos under a folder such as /home/you/Work, and run this again from there."
  fi
  parent="$(dirname "$FOLDER")"
  if [[ -z "$(_ws_problem "$parent")" ]]; then
    echo "If DEVLEAD_REPOS already lists repos outside $FOLDER, set DEVLEAD_WORKSPACE to a"
    echo "folder that holds them all (for example $parent) and add these entries to that list."
  else
    echo "If DEVLEAD_REPOS already lists repos outside $FOLDER, set DEVLEAD_WORKSPACE to a"
    echo "folder that holds them all and add these entries to that list."
  fi
  if [[ "$PUBLISH" == "1" ]]; then
    echo "A repo counts as enrolled for the server only once its PR is merged: the server"
    echo "reads $ENVELOPE_PATH from origin's default branch. After you edit .env, run"
    echo "docker compose up -d so the container picks it up."
  else
    echo "Nothing was added to your repos. The server reads these envelopes from"
    echo "$STORE, which compose.yaml mounts read-only (it is under"
    echo "DEVLEAD_STATE_DIR). After you edit .env, run docker compose up -d so the"
    echo "container picks it up."
  fi
}

_exit_code() { [[ "$(_count error)" -eq 0 ]]; }

_discover
echo ""
echo "Repos under $FOLDER:"
if [[ ${#R_NAME[@]} -eq 0 ]]; then
  echo "  (no directories)"
else
  _show_list
fi

N_READY="$(_count ready)"
if [[ "$N_READY" -eq 0 ]]; then
  echo ""
  echo "Nothing to enroll."
  _env_lines has-envelope pending
  _exit_code; exit $?
fi

# --- 2. Ask once ---------------------------------------------------------------------
# The answers live in a scratch git repo so config.sh and envelope.sh read
# them exactly as they read a repo's envelope. That repo has no remote, so for
# the integration-branch rule envelope.sh falls back to origin/HEAD; it points
# at a name no repo uses, and the real check happens per repo in step 3.
ANSWERS="$WORK/answers"
git init -q "$ANSWERS" \
  && git -C "$ANSWERS" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/devlead-enroll-checks-each-repo \
  && mkdir -p "$ANSWERS/.devlead" \
  && bash "$ENVELOPE_BIN" template > "$ANSWERS/$ENVELOPE_PATH" \
  && [[ -s "$ANSWERS/$ENVELOPE_PATH" ]] \
  || { echo "enroll: cannot prepare the draft envelope — nothing was pushed" >&2; exit 1; }

_answers_show() { (cd "$ANSWERS" && env -u GH_REPO bash "$ENVELOPE_BIN" show </dev/null 2>/dev/null); }

SHOW="$(_answers_show)"
echo ""
echo "The envelope questions, asked once for these $N_READY repos. The draft starts"
echo "from the scaffold: enabled $(_show_kv "$SHOW" ENABLED), merge.mode $(_show_kv "$SHOW" MERGE_MODE), budget.max_issues $(_show_kv "$SHOW" MAX_ISSUES)."
if [[ "$PUBLISH" == "1" ]]; then
  echo "Pick a field to change it; Back (b) when the answers are right. Nothing reaches"
  echo "your repos until you confirm the plan."
else
  echo "Pick a field to change it; Back (b) when the answers are right. Nothing is"
  echo "written until you confirm the plan, and nothing is added to your repos."
fi

if ! (cd "$ANSWERS" && env -u GH_REPO DEVLEAD_CONFIG_ENVELOPE_ONLY=1 bash "$CONFIG_BIN"); then
  echo "enroll: the envelope editor stopped with an error — nothing was pushed" >&2
  exit 1
fi

SHOW="$(_answers_show)"
if [[ "$SHOW" != "STATUS: ok"* ]]; then
  echo "enroll: the answers do not validate — $(_show_kv "$SHOW" GAP). Nothing was pushed." >&2
  exit 1
fi
ENABLED="$(_show_kv "$SHOW" ENABLED)"
MERGE_MODE="$(_show_kv "$SHOW" MERGE_MODE)"
MAX_ISSUES="$(_show_kv "$SHOW" MAX_ISSUES)"
ANSWER_LINE="enabled $ENABLED, merge.mode $MERGE_MODE, budget.max_issues $MAX_ISSUES"
if [[ "$MERGE_MODE" == "integration-branch" ]]; then
  ANSWER_LINE+=", base.integration_branch $(_show_kv "$SHOW" INTEGRATION_BRANCH)"
fi

# --- 3. Check the answers against each repo ------------------------------------------
# A scratch repo per target that envelope.sh reads as that repo: the same
# envelope, origin pointing at the repo on GitHub (so `gh repo view` answers
# for it) and origin/HEAD at its default branch for the fallback.
for i in "${!R_NAME[@]}"; do
  [[ "${R_STATE[$i]}" == "ready" ]] || continue
  c="$WORK/check/$i"
  if ! { git init -q "$c" \
         && git -C "$c" remote add origin "https://github.com/${R_SLUG[$i]}.git" \
         && git -C "$c" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/${R_DEF[$i]}" \
         && mkdir -p "$c/.devlead" \
         && cp "$ANSWERS/$ENVELOPE_PATH" "$c/$ENVELOPE_PATH"; }; then
    _set "$i" error "error: cannot prepare the check of the answers for this repo"
    continue
  fi
  out="$(cd "$c" && env -u GH_REPO bash "$ENVELOPE_BIN" show </dev/null 2>/dev/null)"
  if [[ "$out" != "STATUS: ok"* ]]; then
    gap="$(_show_kv "$out" GAP)"
    _set "$i" refused "refused: ${gap:-envelope.sh show did not accept the answers for this repo}"
  fi
done

# --- 4. Plan and confirm ------------------------------------------------------------
echo ""
echo "Plan — answers: $ANSWER_LINE"
_show_list plan
if [[ "$ENABLED" == "false" ]]; then
  echo ""
  if [[ "$PUBLISH" == "1" ]]; then
    echo "Note: enabled is false — once merged, DevLead reads these repos but takes no"
    echo "work in them until a repo's envelope says enabled: true."
  else
    echo "Note: enabled is false — DevLead reads these repos but takes no work in them"
    echo "until a repo's envelope says enabled: true."
  fi
fi

N_READY="$(_count ready)"
if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  if [[ "$PUBLISH" == "1" ]]; then echo "dry run: nothing was committed, pushed or opened."; else echo "dry run: nothing was written."; fi
  _env_lines ready has-envelope pending
  _exit_code; exit $?
fi
if [[ "$N_READY" -eq 0 ]]; then
  echo ""
  if [[ "$PUBLISH" == "1" ]]; then echo "Nothing to push."; else echo "Nothing to write."; fi
  _env_lines has-envelope pending
  _exit_code; exit $?
fi

echo ""
if [[ "$PUBLISH" != "1" ]]; then
  if [[ "$N_READY" -eq 1 ]]; then _q="Write 1 envelope under $STORE?"; else _q="Write $N_READY envelopes under $STORE?"; fi
elif [[ "$N_READY" -eq 1 ]]; then _q="Push 1 branch and open 1 PR?"
else _q="Push $N_READY branches and open $N_READY PRs?"
fi
read -r -p "$_q [y/N] " _ans || _ans=""
case "${_ans,,}" in
  y|yes|si|sí) ;;
  *)
    if [[ "$PUBLISH" == "1" ]]; then echo "Cancelled — nothing was pushed."; else echo "Cancelled — nothing was written."; fi
    _exit_code; exit $? ;;
esac

# --- 5. Write the store ---------------------------------------------------------------
# Without --publish this is all that happens: one file per repo, outside the
# repos. Written to a sibling temporary file and renamed, so an entry is never
# half an envelope; an entry that appeared since the listing is left alone.
if [[ "$PUBLISH" != "1" ]]; then
  echo ""
  for i in "${!R_NAME[@]}"; do
    [[ "${R_STATE[$i]}" == "ready" ]] || continue
    f="$(_store_file "${R_PATH[$i]}")"
    if [[ -e "$f" || -L "$f" ]]; then
      _set "$i" error "error: $f appeared while this ran — left as is"
    elif mkdir -p "$(dirname "$f")" 2>/dev/null \
         && cp "$ANSWERS/$ENVELOPE_PATH" "$f.tmp.$$" 2>/dev/null \
         && mv -n "$f.tmp.$$" "$f" 2>/dev/null && [[ ! -e "$f.tmp.$$" ]]; then
      _set "$i" written ""
    else
      rm -f "$f.tmp.$$" 2>/dev/null
      _set "$i" error "error: cannot write $f"
    fi
    case "${R_STATE[$i]}" in
      written) _line "${R_NAME[$i]}" "${R_SLUG[$i]} — envelope written: $f" ;;
      *)       _line "${R_NAME[$i]}" "${R_NOTE[$i]}" ;;
    esac
  done
  _env_lines written has-envelope
  _exit_code; exit $?
fi

# --- 5 (--publish). Commit, push, open ------------------------------------------------
COMMIT_BODY="Enrolls this repo in DevLead with the answers given once to \`devlead enroll\` for every repo in its folder."
PR_BODY="Adds \`$ENVELOPE_PATH\`: the answers given once to \`devlead enroll\` for every repo in the folder.

- enabled: $ENABLED
- merge.mode: $MERGE_MODE
- budget.max_issues: $MAX_ISSUES

Merging this PR enrolls the repo: the DevLead server reads the envelope from this branch. Change it later with \`devlead config\` in the repo."

# _build_commit <i> — the base tree plus the envelope, as a commit on top of
# origin's default branch. A private index: the user's index is never read
# or written.
_build_commit() {
  local p="${R_PATH[$1]}" base="${R_BASE[$1]}" idx="$WORK/index.$1" blob tree
  blob="$(_g "$p" hash-object -w --stdin < "$ANSWERS/$ENVELOPE_PATH" 2>/dev/null)" || return 1
  GIT_INDEX_FILE="$idx" _g "$p" read-tree "$base" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE="$idx" _g "$p" update-index --add --cacheinfo "100644,$blob,$ENVELOPE_PATH" >/dev/null 2>&1 || return 1
  tree="$(GIT_INDEX_FILE="$idx" _g "$p" write-tree 2>/dev/null)" || return 1
  _g "$p" commit-tree "$tree" -p "$base" -m "$COMMIT_SUBJECT" -m "$COMMIT_BODY" </dev/null 2>/dev/null
}

echo ""
for i in "${!R_NAME[@]}"; do
  [[ "${R_STATE[$i]}" == "ready" ]] || continue
  p="${R_PATH[$i]}"
  if ! commit="$(_build_commit "$i")" || [[ -z "$commit" ]]; then
    _set "$i" error "error: cannot build the commit (is user.name and user.email set for this repo?)"
    _line "${R_NAME[$i]}" "${R_NOTE[$i]}"; continue
  fi
  if ! _g "$p" push --quiet --no-follow-tags --recurse-submodules=no origin \
       "$commit:refs/heads/$BRANCH" </dev/null >/dev/null 2>&1; then
    _set "$i" error "error: the push to origin failed — nothing was opened"
    _line "${R_NAME[$i]}" "${R_NOTE[$i]}"; continue
  fi
  url="$(gh pr create --repo "${R_SLUG[$i]}" --base "${R_DEF[$i]}" --head "$BRANCH" \
    --title "$COMMIT_SUBJECT" --body "$PR_BODY" </dev/null 2>/dev/null | tail -n 1)"
  if [[ "$url" != https://* ]]; then
    _set "$i" error "error: branch pushed, but gh pr create failed — open the PR at https://github.com/${R_SLUG[$i]}/compare/${R_DEF[$i]}...$BRANCH"
    _line "${R_NAME[$i]}" "${R_NOTE[$i]}"; continue
  fi
  R_PR[i]="$url"
  _set "$i" opened ""
  _line "${R_NAME[$i]}" "PR opened: $url"
done

if [[ "$(_count opened)" -gt 0 ]]; then
  echo ""
  echo "PRs:"
  for i in "${!R_NAME[@]}"; do
    [[ "${R_STATE[$i]}" == "opened" ]] && echo "  ${R_PR[$i]}"
  done
fi
_env_lines opened has-envelope pending
_exit_code
