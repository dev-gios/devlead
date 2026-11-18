#!/usr/bin/env bash
# envelope.sh — DevLead persisted per-repo envelope: parser + enrollment + dry-run planner.
# Subcommands: check | init | show [--origin] | plan | upgrade | schema | template | path. KEY:value stdout
# (template: the scaffold YAML init writes; path: the envelope file in use). Always exits 0 on operational outcomes.
# Envelope file: this repo's entry in the envelope store outside the repos (S25, below) when it has one,
# otherwise <git-root>/.devlead/envelope.yml (committed, auditable). READ-ONLY except `init` scaffold.
set -uo pipefail

# Sourced as a self-resolved sibling (NOT a hardcoded ~/.devlead/scripts path):
# on a fresh machine `init` runs straight from the repo checkout, before the
# ~/.devlead/scripts/ symlink farm exists — readlink -f on envelope.sh's OWN
# BASH_SOURCE resolves its real location first (checkout or installed
# symlink, either way), then looks up bootstrap-lib.sh as a plain sibling in
# that same real directory. Provides bootstrap_symlinks/_systemd/_token_seed.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bootstrap-lib.sh"

_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
# The untrusted-content scanner (S6, GOVERNANCE.md §untrusted-content), as a
# sibling of this script's real location — same resolution as bootstrap-lib.
# Missing or failing, every candidate issue fails closed in `plan`.
UNTRUSTED_BIN="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/untrusted.sh"
REPO_ENV_FILE="$(_repo_root)/.devlead/envelope.yml"

# ---------------------------------------------------------------------------
# The envelope store (S25): an envelope kept outside the repo, so nothing of
# DevLead's is committed to it. One file per repo, keyed by the repo's
# absolute path:
#   <store>/<absolute repo path>/envelope.yml
# Where a repo has an entry, that file is its envelope for every reader here
# and it wins over a committed .devlead/envelope.yml. A linked worktree reads
# its main checkout's entry.
#
# On the user's machine the store is ~/.devlead/envelopes; guard.sh denies a
# session every write under ~/.devlead. In the server it is the fixed path
# below, where compose mounts the host's store read-only — never a path taken
# from HOME or the environment, which a session sets for the commands it
# runs. It sits beside the loop's plan, outside /etc/devlead: what compose
# mounts from the host is the host user's, and /etc/devlead stays all root's. An entry the caller could write there grants nothing: show, plan and
# check block (see the dispatch).
# test/unit-envelope-store.sh rewrites these two paths in a copy.
# ---------------------------------------------------------------------------
SERVER_MARKER=/etc/devlead/server-mode
SERVER_STORE=/run/devlead/envelopes

_store_root() {
  if [[ -e "$SERVER_MARKER" ]]; then
    printf '%s' "$SERVER_STORE"
  else
    printf '%s' "${HOME:-/nonexistent}/.devlead/envelopes"
  fi
}

# _main_checkout — the main checkout of the repo this worktree belongs to.
_main_checkout() {
  local c
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$c" == /*/.git ]] || return 1
  printf '%s' "${c%/.git}"
}

# _store_entry — this repo's store file, when it has one.
_store_entry() {
  local root top p f
  root="$(_store_root)"
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  for p in "$top" "$(_main_checkout)"; do
    [[ "$p" == /* && "$p" != *"/.."* ]] || continue
    f="$root$p/envelope.yml"
    if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# _store_writable <entry> — the caller can write the entry, or a directory
# between it and the store's root: it could replace the entry.
_store_writable() {
  local root d
  root="$(_store_root)"
  [[ -w "$1" ]] && return 0
  d="$(dirname "$1")"
  while [[ "$d" == "$root" || "$d" == "$root"/* ]]; do
    [[ -w "$d" ]] && return 0
    d="$(dirname "$d")"
  done
  return 1
}

ENV_FILE="$REPO_ENV_FILE"
_FROM_STORE=""
_STORE_UNSAFE=""
if _entry="$(_store_entry)"; then
  if [[ -e "$SERVER_MARKER" ]] && _store_writable "$_entry"; then
    _STORE_UNSAFE=1
  else
    ENV_FILE="$_entry"
    _FROM_STORE=1
  fi
fi

# LOCKED schema whitelists (D5)
_TOP_REQUIRED="version enabled select order budget base forbidden_zones on_failure merge report"
# discover is the only OPTIONAL top-level key: absent means discovery is
# disabled (enabled: false), so pre-existing envelopes stay valid unchanged.
_TOP_OPTIONAL="discover"
_TOP="$_TOP_REQUIRED $_TOP_OPTIONAL"
# nested: select{bucket exclude_labels require_readiness intake_label intake_labelers} order{by} budget{max_issues stop_at}
#         base{strategy integration_branch} on_failure{policy skip_dependents} merge{mode} report{to}
#         discover{enabled label modules} — OPTIONAL block, absent means enabled: false (D5)

_emit() {
  # Quote values bearing ':' or newline so KEY:value stays parseable
  local k="$1" v="$2"
  if [[ "$v" == *:* || "$v" == *$'\n'* ]]; then v="\"$(printf '%s' "$v" | tr '\n' ' ')\""; fi
  printf '%s %s\n' "$k" "$v"
}

_block() { echo "STATUS: blocked"; echo "GAP:    $1"; exit 0; }
# GH_TIMEOUT_SECS — bound on each `gh` call inside _resolve_default_branch.
# Override via env for operators on slow links. A hung `gh` (dead network,
# stalled auth prompt, etc.) must degrade to the local fallback, never hang
# the caller — this runs on every `envelope.sh show` for a repo declaring
# merge.mode: integration-branch, and again per merge-eligible work unit in
# Delta 6, including inside the unattended nightly loop.
#
# VALIDATED, never passed to `timeout` raw: GNU `timeout` treats a duration of
# `0` as "no timeout", so an unvalidated $DEVLEAD_GH_TIMEOUT_SECS=0 — a
# plausible operator value for "do not wait" — would silently reinstate the
# unbounded hang this guard exists to close. A non-numeric override would
# also reach `timeout` and make it error out: fail-safe, but silent (stderr
# discarded downstream). Only a positive integer (>= 1) is accepted; anything
# else falls back to the default and prints a one-line warning naming both
# the offending value and the value actually used.
_GH_TIMEOUT_DEFAULT=10
GH_TIMEOUT_SECS="${DEVLEAD_GH_TIMEOUT_SECS:-$_GH_TIMEOUT_DEFAULT}"
if ! [[ "$GH_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
  echo "envelope: DEVLEAD_GH_TIMEOUT_SECS='$GH_TIMEOUT_SECS' is not a positive integer — using ${_GH_TIMEOUT_DEFAULT}s instead" >&2
  GH_TIMEOUT_SECS="$_GH_TIMEOUT_DEFAULT"
fi
# _resolve_default_branch — ground truth for "what is the repo's default
# branch", used by A3 clause 2 (an integration branch must never BE the
# default branch). Prefers `gh repo view` (live remote query) over the local
# `refs/remotes/origin/HEAD` symref, because git never auto-updates that
# symref: if the remote default branch is renamed after cloning, the symref
# still points at the OLD name and a comparison against it would approve
# merging into what is now the real default branch. Falls back to the
# symref when `gh` is unavailable, unauthenticated, OR times out — a hung
# `gh` is treated exactly like "gh unavailable", never like "no default
# branch". Prints the branch name and returns 0, or returns 1 (no stdout)
# when neither source resolves — callers fail closed on that case
# (GOVERNANCE.md §A3).
# _GH_ONLY=1 (set by `show --origin`) drops the symref fallback: there the
# answer decides which branch merge authority is read from, and a session can
# rewrite the local symref — no answer from GitHub, no default branch.
_GH_ONLY=0
_resolve_default_branch() {
  local _db _auth_rc _view_rc _gh_timeout=()
  # `timeout` is coreutils and normally present, but don't assume it: if
  # missing, call `gh` directly (unbounded, as before) rather than break the
  # check entirely.
  if command -v timeout &>/dev/null; then
    _gh_timeout=(timeout "$GH_TIMEOUT_SECS")
  fi
  if command -v gh &>/dev/null; then
    "${_gh_timeout[@]}" gh auth status &>/dev/null
    _auth_rc=$?
    if [[ ${#_gh_timeout[@]} -gt 0 && $_auth_rc -eq 124 ]]; then
      echo "envelope: gh auth status timed out after ${GH_TIMEOUT_SECS}s — falling back to local symref" >&2
    fi
    if [[ $_auth_rc -eq 0 ]]; then
      _db=$("${_gh_timeout[@]}" gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
      _view_rc=$?
      if [[ ${#_gh_timeout[@]} -gt 0 && $_view_rc -eq 124 ]]; then
        echo "envelope: gh repo view timed out after ${GH_TIMEOUT_SECS}s — falling back to local symref" >&2
      fi
      if [[ -n "$_db" ]]; then
        printf '%s' "$_db"
        return 0
      fi
    fi
  fi
  [[ "$_GH_ONLY" == "1" ]] && return 1
  _db=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [[ -n "$_db" ]]; then
    printf '%s' "$_db"
    return 0
  fi
  return 1
}
_is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }
# _read_version_sha — reads the SHA: field from ~/.devlead/VERSION (KEY:
# value, one per line — see upgrade's write below). Prints the sha and
# returns 0, or returns 1 (no stdout) when VERSION is absent or has no SHA
# line — used by `upgrade`'s idempotency gate (REQ-03).
_read_version_sha() {
  local vf="$HOME/.devlead/VERSION" sha
  [[ -f "$vf" ]] || return 1
  sha="$(awk -F': ' '/^SHA:/{print $2; exit}' "$vf" 2>/dev/null)"
  [[ -n "$sha" ]] || return 1
  printf '%s\n' "$sha"
}
_in() { local v="$1"; shift; local x; for x in "$@"; do [[ "$v" == "$x" ]] && return 0; done; return 1; }
_assert_keys() {
  # $1=yq-path $2=label rest=allowed nested keys
  local path="$1" label="$2"; shift 2; local allowed=" $* " k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$allowed" == *" $k "* ]] || _block "unknown key '$k' under $label"
  done < <(yq e "${path} | keys | .[]" "$ENV_FILE" 2>/dev/null)
}
# _intake_actor <issue> <label> — login that applied <label> to <issue> MOST
# RECENTLY, read from the issue's events (every page). A label removed and
# re-added is vouched for by whoever re-added it. Label names compare
# case-insensitively, as GitHub does. Returns 1 with no stdout
# when the events cannot be read, hold no `labeled` event for that exact
# label, or name an actor that is not a plain GitHub login — the caller
# treats every one of those as unverified (fail closed, S5).
_intake_actor() {
  local events actor
  events=$(gh api "repos/{owner}/{repo}/issues/$1/events" --paginate 2>/dev/null) || return 1
  actor=$(printf '%s' "$events" | jq -rs --arg l "$2" '
    [.[][] | select(.event == "labeled" and ((.label.name // "") | ascii_downcase) == ($l | ascii_downcase))]
    | sort_by(.created_at) | last | .actor.login // empty' 2>/dev/null) || return 1
  [[ "$actor" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || return 1
  printf '%s' "$actor"
}

# ---------------------------------------------------------------------------
# check — enrollment + kill-switch read. Always exit 0.
# ---------------------------------------------------------------------------
_do_check() {
  if [[ ! -f "$ENV_FILE" ]]; then echo "ENROLLED: false"; exit 0; fi
  echo "ENROLLED: true"
  if ! command -v yq &>/dev/null; then
    echo "ENABLED: unknown"
    echo "GAP:     yq not found — cannot read enabled flag"
    exit 0
  fi
  local en
  en=$(yq e '.enabled' "$ENV_FILE" 2>/dev/null)
  case "$en" in
    true)  echo "ENABLED: true" ;;
    false) echo "ENABLED: false" ;;
    *)     echo "ENABLED: unknown"; echo "GAP:     enabled missing/non-boolean" ;;
  esac
  exit 0
}

# ---------------------------------------------------------------------------
# template — the scaffold, on stdout. The one copy of it: `init` writes it,
# and `devlead enroll` (enroll.sh) starts its answers from it. Writes nothing.
# ---------------------------------------------------------------------------
_template() {
  cat <<'YML'
# DevLead envelope — persisted per-repo authorization (Nivel 2 substrate).
version: 1
enabled: false
select:
  bucket: nuevo-entrante
  exclude_labels: [blocked, wip, discuss]
  require_readiness: true
  # intake_label: devlead  # OPTIONAL. Also take open issues carrying this label, but only when a login in intake_labelers applied it (checked in the issue's events). Must not be in exclude_labels nor equal discover.label.
  # intake_labelers: [your-login]  # OPTIONAL, requires intake_label. GitHub logins allowed to apply intake_label. Omit → only the authenticated gh user.
order:
  by: [priority-label, created-asc]
  # priority_labels: [p0, priority:high, priority:urgent, bug]  # OPTIONAL. Position = tier (0=highest); no-match issues share the lowest tier (FIFO created-asc). Omit → built-in cascade where priority:high and priority:urgent TIE at tier 1 (a positional list cannot express that tie).
budget:
  max_issues: 3
  stop_at: null
base:
  strategy: nearest-tag
  # integration_branch: dev  # OPTIONAL, default dev
forbidden_zones: inherit
on_failure:
  policy: park-and-continue
  skip_dependents: true
merge:
  # How far DevLead may merge on its own. See GOVERNANCE.md §A3.
  #
  #   never               DEFAULT. DevLead never invokes git merge / gh pr merge.
  #                       The pipeline ends at `gh pr create` and every PR waits
  #                       for you.
  #
  #   integration-branch  DevLead may merge green work-unit PRs into
  #                       base.integration_branch, and ONLY into that branch. It
  #                       then opens one long-lived PR from there to the default
  #                       branch: your single review point for the whole run.
  #                       Requires base.integration_branch to be declared above,
  #                       and it must NOT be the repo's default branch — the
  #                       envelope is blocked if it is.
  #
  #   default-branch      RESERVED, not implemented, rejected. Enabling it is its
  #                       own governance decision, not an envelope edit.
  #
  # A red gate never merges (§A4), and a failed merge parks with gh's exact
  # reason — never retried, never forced, never --admin.
  mode: never
report:
  to: journal-per-repo
YML
}

# ---------------------------------------------------------------------------
# init — copy-if-not-exists; never overwrites.
# NOTE: `return 0`, not `exit 0` — this runs as the middle phase of the
# `init)` dispatch case (bootstrap -> _do_init -> _do_optin); exiting here
# would skip the opt-in question entirely.
# ---------------------------------------------------------------------------
_do_init() {
  mkdir -p "$(dirname "$ENV_FILE")"
  if [[ -f "$ENV_FILE" ]]; then
    echo "STATUS: exists"
    echo "PATH:   $ENV_FILE"
    return 0
  fi
  _template > "$ENV_FILE"
  echo "STATUS: created"
  echo "PATH:   $ENV_FILE"
  return 0
}

# ---------------------------------------------------------------------------
# opt-in — the SOLE mutator of ~/.devlead/autonomous-repos + the sweep timer.
# Exactly one explicit yes/no question, asked once per `init` run. Never
# touches envelope.yml's `enabled:` kill-switch — enrollment (is this repo in
# the sweep list?) and the kill-switch (committed, auditable) are independent
# gates by design. `return 0` always: declining or defaulting is a normal
# outcome, not an error.
# ---------------------------------------------------------------------------
_do_optin() {
  local repo
  repo="$(_repo_root)"

  # Inv 2 — re-derive live state, never assume from a prior run. Same dedup
  # pattern used elsewhere in this codebase (e.g. devlead-session.sh): a plain
  # grep -qxF against the repos file, not a remembered/hardcoded status.
  local repos_file="$HOME/.devlead/autonomous-repos"
  local _already_enrolled=false
  if [[ -f "$repos_file" ]] && grep -qxF "$repo" "$repos_file" 2>/dev/null; then
    _already_enrolled=true
  fi

  if [[ ! -t 0 ]]; then
    if [[ "$_already_enrolled" == "true" ]]; then
      echo "SWEEP: already enrolled (non-interactive)"
    else
      echo "SWEEP: not enrolled (non-interactive)"
    fi
    return 0
  fi

  local ans
  read -r -p "Enroll this repo in the daily sweep (Nivel 2)? [y/N] " ans || ans=""

  # Affirmative tokens (case-insensitive): y, yes, and rioplatense sí/si —
  # both the accented and unaccented spelling are accepted (locked decision).
  case "${ans,,}" in
    y|yes|si|sí)
      mkdir -p "$(dirname "$repos_file")"
      touch "$repos_file"
      grep -qxF "$repo" "$repos_file" 2>/dev/null || echo "$repo" >> "$repos_file"

      local timer_status
      if systemctl --user is-enabled devlead-sweep.timer &>/dev/null; then
        timer_status="already-enabled"
      else
        # Check the REAL exit status — a swallowed `|| true` here would print
        # "enabled" even when systemctl failed (e.g. no user session, unit
        # missing). Report honestly; never abort _do_optin on this failure.
        if systemctl --user enable --now devlead-sweep.timer &>/dev/null; then
          timer_status="enabled"
        else
          timer_status="enable-failed"
        fi
      fi
      echo "SWEEP: enrolled"
      echo "TIMER: $timer_status"
      ;;
    *)
      if [[ "$_already_enrolled" == "true" ]]; then
        echo "SWEEP: already enrolled"
      else
        echo "SWEEP: not enrolled"
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# upgrade [explicit_repo_dir] — versioned publish. Replaces the old always-on
# symlink bootstrap with an explicit, stamped publish: dirty-tree honest-gap
# (REQ-05) -> HEAD sha idempotency check (REQ-03) -> SOURCE_REPO written
# EARLY, before any copy (REQ-11) -> copy set via bootstrap_symlinks/_systemd
# (REQ-01/02/08) -> conditional daemon-reload (REQ-04) -> VERSION written
# LAST, only on a fully successful copy set (set-level atomicity via
# heal-on-rerun, see design).
#
# The optional positional arg is threaded straight through to
# `_bootstrap_source_repo`'s tier-1 (explicit arg wins over the SOURCE_REPO
# anchor and self-resolve fallback) — `devlead upgrade /path/to/checkout`
# gives the user an explicit escape hatch to publish from a specific
# checkout instead of silently trusting the possibly-stale anchor. Omitted →
# behavior is unchanged (falls through to tier-2/tier-3 exactly as before).
#
# NOTE: `return 0` throughout, never `exit` — this is called both directly
# from the `upgrade)` dispatch case (which exits after) AND from `init`'s
# first-time-publish branch (which must continue on to bootstrap_token_seed /
# _do_init / _do_optin regardless of publish outcome, matching the
# pre-existing init idiom of never aborting the init chain on a bootstrap
# degradation).
# ---------------------------------------------------------------------------
_do_upgrade() {
  local _explicit_repo="${1:-}"
  local src
  if ! src="$(_bootstrap_source_repo "$_explicit_repo")"; then
    echo "STATUS: blocked"
    echo "GAP:    could not resolve source repo (no ~/.devlead/SOURCE_REPO anchor and bootstrap-lib.sh is not a symlink)"
    return 0
  fi

  # REQ-05 [GATE — CARDINAL]: dirty tree blocks publish. A non-zero exit from
  # `git status` (e.g. src is not a git checkout) is treated the same as
  # dirty — never silently proceed on an unreadable git status.
  local dirty
  if ! dirty="$(git -C "$src" status --porcelain 2>/dev/null)"; then
    echo "STATUS: blocked"
    echo "GAP:    could not read git status for source repo '$src'"
    return 0
  fi
  if [[ -n "$dirty" ]]; then
    echo "STATUS: blocked"
    echo "GAP:    devlead repo has uncommitted changes — refusing to publish"
    return 0
  fi

  # The publish set is the SOURCE's manifest. `devlead upgrade` runs the
  # installed envelope.sh, which sourced the installed bootstrap-lib.sh: a
  # file the source added to the manifest since the last install would be
  # skipped while VERSION still advanced to HEAD, and every later run would
  # then report up-to-date. Hand the run, once, to the source checkout's own
  # envelope.sh, after the clean-tree gate so only committed code runs.
  if [[ "${2:-}" == "--from-source" && "${DEVLEAD_UPGRADE_FROM_SOURCE:-}" != "1" ]]; then
    local _self_dir _src_dir
    _self_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    _src_dir="$(readlink -f "$src/.devlead/scripts" 2>/dev/null || true)"
    if [[ -n "$_src_dir" && "$_src_dir" != "$_self_dir" && -f "$_src_dir/envelope.sh" ]]; then
      DEVLEAD_UPGRADE_FROM_SOURCE=1 exec bash "$_src_dir/envelope.sh" upgrade "$src"
    fi
  fi

  local head_sha head_branch
  head_sha="$(git -C "$src" rev-parse --short HEAD 2>/dev/null)"
  if [[ -z "$head_sha" ]]; then
    echo "STATUS: blocked"
    echo "GAP:    could not resolve HEAD sha in '$src'"
    return 0
  fi
  head_branch="$(git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -z "$head_branch" ]] && head_branch="HEAD"

  # REQ-03: idempotency gate against the current stamp. A failed prior run
  # never advances SHA (see below), so this comparison is never fooled by a
  # half-published set.
  local current_sha
  current_sha="$(_read_version_sha)" || current_sha=""
  if [[ -n "$current_sha" && "$current_sha" == "$head_sha" ]]; then
    echo "STATUS: up-to-date"
    echo "SHA:    $head_sha"
    return 0
  fi

  # REQ-11: SOURCE_REPO write is EARLY — before any copy — so a mid-run
  # failure never leaves published copies without a recorded anchor.
  mkdir -p "$HOME/.devlead" 2>/dev/null
  printf '%s\n' "$src" > "$HOME/.devlead/SOURCE_REPO"

  bootstrap_symlinks "$src"
  if [[ ${#BOOTSTRAP_SYMLINKS_FAILED[@]} -gt 0 ]]; then
    echo "STATUS: blocked"
    local f
    for f in "${BOOTSTRAP_SYMLINKS_FAILED[@]}"; do
      echo "GAP:    failed to publish $f"
    done
    return 0
  fi

  bootstrap_systemd "$src"
  if [[ ${#BOOTSTRAP_SYSTEMD_FAILED[@]} -gt 0 ]]; then
    echo "STATUS: blocked"
    local f
    for f in "${BOOTSTRAP_SYSTEMD_FAILED[@]}"; do
      echo "GAP:    failed to publish $f"
    done
    return 0
  fi
  if [[ "${BOOTSTRAP_SYSTEMD_RELOAD_NEEDED:-0}" == "1" ]]; then
    systemctl --user daemon-reload 2>/dev/null \
      || echo "upgrade: WARNING: systemctl --user daemon-reload failed" >&2
  fi

  # VERSION written LAST — only after the whole copy set succeeded. Written
  # atomically (temp file + mv -f, mirroring _bootstrap_copy_one's own
  # temp+mv pattern) so a killed-mid-write never leaves a partial/malformed
  # VERSION file behind.
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _version_tmp="$HOME/.devlead/VERSION.tmp.$$"
  if ! { echo "SHA: $head_sha"; echo "BRANCH: $head_branch"; echo "STAMPED: $stamp"; } > "$_version_tmp" \
    || ! mv -f "$_version_tmp" "$HOME/.devlead/VERSION"; then
    echo "STATUS: blocked"
    echo "GAP:    failed to write ~/.devlead/VERSION"
    return 0
  fi

  echo "STATUS: ok"
  echo "VERSION: $head_sha ($stamp)"
  return 0
}

# ---------------------------------------------------------------------------
# show --origin — the envelope as committed on origin's default branch,
# fetched now, instead of the working tree's copy. The DevLead server's doors
# (merge.sh, open-pr.sh) read merge authority this way (L21 A1): a session can
# rewrite the working-tree file through paths the guard allows (`git checkout
# <ref> -- …`, an interpreter, `patch`, `git apply`), but not what origin's
# default branch holds. Points ENV_FILE at a private copy of that blob; any
# step that cannot be completed blocks (fail closed). Replace objects are
# ignored: a planted refs/replace/ entry cannot swap the blob read here.
# The default branch is GitHub's answer only (gh repo view), never the local
# origin/HEAD symref, which a session can point at a branch it pushed; the
# same holds for the integration-branch check that follows.
# ---------------------------------------------------------------------------
_ORIGIN_TMP=""
_origin_envelope() {
  local d _t=()
  command -v timeout &>/dev/null && _t=(timeout 60)
  _GH_ONLY=1
  # In the server, a repo with an entry in the read-only store (S25): that is
  # the envelope the user wrote, and no session can write it. Origin is not
  # read. Anywhere else --origin means origin: the store on the user's machine
  # is found through HOME, which the caller sets.
  [[ -n "$_FROM_STORE" && -e "$SERVER_MARKER" ]] && return 0
  d="$(_resolve_default_branch)" || d=""
  [[ -n "$d" ]] \
    || _block "cannot ask GitHub for origin's default branch — the envelope committed there cannot be read"
  [[ "$d" =~ ^[A-Za-z0-9._/-]+$ && "$d" != *..* && "$d" != -* ]] \
    || _block "origin's default branch has a name DevLead does not read — the envelope committed there cannot be read"
  "${_t[@]}" git -c fetch.prune=false fetch --quiet --no-tags origin \
      "+refs/heads/$d:refs/remotes/origin/$d" </dev/null >/dev/null 2>&1 \
    || _block "cannot fetch origin's default branch '$d' — the envelope committed there cannot be read"
  _ORIGIN_TMP="$(mktemp "${TMPDIR:-/tmp}/devlead-envelope.XXXXXX")" \
    || _block "cannot create a private copy of the envelope committed on origin"
  trap 'rm -f "$_ORIGIN_TMP"' EXIT
  git --no-replace-objects show "refs/remotes/origin/$d:.devlead/envelope.yml" > "$_ORIGIN_TMP" 2>/dev/null \
    || _block "no envelope.yml on origin's default branch '$d' — repo not enrolled"
  ENV_FILE="$_ORIGIN_TMP"
}

# ---------------------------------------------------------------------------
# show — FAIL-CLOSED parser: structural + value validation; emit on pass.
# ---------------------------------------------------------------------------
_do_show() {
  [[ -f "$ENV_FILE" ]] || _block "no envelope.yml — repo not enrolled"
  command -v yq &>/dev/null || _block "yq not found — install yq to parse envelope"
  yq e '.' "$ENV_FILE" > /dev/null 2>&1 || _block "envelope.yml is not valid YAML"

  local ver
  ver=$(yq e '.version' "$ENV_FILE" 2>/dev/null)
  [[ "$ver" == "1" ]] || _block "unsupported version '$ver' (expected 1)"

  # Top-level key set: no unknown keys (closed schema) + no missing REQUIRED
  # keys. `discover` is the sole OPTIONAL key (_TOP_OPTIONAL) — its absence
  # is not a schema drift, everything else in _TOP_REQUIRED still is.
  local top k
  top=$(yq e 'keys | .[]' "$ENV_FILE" 2>/dev/null)
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    _in "$k" $_TOP || _block "unknown top-level key '$k'"
  done <<< "$top"
  for k in $_TOP_REQUIRED; do
    _in "$k" $top || _block "missing required top-level key '$k'"
  done

  # Nested key validation
  _assert_keys '.select'     'select'     bucket exclude_labels require_readiness intake_label intake_labelers
  _assert_keys '.order'      'order'      by priority_labels
  _assert_keys '.budget'     'budget'     max_issues stop_at
  _assert_keys '.base'       'base'       strategy integration_branch
  _assert_keys '.on_failure' 'on_failure' policy skip_dependents
  _assert_keys '.merge'      'merge'      mode
  _assert_keys '.report'     'report'     to
  # .discover is OPTIONAL (absent → block absent entirely, no error): the
  # 'yq keys' call on a missing path fails and is silenced by the 2>/dev/null
  # inside _assert_keys, so its read loop simply consumes nothing — same
  # idiom relied on by order.priority_labels below, no special-casing needed.
  _assert_keys '.discover'   'discover'   enabled label modules

  local fz
  fz=$(yq e '.forbidden_zones' "$ENV_FILE" 2>/dev/null)
  [[ "$fz" == "inherit" ]] || _block "forbidden_zones must be 'inherit' in v1 (got '$fz')"

  # FAIL-CLOSED VALUE VALIDATION against LOCKED v1 vocabulary (D7)
  local en bk rr mx sa bs op sd mm rt
  en=$(yq e '.enabled' "$ENV_FILE" 2>/dev/null)
  local en_type
  en_type=$(yq e '.enabled | type' "$ENV_FILE" 2>/dev/null)
  [[ "$en_type" == "!!bool" ]] || _block "enabled must be a YAML boolean (got type '$en_type')"
  _is_bool "$en" || _block "enabled must be boolean (got '$en')"

  bk=$(yq e '.select.bucket' "$ENV_FILE" 2>/dev/null)
  [[ "$bk" == "nuevo-entrante" ]] || _block "select.bucket must be 'nuevo-entrante' in v1 (got '$bk')"

  local el_type
  el_type=$(yq e '.select.exclude_labels | type' "$ENV_FILE" 2>/dev/null)
  [[ "$el_type" == "!!seq" ]] || _block "select.exclude_labels must be a YAML list"

  rr=$(yq e '.select.require_readiness' "$ENV_FILE" 2>/dev/null)
  local rr_type
  rr_type=$(yq e '.select.require_readiness | type' "$ENV_FILE" 2>/dev/null)
  [[ "$rr_type" == "!!bool" ]] || _block "select.require_readiness must be a YAML boolean (got type '$rr_type')"
  _is_bool "$rr" || _block "select.require_readiness must be boolean (got '$rr')"

  # order.by: v1 locks to exactly [priority-label, created-asc] in that order
  local ob_type ob_val
  ob_type=$(yq e '.order.by | type' "$ENV_FILE" 2>/dev/null)
  [[ "$ob_type" == "!!seq" ]] || _block "order.by must be [priority-label, created-asc] in v1"
  ob_val=$(yq e '.order.by | join(",")' "$ENV_FILE" 2>/dev/null)
  [[ "$ob_val" == "priority-label,created-asc" ]] \
    || _block "order.by must be [priority-label, created-asc] in v1 (got '$ob_val')"

  # order.priority_labels (OPTIONAL): present → non-empty !!seq of !!str
  local pl_type
  pl_type=$(yq e '.order.priority_labels | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$pl_type" != "!!null" ]]; then
    [[ "$pl_type" == "!!seq" ]] \
      || _block "order.priority_labels must be a YAML list when present (got type '$pl_type')"
    local pl_len
    pl_len=$(yq e '.order.priority_labels | length' "$ENV_FILE" 2>/dev/null)
    [[ "$pl_len" =~ ^[1-9][0-9]*$ ]] \
      || _block "order.priority_labels present but empty — positional list needs >=1 entry"
    local pe_type
    while IFS= read -r pe_type; do
      [[ "$pe_type" == "!!str" ]] \
        || _block "order.priority_labels entries must be strings (got type '$pe_type')"
    done < <(yq e '.order.priority_labels[] | type' "$ENV_FILE" 2>/dev/null)
    local pe_val pe_trim
    while IFS= read -r pe_val; do
      pe_trim=$(printf '%s' "$pe_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -n "$pe_trim" && "$pe_val" == "$pe_trim" ]] \
        || _block "order.priority_labels entries must be non-empty strings without surrounding whitespace"
    done < <(yq e '.order.priority_labels[]' "$ENV_FILE" 2>/dev/null)
  fi

  mx=$(yq e '.budget.max_issues' "$ENV_FILE" 2>/dev/null)
  local mx_type
  mx_type=$(yq e '.budget.max_issues | type' "$ENV_FILE" 2>/dev/null)
  [[ "$mx_type" == "!!int" ]] || _block "budget.max_issues must be a positive integer"
  [[ "$mx" =~ ^[1-9][0-9]*$ ]] || _block "budget.max_issues must be a positive integer (got '$mx')"

  sa=$(yq e '.budget.stop_at' "$ENV_FILE" 2>/dev/null)
  [[ "$sa" == "null" || "$sa" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || _block "budget.stop_at must be null or HH:MM (got '$sa')"

  bs=$(yq e '.base.strategy' "$ENV_FILE" 2>/dev/null)
  _in "$bs" nearest-tag dev || _block "base.strategy must be 'nearest-tag' or 'dev' (got '$bs')"

  # base.integration_branch (OPTIONAL): present → non-empty !!str
  local ib_type
  ib_type=$(yq e '.base.integration_branch | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$ib_type" != "!!null" ]]; then
    [[ "$ib_type" == "!!str" ]] \
      || _block "base.integration_branch must be a YAML string when present (got type '$ib_type')"
    local ib_val ib_trim
    ib_val=$(yq e '.base.integration_branch' "$ENV_FILE" 2>/dev/null)
    ib_trim=$(printf '%s' "$ib_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$ib_trim" && "$ib_val" == "$ib_trim" ]] \
      || _block "base.integration_branch must be a non-empty string without surrounding whitespace"
  fi

  op=$(yq e '.on_failure.policy' "$ENV_FILE" 2>/dev/null)
  [[ "$op" == "park-and-continue" ]] \
    || _block "on_failure.policy must be 'park-and-continue' in v1 (got '$op')"

  sd=$(yq e '.on_failure.skip_dependents' "$ENV_FILE" 2>/dev/null)
  local sd_type
  sd_type=$(yq e '.on_failure.skip_dependents | type' "$ENV_FILE" 2>/dev/null)
  [[ "$sd_type" == "!!bool" ]] || _block "on_failure.skip_dependents must be a YAML boolean"
  _is_bool "$sd" || _block "on_failure.skip_dependents must be boolean (got '$sd')"

  # merge.mode — see GOVERNANCE.md §A3. `default-branch` is RESERVED and stays
  # rejected: enabling it is its own governance decision, not an envelope edit.
  mm=$(yq e '.merge.mode' "$ENV_FILE" 2>/dev/null)
  case "$mm" in
    never|integration-branch) ;;
    default-branch)
      _block "merge.mode 'default-branch' is RESERVED and not implemented — see GOVERNANCE.md §A3" ;;
    *)
      _block "merge.mode must be 'never' or 'integration-branch' (got '$mm')" ;;
  esac

  # A3 clause 2, enforced in code rather than prose: an integration branch that
  # IS the default branch would grant merge-to-trunk under a name that reads as
  # safe. The default branch is resolved from the REMOTE, never from anything
  # DevLead can write.
  if [[ "$mm" == "integration-branch" ]]; then
    local _ib _default_branch
    _ib=$(yq e '.base.integration_branch' "$ENV_FILE" 2>/dev/null)
    # Judge by TYPE, not by spelling: yq prints a null written as `~`, `Null`
    # or `NULL` verbatim, so a string comparison against "null" lets those
    # through — and the `// "dev"` default below would then report `dev` as the
    # integration branch without it ever having been compared to the trunk.
    local _ib_type
    _ib_type=$(yq e '.base.integration_branch | type' "$ENV_FILE" 2>/dev/null)
    if [[ "$_ib_type" != "!!str" || -z "$_ib" ]]; then
      _block "merge.mode 'integration-branch' requires base.integration_branch to be declared"
    else
      _default_branch="$(_resolve_default_branch)" || _default_branch=""
      if [[ -z "$_default_branch" ]]; then
        _block "merge.mode 'integration-branch' requires a resolvable default branch (gh repo view and git symbolic-ref refs/remotes/origin/HEAD both failed) — cannot prove base.integration_branch is not the trunk"
      elif [[ "$_ib" == "$_default_branch" ]]; then
        _block "base.integration_branch ('$_ib') must not be the default branch — that would grant merge-to-trunk (GOVERNANCE.md §A3)"
      fi
    fi
  fi

  rt=$(yq e '.report.to' "$ENV_FILE" 2>/dev/null)
  [[ "$rt" == "journal-per-repo" ]] \
    || _block "report.to must be 'journal-per-repo' (got '$rt')"

  # discover (OPTIONAL): absent → discovery disabled, envelope stays valid
  # (backward compatible — every envelope written before this block existed
  # keeps working unchanged). DISCOVERY, when it lands, only FILES issues; it
  # never executes from them — the issue is the artifact that crosses the
  # boundary into the existing envelope-governed pipeline.
  local disc_enabled="false" disc_label=""
  local disc_type
  disc_type=$(yq e '.discover | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$disc_type" != "!!null" ]]; then
    [[ "$disc_type" == "!!map" ]] \
      || _block "discover must be a YAML map when present (got type '$disc_type')"

    local de_type
    de_type=$(yq e '.discover.enabled | type' "$ENV_FILE" 2>/dev/null)
    [[ "$de_type" == "!!bool" ]] \
      || _block "discover.enabled must be a YAML boolean (got type '$de_type')"
    disc_enabled=$(yq e '.discover.enabled' "$ENV_FILE" 2>/dev/null)
    _is_bool "$disc_enabled" || _block "discover.enabled must be boolean (got '$disc_enabled')"

    if [[ "$disc_enabled" == "true" ]]; then
      local dl_type
      dl_type=$(yq e '.discover.label | type' "$ENV_FILE" 2>/dev/null)
      [[ "$dl_type" == "!!str" ]] \
        || _block "discover.label must be a non-empty string when discover.enabled is true (got type '$dl_type')"
      disc_label=$(yq e '.discover.label' "$ENV_FILE" 2>/dev/null)
      local disc_label_trim
      disc_label_trim=$(printf '%s' "$disc_label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -n "$disc_label_trim" ]] \
        || _block "discover.label must be non-empty when discover.enabled is true"

      local dm_type
      dm_type=$(yq e '.discover.modules | type' "$ENV_FILE" 2>/dev/null)
      [[ "$dm_type" == "!!seq" ]] \
        || _block "discover.modules must be a YAML list when discover.enabled is true (got type '$dm_type')"
      local dm_len
      dm_len=$(yq e '.discover.modules | length' "$ENV_FILE" 2>/dev/null)
      [[ "$dm_len" =~ ^[1-9][0-9]*$ ]] \
        || _block "discover.modules must be a non-empty list when discover.enabled is true"

      local dm_idx dm_path dm_spec
      for (( dm_idx=0; dm_idx<dm_len; dm_idx++ )); do
        dm_path=$(yq e ".discover.modules[$dm_idx].path" "$ENV_FILE" 2>/dev/null)
        dm_spec=$(yq e ".discover.modules[$dm_idx].spec" "$ENV_FILE" 2>/dev/null)
        [[ -n "$dm_path" && "$dm_path" != "null" ]] \
          || _block "discover.modules[$dm_idx] is missing or has an empty 'path'"
        [[ -n "$dm_spec" && "$dm_spec" != "null" ]] \
          || _block "discover.modules[$dm_idx] is missing or has an empty 'spec'"
        # ADR-3 convention (same rule ref-resolver.sh enforces for task
        # specs): every module reference must be repo-relative, never
        # absolute — an absolute path silently escapes the repo boundary.
        [[ "$dm_path" == /* ]] \
          && _block "discover.modules[$dm_idx].path must be repo-relative, not absolute (got '$dm_path')"
        [[ "$dm_spec" == /* ]] \
          && _block "discover.modules[$dm_idx].spec must be repo-relative, not absolute (got '$dm_spec')"
      done

      # Coupling rule (the whole point of this block): discovery FILES issues
      # against a spec but never executes from them — the issue is the
      # artifact that crosses the boundary. Those filed issues carry
      # discover.label. If that label is not also excluded by
      # select.exclude_labels, plan-driven mode would pick up discovery's own
      # freshly-filed issues on its very next run and start working them
      # unreviewed. The label is what holds the two-night cycle open: night
      # one files, you look, night two works whatever survived review.
      # Without the exclusion, DevLead would file work for itself and
      # immediately do it — collapsing the cycle and removing the only human
      # checkpoint in it.
      local excl_csv
      excl_csv=$(yq e '.select.exclude_labels | join(",")' "$ENV_FILE" 2>/dev/null)
      local -a excl_arr=()
      IFS=',' read -ra excl_arr <<< "$excl_csv"
      local _excl_hit=false _el
      for _el in "${excl_arr[@]}"; do
        [[ "$_el" == "$disc_label" ]] && { _excl_hit=true; break; }
      done
      [[ "$_excl_hit" == "true" ]] \
        || _block "discover.label '$disc_label' must appear in select.exclude_labels — otherwise plan-driven mode would pick up and execute discovery's own filed issues on its very next run, unreviewed"
    fi
  fi

  # select.intake_label / select.intake_labelers (OPTIONAL, S5). The label
  # widens what plan may take beyond the issues assigned to you, so it is
  # trusted only as far as WHO applied it: plan verifies the labeler in the
  # issue's events against intake_labelers (default: the authenticated gh
  # user). Validated here so a typo can never widen that set silently.
  local il_type il_val="" il_trim
  il_type=$(yq e '.select.intake_label | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$il_type" != "!!null" ]]; then
    [[ "$il_type" == "!!str" ]] \
      || _block "select.intake_label must be a YAML string when present (got type '$il_type')"
    il_val=$(yq e '.select.intake_label' "$ENV_FILE" 2>/dev/null)
    il_trim=$(printf '%s' "$il_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$il_trim" && "$il_val" == "$il_trim" ]] \
      || _block "select.intake_label must be a non-empty string without surrounding whitespace"
    # Same label as discovery's: plan would take discovery's own filed
    # issues, which is exactly what the discover coupling rule forbids.
    # Case-insensitive, as GitHub compares label names.
    if [[ "$disc_enabled" == "true" && "${il_val,,}" == "${disc_label,,}" ]]; then
      _block "select.intake_label '$il_val' must not equal discover.label — plan would take discovery's own filed issues"
    fi
    # An excluded intake label would never take anything: fail loudly.
    local _xl
    while IFS= read -r _xl; do
      _xl=$(printf '%s' "$_xl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ "${_xl,,}" == "${il_val,,}" ]] \
        && _block "select.intake_label '$il_val' must not appear in select.exclude_labels — no issue carrying it could ever be taken"
    done < <(yq e '.select.exclude_labels[]' "$ENV_FILE" 2>/dev/null)
  fi

  local ils_type
  ils_type=$(yq e '.select.intake_labelers | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$ils_type" != "!!null" ]]; then
    [[ -n "$il_val" ]] \
      || _block "select.intake_labelers requires select.intake_label"
    [[ "$ils_type" == "!!seq" ]] \
      || _block "select.intake_labelers must be a YAML list when present (got type '$ils_type')"
    local _ile_type
    while IFS= read -r _ile_type; do
      [[ "$_ile_type" == "!!str" ]] \
        || _block "select.intake_labelers entries must be GitHub logins (got type '$_ile_type')"
    done < <(yq e '.select.intake_labelers[] | type' "$ENV_FILE" 2>/dev/null)
    local _ile
    while IFS= read -r _ile; do
      [[ "$_ile" =~ ^[A-Za-z0-9-]+$ ]] \
        || _block "select.intake_labelers entries must be GitHub logins matching ^[A-Za-z0-9-]+\$ (got '$_ile')"
    done < <(yq e '.select.intake_labelers[]' "$ENV_FILE" 2>/dev/null)
  fi

  # All checks passed — emit structured output
  echo "STATUS: ok"
  _emit "VERSION:"           "$ver"
  _emit "ENABLED:"           "$en"
  _emit "BUCKET:"            "$bk"
  _emit "EXCLUDE_LABELS:"    "$(yq e '.select.exclude_labels | join(",")' "$ENV_FILE")"
  _emit "REQUIRE_READINESS:" "$rr"
  # Optional intake fields: omitted when absent (same convention as
  # PRIORITY_LABELS), so an envelope without them prints exactly as before.
  if [[ "$il_type" != "!!null" ]]; then
    _emit "INTAKE_LABEL:" "$il_val"
  fi
  if [[ "$ils_type" != "!!null" ]]; then
    _emit "INTAKE_LABELERS:" "$(yq e '.select.intake_labelers | join(",")' "$ENV_FILE")"
  fi
  _emit "ORDER_BY:"          "$(yq e '.order.by | join(",")' "$ENV_FILE")"
  local pl_present
  pl_present=$(yq e '.order.priority_labels | type' "$ENV_FILE" 2>/dev/null)
  if [[ "$pl_present" != "!!null" ]]; then
    _emit "PRIORITY_LABELS:" "$(yq e '.order.priority_labels | join(",")' "$ENV_FILE")"
  fi
  _emit "MAX_ISSUES:"        "$mx"
  _emit "STOP_AT:"           "$sa"
  _emit "BASE_STRATEGY:"     "$bs"
  local ib
  ib=$(yq e '.base.integration_branch // "dev"' "$ENV_FILE" 2>/dev/null)
  _emit "INTEGRATION_BRANCH:" "$ib"
  _emit "FORBIDDEN_ZONES:"   "inherit"
  _emit "ON_FAILURE_POLICY:" "$op"
  _emit "SKIP_DEPENDENTS:"   "$sd"
  _emit "MERGE_MODE:"        "$mm"
  _emit "REPORT_TO:"         "$rt"
  _emit "DISCOVER_ENABLED:"  "$disc_enabled"
  if [[ "$disc_enabled" == "true" ]]; then
    # Omitted entirely when disabled — same convention already used above for
    # order.priority_labels (an absent optional value is left out, not
    # emitted empty).
    _emit "DISCOVER_LABEL:"        "$disc_label"
    _emit "DISCOVER_MODULE_PATHS:" "$(yq e '[.discover.modules[].path] | join(",")' "$ENV_FILE" 2>/dev/null)"
    _emit "DISCOVER_MODULE_SPECS:" "$(yq e '[.discover.modules[].spec] | join(",")' "$ENV_FILE" 2>/dev/null)"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# plan — DRY-RUN queue builder. No branches, no PRs, no mutations.
# ---------------------------------------------------------------------------
_do_plan() {
  # 1. Internal show gate (subshell capture — inherit both key and value blocks)
  local show_out
  show_out=$(bash "$0" show 2>/dev/null)
  if echo "$show_out" | grep -q "^STATUS: blocked"; then
    echo "$show_out"
    exit 0
  fi

  # 2. Kill-switch gate
  local enabled
  enabled=$(echo "$show_out" | grep "^ENABLED:" | awk '{print $2}')
  if [[ "$enabled" != "true" ]]; then
    echo "STATUS: paused"
    echo "GAP:    envelope is disabled (enabled: false) — no queue produced"
    exit 0
  fi

  # Extract envelope settings from show output
  local max_issues exclude_labels require_readiness order_by
  max_issues=$(echo "$show_out" | grep "^MAX_ISSUES:" | awk '{print $2}')
  exclude_labels=$(echo "$show_out" | grep "^EXCLUDE_LABELS:" | awk '{print $2}')
  require_readiness=$(echo "$show_out" | grep "^REQUIRE_READINESS:" | awk '{print $2}')
  order_by=$(echo "$show_out" | grep "^ORDER_BY:" | awk '{print $2}')
  # priority_labels (optional): _emit quotes ':'-bearing values → strip before split
  local pl_raw
  local -a priority_labels_arr=()
  pl_raw=$(printf '%s\n' "$show_out" | sed -n 's/^PRIORITY_LABELS: //p')
  pl_raw="${pl_raw#\"}"; pl_raw="${pl_raw%\"}"
  if [[ -n "$pl_raw" ]]; then
    IFS=',' read -ra priority_labels_arr <<< "$pl_raw"
  fi
  # intake_label / intake_labelers (optional, S5): same sed + de-quote read,
  # never awk '{print $2}' — _emit quotes ':'-bearing values. A present but
  # empty INTAKE_LABELERS line is an empty allowlist, not the default.
  local intake_label intake_labelers_raw="" intake_labelers_set=false
  intake_label=$(printf '%s\n' "$show_out" | sed -n 's/^INTAKE_LABEL: //p')
  intake_label="${intake_label#\"}"; intake_label="${intake_label%\"}"
  if printf '%s\n' "$show_out" | grep -q '^INTAKE_LABELERS:'; then
    intake_labelers_set=true
    intake_labelers_raw=$(printf '%s\n' "$show_out" | sed -n 's/^INTAKE_LABELERS: //p')
  fi
  local git_root
  git_root="$(_repo_root)"

  # 3. Capture state.sh once (D6 — invoke the installed symlink)
  local state_bin="$HOME/.devlead/scripts/state.sh"
  if [[ ! -f "$state_bin" ]]; then
    # Fallback to repo-relative path
    state_bin="$git_root/.devlead/scripts/state.sh"
  fi
  local ST
  if ! ST=$(bash "$state_bin" 2>/dev/null); then
    echo "STATUS: blocked"
    echo "GAP:    state.sh failed to execute"
    exit 0
  fi

  # 4. Extract ASSIGNED_ISSUES via awk flag-toggle on '^--- '
  local assigned_raw
  assigned_raw=$(echo "$ST" | awk '
    /^--- ASSIGNED_ISSUES ---/ { in_section=1; next }
    /^--- / { in_section=0 }
    in_section && NF { print }
  ')

  if echo "$assigned_raw" | grep -q "^# UNAVAILABLE"; then
    local gap_msg
    gap_msg=$(echo "$assigned_raw" | grep "^# UNAVAILABLE" | sed 's/^# UNAVAILABLE: //')
    echo "STATUS: blocked"
    echo "GAP:    state.sh ASSIGNED_ISSUES unavailable: $gap_msg"
    exit 0
  fi

  # Extract BRANCHES and OPEN_PRS for nuevo-entrante detection
  local branches_raw prs_raw
  branches_raw=$(echo "$ST" | awk '
    /^--- BRANCHES ---/ { in_section=1; next }
    /^--- / { in_section=0 }
    in_section && NF { print }
  ')
  prs_raw=$(echo "$ST" | awk '
    /^--- OPEN_PRS ---/ { in_section=1; next }
    /^--- / { in_section=0 }
    in_section && NF { print }
  ')

  # 5. Supplement: createdAt for ordering (gh required for plan)
  if ! command -v gh &>/dev/null; then
    echo "STATUS: blocked"
    echo "GAP:    gh not found — cannot supplement issue metadata for plan"
    exit 0
  fi

  local created_json
  if ! created_json=$(gh issue list --assignee @me --state open \
    --limit 50 --json number,createdAt 2>/dev/null); then
    echo "STATUS: blocked"
    echo "GAP:    gh issue list (createdAt) failed — check gh auth status"
    exit 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "STATUS: blocked"
    echo "GAP:    jq not found — cannot parse gh issue metadata"
    exit 0
  fi

  # Body of every candidate: the untrusted-content scan (S6) reads it, and
  # so does the readiness check. A failed fetch blocks the plan whatever
  # require_readiness says — no issue is ever taken without its text having
  # been scanned. An issue missing from the list is excluded below.
  local body_json
  if ! body_json=$(gh issue list --assignee @me --state open \
    --limit 50 --json number,body 2>/dev/null); then
    echo "STATUS: blocked"
    echo "GAP:    gh issue list (body) failed — check gh auth status"
    exit 0
  fi

  # 6. Intake by label (S5): open issues carrying select.intake_label that
  # are not already assigned. They join the SAME per-issue loop below, where
  # one check runs first — who applied the label — and then every check,
  # the ordering and the budget cut assigned issues get. Their createdAt and
  # body are merged into the lookups the loop already reads.
  local intake_rows="" intake_nums=""
  local -a intake_allow=()
  local intake_allow_ok=true
  if [[ -n "$intake_label" ]]; then
    local intake_json assigned_nums
    if ! intake_json=$(gh issue list --label "$intake_label" --state open \
      --limit 50 --json number,title,labels,createdAt,updatedAt,body 2>/dev/null); then
      echo "STATUS: blocked"
      echo "GAP:    gh issue list (intake label) failed — check gh auth status"
      exit 0
    fi
    assigned_nums=$(printf '%s\n' "$assigned_raw" \
      | awk -F'\t' '$1 ~ /^#[0-9]+$/ { print substr($1, 2) }' | paste -sd, -)
    if ! intake_json=$(printf '%s' "$intake_json" | jq -c --arg skip "$assigned_nums" '
          ($skip | split(",") | map(select(. != "") | tonumber)) as $s
          | [.[] | select(.number as $n | any($s[]; . == $n) | not)]' 2>/dev/null) \
      || ! intake_rows=$(printf '%s' "$intake_json" | jq -r '.[] | [("#" + (.number | tostring)), .title,
          (if (.labels | length) == 0 then "" else [.labels[].name] | join(",") end),
          .updatedAt] | @tsv' 2>/dev/null) \
      || ! created_json=$(printf '%s\n%s\n' "$created_json" "$intake_json" \
          | jq -cs '.[0] + [.[1][] | {number, createdAt}]' 2>/dev/null) \
      || { [[ -n "$body_json" ]] && ! body_json=$(printf '%s\n%s\n' "$body_json" "$intake_json" \
          | jq -cs '.[0] + [.[1][] | {number, body}]' 2>/dev/null); }; then
      echo "STATUS: blocked"
      echo "GAP:    gh issue list (intake label) returned unparseable data"
      exit 0
    fi
    intake_nums=" $(printf '%s' "$intake_json" | jq -r '.[].number' | paste -sd' ' -) "

    # The allowlist: intake_labelers when declared, otherwise the
    # authenticated gh user. Looked up once, only when there is something to
    # check. The login is asked of the host gh is pointed at (GH_HOST, when
    # set, as an explicit --hostname); GH_REPO and GH_HOST themselves are
    # dropped for that one call.
    if [[ -n "${intake_nums// /}" ]]; then
      if [[ "$intake_labelers_set" == "true" ]]; then
        IFS=',' read -ra intake_allow <<< "$intake_labelers_raw"
      else
        local _me
        if _me=$(_h="${GH_HOST:-}"; unset GH_REPO GH_HOST
                 if [[ -n "$_h" ]]; then gh api --hostname "$_h" user -q .login
                 else gh api user -q .login; fi 2>/dev/null) \
          && [[ "$_me" =~ ^[A-Za-z0-9-]+$ ]]; then
          intake_allow=("$_me")
        else
          intake_allow_ok=false
        fi
      fi
    fi
  fi

  # Build exclude_labels array from comma-separated string
  local IFS_SAVE="$IFS"
  IFS=',' read -ra exc_labels <<< "$exclude_labels"
  IFS="$IFS_SAVE"

  # Build order_by array
  # Process each assigned issue. Entries are joined with the ASCII unit
  # separator (\x1f), which is stripped from every title and label below:
  # a '|' — or anything else a title may carry — can never cut a title or
  # shift the reason that follows it.
  local _FS=$'\x1f'
  # Issues excluded for their text are listed without it: the text is
  # exactly what is not trusted, so it never reaches the digest or the model.
  local _UNTRUSTED_TITLE='(título omitido — contenido no confiable)'
  local -a included_issues=()
  local -a excluded_issues=()

  while IFS=$'\t' read -r num title labels _updated; do
    # Strip leading '#' from issue number
    local issue_num="${num#\#}"
    [[ -z "$issue_num" ]] && continue
    # Skip unavailable markers
    [[ "$issue_num" == "#"* ]] && continue
    [[ "$issue_num" =~ ^[0-9]+$ ]] || continue
    title="${title//"$_FS"/}"
    labels="${labels//"$_FS"/}"

    local exclude_reason=""

    # Intake issues are trusted only as far as who applied the label (S5):
    # the latest `labeled` event for it must come from the allowlist. Any
    # lookup that cannot answer fails closed. Assigned issues skip this.
    if [[ "$intake_nums" == *" $issue_num "* ]]; then
      local _actor _allowed=false _a
      if [[ "$intake_allow_ok" != "true" ]] || ! _actor=$(_intake_actor "$issue_num" "$intake_label"); then
        excluded_issues+=("${issue_num}${_FS}${title}${_FS}intake-label-unverified")
        continue
      fi
      for _a in "${intake_allow[@]+"${intake_allow[@]}"}"; do
        [[ "${_a,,}" == "${_actor,,}" ]] && { _allowed=true; break; }
      done
      if [[ "$_allowed" != "true" ]]; then
        excluded_issues+=("${issue_num}${_FS}${title}${_FS}intake-label-untrusted (applied by ${_actor})")
        continue
      fi
    fi

    # Issue text is untrusted data (S6, GOVERNANCE.md §untrusted-content):
    # title and body go through the (heuristic) scan before every other check
    # except the intake labeler check above, so an instruction aimed at the
    # agent is reported even when another rule would also have excluded the
    # issue. No body to scan, or a scanner that cannot answer (exit 2 on an
    # empty text, 127 when missing), fails closed. The title is never empty
    # on GitHub, so the scan always receives text.
    local _scan_body _scan_out _scan_rc
    if ! _scan_body=$(printf '%s' "$body_json" | jq -er --arg n "$issue_num" \
        'first(.[] | select(.number == ($n | tonumber))) | .body // ""' 2>/dev/null); then
      excluded_issues+=("${issue_num}${_FS}${_UNTRUSTED_TITLE}${_FS}untrusted-content-unverified")
      continue
    fi
    _scan_out=$(printf '%s\n%s\n' "$title" "$_scan_body" | bash "$UNTRUSTED_BIN" scan 2>/dev/null)
    _scan_rc=$?
    if [[ $_scan_rc -eq 1 && -n "$_scan_out" ]] && ! grep -qvE '^[a-z-]+$' <<< "$_scan_out"; then
      excluded_issues+=("${issue_num}${_FS}${_UNTRUSTED_TITLE}${_FS}untrusted-content ($(paste -sd, - <<< "$_scan_out"))")
      continue
    elif [[ $_scan_rc -ne 0 ]]; then
      excluded_issues+=("${issue_num}${_FS}${_UNTRUSTED_TITLE}${_FS}untrusted-content-unverified")
      continue
    fi

    # 5a. nuevo-entrante check: no branch issue-N- and no PR headRefName issue-N-
    local is_nuevo=true
    if echo "$branches_raw" | grep -q "issue-${issue_num}-"; then
      is_nuevo=false
      exclude_reason="not-nuevo-entrante (branch issue-${issue_num}-* exists)"
    elif echo "$prs_raw" | awk -F'\t' '{print $NF}' | grep -q "issue-${issue_num}-"; then
      is_nuevo=false
      exclude_reason="not-nuevo-entrante (PR headRefName issue-${issue_num}-* exists)"
    fi

    if [[ "$is_nuevo" == "false" ]]; then
      excluded_issues+=("${issue_num}${_FS}${title}${_FS}${exclude_reason}")
      continue
    fi

    # 7. Filter: exclude_labels
    if [[ -n "$labels" ]]; then
      local lbl_hit=""
      IFS=',' read -ra issue_labels <<< "$labels"
      local il
      for il in "${issue_labels[@]}"; do
        il=$(echo "$il" | xargs)  # trim
        local el
        for el in "${exc_labels[@]}"; do
          el=$(echo "$el" | xargs)  # trim
          if [[ "$il" == "$el" ]]; then
            lbl_hit="$il"
            break 2
          fi
        done
      done
      if [[ -n "$lbl_hit" ]]; then
        excluded_issues+=("${issue_num}${_FS}${title}${_FS}excluded-label (${lbl_hit})")
        continue
      fi
    fi

    # Readiness check (require_readiness)
    if [[ "$require_readiness" == "true" && -n "$body_json" ]]; then
      local body_val
      body_val=$(echo "$body_json" | jq -r --arg n "$issue_num" \
        '.[] | select(.number == ($n | tonumber)) | .body // ""' 2>/dev/null)
      local body_trimmed
      body_trimmed=$(printf '%s' "$body_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -z "$body_trimmed" ]]; then
        excluded_issues+=("${issue_num}${_FS}${title}${_FS}not-ready (empty body)")
        continue
      fi
    fi

    # Get createdAt for this issue
    local created_at
    created_at=$(echo "$created_json" | jq -r --arg n "$issue_num" \
      '.[] | select(.number == ($n | tonumber)) | .createdAt // ""' 2>/dev/null)

    # Priority tier — dual-path (present=index lookup, absent=cascade)
    local tier
    if [[ ${#priority_labels_arr[@]} -gt 0 ]]; then
      # PRESENT: tier = lowest list index the issue carries; none → no-priority tier
      IFS=',' read -ra issue_label_arr <<< "$labels"
      tier=${#priority_labels_arr[@]}
      local i lbl
      for (( i=0; i<${#priority_labels_arr[@]}; i++ )); do
        for lbl in "${issue_label_arr[@]}"; do
          lbl=$(echo "$lbl" | xargs)
          if [[ "$lbl" == "${priority_labels_arr[$i]}" ]]; then
            tier=$i; break 2
          fi
        done
      done
    else
      # ABSENT: existing cascade UNCHANGED (preserves high==urgent tie)
      tier=3
      IFS=',' read -ra issue_label_arr <<< "$labels"
      local lbl
      for lbl in "${issue_label_arr[@]}"; do
        lbl=$(echo "$lbl" | xargs)
        if [[ "$lbl" == "p0" ]]; then tier=0; break; fi
        if [[ "$lbl" == "priority:high" || "$lbl" == "priority:urgent" ]]; then
          [[ $tier -gt 1 ]] && tier=1
        fi
        if [[ "$lbl" == "bug" ]]; then
          [[ $tier -gt 2 ]] && tier=2
        fi
      done
    fi

    included_issues+=("${tier}${_FS}${created_at}${_FS}${issue_num}${_FS}${title}${_FS}${labels}")
  done < <(echo "$assigned_raw"; [[ -n "$intake_rows" ]] && printf '%s\n' "$intake_rows")

  # 8. Sort INCLUDED by tier then createdAt asc
  local -a sorted_included=()
  if [[ ${#included_issues[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      sorted_included+=("$line")
    done < <(printf '%s\n' "${included_issues[@]}" | sort -t"$_FS" -k1,1n -k2,2)
  fi

  # 9. Cut at max_issues; remainder → budget-cut
  local count=0
  local -a final_included=()
  local -a budget_cut=()
  for entry in "${sorted_included[@]}"; do
    if [[ $count -lt $max_issues ]]; then
      final_included+=("$entry")
      (( count++ )) || true
    else
      # Extract issue_num and title for budget-cut
      local bc_num bc_title
      bc_num=$(echo "$entry" | cut -d"$_FS" -f3)
      bc_title=$(echo "$entry" | cut -d"$_FS" -f4)
      budget_cut+=("${bc_num}${_FS}${bc_title}${_FS}budget-cut (beyond max_issues=${max_issues})")
    fi
  done

  # Print header
  echo "=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ==="
  echo "ENVELOPE: ${git_root}/.devlead/envelope.yml  ENABLED: ${enabled}"
  echo "DATA_SOURCES: state.sh(ASSIGNED_ISSUES,BRANCHES,OPEN_PRS); gh issue list(createdAt,body)$([[ -n "$intake_label" ]] && echo "; gh issue list(intake label); gh api(issue events)")"
  echo "ORDER: ${order_by}  MAX_ISSUES: ${max_issues}  EXCLUDE_LABELS: ${exclude_labels}  READINESS: ${require_readiness}"
  echo "FORBIDDEN_ZONES: inherit (labels-based pre-check only)"
  echo ""

  # INCLUDED
  echo "--- INCLUDED (queue order) ---"
  if [[ ${#final_included[@]} -eq 0 ]]; then
    echo "(none)"
  else
    local qi=1
    for entry in "${final_included[@]}"; do
      local tier created num title
      tier=$(echo "$entry" | cut -d"$_FS" -f1)
      created=$(echo "$entry" | cut -d"$_FS" -f2)
      num=$(echo "$entry" | cut -d"$_FS" -f3)
      title=$(echo "$entry" | cut -d"$_FS" -f4)
      # Determine tier label for output — dual-path mirrors Site A
      local tier_label
      if [[ ${#priority_labels_arr[@]} -gt 0 ]]; then
        if [[ "$tier" -lt ${#priority_labels_arr[@]} ]]; then
          tier_label="${priority_labels_arr[$tier]}"
        else
          tier_label="none"
        fi
      else
        case "$tier" in
          0) tier_label="p0" ;;
          1) tier_label="priority:high/urgent" ;;
          2) tier_label="bug" ;;
          *) tier_label="none" ;;
        esac
      fi
      # Quote title if it contains ':'
      local display_title="$title"
      if [[ "$display_title" == *:* ]]; then display_title="\"${display_title}\""; fi
      printf '%d. #%s  %s\n' "$qi" "$num" "$display_title"
      printf '   basis: tier=%s, created=%s, nuevo-entrante  [zone-check: pre-check only, labels-based]\n' \
        "$tier_label" "${created:0:10}"
      (( qi++ )) || true
    done
  fi
  echo ""

  # EXCLUDED
  echo "--- EXCLUDED ---"
  local all_excluded=()
  # Merge non-nuevo-entrante excluded + label/readiness excluded + budget-cut
  all_excluded+=("${excluded_issues[@]+"${excluded_issues[@]}"}")
  all_excluded+=("${budget_cut[@]+"${budget_cut[@]}"}")

  if [[ ${#all_excluded[@]} -eq 0 ]]; then
    echo "(none)"
  else
    for entry in "${all_excluded[@]}"; do
      local ex_num ex_title ex_reason
      ex_num=$(echo "$entry" | cut -d"$_FS" -f1)
      ex_title=$(echo "$entry" | cut -d"$_FS" -f2)
      ex_reason=$(echo "$entry" | cut -d"$_FS" -f3-)
      local display_title="$ex_title"
      if [[ "$display_title" == *:* ]]; then display_title="\"${display_title}\""; fi
      printf '#%s  %s   reason: %s\n' "$ex_num" "$display_title" "$ex_reason"
    done
  fi
  echo ""
  echo "=== END PLAN ==="
  exit 0
}

# ---------------------------------------------------------------------------
# schema — machine-readable descriptor of every envelope field. Describes the
# SCHEMA, not an instance: does NOT read or require $ENV_FILE to exist.
#
# This exists so a future interactive config menu (and anything else that
# needs to render/explain the envelope's fields) has ONE source to render
# from. This repo already carries three independently hand-maintained
# publish lists (bootstrap_symlinks, bootstrap_systemd,
# smoke-pinned-release.sh) that drifted from each other — see
# test/unit-publish-manifest.sh. A menu with its own hardcoded field list
# would be a fourth. test/unit-envelope-schema.sh cross-checks this
# descriptor against _TOP_REQUIRED/_TOP_OPTIONAL, every _assert_keys call,
# and every field this file's `show` subcommand actually reads/emits, in
# BOTH directions, so the two can never drift silently.
#
# Record format (stable — parse this, do not rely on prose above it):
# one block per field, blocks separated by exactly one blank line. Each
# block is a fixed, ordered set of `KEY: value` lines (via _emit, so
# quoting stays consistent with `show`'s output):
#
#   FIELD:       dotted path (e.g. budget.max_issues). A list-of-objects
#                child uses an empty-index segment (e.g. discover.modules[].path).
#   TYPE:        bool | int | string | list | list-of-objects | map
#   DEFAULT:     the value `init` scaffolds, the resolved fallback when the
#                field may be absent, or "none" when there is neither.
#   REQUIRED:    true | false | conditional (<the exact condition>)
#   HELP:        one-line description of what the field controls.
#   CONSEQUENCE: OPTIONAL — only present where getting this field wrong has
#                a real, enforced effect (see the validation code cited in
#                each one). Its absence means no such effect is enforced.
#
# A consumer scans for `^FIELD: ` to find block starts and reads whatever
# `KEY: ` lines follow, up to the next blank line.
# ---------------------------------------------------------------------------
_schema_field() {
  # $1=path $2=type $3=default $4=required $5=help $6=consequence(optional)
  _emit "FIELD:"       "$1"
  _emit "TYPE:"        "$2"
  _emit "DEFAULT:"     "$3"
  _emit "REQUIRED:"    "$4"
  _emit "HELP:"        "$5"
  [[ -n "${6:-}" ]] && _emit "CONSEQUENCE:" "$6"
  echo ""
}

_do_schema() {
  echo "STATUS: ok"
  echo ""

  _schema_field "version" "int" "1" "true" \
    "Envelope schema version; v1 is the only version implemented — show blocks on anything else."

  _schema_field "enabled" "bool" "false" "true" \
    "Master run switch for this repo's pipeline." \
    "The kill switch. When false, 'plan' exits immediately with STATUS: paused and produces no queue — no issue is touched, regardless of every other field in this envelope."

  _schema_field "select" "map" "none (required map, no default)" "true" \
    "Which issues are eligible for this run: bucket, label exclusions, and the readiness gate."

  _schema_field "select.bucket" "string" "nuevo-entrante" "true" \
    "Which triage bucket the queue is built from; locked to 'nuevo-entrante' in v1."

  _schema_field "select.exclude_labels" "list" "[blocked, wip, discuss]" "true" \
    "Labels that remove an otherwise-eligible issue from the queue."

  _schema_field "select.require_readiness" "bool" "true" "true" \
    "When true, an issue with an empty body is excluded from the queue as not-ready."

  _schema_field "select.intake_label" "string" \
    "none — absent means only issues assigned to you are taken" "false" \
    "Optional label that also makes an open issue eligible, but only when a login in select.intake_labelers applied it." \
    "Fails closed. 'plan' reads each labeled issue's events and takes it only when the LATEST 'labeled' event for this label came from an allowed login; any other login excludes it as 'intake-label-untrusted (applied by <login>)', and an events or login lookup that cannot answer excludes it as 'intake-label-unverified'. Label names compare case-insensitively, as on GitHub. Assigned issues never go through this check. Must not appear in select.exclude_labels nor equal discover.label, in any case — envelope.sh blocks 'show' otherwise."

  _schema_field "select.intake_labelers" "list" \
    "none — absent means only the authenticated gh user (gh api user) may apply select.intake_label" \
    "conditional (optional; requires select.intake_label when present)" \
    "GitHub logins allowed to apply select.intake_label; an empty list allows nobody." \
    "Every entry must match ^[A-Za-z0-9-]+\$ and the list requires select.intake_label — envelope.sh blocks 'show' otherwise."

  _schema_field "order" "map" "none (required map, no default)" "true" \
    "How the eligible queue is ordered before the budget cut is applied."

  _schema_field "order.by" "list" "[priority-label, created-asc] (the only legal value in v1)" "true" \
    "Ordering keys, in priority; locked to [priority-label, created-asc] in v1."

  _schema_field "order.priority_labels" "list" \
    "none — absent means the built-in cascade (p0 > priority:high/priority:urgent tied > bug > none), FIFO by created-asc within a tier" \
    "false" \
    "Optional positional priority list — list position is the tier (0 = highest); overrides the built-in cascade when present."

  _schema_field "budget" "map" "none (required map, no default)" "true" \
    "How much work and how much time this run may spend."

  _schema_field "budget.max_issues" "int" "3" "true" \
    "Maximum number of issues taken from the ordered queue in one run." \
    "One of only two things that actually stop a run. 'plan' sorts the eligible queue by tier then created-at and cuts it at this position — everything past the cut is excluded with reason 'budget-cut (beyond max_issues=N)'."

  _schema_field "budget.stop_at" "string (nullable HH:MM)" "null (no cutoff time)" "true" \
    "Optional wall-clock cutoff; null means no time limit." \
    "The other thing that actually stops a run. When non-null, sweep-execute checks it before starting each issue (E2.1): once now >= stop_at, the current issue and every remaining pending issue in this repo are marked no_alcanzada ('stop_at HH:MM alcanzado') and the run ends here without starting them."

  _schema_field "base" "map" "none (required map, no default)" "true" \
    "Which git ref new work-unit branches are cut from, and (optionally) the integration branch."

  _schema_field "base.strategy" "string" "nearest-tag" "true" \
    "Branch strategy for new work: 'nearest-tag' or 'dev'."

  _schema_field "base.integration_branch" "string" \
    "dev (envelope.sh show falls back to 'dev' when this key is absent)" \
    "conditional (optional in general; required when merge.mode is integration-branch)" \
    "Branch DevLead may merge work-unit PRs into when merge.mode is integration-branch." \
    "Must never be the repo's default branch. When merge.mode is integration-branch, envelope.sh resolves the TRUE current default branch from the remote (gh repo view, falling back to the local symref) and blocks 'show' if this matches it — otherwise merge-to-trunk becomes reachable under a name that reads as safe (GOVERNANCE.md §A3, clause 2)."

  _schema_field "forbidden_zones" "string" "inherit (the only legal value in v1)" "true" \
    "Forbidden-zone policy source; locked to 'inherit' in v1 — comes from the global config, not a per-repo override."

  _schema_field "on_failure" "map" "none (required map, no default)" "true" \
    "What happens to the queue when a work unit's gate goes red."

  _schema_field "on_failure.policy" "string" "park-and-continue (the only legal value in v1)" "true" \
    "Failure handling policy; locked to 'park-and-continue' in v1."

  _schema_field "on_failure.skip_dependents" "bool" "true" "true" \
    "When true, work units that depend on a parked unit are skipped rather than attempted out of order."

  _schema_field "merge" "map" "none (required map, no default)" "true" \
    "How far DevLead may merge on its own. See GOVERNANCE.md §A3."

  _schema_field "merge.mode" "string" "never" "true" \
    "Merge authority granted to DevLead for this repo." \
    "never (default) ends the pipeline at PR creation — DevLead invokes neither git merge nor gh pr merge. integration-branch lets DevLead merge green work-unit PRs into base.integration_branch, and ONLY there, then opens one long-lived PR from that branch to the default branch. default-branch is RESERVED and REJECTED outright — enabling it is its own governance decision, not an envelope edit (GOVERNANCE.md §A3)."

  _schema_field "report" "map" "none (required map, no default)" "true" \
    "Where run results are written."

  _schema_field "report.to" "string" "journal-per-repo (the only legal value in v1)" "true" \
    "Report destination; locked to 'journal-per-repo' in v1."

  _schema_field "discover" "map" \
    "absent — discovery stays disabled; pre-existing envelopes stay valid unchanged" "false" \
    "Optional issue-discovery stage: explores declared modules against specs and files issues for gaps found. It never executes from what it files — the issue is the artifact that crosses into the already-governed pipeline."

  _schema_field "discover.enabled" "bool" "none — must be set explicitly whenever the discover: block is present" \
    "conditional (required once the discover: block is present)" \
    "Turns the discovery stage on or off for this repo."

  _schema_field "discover.label" "string" "none" \
    "conditional (required when discover.enabled is true)" \
    "Label discovery stamps on every issue it files." \
    "Must appear in select.exclude_labels. Otherwise plan-driven mode picks up and executes discovery's own filed issues on its very next run, unreviewed, which collapses the two-night review cycle — envelope.sh blocks 'show' outright when it is missing."

  _schema_field "discover.modules" "list-of-objects" "none" \
    "conditional (required, non-empty, when discover.enabled is true)" \
    "Modules discovery explores, each paired with the spec it is checked against."

  _schema_field "discover.modules[].path" "string" "none" \
    "conditional (required on every entry when discover.enabled is true)" \
    "Repo-relative path (ADR-3 convention) to the module being explored." \
    "Must be repo-relative, not absolute — same ADR-3 convention ref-resolver.sh enforces for task specs. An absolute path silently escapes the repo boundary; envelope.sh blocks 'show' outright when it sees one."

  _schema_field "discover.modules[].spec" "string" "none" \
    "conditional (required on every entry when discover.enabled is true)" \
    "Repo-relative path to the spec file this module is checked against." \
    "Must be repo-relative, not absolute — same ADR-3 convention ref-resolver.sh enforces for task specs. An absolute path silently escapes the repo boundary; envelope.sh blocks 'show' outright when it sees one."

  exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
_cmd="${1:-check}"
# A store entry a session could write is nobody's envelope (S25): every read
# that grants or reports authority stops here.
if [[ -n "$_STORE_UNSAFE" ]]; then
  case "$_cmd" in
    show|plan|check|path)
      _block "the envelope store $SERVER_STORE is writable here — the server reads it only from a read-only mount (compose.yaml mounts it read-only; recreate the container with that file)" ;;
  esac
fi
case "$_cmd" in
  check) _do_check ;;
  init)
    # Phase order (locked, REQ-06/07): first-time-vs-versioned publish branch
    # -> token seed (unrelated to versioning, unconditional, unchanged from
    # before this change) -> envelope scaffold (unchanged behavior) -> single
    # opt-in question (sole mutator of enrollment + timer state).
    if [[ ! -f "$HOME/.devlead/VERSION" ]]; then
      # First-time (REQ-06): no VERSION stamp yet -> run the exact same
      # publish path as `upgrade` (dirty-check, SOURCE_REPO early, copy set,
      # VERSION last).
      _do_upgrade
    else
      # Already-versioned (REQ-07): skip re-publish entirely, but SOURCE_REPO
      # still self-heals on every run (REQ-11) independent of the publish
      # step — cheap, idempotent, best-effort (never blocks the rest of init).
      _src_heal="$(_bootstrap_source_repo 2>/dev/null)" && {
        mkdir -p "$HOME/.devlead" 2>/dev/null
        printf '%s\n' "$_src_heal" > "$HOME/.devlead/SOURCE_REPO"
      }
    fi
    bootstrap_token_seed
    _do_init
    _do_optin
    exit 0
    ;;
  upgrade) _do_upgrade "${2:-}" --from-source; exit 0 ;;
  path) printf '%s\n' "$ENV_FILE"; exit 0 ;;
  show)
    # `show --origin`: read the envelope committed on origin's default branch
    # (see _origin_envelope), unless the repo has an entry in the server's
    # store. Plain `show` reads the store entry or the working tree.
    [[ "${2:-}" == "--origin" ]] && _origin_envelope
    _do_show ;;
  plan)   _do_plan ;;
  schema) _do_schema ;;
  template) _template; exit 0 ;;
  *) echo "uso: envelope.sh {check|init|show [--origin]|plan|upgrade|schema|path}" >&2; exit 2 ;;
esac
