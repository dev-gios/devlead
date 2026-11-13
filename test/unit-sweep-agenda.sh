#!/usr/bin/env bash
# unit-sweep-agenda.sh — the morning sweep publishes each repo's agenda and
# tells the human once.
#
#   bash test/unit-sweep-agenda.sh
#
# Runs the real sweep.sh, agenda.sh and notify.sh. `envelope.sh` is a fixture
# placed in the sandboxed $HOME (sweep.sh calls it by absolute path) whose
# plan comes from a `.plan` file in each repo; `curl` and `gh` are fakes on
# $PATH.
#
# SAFETY: $HOME is a sandbox, so the real ~/.devlead (reports, agenda, inbox,
# notify.env) is never read or written, and nothing reaches the network.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SCRIPTS="$REPO_ROOT/.devlead/scripts"
SANDBOX="$(mktemp -d /tmp/devlead-sweep-agenda.XXXXXX)"
trap 'cd /tmp && chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
FAKEBIN="$SANDBOX/fakebin"
CURL_LOG="$SANDBOX/curl.log"
export CURL_LOG
mkdir -p "$FAKEBIN" "$SANDBOX/repos"
# The scripts under test must not inherit a developer's overrides.
unset DEVLEAD_AGENDA_DIR DEVLEAD_NOTIFY_DIR DEVLEAD_AGENDA_DATE GH_TOKEN

PASS_COUNT=0
FAIL_COUNT=0
check() {
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
contains() {
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$CURL_LOG"
exit 0
EOF
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
# `auth token` succeeds so the sweep clears its auth gate; every other call
# (the outcomes read) fails, which sweep.sh reports and survives.
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then echo "fake-token"; exit 0; fi
exit 1
EOF
cat > "$FAKEBIN/envelope-fixture.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  check) echo "ENROLLED: true"; echo "ENABLED: true" ;;
  plan)
    if [[ ! -f .plan ]]; then echo "STATUS: blocked"; echo "GAP:    fixture has no plan"; exit 0; fi
    echo "=== DEVLEAD ENVELOPE PLAN v1 (DRY-RUN — nothing executed) ==="
    echo ""
    echo "--- INCLUDED (queue order) ---"
    if [[ -s .plan ]]; then
      i=1
      while IFS= read -r line; do
        printf '%d. %s\n' "$i" "$line"
        echo "   basis: tier=none, created=2026-11-01, nuevo-entrante"
        i=$((i + 1))
      done < .plan
    else
      echo "(none)"
    fi
    echo ""
    echo "--- EXCLUDED ---"
    echo "(none)"
    echo ""
    echo "=== END PLAN ===" ;;
esac
EOF
chmod +x "$FAKEBIN"/*

# fresh_home <name> [with-agenda=1] — sandboxed $HOME with the real scripts.
fresh_home() {
  local d="$SANDBOX/homes/$1"
  mkdir -p "$d/.devlead/scripts"
  cp "$FAKEBIN/envelope-fixture.sh" "$d/.devlead/scripts/envelope.sh"
  cp "$SCRIPTS/notify.sh" "$d/.devlead/scripts/notify.sh"
  [[ "${2:-1}" == "1" ]] && cp "$SCRIPTS/agenda.sh" "$d/.devlead/scripts/agenda.sh"
  printf '%s\n' "$d"
}
# mk_repo <name> [plan lines...] — a git repo whose fixture plan has that
# queue. No arguments at all -> no `.plan` file -> the plan is blocked.
mk_repo() {
  local d="$SANDBOX/repos/$1"; shift
  git init -q "$d"
  if [[ $# -gt 0 ]]; then
    if [[ -n "$1" ]]; then printf '%s\n' "$@" > "$d/.plan"; else : > "$d/.plan"; fi
  fi
  (cd "$d" && git rev-parse --show-toplevel)
}
enroll() { local home="$1"; shift; printf '%s\n' "$@" > "$home/.devlead/autonomous-repos"; }
push_config() { printf '%s\n' "$@" > "$1/.devlead/notify.env.tmp"; sed -i 1d "$1/.devlead/notify.env.tmp"; mv "$1/.devlead/notify.env.tmp" "$1/.devlead/notify.env"; chmod 600 "$1/.devlead/notify.env"; }
run_sweep() { ( cd "$SANDBOX" && HOME="$1" PATH="$FAKEBIN:$PATH" bash "$SCRIPTS/sweep.sh" >/dev/null 2>&1 ); }
agenda_in() { ( cd "$2" && HOME="$1" bash "$SCRIPTS/agenda.sh" "${@:3}" ); }
inbox() { cat "$1/.devlead/inbox.tsv" 2>/dev/null; }
curl_calls() { if [[ -f "$CURL_LOG" ]]; then wc -l < "$CURL_LOG" | tr -d ' '; else echo 0; fi; }

# ===========================================================================
# two repos with work, one with none, one blocked -> one notice
# ===========================================================================
HOME1="$(fresh_home h1)"
ALPHA="$(mk_repo alpha '#12  Fix login' '#15  "Docs: update guide"')"
BETA="$(mk_repo beta '#3  Add export')"
QUIET="$(mk_repo quiet '')"
BLOCKED="$(mk_repo blocked)"
enroll "$HOME1" "$ALPHA" "$BETA" "$QUIET" "$BLOCKED"
push_config "$HOME1" "DEVLEAD_NTFY_URL=https://push.example/topic-abc"
rm -f "$CURL_LOG"
run_sweep "$HOME1"; rc=$?
check "sweep: exit 0" "$rc" "0"

out="$(agenda_in "$HOME1" "$ALPHA" show)"
contains "alpha: agenda published" "$out" "1. #12  Fix login"
contains "alpha: second issue, title unquoted" "$out" "2. #15  Docs: update guide"
contains "beta: agenda published" "$(agenda_in "$HOME1" "$BETA" show)" "1. #3  Add export"
contains "quiet: an empty agenda is published" "$(agenda_in "$HOME1" "$QUIET" show)" "STATUS: empty"
check "blocked: no agenda is published" "$(agenda_in "$HOME1" "$BLOCKED" show)" "STATUS: none"

check "one inbox entry for the whole run" "$(inbox "$HOME1" | wc -l | tr -d ' ')" "1"
entry="$(inbox "$HOME1")"
check "inbox: level agenda" "$(cut -f2 <<<"$entry")" "agenda"
check "inbox: code carries the counts" "$(cut -f3 <<<"$entry")" "2 repo(s), 3 issue(s) today"
check "inbox: push outcome sent" "$(cut -f4 <<<"$entry")" "sent"
msg="$(cut -f6 <<<"$entry")"
contains "inbox: names alpha's issues" "$msg" "alpha: #12 Fix login; #15 Docs: update guide"
contains "inbox: names beta's issue" "$msg" "beta: #3 Add export"
lacks "inbox: a repo with no work is not listed" "$msg" "quiet"
lacks "inbox: a blocked repo is not listed" "$msg" "blocked:"
contains "inbox: says how to change it" "$msg" "devlead agenda first <N> | skip <N>"

check "exactly one push for the whole run" "$(curl_calls)" "1"
log="$(cat "$CURL_LOG")"
contains "push: carries the counts" "$log" "DevLead agenda: 2 repo(s), 3 issue(s) today"
contains "push: normal priority" "$log" "Priority: default"
lacks "push: no repository name by default" "$log" "alpha"
lacks "push: no issue title by default" "$log" "Fix login"
lacks "push: no issue number by default" "$log" "#12"

digest="$(find "$HOME1/.devlead/reports" -maxdepth 1 -name '*.md' | head -1)"
check "digest: still written" "$([[ -s "$digest" ]] && echo yes)" "yes"
check "digest: every repo whose plan ran is included" "$(grep -c '^\*\*STATUS: included\*\*' "$digest")" "3"
check "no temp file left in reports" "$(find "$HOME1/.devlead/reports" -name '.agenda-*' | wc -l | tr -d ' ')" "0"

# ===========================================================================
# `devlead agenda` is the human's way in
# ===========================================================================
cli() { ( cd "$ALPHA" && HOME="$HOME1" bash "$REPO_ROOT/.devlead/bin/devlead" agenda "$@" ); }
contains "devlead agenda: shows the agenda" "$(cli)" "1. #12  Fix login"
contains "devlead agenda first: recorded" "$(cli first 15)" "STATUS: recorded"
contains "devlead agenda: the prioritised issue leads" "$(cli show)" "1. #15  Docs: update guide"
contains "devlead agenda reset: reset" "$(cli reset)" "STATUS: reset"
out="$(cli first 999 2>&1)"; rc=$?
check "devlead agenda first (not on the agenda): exit 1" "$rc" "1"

# ===========================================================================
# the human's adjustments survive a second sweep the same day
# ===========================================================================
agenda_in "$HOME1" "$ALPHA" skip 12 >/dev/null
rm -f "$CURL_LOG" "$HOME1/.devlead/inbox.tsv"
run_sweep "$HOME1"
entry="$(inbox "$HOME1")"
check "after a skip: the count drops" "$(cut -f3 <<<"$entry")" "2 repo(s), 2 issue(s) today"
lacks "after a skip: the skipped issue is not announced" "$(cut -f6 <<<"$entry")" "#12"
contains "after a skip: the agenda still shows it as skipped" "$(agenda_in "$HOME1" "$ALPHA" show)" "SKIPPED: #12"

# ===========================================================================
# detail opt-in -> the list travels in the push
# ===========================================================================
push_config "$HOME1" "DEVLEAD_NTFY_URL=https://push.example/topic-abc" "DEVLEAD_NOTIFY_DETAIL=1"
rm -f "$CURL_LOG" "$HOME1/.devlead/inbox.tsv"
run_sweep "$HOME1"
log="$(cat "$CURL_LOG")"
contains "detail opt-in: push names the repo" "$log" "beta: #3 Add export"
lacks "detail opt-in: never a local path" "$log" "$SANDBOX"

# ===========================================================================
# a long agenda is cut, and still says how to change it
# ===========================================================================
HOME6="$(fresh_home h6)"
long_title="$(printf 'x%.0s' {1..190})"
BIG="$(mk_repo big "#1  $long_title" "#2  $long_title" "#3  $long_title" "#4  $long_title" \
  "#5  $long_title" "#6  $long_title" "#7  $long_title" "#8  $long_title" "#9  $long_title")"
enroll "$HOME6" "$BIG"
run_sweep "$HOME6"
entry="$(inbox "$HOME6")"
check "long agenda: the count is not cut" "$(cut -f3 <<<"$entry")" "1 repo(s), 9 issue(s) today"
msg="$(cut -f6 <<<"$entry")"
check "long agenda: the message is bounded" "$([[ ${#msg} -lt 1600 ]] && echo yes)" "yes"
contains "long agenda: marks the cut" "$msg" "…"
contains "long agenda: still says how to change it" "$msg" "devlead agenda first <N> | skip <N>"

# ===========================================================================
# nothing to do anywhere -> no notice at all
# ===========================================================================
HOME2="$(fresh_home h2)"
enroll "$HOME2" "$QUIET" "$BLOCKED"
push_config "$HOME2" "DEVLEAD_NTFY_URL=https://push.example/topic-abc"
rm -f "$CURL_LOG"
run_sweep "$HOME2"; rc=$?
check "no work: exit 0" "$rc" "0"
check "no work: nothing in the inbox" "$(inbox "$HOME2" | wc -l | tr -d ' ')" "0"
check "no work: no push" "$(curl_calls)" "0"

# ===========================================================================
# no push configured -> the inbox still has the agenda
# ===========================================================================
HOME3="$(fresh_home h3)"
enroll "$HOME3" "$BETA"
rm -f "$CURL_LOG"
run_sweep "$HOME3"
check "unconfigured: no push" "$(curl_calls)" "0"
check "unconfigured: inbox entry recorded" "$(inbox "$HOME3" | cut -f2,4)" "agenda"$'\t'"off"

# ===========================================================================
# an install without agenda.sh sweeps exactly as before
# ===========================================================================
HOME4="$(fresh_home h4 0)"
enroll "$HOME4" "$BETA"
rm -f "$CURL_LOG"
run_sweep "$HOME4"; rc=$?
check "no agenda.sh: exit 0" "$rc" "0"
check "no agenda.sh: no notice" "$(inbox "$HOME4" | wc -l | tr -d ' ')" "0"
check "no agenda.sh: digest still written" "$(find "$HOME4/.devlead/reports" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "1"

# ===========================================================================
# an agenda that cannot be stored does not break the sweep
# ===========================================================================
HOME5="$(fresh_home h5)"
enroll "$HOME5" "$BETA"
mkdir -p "$HOME5/.devlead/agenda"
chmod a-w "$HOME5/.devlead/agenda"
run_sweep "$HOME5"; rc=$?
check "unwritable agenda: exit 0" "$rc" "0"
check "unwritable agenda: digest still written" "$(find "$HOME5/.devlead/reports" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "1"
check "unwritable agenda: no notice claims a published agenda" "$(inbox "$HOME5" | wc -l | tr -d ' ')" "0"
chmod u+w "$HOME5/.devlead/agenda"

# ===========================================================================
# the sweep still mutates nothing outside its own state
# ===========================================================================
check "sweep.sh never adjusts an agenda" \
  "$(grep -cE 'AGENDA_BIN"[[:space:]]+(first|skip|reset)' "$SCRIPTS/sweep.sh")" "0"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
