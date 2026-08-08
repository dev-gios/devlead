#!/usr/bin/env bash
# envelope.sh — DevLead persisted per-repo envelope: parser + enrollment + dry-run planner.
# Subcommands: check | init | show | plan | upgrade. KEY:value stdout. Always exits 0 on operational outcomes.
# Envelope file: <git-root>/.devlead/envelope.yml (committed, auditable). READ-ONLY except `init` scaffold.
set -uo pipefail

# Sourced as a self-resolved sibling (NOT a hardcoded ~/.devlead/scripts path):
# on a fresh machine `init` runs straight from the repo checkout, before the
# ~/.devlead/scripts/ symlink farm exists — readlink -f on envelope.sh's OWN
# BASH_SOURCE resolves its real location first (checkout or installed
# symlink, either way), then looks up bootstrap-lib.sh as a plain sibling in
# that same real directory. Provides bootstrap_symlinks/_systemd/_token_seed.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bootstrap-lib.sh"

_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
ENV_FILE="$(_repo_root)/.devlead/envelope.yml"

# LOCKED schema whitelists (D5)
_TOP="version enabled select order budget base forbidden_zones on_failure merge report"
# nested: select{bucket exclude_labels require_readiness} order{by} budget{max_issues stop_at}
#         base{strategy integration_branch} on_failure{policy skip_dependents} merge{mode} report{to}

_emit() {
  # Quote values bearing ':' or newline so KEY:value stays parseable
  local k="$1" v="$2"
  if [[ "$v" == *:* || "$v" == *$'\n'* ]]; then v="\"$(printf '%s' "$v" | tr '\n' ' ')\""; fi
  printf '%s %s\n' "$k" "$v"
}

_block() { echo "STATUS: blocked"; echo "GAP:    $1"; exit 0; }
# _resolve_default_branch — ground truth for "what is the repo's default
# branch", used by A3 clause 2 (an integration branch must never BE the
# default branch). Prefers `gh repo view` (live remote query) over the local
# `refs/remotes/origin/HEAD` symref, because git never auto-updates that
# symref: if the remote default branch is renamed after cloning, the symref
# still points at the OLD name and a comparison against it would approve
# merging into what is now the real default branch. Falls back to the
# symref only when `gh` is unavailable or unauthenticated. Prints the
# branch name and returns 0, or returns 1 (no stdout) when neither source
# resolves — callers fail closed on that case (GOVERNANCE.md §A3).
_resolve_default_branch() {
  local _db
  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    _db=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
    if [[ -n "$_db" ]]; then
      printf '%s' "$_db"
      return 0
    fi
  fi
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
  cat > "$ENV_FILE" <<'YML'
# DevLead envelope — persisted per-repo authorization (Nivel 2 substrate).
version: 1
enabled: false
select:
  bucket: nuevo-entrante
  exclude_labels: [blocked, wip, discuss]
  require_readiness: true
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
  # pattern used elsewhere in this codebase (e.g. devlead-active.sh): a plain
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
# show — FAIL-CLOSED parser: structural + value validation; emit on pass.
# ---------------------------------------------------------------------------
_do_show() {
  [[ -f "$ENV_FILE" ]] || _block "no envelope.yml — repo not enrolled"
  command -v yq &>/dev/null || _block "yq not found — install yq to parse envelope"
  yq e '.' "$ENV_FILE" > /dev/null 2>&1 || _block "envelope.yml is not valid YAML"

  local ver
  ver=$(yq e '.version' "$ENV_FILE" 2>/dev/null)
  [[ "$ver" == "1" ]] || _block "unsupported version '$ver' (expected 1)"

  # Exact top-level key set: no unknown + no missing
  local top want
  top=$(yq e 'keys | .[]' "$ENV_FILE" 2>/dev/null | sort | tr '\n' ' ' | xargs)
  want=$(echo "$_TOP" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)
  [[ "$top" == "$want" ]] || _block "top-level keys drifted from schema: got [$top]"

  # Nested key validation
  _assert_keys '.select'     'select'     bucket exclude_labels require_readiness
  _assert_keys '.order'      'order'      by priority_labels
  _assert_keys '.budget'     'budget'     max_issues stop_at
  _assert_keys '.base'       'base'       strategy integration_branch
  _assert_keys '.on_failure' 'on_failure' policy skip_dependents
  _assert_keys '.merge'      'merge'      mode
  _assert_keys '.report'     'report'     to

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
    if [[ -z "$_ib" || "$_ib" == "null" ]]; then
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

  # All checks passed — emit structured output
  echo "STATUS: ok"
  _emit "VERSION:"           "$ver"
  _emit "ENABLED:"           "$en"
  _emit "BUCKET:"            "$bk"
  _emit "EXCLUDE_LABELS:"    "$(yq e '.select.exclude_labels | join(",")' "$ENV_FILE")"
  _emit "REQUIRE_READINESS:" "$rr"
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

  # Supplement body if require_readiness is true
  local body_json=""
  if [[ "$require_readiness" == "true" ]]; then
    if ! body_json=$(gh issue list --assignee @me --state open \
      --limit 50 --json number,body 2>/dev/null); then
      echo "STATUS: blocked"
      echo "GAP:    gh issue list (body) failed — check gh auth status"
      exit 0
    fi
  fi

  # Build exclude_labels array from comma-separated string
  local IFS_SAVE="$IFS"
  IFS=',' read -ra exc_labels <<< "$exclude_labels"
  IFS="$IFS_SAVE"

  # Build order_by array
  # Process each assigned issue
  local -a included_issues=()
  local -a excluded_issues=()

  while IFS=$'\t' read -r num title labels _updated; do
    # Strip leading '#' from issue number
    local issue_num="${num#\#}"
    [[ -z "$issue_num" ]] && continue
    # Skip unavailable markers
    [[ "$issue_num" == "#"* ]] && continue
    [[ "$issue_num" =~ ^[0-9]+$ ]] || continue

    local exclude_reason=""

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
      excluded_issues+=("${issue_num}|${title}|${exclude_reason}")
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
        excluded_issues+=("${issue_num}|${title}|excluded-label (${lbl_hit})")
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
        excluded_issues+=("${issue_num}|${title}|not-ready (empty body)")
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

    included_issues+=("${tier}|${created_at}|${issue_num}|${title}|${labels}")
  done < <(echo "$assigned_raw")

  # 8. Sort INCLUDED by tier then createdAt asc
  local -a sorted_included=()
  if [[ ${#included_issues[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      sorted_included+=("$line")
    done < <(printf '%s\n' "${included_issues[@]}" | sort -t'|' -k1,1n -k2,2)
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
      bc_num=$(echo "$entry" | cut -d'|' -f3)
      bc_title=$(echo "$entry" | cut -d'|' -f4)
      budget_cut+=("${bc_num}|${bc_title}|budget-cut (beyond max_issues=${max_issues})")
    fi
  done

  # Print header
  echo "=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ==="
  echo "ENVELOPE: ${git_root}/.devlead/envelope.yml  ENABLED: ${enabled}"
  echo "DATA_SOURCES: state.sh(ASSIGNED_ISSUES,BRANCHES,OPEN_PRS); gh issue list(createdAt$([ "$require_readiness" == "true" ] && echo ",body" || echo ""))"
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
      tier=$(echo "$entry" | cut -d'|' -f1)
      created=$(echo "$entry" | cut -d'|' -f2)
      num=$(echo "$entry" | cut -d'|' -f3)
      title=$(echo "$entry" | cut -d'|' -f4)
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
      ex_num=$(echo "$entry" | cut -d'|' -f1)
      ex_title=$(echo "$entry" | cut -d'|' -f2)
      ex_reason=$(echo "$entry" | cut -d'|' -f3-)
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
# Dispatch
# ---------------------------------------------------------------------------
_cmd="${1:-check}"
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
  upgrade) _do_upgrade "${2:-}"; exit 0 ;;
  show)  _do_show ;;
  plan)  _do_plan ;;
  *) echo "uso: envelope.sh {check|init|show|plan|upgrade}" >&2; exit 2 ;;
esac
