#!/usr/bin/env bash
# unit-enroll.sh — `devlead enroll <folder>` (.devlead/scripts/enroll.sh), S24.
#
#   bash test/unit-enroll.sh
#
# The command enrolls every git repo directly under a folder: it asks the
# envelope questions once (config.sh's own envelope editor), validates the
# answers per repo with envelope.sh, commits .devlead/envelope.yml on a new
# branch made from origin's default branch, pushes it and opens one PR per
# repo. This suite pins:
#   - Inv 3: no TTY, a Claude Code session, an unattended run → refused before
#     anything is read, pushed or asked;
#   - the user's working copies, branches, index and stashes stay untouched;
#   - one line per directory, with its reason, and the run goes on after a
#     skip, a refusal or an error;
#   - the per-repo refusal of an integration branch that is that repo's
#     default branch (envelope.sh's own rule);
#   - --dry-run and a declined confirmation push nothing;
#   - the DEVLEAD_REPOS / DEVLEAD_WORKSPACE lines and the PR links;
#   - wiring: the CLI dispatch and help, the publish manifest, the Makefile,
#     and that no autonomous path names the command.
#
# SANDBOX: everything lives under one throwaway directory in
# ${XDG_CACHE_HOME:-$HOME/.cache} (as unit-guard.sh does), not /tmp: the
# server refuses a workspace inside /tmp, and the main scenario needs a
# workspace it accepts. $HOME is overridden, git reads only a test config
# (GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM), `gh` is a fake on $PATH, and the
# "GitHub" remotes are bare repos reached through url.insteadOf. Nothing here
# touches a real repo, a real remote or the real ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SCRIPTS_SRC="$REPO_ROOT/.devlead/scripts"
CLI="$REPO_ROOT/.devlead/bin/devlead"

_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$_CACHE"
SANDBOX="$(mktemp -d "$_CACHE/devlead-enroll.XXXXXX")"
TMP_WS=""
cleanup() { cd / && rm -rf "$SANDBOX"; [[ -n "$TMP_WS" ]] && rm -rf "$TMP_WS"; }
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else
    fail "$1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"
  fi
}
not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else
    fail "$1"; echo "        unexpected substring: [$3]"
  fi
}
check_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else
    fail "$1"; echo "        expected: [$3]"; echo "        actual: [$2]"
  fi
}

# --- Environment ---------------------------------------------------------------
export HOME="$SANDBOX/home"
REMOTES="$SANDBOX/remotes"
FAKEBIN="$SANDBOX/bin"
export FAKE_GH_DIR="$SANDBOX/gh"
export FAKE_GH_REMOTES="$REMOTES"
mkdir -p "$HOME/.devlead/scripts" "$REMOTES" "$FAKEBIN" "$FAKE_GH_DIR"
: > "$FAKE_GH_DIR/repos.tsv"
: > "$FAKE_GH_DIR/calls"

# The installed copy the CLI forwards to: the working tree's scripts, so the
# suite exercises them before they are committed.
for f in enroll.sh config.sh envelope.sh bootstrap-lib.sh untrusted.sh doctor.sh; do
  [[ -f "$SCRIPTS_SRC/$f" ]] && cp "$SCRIPTS_SRC/$f" "$HOME/.devlead/scripts/$f"
done
chmod +x "$HOME"/.devlead/scripts/*.sh 2>/dev/null

export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = Test User
	email = test@example.com
[init]
	defaultBranch = main
[url "file://$REMOTES/"]
	insteadOf = https://github.com/
	insteadOf = https://someone:s3cr3t-token@github.com/
EOF

export DEVLEAD_NO_GUM=1
export SHELL=/bin/bash
export LC_ALL=C
unset CLAUDECODE DEVLEAD_GUARD GH_REPO GH_TOKEN GITHUB_TOKEN GH_HOST
# enroll.sh refuses under a Claude Code ancestor; the suite may run inside a
# Claude Code session, so every pty run starts outside this process tree.
# shellcheck source=test/lib-outside-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-outside-session.sh"
export RUN_OUTSIDE_PACE=0.3

# A fake gh: answers `auth status`, `repo view` (by slug, or from the cwd's
# origin like the real one) and `pr create` (refuses a head branch the bare
# remote does not have). Records every call. Never reads stdin.
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_DIR/calls"
_slug_from_cwd() {
  local u
  u="$(git config --get remote.origin.url 2>/dev/null)" || return 1
  u="${u%.git}"
  [[ "$u" == *github.com[:/]* ]] || return 1
  printf '%s' "${u#*github.com[:/]}"
}
_lookup() { awk -F'\t' -v s="$1" '$1 == s { print $2; f = 1 } END { exit !f }' "$FAKE_GH_DIR/repos.tsv"; }
case "${1:-} ${2:-}" in
  "auth status") exit "${FAKE_GH_AUTH_RC:-0}" ;;
  "repo view")
    shift 2
    slug="" expr="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) shift 2 ;;
        -q|--jq) expr="$2"; shift 2 ;;
        -*) shift ;;
        *) slug="$1"; shift ;;
      esac
    done
    if [[ -z "$slug" ]]; then
      slug="$(_slug_from_cwd)" || { echo "none of the git remotes point to a known GitHub host" >&2; exit 1; }
    fi
    d="$(_lookup "$slug")" || { echo "GraphQL: Could not resolve to a Repository with the name '$slug'." >&2; exit 1; }
    jq -n --arg s "$slug" --arg d "$d" '{nameWithOwner: $s, defaultBranchRef: {name: $d}}' | jq -r "$expr"
    ;;
  "pr create")
    shift 2
    repo="" head=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo|-R) repo="$2"; shift 2 ;;
        --head|-H) head="$2"; shift 2 ;;
        --*) shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ ",${FAKE_GH_PR_FAIL:-}," == *",$repo,"* ]]; then
      echo "pull request create failed: GraphQL: something went wrong" >&2; exit 1
    fi
    git --git-dir="$FAKE_GH_REMOTES/$repo.git" rev-parse -q --verify "refs/heads/$head" >/dev/null \
      || { echo "head branch $head not found on $repo" >&2; exit 1; }
    echo "$repo" >> "$FAKE_GH_DIR/prs"
    echo "https://github.com/$repo/pull/$(wc -l < "$FAKE_GH_DIR/prs" | tr -d ' ')"
    ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

BRANCH="devlead/enroll"

# --- Fixtures ------------------------------------------------------------------
# _remote <owner/repo> <default branch> [envelope] — a "GitHub" repo: a bare
# remote with one commit on its default branch, known to the fake gh.
_remote() {
  local slug="$1" def="$2" bare="$REMOTES/$1.git" seed
  git init -q --bare -b "$def" "$bare"
  seed="$(mktemp -d "$SANDBOX/seed.XXXXXX")"
  git -C "$seed" init -q -b "$def"
  printf 'readme of %s\n' "$slug" > "$seed/README.md"
  mkdir -p "$seed/src"; printf 'x=1\n' > "$seed/src/app.sh"
  if [[ "${3:-}" == envelope ]]; then
    mkdir -p "$seed/.devlead"; printf 'version: 1 # theirs\n' > "$seed/.devlead/envelope.yml"
  fi
  git -C "$seed" add -A && git -C "$seed" commit -qm init
  git -C "$seed" push -q "$bare" "HEAD:refs/heads/$def"
  printf '%s\t%s\n' "$slug" "$def" >> "$FAKE_GH_DIR/repos.tsv"
}

# _dirty <dir> — the user's work in progress: a feature branch checked out, a
# stash, an unstaged edit, a staged file and an untracked one.
_dirty() {
  git -C "$1" checkout -q -b feat/mine
  printf 'stash me\n' >> "$1/README.md"; git -C "$1" stash -q
  printf 'y=2\n' >> "$1/src/app.sh"
  printf 'new\n' > "$1/staged.txt"; git -C "$1" add staged.txt
  printf 'untracked\n' > "$1/notes.txt"
}

_snapshot() {
  {
    git -C "$1" symbolic-ref HEAD
    git -C "$1" rev-parse HEAD
    git -C "$1" status --porcelain=v1 -uall
    git -C "$1" stash list
    git -C "$1" diff
    git -C "$1" diff --cached
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/stash
    git -C "$1" worktree list --porcelain
    ls -A "$1"
  } 2>&1
}

_has_branch() { git --git-dir="$REMOTES/$1.git" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; }

# _enroll <args> <input line>... — runs `devlead enroll <args>` through the CLI
# over a real pty, outside this process tree (run_outside), typing the given
# lines. Sets OUT (CR stripped) and RC. The timeout keeps a test bug from
# hanging the suite on a read. _ENROLL_VIA, when set, is a program the run
# goes through (a fake ancestor, run as `<via> -c "<cmd>" [_ENROLL_ARG0]`).
OUT="" RC=0 _ENROLL_VIA="" _ENROLL_ARG0=""
_enroll() {
  local args="$1" cmd; shift
  cmd="bash '$CLI' enroll $args"
  [[ -n "$_ENROLL_VIA" ]] && cmd="$_ENROLL_VIA -c \"$cmd; exit \\\$?\" $_ENROLL_ARG0"
  OUT="$(run_outside 120 "$(lines_file "$SANDBOX" "$@")" "$cmd")"
  RC=$?
}

TEMPLATE="$(bash "$SCRIPTS_SRC/envelope.sh" template 2>/dev/null)"

# ===========================================================================
# E1 — Inv 3: without a terminal the command refuses before it reads, asks or
# pushes anything.
# ===========================================================================
e1_tty_gate() {
  _remote acme/tty main
  mkdir -p "$SANDBOX/ws-tty"
  git clone -q https://github.com/acme/tty.git "$SANDBOX/ws-tty/tty"
  : > "$FAKE_GH_DIR/calls"
  local out rc
  out="$(bash "$CLI" enroll "$SANDBOX/ws-tty" < /dev/null 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && pass "E1: exits non-zero without a TTY" || fail "E1: expected non-zero exit, got $rc"
  contains "E1: names the reason (not a TTY)" "$out" "TTY"
  contains "E1: cites GOVERNANCE.md §A3" "$out" "GOVERNANCE.md §A3"
  check_eq "E1: gh was never called" "$(cat "$FAKE_GH_DIR/calls")" ""
  _has_branch acme/tty && fail "E1: a branch was pushed" || pass "E1: nothing pushed"
}

# ===========================================================================
# E2 — Inv 3: out of every session's reach, even with a pty. Claude Code sets
# CLAUDECODE in the commands it runs; the unattended launchers export
# DEVLEAD_GUARD=1.
# ===========================================================================
e2_session_gate() {
  : > "$FAKE_GH_DIR/calls"
  CLAUDECODE=1 _enroll "'$SANDBOX/ws-tty'"
  [[ $RC -ne 0 ]] && pass "E2: refused inside a Claude Code session" || fail "E2: expected non-zero exit under CLAUDECODE, got $RC"
  contains "E2: says it is a Claude Code session" "$OUT" "Claude Code session"
  DEVLEAD_GUARD=1 _enroll "'$SANDBOX/ws-tty'"
  [[ $RC -ne 0 ]] && pass "E2: refused in an unattended run" || fail "E2: expected non-zero exit under DEVLEAD_GUARD=1, got $RC"
  contains "E2: says it is an unattended run" "$OUT" "unattended"
  check_eq "E2: gh was never called" "$(cat "$FAKE_GH_DIR/calls")" ""
  _has_branch acme/tty && fail "E2: a branch was pushed" || pass "E2: nothing pushed"
}

# ===========================================================================
# E3 — the whole folder: one line per directory, PRs for the repos that can be
# enrolled, the user's working copies untouched, the .env lines at the end.
# ===========================================================================
e3_folder() {
  local ws="$SANDBOX/ws"
  mkdir -p "$ws"
  _remote acme/web main
  _remote acme/api dev
  _remote acme/enrolled main envelope
  _remote acme/tok main
  git clone -q https://github.com/acme/web.git "$ws/web"
  git clone -q https://github.com/acme/api.git "$ws/api"
  git clone -q https://github.com/acme/enrolled.git "$ws/enrolled"
  git clone -q https://someone:s3cr3t-token@github.com/acme/tok.git "$ws/tok"
  _dirty "$ws/web"
  printf 'wip\n' >> "$ws/api/README.md"          # api: on its default branch, unstaged work
  git -C "$ws/web" worktree add -q "$ws/wt" -b wt-branch
  git init -q "$ws/local-only"
  git init -q "$ws/gitlab"; git -C "$ws/gitlab" remote add origin https://gitlab.com/acme/gitlab.git
  mkdir -p "$ws/notes"
  ln -s web "$ws/link"

  local snap_web snap_api idx_web idx_api
  snap_web="$(_snapshot "$ws/web")"; snap_api="$(_snapshot "$ws/api")"
  idx_web="$(sha256sum < "$ws/web/.git/index")"; idx_api="$(sha256sum < "$ws/api/.git/index")"
  : > "$FAKE_GH_DIR/calls"

  _enroll "'$ws'" b y

  check_eq "E3: exit 0" "$RC" "0"
  contains "E3: the envelope questions are config.sh's own editor" "$OUT" "Envelope ("
  contains "E3: web gets a PR" "$OUT" "https://github.com/acme/web/pull/"
  contains "E3: api gets a PR" "$OUT" "https://github.com/acme/api/pull/"
  contains "E3: tok gets a PR" "$OUT" "https://github.com/acme/tok/pull/"
  contains "E3: enrolled is skipped, envelope kept" "$OUT" "already has .devlead/envelope.yml on main"
  contains "E3: the linked worktree is skipped" "$OUT" "linked worktree"
  contains "E3: the repo without origin is skipped" "$OUT" "no origin remote"
  contains "E3: the GitLab repo is skipped" "$OUT" "origin is not a GitHub repository"
  contains "E3: the plain directory is skipped" "$OUT" "not a git repository"
  contains "E3: the symlink is skipped" "$OUT" "symbolic link"
  contains "E3: the plan asks before pushing" "$OUT" "Push 3 branches and open 3 PRs?"
  not_contains "E3: the token in an origin URL is never printed" "$OUT" "s3cr3t"

  local ok=true s
  for s in acme/web acme/api acme/tok; do _has_branch "$s" || ok=false; done
  [[ "$ok" == true ]] && pass "E3: the branch is on every enrolled remote" || fail "E3: a branch is missing on a remote"
  _has_branch acme/enrolled && fail "E3: the repo that already had an envelope got a branch" || pass "E3: the repo with an envelope got no branch"

  local g="--git-dir=$REMOTES/acme/web.git"
  check_eq "E3: the branch starts at origin's default branch" \
    "$(git "$g" rev-parse "$BRANCH^")" "$(git "$g" rev-parse main)"
  check_eq "E3: the commit adds only .devlead/envelope.yml" \
    "$(git "$g" diff --name-status main "$BRANCH")" "A	.devlead/envelope.yml"
  check_eq "E3: the envelope is the answers (defaults: the scaffold)" \
    "$(git "$g" show "$BRANCH:.devlead/envelope.yml")" "$TEMPLATE"
  check_eq "E3: api's branch starts at its default branch (dev)" \
    "$(git --git-dir="$REMOTES/acme/api.git" rev-parse "$BRANCH^")" \
    "$(git --git-dir="$REMOTES/acme/api.git" rev-parse dev)"
  local env; env="$(git "$g" show "$BRANCH:.devlead/envelope.yml")"
  contains "E3: safe default merge.mode: never" "$env" "mode: never"
  contains "E3: safe default budget.max_issues: 3" "$env" "max_issues: 3"

  local calls; calls="$(cat "$FAKE_GH_DIR/calls")"
  contains "E3: web's PR targets main from the branch" "$calls" "pr create --repo acme/web --base main --head $BRANCH"
  contains "E3: api's PR targets its default branch dev" "$calls" "pr create --repo acme/api --base dev --head $BRANCH"

  check_eq "E3: web's working copy, branch, stash and index are untouched" "$(_snapshot "$ws/web")" "$snap_web"
  check_eq "E3: api's working copy is untouched" "$(_snapshot "$ws/api")" "$snap_api"
  check_eq "E3: web's index file is byte-identical" "$(sha256sum < "$ws/web/.git/index")" "$idx_web"
  check_eq "E3: api's index file is byte-identical" "$(sha256sum < "$ws/api/.git/index")" "$idx_api"
  [[ -e "$ws/web/.devlead" ]] && fail "E3: .devlead appeared in the working copy" || pass "E3: no .devlead in the working copy"

  contains "E3: DEVLEAD_WORKSPACE is the folder" "$OUT" "DEVLEAD_WORKSPACE=$ws"
  contains "E3: DEVLEAD_REPOS lists the enrolled and the already-enrolled repos" "$OUT" \
    "DEVLEAD_REPOS=$ws/api=acme/api,$ws/enrolled=acme/enrolled,$ws/tok=acme/tok,$ws/web=acme/web"
  not_contains "E3: a workspace the server accepts gets no warning" "$OUT" "cannot be the server's workspace"
  contains "E3: reminds that a repo counts only once its PR is merged" "$OUT" "only once its PR is merged"
}

# ===========================================================================
# E4 — the answers are validated per repo with envelope.sh: an integration
# branch that IS a repo's default branch is refused for that repo only.
# ===========================================================================
e4_per_repo_refusal() {
  local ws="$SANDBOX/ws4"
  mkdir -p "$ws"
  _remote acme/main-repo main
  _remote acme/dev-repo dev
  git clone -q https://github.com/acme/main-repo.git "$ws/main-repo"
  git clone -q https://github.com/acme/dev-repo.git "$ws/dev-repo"
  : > "$FAKE_GH_DIR/calls"

  _enroll "'$ws'" base.integration_branch dev y merge.mode integration-branch y b y

  check_eq "E4: exit 0 (a refusal is reported, not an error)" "$RC" "0"
  contains "E4: dev-repo is refused with envelope.sh's reason" "$OUT" \
    "base.integration_branch ('dev') must not be the default branch"
  _has_branch acme/dev-repo && fail "E4: the refused repo got a branch" || pass "E4: the refused repo got no branch"
  _has_branch acme/main-repo && pass "E4: main-repo got its branch" || fail "E4: main-repo got no branch"
  local env; env="$(git --git-dir="$REMOTES/acme/main-repo.git" show "$BRANCH:.devlead/envelope.yml" 2>/dev/null)"
  contains "E4: the answers reached the envelope (merge.mode)" "$env" "mode: integration-branch"
  contains "E4: the answers reached the envelope (integration branch)" "$env" "integration_branch: dev"
  contains "E4: DEVLEAD_REPOS lists only the accepted repo" "$OUT" "DEVLEAD_REPOS=$ws/main-repo=acme/main-repo"$'\n'
}

# ===========================================================================
# E5 — --dry-run shows the plan and pushes nothing. Its workspace sits in
# /tmp, which the server refuses: the warning says so.
# ===========================================================================
e5_dry_run() {
  TMP_WS="$(mktemp -d /tmp/devlead-enroll-dry.XXXXXX)"
  _remote acme/dry main
  git clone -q https://github.com/acme/dry.git "$TMP_WS/dry"
  : > "$FAKE_GH_DIR/calls"

  _enroll "--dry-run '$TMP_WS'" b

  check_eq "E5: exit 0" "$RC" "0"
  contains "E5: the plan names the PR it would open" "$OUT" "open a PR to main"
  contains "E5: says nothing was pushed" "$OUT" "dry run"
  not_contains "E5: no confirmation is asked" "$OUT" "Push 1 branch"
  _has_branch acme/dry && fail "E5: a branch was pushed" || pass "E5: nothing pushed"
  not_contains "E5: no PR was created" "$(cat "$FAKE_GH_DIR/calls")" "pr create"
  contains "E5: the .env line is shown" "$OUT" "DEVLEAD_REPOS=$TMP_WS/dry=acme/dry"
  contains "E5: a /tmp workspace is flagged" "$OUT" "cannot be the server's workspace"
}

# ===========================================================================
# E6 — declining the confirmation pushes nothing.
# ===========================================================================
e6_decline() {
  local ws="$SANDBOX/ws6"
  mkdir -p "$ws"
  _remote acme/no main
  git clone -q https://github.com/acme/no.git "$ws/no"
  : > "$FAKE_GH_DIR/calls"
  _enroll "'$ws'" b n
  check_eq "E6: exit 0" "$RC" "0"
  contains "E6: says nothing was pushed" "$OUT" "nothing was pushed"
  _has_branch acme/no && fail "E6: a branch was pushed" || pass "E6: nothing pushed"
  not_contains "E6: no PR was created" "$(cat "$FAKE_GH_DIR/calls")" "pr create"
}

# ===========================================================================
# E7 — one repo's failure is reported and the run goes on with the rest.
# ===========================================================================
e7_errors_continue() {
  local ws="$SANDBOX/ws7"
  mkdir -p "$ws"
  _remote acme/prfail main
  _remote acme/fine main
  _remote acme/pend main
  git clone -q https://github.com/acme/prfail.git "$ws/prfail"
  git clone -q https://github.com/acme/fine.git "$ws/fine"
  git clone -q https://github.com/acme/pend.git "$ws/pend"
  git -C "$ws/pend" push -q origin "main:refs/heads/$BRANCH"     # an earlier run's PR, still open
  printf 'acme/gone\tmain\n' >> "$FAKE_GH_DIR/repos.tsv"          # GitHub knows it, the fetch fails
  git init -q "$ws/gone"; git -C "$ws/gone" remote add origin https://github.com/acme/gone.git
  git init -q "$ws/ghost"; git -C "$ws/ghost" remote add origin git@github.com:acme/ghost.git
  : > "$FAKE_GH_DIR/calls"

  FAKE_GH_PR_FAIL=acme/prfail _enroll "'$ws'" b y

  check_eq "E7: exit 1 when a repo ended in an error" "$RC" "1"
  contains "E7: the failed PR is reported with a link to open it" "$OUT" \
    "https://github.com/acme/prfail/compare/main...$BRANCH"
  contains "E7: the fetch failure is reported" "$OUT" "cannot fetch origin's default branch 'main'"
  contains "E7: a repo GitHub does not know is skipped" "$OUT" "GitHub does not answer for acme/ghost"
  contains "E7: an existing enrollment branch is skipped" "$OUT" "branch $BRANCH is already on origin"
  contains "E7: the others still get their PR" "$OUT" "https://github.com/acme/fine/pull/"
  contains "E7: DEVLEAD_REPOS keeps the opened and the pending repos" "$OUT" \
    "DEVLEAD_REPOS=$ws/fine=acme/fine,$ws/pend=acme/pend"
}

# ===========================================================================
# E8 — a folder with nothing to enroll asks nothing.
# ===========================================================================
e8_nothing() {
  local ws="$SANDBOX/ws8"
  mkdir -p "$ws/plain"
  git init -q "$ws/solo"
  _enroll "'$ws'"
  check_eq "E8: exit 0" "$RC" "0"
  contains "E8: says there is nothing to enroll" "$OUT" "Nothing to enroll"
  not_contains "E8: the envelope editor is not opened" "$OUT" "Envelope ("
}

# ===========================================================================
# E9 — usage errors.
# ===========================================================================
e9_usage() {
  _enroll ""
  check_eq "E9: no folder → exit 2" "$RC" "2"
  contains "E9: prints the usage" "$OUT" "usage: devlead enroll <folder> [--dry-run]"
  _enroll "'$SANDBOX/does-not-exist'"
  check_eq "E9: a missing folder → exit 2" "$RC" "2"
  contains "E9: names the missing folder" "$OUT" "not a directory"
  _enroll "--bogus '$SANDBOX/ws8'"
  check_eq "E9: an unknown option → exit 2" "$RC" "2"
}

# ===========================================================================
# E10 — wiring, and Inv 3 by construction: no autonomous path names it.
# ===========================================================================
e10_wiring() {
  local help; help="$(bash "$CLI" help 2>&1)"
  contains "E10: devlead help lists enroll" "$help" "enroll <folder> [--dry-run]"
  local out; out="$(bash "$CLI" enroll "$SANDBOX/ws8" < /dev/null 2>&1)"
  contains "E10: devlead enroll reaches enroll.sh" "$out" "enroll: refusing to run"
  grep -qF '.devlead/scripts/enroll.sh|' "$SCRIPTS_SRC/bootstrap-lib.sh" \
    && pass "E10: enroll.sh is in the publish manifest" || fail "E10: enroll.sh missing from the publish manifest"
  grep -qF 'test/unit-enroll.sh' "$REPO_ROOT/Makefile" \
    && pass "E10: this suite is wired into the Makefile" || fail "E10: test/unit-enroll.sh missing from the Makefile"

  local hits="" f
  for f in "$SCRIPTS_SRC"/*.sh "$REPO_ROOT"/.claude/commands/*.md "$REPO_ROOT"/docker/*.sh "$REPO_ROOT"/docker/Dockerfile "$REPO_ROOT"/.devlead/systemd/*; do
    # enroll.sh itself, and the publish manifest, which copies it to
    # ~/.devlead/scripts but never runs it.
    case "$(basename "$f")" in enroll.sh|bootstrap-lib.sh) continue ;; esac
    # Comments may name it (config.sh and envelope.sh say who reuses them);
    # a line that runs something may not.
    grep -vE '^[[:space:]]*#' "$f" | grep -qE 'enroll\.sh|devlead enroll' && hits+="${f#"$REPO_ROOT"/} "
  done
  check_eq "E10: no script, command, unit or server file invokes the enroll command" "$hits" ""

  # The server's workspace rules, copied from docker/runner-config.sh: the two
  # lists must not drift apart.
  check_eq "E10: the image paths match docker/runner-config.sh" \
    "$(grep -m1 '^IMAGE_PATHS=' "$REPO_ROOT/docker/runner-config.sh" | sed 's/^IMAGE_PATHS=//')" \
    "$(grep -m1 '^_IMAGE_PATHS=' "$SCRIPTS_SRC/enroll.sh" | sed 's/^_IMAGE_PATHS=//')"
}

# ===========================================================================
# E11 — existing behavior the change touched still holds.
# ===========================================================================
e11_existing_behavior() {
  # devlead config, without the envelope-only entry, still opens its main menu.
  local cfg="$SANDBOX/cfg"
  git init -q "$cfg"
  local out
  out="$(run_outside 60 "$(lines_file "$SANDBOX" q)" "cd '$cfg' && bash '$HOME/.devlead/scripts/config.sh'")"
  contains "E11: devlead config still opens the main menu" "$out" "=== DevLead config"
  contains "E11: the main menu still offers Machine setup" "$out" "Machine setup"

  # envelope.sh init still writes the scaffold, and `template` prints exactly it.
  local ini="$SANDBOX/ini" h="$SANDBOX/ini-home"
  mkdir -p "$h/.devlead"
  git init -q "$ini"
  printf 'stamp\n' > "$h/.devlead/VERSION"
  printf 'tok\n' > "$h/.devlead/gh-token"; chmod 600 "$h/.devlead/gh-token"
  out="$(cd "$ini" && HOME="$h" bash "$SCRIPTS_SRC/envelope.sh" init < /dev/null 2>&1)"
  contains "E11: init still creates the envelope" "$out" "STATUS: created"
  check_eq "E11: init writes exactly what template prints" "$(cat "$ini/.devlead/envelope.yml")" "$TEMPLATE"
  contains "E11: the scaffold keeps merge.mode: never" "$TEMPLATE" "  mode: never"
  contains "E11: the scaffold keeps enabled: false" "$TEMPLATE" "enabled: false"
}

# ===========================================================================
# E12 — Inv 3: the process tree, not the environment. Under a Claude Code
# ancestor (the claude binary, or node running Claude Code's CLI) the command
# refuses with CLAUDECODE unset, before it asks or pushes anything; /proc
# unreadable on Linux refuses too (fail closed).
# ===========================================================================
e12_claude_ancestor() {
  local fake="$SANDBOX/fake-ancestors"
  mkdir -p "$fake"
  cp "$(command -v bash)" "$fake/claude"
  cp "$(command -v bash)" "$fake/node"
  : > "$FAKE_GH_DIR/calls"

  _ENROLL_VIA="'$fake/claude'" _enroll "'$SANDBOX/ws-tty'" b y
  [[ $RC -ne 0 ]] && pass "E12: refused under a claude ancestor" || fail "E12: expected non-zero exit under claude, got $RC"
  contains "E12: names Claude Code as the reason" "$OUT" "refusing to run under Claude Code"
  contains "E12: points at the user's own terminal, not the ! prefix" "$OUT" "not through Claude Code's ! prefix"

  _ENROLL_VIA="'$fake/node'" _ENROLL_ARG0=/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js _enroll "'$SANDBOX/ws-tty'" b y
  [[ $RC -ne 0 ]] && pass "E12: refused under node running Claude Code's CLI" || fail "E12: expected non-zero exit under node, got $RC"
  contains "E12: node form names Claude Code as the reason" "$OUT" "refusing to run under Claude Code"

  check_eq "E12: gh was never called" "$(cat "$FAKE_GH_DIR/calls")" ""
  _has_branch acme/tty && fail "E12: a branch was pushed" || pass "E12: nothing pushed"

  if unshare -rm true 2>/dev/null; then
    OUT="$(run_outside 60 /dev/null "unshare -rm bash -c 'mount -t tmpfs none /proc && bash \"$CLI\" enroll \"$SANDBOX/ws-tty\"'")"; RC=$?
    [[ $RC -ne 0 ]] && pass "E12: /proc unreadable on Linux: refused (fail closed)" || fail "E12: expected non-zero exit without /proc, got $RC"
    contains "E12: says why" "$OUT" "cannot read /proc"
  else
    echo "NOTE  E12 /proc case skipped: unshare -rm is not available here"
  fi

  # One walker, two copies: config.sh and enroll.sh are separate scripts.
  _walker() { sed -n '/^# >>> _claude_code_ancestor/,/^# <<< _claude_code_ancestor/p' "$1"; }
  local a b
  a="$(_walker "$SCRIPTS_SRC/enroll.sh")"; b="$(_walker "$SCRIPTS_SRC/config.sh")"
  [[ -n "$a" ]] && pass "E12: enroll.sh carries the ancestor walker" || fail "E12: enroll.sh has no ancestor walker"
  check_eq "E12: config.sh carries the same walker" "$b" "$a"
}

main() {
  e1_tty_gate
  e2_session_gate
  e3_folder
  e4_per_repo_refusal
  e5_dry_run
  e6_decline
  e7_errors_continue
  e8_nothing
  e9_usage
  e10_wiring
  e11_existing_behavior
  e12_claude_ancestor
  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
