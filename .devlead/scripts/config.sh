#!/usr/bin/env bash
# config.sh — interactive setup + per-repo configuration menu. The ONLY
# supported way for a human to write DevLead's persisted configuration by
# hand: this machine's install/token/enrollment/timer state, and this repo's
# envelope.
#
# GOVERNANCE.md §A3 ("Quién escribe el envelope"): an interactive editor
# where a human sitting at the terminal chooses every value IS the user
# configuring their own machine — with assistance. That is allowed. What
# stays forbidden, without exception, is DevLead deriving and applying
# configuration on its own. Two requirements make that distinction real
# instead of just prose:
#
#   1. This script refuses to run at all without a real TTY on stdin — see
#      the gate immediately below, which runs before ANYTHING else (no read,
#      no write, not even a stat) is attempted.
#   2. This script is not invoked from anywhere in the autonomous paths
#      (sweep-execute / sweep-loop / sweep-discover), directly or through a
#      wrapper. It is wired ONLY into the `devlead config` CLI entry point,
#      which a human runs by hand.
#
# Both are load-bearing, not decorative — see test/unit-config-menu.sh.
#
# Machine-setup actions reuse the existing scripts (doctor.sh for install
# state, envelope.sh for the 4-step auth chain's own file convention) rather
# than re-deriving any of it here.
#
# The envelope section renders and edits itself entirely from
# `envelope.sh schema` at runtime — this file carries NO list of envelope
# field names, types, defaults, or help text of its own. This repo already
# grew three independently hand-maintained copies of a single list (see
# test/unit-publish-manifest.sh); a menu with its own hardcoded field table
# would have been a fourth. Add a field to the schema and it appears here
# unchanged — see test/unit-config-menu.sh for the check that keeps it that
# way.
set -uo pipefail

# ---------------------------------------------------------------------------
# TTY gate — FIRST THING this script does, before any other statement.
# GOVERNANCE.md §A3 requires this: without a human on the other end of stdin,
# there is nobody to direct the write, and a tool that still writes anyway
# has stopped being "assistance" and become DevLead writing its own
# configuration — which is the one thing this whole model forbids without
# exception. Nothing is read and nothing is written before this check.
# ---------------------------------------------------------------------------
if [[ ! -t 0 ]]; then
  echo "config: refusing to run — stdin is not a TTY." >&2
  echo "config: GOVERNANCE.md §A3 requires a human directing every envelope" >&2
  echo "        write. Without an interactive terminal there is nobody to" >&2
  echo "        direct it, so this tool must not read or write anything." >&2
  echo "config: run this from an interactive shell." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Paths — resolved as self-resolved siblings (same convention envelope.sh
# uses for bootstrap-lib.sh): readlink -f on this file's own BASH_SOURCE
# finds its real location (checkout or installed copy, either way), then
# envelope.sh/doctor.sh are looked up as plain siblings in that directory.
# ---------------------------------------------------------------------------
_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ENVELOPE_BIN="$_SELF_DIR/envelope.sh"
DOCTOR_BIN="$_SELF_DIR/doctor.sh"

_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
REPO_ROOT="$(_repo_root)"
ENV_FILE="$REPO_ROOT/.devlead/envelope.yml"

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------
# --- Presentation layer -----------------------------------------------------
# Every menu below renders through _menu/_confirm rather than printing its own
# numbered list, so there is ONE place that knows how a choice is presented.
# gum (github.com/charmbracelet/gum) gives arrow-key navigation when it is
# installed; without it the original numbered prompts are used verbatim.
#
# The fallback is not a courtesy. It is required in three situations that all
# happen for real:
#   - a machine that simply does not have gum installed
#   - DEVLEAD_NO_GUM=1, the explicit opt-out
#   - test/unit-config-menu.sh, which drives this script through a pty with
#     `script -qec` and types "1", "2", "b" at it. Those keystrokes mean
#     nothing to gum's selector, so the suite exports the opt-out and keeps
#     exercising the plain path end to end.
#
# Choosing is presentation. What a choice DOES is unchanged, and the TTY gate
# above still governs whether any of this runs at all.
_has_gum() {
  [[ "${DEVLEAD_NO_GUM:-0}" != "1" ]] && command -v gum &>/dev/null
}

# _menu <header> <label1> <value1> [<label2> <value2> ...]
# Prints the chosen value on stdout. Prints "b" when the user goes back or
# cancels, so every caller's existing `b)` case keeps working untouched.
_menu() {
  local _header="$1"; shift
  local -a _labels=() _values=()
  while [[ "$#" -ge 2 ]]; do
    _labels+=("$1"); _values+=("$2"); shift 2
  done

  if _has_gum; then
    local _pick
    _pick="$(printf '%s\n' "${_labels[@]}" "Back" \
      | gum choose --header "$_header" 2>/dev/null)" || { printf 'b'; return 0; }
    local _i
    for _i in "${!_labels[@]}"; do
      if [[ "${_labels[$_i]}" == "$_pick" ]]; then
        printf '%s' "${_values[$_i]}"; return 0
      fi
    done
    printf 'b'; return 0
  fi

  # Everything the human SEES goes to stderr: this function's stdout is its
  # return channel, and a caller reads it through $( ). Printing the list on
  # stdout would swallow the menu and hand the caller the menu text glued to
  # the answer.
  echo "" >&2
  echo "=== $_header ===" >&2
  local _i
  for _i in "${!_labels[@]}"; do
    printf '%d) %s\n' "$((_i + 1))" "${_labels[$_i]}" >&2
  done
  echo "b) Back" >&2
  local _choice
  read -r -p "> " _choice || _choice="b"
  case "$_choice" in
    # q/Q accepted everywhere, not just at the top level: it was the documented
    # quit key before this helper existed, and muscle memory outlives menus.
    b|B|q|Q|"") printf 'b'; return 0 ;;
  esac
  if [[ "$_choice" =~ ^[0-9]+$ ]] && \
     (( _choice >= 1 && _choice <= ${#_values[@]} )); then
    printf '%s' "${_values[$((_choice - 1))]}"; return 0
  fi
  printf '__invalid__%s' "$_choice"
  return 0
}

_confirm() {
  # $1 = prompt describing what will happen. Same affirmative-token
  # convention as envelope.sh's own _do_optin: y/yes/si/sí, case-insensitive.
  if _has_gum; then
    gum confirm "$1" && return 0
    return 1
  fi
  local ans
  read -r -p "$1 [y/N] " ans || ans=""
  case "${ans,,}" in
    y|yes|si|sí) return 0 ;;
    *) return 1 ;;
  esac
}

# _input <prompt> <current> — mirrors _menu's has-gum/fallback shape for
# free-text entry, so envelope field editors get the same presentation
# contract as every other widget in this file (D1). Prints the resolved
# value on stdout and nothing else (C3); returns non-zero on cancel/decline
# so callers use the same `v="$(_input ...)" || v=""` shape _menu's callers
# already use.
_input() {
  local _prompt="$1" _cur="$2"
  if _has_gum; then
    local _v
    _v="$(gum input --header "${_prompt%: }" --value "$_cur" 2>/dev/null)" || return 1
    printf '%s' "$_v"
    return 0
  fi
  local _v
  read -r -p "$_prompt" _v || return 1
  printf '%s' "$_v"
}

_json_escape_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

_csv_to_json_array() {
  # Comma-separated free text -> a JSON array of trimmed, non-empty strings.
  local csv="$1"
  local -a items=()
  IFS=',' read -ra items <<< "$csv"
  local i trimmed json="[" first=true
  for i in "${items[@]}"; do
    trimmed="$(printf '%s' "$i" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] || continue
    if [[ "$first" == true ]]; then first=false; else json+=","; fi
    json+="$(_json_escape_str "$trimmed")"
  done
  json+="]"
  printf '%s' "$json"
}

# =============================================================================
# Section 1 — Machine setup
# =============================================================================

_machine_doctor() {
  echo ""
  echo "--- Install state ---"
  if [[ -x "$DOCTOR_BIN" || -f "$DOCTOR_BIN" ]]; then
    bash "$DOCTOR_BIN"
  else
    echo "config: doctor.sh not found at $DOCTOR_BIN"
  fi
}

_machine_source_repo() {
  local anchor="$HOME/.devlead/SOURCE_REPO"
  echo ""
  echo "--- Source checkout anchor ---"
  if [[ -f "$anchor" ]]; then
    echo "current: $(cat "$anchor" 2>/dev/null)"
  else
    echo "current: (not set)"
  fi
  local newpath
  read -r -p "New absolute path (blank = keep current): " newpath || newpath=""
  if [[ -z "$newpath" ]]; then
    echo "config: unchanged"
    return 0
  fi
  if [[ ! -d "$newpath/.git" ]]; then
    echo "config: '$newpath' is not a readable git checkout — unchanged" >&2
    return 1
  fi
  mkdir -p "$HOME/.devlead"
  printf '%s\n' "$newpath" > "$anchor"
  echo "config: anchor set to $newpath"
}

_machine_token() {
  local token_file="$HOME/.devlead/gh-token"
  echo ""
  echo "--- GitHub token ---"
  echo "file present: $([[ -f "$token_file" ]] && echo yes || echo no)"
  if [[ -f "$token_file" ]]; then
    local perm
    perm="$(stat -c '%a' "$token_file" 2>/dev/null || echo unknown)"
    echo "file mode: $perm$([[ "$perm" == "600" ]] || echo " (must be 600 to be used)")"
    echo "file empty: $([[ -s "$token_file" ]] && echo no || echo yes)"
  fi

  # Same 4-step chain used by sweep.sh's _ensure_auth / envelope-auth.sh —
  # reported here, never re-implemented. The token value itself is NEVER
  # printed at any step, only presence/permission/step facts about it.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "resolves via: step 1 (\$GH_TOKEN environment variable)"
  elif [[ -f "$token_file" ]] && [[ "$(stat -c '%a' "$token_file" 2>/dev/null || echo)" == "600" ]] && [[ -s "$token_file" ]]; then
    echo "resolves via: step 2 (the file above — mode 600, non-empty)"
  elif command -v gh &>/dev/null && gh auth token &>/dev/null; then
    echo "resolves via: step 3 (gh auth token CLI)"
  else
    echo "resolves via: none — no step currently resolves a usable token"
  fi

  if _confirm "Seed/overwrite the token file now?"; then
    local tok=""
    read -rs -p "Paste the token (input hidden, never echoed or logged): " tok
    echo ""
    if [[ -z "$tok" ]]; then
      echo "config: empty input — not changed"
      return 0
    fi
    mkdir -p "$HOME/.devlead"
    local tmp="$token_file.tmp.$$"
    rm -f "$tmp" 2>/dev/null
    if ( umask 077 && printf '%s' "$tok" > "$tmp" ) && chmod 600 "$tmp" && mv -f "$tmp" "$token_file"; then
      echo "config: token file written (mode 600) — value not shown"
    else
      echo "config: failed to write the token file" >&2
      rm -f "$tmp" 2>/dev/null
    fi
    tok=""
  fi
  return 0
}

_machine_toggle_timer() {
  local unit="$1" desc="$2"
  local state
  state="$(systemctl --user is-enabled "$unit" 2>/dev/null || echo "not-found")"
  echo "$unit: $state"
  if [[ "$state" == "enabled" ]]; then
    if _confirm "Disable $unit?"; then
      if systemctl --user disable --now "$unit" &>/dev/null; then
        echo "config: $unit disabled"
      else
        echo "config: failed to disable $unit" >&2
      fi
    fi
  else
    echo "$desc"
    if _confirm "Enable $unit now?"; then
      if systemctl --user enable --now "$unit" &>/dev/null; then
        echo "config: $unit enabled"
      else
        echo "config: failed to enable $unit (is it installed? run 'devlead upgrade' first)" >&2
      fi
    fi
  fi
  return 0
}

_machine_timers() {
  local choice
  choice="$(_menu "Timers" \
    "sweep timer  — plan-only, read-only; writes nothing to any repo" sweep \
    "loop timer   — autonomous; CREATES BRANCHES, COMMITS, and OPENS PRs" loop)"
  case "$choice" in
    sweep) _machine_toggle_timer devlead-sweep.timer \
         "This timer only reads state and writes a plan-only report — it makes no repo changes." ;;
    loop) _machine_toggle_timer devlead-loop.timer \
         "This timer runs the autonomous loop unattended — it CREATES BRANCHES, COMMITS, and OPENS PRs against enrolled repos." ;;
    b) return 0 ;;
    *) echo "config: unknown option '${choice#__invalid__}'" ;;
  esac
  return 0
}

_machine_menu() {
  while true; do
    local choice
    choice="$(_menu "Machine setup" \
      "Install state"                        doctor \
      "Source checkout anchor"               source \
      "GitHub token"                         token \
      "Timers"                               timers)"
    case "$choice" in
      doctor) _machine_doctor ;;
      source) _machine_source_repo ;;
      token) _machine_token ;;
      timers) _machine_timers ;;
      b) return 0 ;;
      *) echo "config: unknown option '${choice#__invalid__}'" ;;
    esac
  done
}

# =============================================================================
# Section 1a — Fleet enrollment (this repo) — REQ-3/D3: a single top-level
# screen replacing the old machine-scoped "Repo enrollment" entry. Fleet-list
# membership is repo-scoped, not machine-scoped, and folding it under
# "Machine setup" was part of why the two enrollment halves read as unrelated
# in the first place.
#
# Both halves are re-derived live on every render (Inv 2), never cached
# across a menu loop iteration: fleet-list membership via a plain grep
# against ~/.devlead/autonomous-repos (same idiom envelope.sh's own
# _do_optin and sweep.sh already use), and envelope state exclusively via
# `envelope.sh check`'s ENROLLED/ENABLED KEY:value CLI protocol — never by
# re-parsing envelope.yml or naming a dotted field, per C4.
# =============================================================================

_fleet_list_status() {
  local repo="$1" repos_file="$HOME/.devlead/autonomous-repos"
  if [[ -f "$repos_file" ]] && grep -qxF "$repo" "$repos_file" 2>/dev/null; then
    printf 'listed'
  else
    printf 'not-listed'
  fi
}

# _fleet_envelope_status — on | off | missing | unreadable, derived purely
# from `envelope.sh check`'s ENROLLED/ENABLED protocol (C4). Mirrors
# sweep.sh's own Gate 1/Gate 2 reading exactly, so the two screens can never
# silently disagree about what "on"/"off"/"missing" means.
_fleet_envelope_status() {
  local check_out enrolled enabled
  check_out="$(bash "$ENVELOPE_BIN" check 2>/dev/null)"
  enrolled="$(echo "$check_out" | grep "^ENROLLED:" | awk '{print $2}')"
  if [[ "$enrolled" != "true" ]]; then
    printf 'missing'
    return 0
  fi
  enabled="$(echo "$check_out" | grep "^ENABLED:" | awk '{print $2}')"
  case "$enabled" in
    true) printf 'on' ;;
    false) printf 'off' ;;
    *) printf 'unreadable' ;;
  esac
}

_fleet_verdict() {
  local list_status="$1" env_status="$2"
  if [[ "$list_status" != "listed" ]]; then
    printf 'the sweep never visits this repo'
    return 0
  fi
  case "$env_status" in
    on) printf 'runs tonight' ;;
    off) printf 'listed, deliberately off — nothing to fix' ;;
    *) printf 'listed but can never run — this is the broken shape' ;;
  esac
}

# Set by _fleet_render for the current loop iteration; consumed by
# _fleet_menu to build its dynamic action labels without re-deriving state
# a second time in the same render.
_FLEET_LIST_STATUS=""
_FLEET_ENV_STATUS=""

# _fleet_render — D5: the human-facing block goes to stderr, same convention
# _menu already uses, so a piped `devlead config` still shows the state next
# to the menu.
_fleet_render() {
  local repo="$REPO_ROOT"
  local list_status env_status verdict
  list_status="$(_fleet_list_status "$repo")"
  env_status="$(_fleet_envelope_status)"
  verdict="$(_fleet_verdict "$list_status" "$env_status")"

  local list_label env_label
  [[ "$list_status" == "listed" ]] && list_label="listed" || list_label="not listed"
  case "$env_status" in
    on) env_label="on" ;;
    off) env_label="off" ;;
    missing) env_label="missing" ;;
    *) env_label="unreadable" ;;
  esac

  {
    echo ""
    echo "--- Enrollment (this repo) ---"
    echo "repo: $repo"
    echo ""
    echo "fleet list (~/.devlead/autonomous-repos): $list_label"
    echo "  grants: WHERE the nightly sweep looks. Listing alone authorizes no work."
    echo "envelope (.devlead/envelope.yml): $env_label"
    echo "  grants: WHETHER this repo may work, and how far. Without it every visit ends in a skip."
    echo ""
    echo "verdict: $verdict"
  } >&2

  _FLEET_LIST_STATUS="$list_status"
  _FLEET_ENV_STATUS="$env_status"
}

# _fleet_toggle_list — verbatim write bodies from the retired
# _machine_enrollment (D3): only the surrounding menu changed, not the logic
# that mutates ~/.devlead/autonomous-repos.
_fleet_toggle_list() {
  local repos_file="$HOME/.devlead/autonomous-repos"
  local repo="$REPO_ROOT"
  if [[ "$_FLEET_LIST_STATUS" == "listed" ]]; then
    if _confirm "Remove this repo from the fleet list (~/.devlead/autonomous-repos)?"; then
      local tmp="$repos_file.tmp.$$"
      grep -vxF "$repo" "$repos_file" > "$tmp" 2>/dev/null || : > "$tmp"
      mv -f "$tmp" "$repos_file"
      echo "config: removed from fleet list"
    fi
  else
    if _confirm "Add this repo to the fleet list (~/.devlead/autonomous-repos)?"; then
      mkdir -p "$(dirname "$repos_file")"
      touch "$repos_file"
      grep -qxF "$repo" "$repos_file" 2>/dev/null || echo "$repo" >> "$repos_file"
      echo "config: added to fleet list"
    fi
  fi
  return 0
}

_fleet_menu() {
  while true; do
    _fleet_render

    local list_label
    if [[ "$_FLEET_LIST_STATUS" == "listed" ]]; then
      list_label="Remove from fleet list"
    else
      list_label="Add to fleet list"
    fi

    local envelope_label
    if [[ "$_FLEET_ENV_STATUS" == "missing" ]]; then
      envelope_label="Create the envelope here"
    else
      envelope_label="Open the envelope editor"
    fi

    local choice
    choice="$(_menu "Enrollment (this repo)" \
      "$list_label"     list \
      "$envelope_label" envelope)"
    case "$choice" in
      list) _fleet_toggle_list ;;
      # Both "create" and "edit" route through the SAME existing
      # _envelope_menu call site (REQ-3/2.3) — it already offers the
      # `bash "$ENVELOPE_BIN" init` prompt when ENV_FILE is missing and the
      # schema-driven editor when it is present. No second init call site
      # is added here.
      envelope) _envelope_menu ;;
      b) return 0 ;;
      *) echo "config: unknown option '${choice#__invalid__}'" ;;
    esac
  done
}

# =============================================================================
# Section 2 — Envelope (schema-driven, no field list of its own)
# =============================================================================

# _load_schema — populates SCHEMA_FIELD/TYPE/DEFAULT/REQUIRED/HELP/CONSEQUENCE
# by parsing `envelope.sh schema`'s own KEY: value block output. This is the
# ONLY place this file learns what fields exist — nothing here names a field.
_load_schema() {
  SCHEMA_FIELD=()
  SCHEMA_TYPE=()
  SCHEMA_DEFAULT=()
  SCHEMA_REQUIRED=()
  SCHEMA_HELP=()
  SCHEMA_CONSEQUENCE=()

  local raw
  raw="$(bash "$ENVELOPE_BIN" schema 2>/dev/null)"
  [[ "$raw" == "STATUS: ok"* ]] || return 1

  local field="" type="" default="" required="" help="" consequence=""
  _flush_record() {
    [[ -n "$field" ]] || return 0
    SCHEMA_FIELD+=("$field")
    SCHEMA_TYPE+=("$type")
    SCHEMA_DEFAULT+=("$default")
    SCHEMA_REQUIRED+=("$required")
    SCHEMA_HELP+=("$help")
    SCHEMA_CONSEQUENCE+=("$consequence")
    field="" type="" default="" required="" help="" consequence=""
  }

  local line key val
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      _flush_record
      continue
    fi
    key="${line%%: *}"
    val="${line#*: }"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then
      val="${val#\"}"
      val="${val%\"}"
    fi
    case "$key" in
      FIELD) field="$val" ;;
      TYPE) type="$val" ;;
      DEFAULT) default="$val" ;;
      REQUIRED) required="$val" ;;
      HELP) help="$val" ;;
      CONSEQUENCE) consequence="$val" ;;
      *) : ;;
    esac
  done <<< "$raw"
  _flush_record
  return 0
}

# _schema_lookup target help_var conseq_var — finds a record by exact FIELD
# match. Used for the two-child prompts of a list-of-objects entry: the
# target string is built at RUNTIME by concatenating the parent's own field
# variable with a literal "[]." separator plus the child name the caller
# already has in hand — never a name typed out here.
_schema_lookup() {
  local target="$1" __help_var="$2" __conseq_var="$3"
  local i
  for i in "${!SCHEMA_FIELD[@]}"; do
    if [[ "${SCHEMA_FIELD[$i]}" == "$target" ]]; then
      printf -v "$__help_var" '%s' "${SCHEMA_HELP[$i]}"
      printf -v "$__conseq_var" '%s' "${SCHEMA_CONSEQUENCE[$i]}"
      return 0
    fi
  done
  printf -v "$__help_var" '%s' ""
  printf -v "$__conseq_var" '%s' ""
  return 1
}

_current_value() {
  local field="$1" type="$2" default="$3"
  local path=".${field}"
  case "$type" in
    list)
      local t
      t="$(yq e "${path} | type" "$ENV_FILE" 2>/dev/null)"
      if [[ "$t" == "!!null" || -z "$t" ]]; then
        printf '(unset — %s)' "$default"
      else
        local v
        v="$(yq e "${path} | join(\",\")" "$ENV_FILE" 2>/dev/null)"
        [[ -z "$v" ]] && v="(empty list)"
        printf '%s' "$v"
      fi
      ;;
    list-of-objects)
      local t n
      t="$(yq e "${path} | type" "$ENV_FILE" 2>/dev/null)"
      if [[ "$t" == "!!null" || -z "$t" ]]; then
        printf '(unset)'
      else
        n="$(yq e "${path} | length" "$ENV_FILE" 2>/dev/null)"
        printf '%s entries' "${n:-0}"
      fi
      ;;
    map)
      printf '(group)'
      ;;
    *)
      local t
      t="$(yq e "${path} | type" "$ENV_FILE" 2>/dev/null)"
      if [[ "$t" == "!!null" || -z "$t" ]]; then
        printf '(unset — default: %s)' "$default"
      else
        yq e "${path}" "$ENV_FILE" 2>/dev/null
      fi
      ;;
  esac
}

# _ensure_parent_path field file — makes sure every ancestor map of a dotted
# path exists (as an empty map) in the given file before a leaf assignment
# runs. Derived purely from the dotted path string handed in at runtime —
# this is what lets an OPTIONAL block be edited into existence generically,
# with no name check anywhere in this file.
_ensure_parent_path() {
  local field="$1" file="$2"
  local -a segs=()
  IFS='.' read -ra segs <<< "$field"
  local cur="" i t
  for ((i = 0; i < ${#segs[@]} - 1; i++)); do
    if [[ -z "$cur" ]]; then cur="${segs[$i]}"; else cur="$cur.${segs[$i]}"; fi
    t="$(yq e ".${cur} | type" "$file" 2>/dev/null)"
    if [[ "$t" == "!!null" || -z "$t" ]]; then
      yq eval -i ".${cur} = {}" "$file" 2>/dev/null
    fi
  done
}

# _CUR_BACKUP / _CUR_TMP — tracked so the interrupt/exit trap below can always
# clean up whatever temp state is live, on every exit path.
_CUR_BACKUP=""
_CUR_TMP=""
_cleanup_on_exit() {
  [[ -n "$_CUR_BACKUP" && -f "$_CUR_BACKUP" ]] && rm -f "$_CUR_BACKUP" 2>/dev/null
  [[ -n "$_CUR_TMP" && -f "$_CUR_TMP" ]] && rm -f "$_CUR_TMP" 2>/dev/null
}
trap _cleanup_on_exit EXIT INT TERM

# _commit_change field expr — the ONLY path that ever writes envelope.yml.
#   1. copies the real file to a same-directory temp file — never edits in
#      place
#   2. ensures the field's ancestor maps exist in that temp copy, then
#      applies the caller's yq expression to the temp copy only
#   3. the temp copy validates (is it parseable YAML at all) BEFORE it is
#      moved over the real file
#   4. once moved, re-validates with `envelope.sh show` — the real semantic
#      gate (locked values, required-when rules, A3's own checks, ...)
#   5. if step 3 or step 4 fails, the previous file is restored byte-for-byte
#      and the exact GAP is printed — this file never leaves envelope.yml on
#      disk in a state that does not validate.
_commit_change() {
  local field="$1" expr="$2"
  local backup tmp
  backup="$(mktemp "${ENV_FILE}.bak.XXXXXX")" || {
    echo "config: failed to create a backup — envelope not touched" >&2
    return 1
  }
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")" || {
    echo "config: failed to create a working copy — envelope not touched" >&2
    rm -f "$backup"
    return 1
  }
  cp "$ENV_FILE" "$backup"
  cp "$ENV_FILE" "$tmp"
  _CUR_BACKUP="$backup"
  _CUR_TMP="$tmp"

  _ensure_parent_path "$field" "$tmp"

  if ! yq eval -i "$expr" "$tmp" 2>/dev/null; then
    echo "config: failed to apply the change — envelope not touched" >&2
    rm -f "$backup" "$tmp"
    _CUR_BACKUP=""; _CUR_TMP=""
    return 1
  fi

  if ! yq e '.' "$tmp" >/dev/null 2>&1; then
    echo "config: edited content failed to parse as YAML — envelope not touched" >&2
    rm -f "$backup" "$tmp"
    _CUR_BACKUP=""; _CUR_TMP=""
    return 1
  fi

  if ! mv -f "$tmp" "$ENV_FILE"; then
    echo "config: failed to move the edited file into place — envelope not touched" >&2
    rm -f "$backup" "$tmp"
    _CUR_BACKUP=""; _CUR_TMP=""
    return 1
  fi
  _CUR_TMP=""

  local show_out
  show_out="$(bash "$ENVELOPE_BIN" show 2>/dev/null)"
  if [[ "$show_out" == "STATUS: ok"* ]]; then
    echo "config: $field updated — envelope re-validated (envelope.sh show: STATUS: ok)"
    rm -f "$backup"
    _CUR_BACKUP=""
    return 0
  fi

  cp -f "$backup" "$ENV_FILE"
  rm -f "$backup"
  _CUR_BACKUP=""
  local gap
  gap="$(printf '%s\n' "$show_out" | grep '^GAP:' | head -1)"
  echo "config: that change makes the envelope invalid — REVERTED. ${gap:-see envelope.sh show for details}" >&2
  return 1
}

_edit_list_of_objects() {
  local field="$1"
  local path_help="" path_conseq="" spec_help="" spec_conseq=""
  _schema_lookup "${field}[].path" path_help path_conseq
  _schema_lookup "${field}[].spec" spec_help spec_conseq
  echo "Enter entries one at a time. Leave the path prompt blank to finish."
  [[ -n "$path_help" ]] && echo "  path: $path_help"
  [[ -n "$path_conseq" ]] && echo "        CONSEQUENCE: $path_conseq"
  [[ -n "$spec_help" ]] && echo "  spec: $spec_help"
  [[ -n "$spec_conseq" ]] && echo "        CONSEQUENCE: $spec_conseq"

  local json="[" first=true count=0 p s
  while true; do
    read -r -p "  entry $((count + 1)) path (blank to finish): " p || p=""
    [[ -z "$p" ]] && break
    read -r -p "  entry $((count + 1)) spec: " s || s=""
    if [[ "$first" == true ]]; then first=false; else json+=","; fi
    json+="{\"path\":$(_json_escape_str "$p"),\"spec\":$(_json_escape_str "$s")}"
    count=$((count + 1))
  done
  json+="]"

  if [[ "$count" -eq 0 ]]; then
    if _confirm "No entries entered — set $field to an empty list?"; then
      _commit_change "$field" ".${field} = []"
    else
      echo "config: cancelled"
    fi
    return 0
  fi

  if _confirm "Save $count entries for $field?"; then
    NEW_MODS_JSON="$json" _commit_change "$field" ".${field} = (strenv(NEW_MODS_JSON) | from_json)"
  else
    echo "config: cancelled"
  fi
}

_edit_field() {
  local field="$1" type="$2" required="$3" help="$4" consequence="$5"
  echo ""
  echo "--- $field ($type) ---"
  [[ -n "$help" ]] && echo "$help"
  if [[ -n "$consequence" ]]; then
    echo ""
    echo "CONSEQUENCE: $consequence"
  fi
  echo ""

  case "$type" in
    bool)
      local ans
      read -r -p "New value for $field — yes/no (blank = cancel): " ans || ans=""
      case "${ans,,}" in
        y|yes|si|sí)
          if _confirm "Set $field = true?"; then _commit_change "$field" ".${field} = true"; else echo "config: cancelled"; fi
          ;;
        n|no)
          if _confirm "Set $field = false?"; then _commit_change "$field" ".${field} = false"; else echo "config: cancelled"; fi
          ;;
        "") echo "config: cancelled" ;;
        *) echo "config: '$ans' is not yes/no — cancelled" ;;
      esac
      ;;
    int)
      local v
      read -r -p "New integer value for $field (blank = cancel): " v || v=""
      if [[ -z "$v" ]]; then
        echo "config: cancelled"
      elif [[ "$v" =~ ^[0-9]+$ ]]; then
        if _confirm "Set $field = $v?"; then _commit_change "$field" ".${field} = ${v}"; else echo "config: cancelled"; fi
      else
        echo "config: '$v' is not a non-negative integer — cancelled"
      fi
      ;;
    "string (nullable HH:MM)")
      local v
      read -r -p "New value HH:MM, or blank to clear: " v || v=""
      if [[ -z "$v" ]]; then
        if _confirm "Clear $field?"; then _commit_change "$field" ".${field} = null"; else echo "config: cancelled"; fi
      elif [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        if _confirm "Set $field = $v?"; then
          NEW_STR_VAL="$v" _commit_change "$field" ".${field} = strenv(NEW_STR_VAL)"
        else
          echo "config: cancelled"
        fi
      else
        echo "config: '$v' is not HH:MM — cancelled"
      fi
      ;;
    string)
      local v
      read -r -p "New value for $field (blank = cancel): " v || v=""
      if [[ -z "$v" ]]; then
        echo "config: cancelled"
      elif _confirm "Set $field = '$v'?"; then
        NEW_STR_VAL="$v" _commit_change "$field" ".${field} = strenv(NEW_STR_VAL)"
      else
        echo "config: cancelled"
      fi
      ;;
    list)
      local v json
      read -r -p "New comma-separated values for $field (blank = $( [[ "$required" == "true" ]] && echo "empty list" || echo "clear" )): " v || v=""
      if [[ -z "$v" && "$required" != "true" ]]; then
        if _confirm "Clear $field?"; then _commit_change "$field" ".${field} = null"; else echo "config: cancelled"; fi
      else
        json="$(_csv_to_json_array "$v")"
        if _confirm "Set $field = $json?"; then
          NEW_LIST_JSON="$json" _commit_change "$field" ".${field} = (strenv(NEW_LIST_JSON) | from_json)"
        else
          echo "config: cancelled"
        fi
      fi
      ;;
    list-of-objects)
      _edit_list_of_objects "$field"
      ;;
    *)
      echo "config: '$field' has no directly settable value here"
      ;;
  esac
}

_envelope_menu() {
  while true; do
    if [[ ! -f "$ENV_FILE" ]]; then
      echo "" >&2
      echo "--- Envelope ---" >&2
      echo "no envelope.yml for this repo yet." >&2
      if _confirm "Create one now (the existing scaffold command)?"; then
        bash "$ENVELOPE_BIN" init
      fi
      [[ -f "$ENV_FILE" ]] || return 0
      continue
    fi

    if ! command -v yq &>/dev/null; then
      echo "config: yq not found — cannot render or edit the envelope" >&2
      return 1
    fi

    if ! _load_schema; then
      echo "config: could not load the schema descriptor" >&2
      return 1
    fi

    # Build the picker over the same eligible-field filter as before (skip
    # groups and list-of-objects children); labels carry the field name +
    # current value, values carry the SCHEMA_FIELD index — never the field
    # name itself, so the field name is never a literal in this file (C1).
    local -a args=() rendered=()
    local i f t cur
    for i in "${!SCHEMA_FIELD[@]}"; do
      f="${SCHEMA_FIELD[$i]}"
      t="${SCHEMA_TYPE[$i]}"
      [[ "$t" == "map" ]] && continue
      [[ "$f" == *"[]."* ]] && continue
      cur="$(_current_value "$f" "$t" "${SCHEMA_DEFAULT[$i]}")"
      args+=("$(printf '%-32s %s' "$f" "$cur")" "$i")
      rendered+=("$i")
    done

    local hdr="Envelope ($ENV_FILE)"
    _has_gum || hdr="$hdr — pick a number, or type a field's exact name"

    local choice
    choice="$(_menu "$hdr" "${args[@]}")"

    if [[ "$choice" == "b" ]]; then
      return 0
    fi

    # Dotted-name entry (typed instead of a number) only ever reaches this
    # function through _menu's fallback-only __invalid__<raw> return — the
    # gum branch never produces it (C4).
    local matched_si=""
    if [[ "$choice" == __invalid__* ]]; then
      local typed="${choice#__invalid__}"
      local k
      for k in "${rendered[@]}"; do
        if [[ "${SCHEMA_FIELD[$k]}" == "$typed" ]]; then
          matched_si="$k"
          break
        fi
      done
    else
      matched_si="$choice"
    fi

    if [[ -n "$matched_si" ]]; then
      _edit_field "${SCHEMA_FIELD[$matched_si]}" "${SCHEMA_TYPE[$matched_si]}" "${SCHEMA_REQUIRED[$matched_si]}" \
        "${SCHEMA_HELP[$matched_si]}" "${SCHEMA_CONSEQUENCE[$matched_si]}"
    else
      echo "config: unknown option '${choice#__invalid__}'" >&2
    fi
  done
}

# =============================================================================
# Top-level menu
# =============================================================================

_main_menu() {
  while true; do
    # "Back" reads as Quit at the top level; the shared helper returns "b" for
    # both cancel and the last entry, and there is nowhere above here to go.
    local choice
    choice="$(_menu "DevLead config — $REPO_ROOT" \
      "Machine setup"              machine \
      "Enrollment (this repo)"     fleet \
      "Envelope (this repo)"       envelope \
      "Quit"                       quit)"
    case "$choice" in
      machine) _machine_menu ;;
      fleet) _fleet_menu ;;
      envelope) _envelope_menu ;;
      quit|b) return 0 ;;
      *) echo "config: unknown option '${choice#__invalid__}'" ;;
    esac
  done
}

_main_menu
