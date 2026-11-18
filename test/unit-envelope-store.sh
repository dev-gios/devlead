#!/usr/bin/env bash
# unit-envelope-store.sh — the envelope store outside the repos (S25)
#
#   bash test/unit-envelope-store.sh
#
# An envelope can live in ~/.devlead/envelopes/<absolute repo path>/envelope.yml
# instead of being committed to the repo. These cases pin where envelope.sh
# reads it from: on the user's machine (the HOME store), in a linked worktree,
# and in the server, where the store is a fixed read-only path and a store a
# session could write is refused.
#
# SAFETY: every scenario runs inside a throwaway /tmp sandbox with its own HOME
# and a local bare remote. Never reads or writes the real repo or ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SANDBOX="$(mktemp -d /tmp/devlead-envstore.XXXXXX)"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected substring: [$3]"
    echo "        actual:             [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected: [$3]"
    echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- A copy of the scripts whose fixed server paths point into the sandbox ---
SRV="$SANDBOX/scripts"
cp -r "$REPO_ROOT/.devlead/scripts" "$SRV"
MARKER="$SANDBOX/server-mode"
SERVER_STORE="$SANDBOX/etc-envelopes"
check "envelope.sh has the fixed path SERVER_MARKER" "$(grep -c '^SERVER_MARKER=' "$SRV/envelope.sh")" "1"
check "envelope.sh has the fixed path SERVER_STORE" "$(grep -c '^SERVER_STORE=' "$SRV/envelope.sh")" "1"
check "the server store is not derived from HOME or the environment" \
  "$(grep -c '^SERVER_STORE=/run/devlead/envelopes$' "$REPO_ROOT/.devlead/scripts/envelope.sh")" "1"
sed -i "s|^SERVER_MARKER=.*|SERVER_MARKER=$MARKER|; s|^SERVER_STORE=.*|SERVER_STORE=$SERVER_STORE|" "$SRV/envelope.sh"
ENVELOPE_SH="$SRV/envelope.sh"

# --- gh: logged in, and `repo view` answers the default branch ----------------
FAKEBIN="$SANDBOX/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") echo "main"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKEBIN/gh"

FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME"
env_sh() { HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" bash "$ENVELOPE_SH" "$@" </dev/null 2>/dev/null; }

# --- Sandbox repo: default branch main, also a dev branch ----------------------
git init -q --bare -b main "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work" 2>/dev/null
cd "$SANDBOX/work" || exit 1
git config user.email t@example.com; git config user.name t
git checkout -q -b main 2>/dev/null
echo x > README.md; git add README.md; git commit -q -m init
git push -q origin main 2>/dev/null
git remote set-head origin main >/dev/null 2>&1
WORK="$(pwd -P)"

# envelope <enabled> — a valid envelope with that switch, on stdout.
envelope() { env_sh template | sed "s/^enabled:.*/enabled: $1/"; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1; }

HOME_STORE="$FAKE_HOME/.devlead/envelopes"
HOME_ENTRY="$HOME_STORE$WORK/envelope.yml"

# ===========================================================================
# T1 — no store: the repo's own file is read, as before
# ===========================================================================
mkdir -p .devlead
envelope false > .devlead/envelope.yml
out="$(env_sh show)"
check "T1: no store entry: show validates the repo's file" "$(kv "$out" STATUS)" "ok"
check "T1: no store entry: the repo's value is read" "$(kv "$out" ENABLED)" "false"
check "T1: no store entry: path names the repo's file" "$(env_sh path)" "$WORK/.devlead/envelope.yml"

# ===========================================================================
# T2 — a store entry wins over the repo's file
# ===========================================================================
mkdir -p "$(dirname "$HOME_ENTRY")"
envelope true > "$HOME_ENTRY"
out="$(env_sh show)"
check "T2: store entry: show validates" "$(kv "$out" STATUS)" "ok"
check "T2: store entry wins over the repo's file" "$(kv "$out" ENABLED)" "true"
check "T2: store entry: path names the store file" "$(env_sh path)" "$HOME_ENTRY"
check "T2: store entry: the repo's file is untouched" "$(sed -n 's/^enabled: //p' .devlead/envelope.yml)" "false"

# ===========================================================================
# T3 — a store entry alone enrolls the repo: nothing in the repo
# ===========================================================================
rm -rf .devlead
out="$(env_sh check)"
check "T3: store only: check reports enrolled" "$(kv "$out" ENROLLED)" "true"
check "T3: store only: check reads enabled" "$(kv "$out" ENABLED)" "true"
check "T3: store only: show validates" "$(kv "$(env_sh show)" STATUS)" "ok"
check "T3: store only: the repo has no .devlead directory" "$([[ -e .devlead ]] && echo yes || echo no)" "no"

# ===========================================================================
# T4 — a linked worktree reads its main checkout's entry
# ===========================================================================
git worktree add -q "$SANDBOX/wt" -b feature >/dev/null 2>&1
out="$(cd "$SANDBOX/wt" && env_sh show)"
check "T4: worktree: show validates" "$(kv "$out" STATUS)" "ok"
check "T4: worktree: reads the main checkout's entry" "$(kv "$out" ENABLED)" "true"
check "T4: worktree: path names the main checkout's entry" "$(cd "$SANDBOX/wt" && env_sh path)" "$HOME_ENTRY"

# ===========================================================================
# T5 — a repo with no entry and no file is not enrolled
# ===========================================================================
git init -q "$SANDBOX/other"
out="$(cd "$SANDBOX/other" && env_sh check)"
check "T5: another repo is not enrolled by this repo's entry" "$(kv "$out" ENROLLED)" "false"

# ===========================================================================
# Server mode: the store is the fixed path, read-only
# ===========================================================================
touch "$MARKER"
SERVER_ENTRY="$SERVER_STORE$WORK/envelope.yml"

# T5b — on the user's machine --origin still means origin: the HOME store
# is found through HOME, which the caller sets.
out="$(env_sh show --origin)"
check "T5b: host: --origin does not read the HOME store" "$(kv "$out" STATUS)" "blocked"
contains "T5b: host: --origin reads origin" "$out" "no envelope.yml on origin's default branch"

# T6 — the HOME store is not read in the server: a session controls HOME.
out="$(env_sh show --origin)"
check "T6: server: the HOME store is ignored" "$(kv "$out" STATUS)" "blocked"
contains "T6: server: with no entry the doors read origin" "$out" "no envelope.yml on origin's default branch"

# T7 — an entry in the read-only server store is the doors' authority.
# T8 — a store the caller could write grants nothing.
# Both need a store this process cannot write; root can write any file.
mkdir -p "$(dirname "$SERVER_ENTRY")"
envelope true > "$SERVER_ENTRY"
if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP  T7, T8: running as root, no file is read-only here"
else
  chmod -R a-w "$SERVER_STORE"
  out="$(env_sh show --origin)"
  check "T7: server: the doors read the store entry" "$(kv "$out" STATUS)" "ok"
  check "T7: server: the store entry's value" "$(kv "$out" ENABLED)" "true"
  out="$(env_sh show)"
  check "T7: server: plain show reads the store entry too" "$(kv "$out" ENABLED)" "true"

  chmod -R u+w "$SERVER_STORE"
  for sub in "show --origin" "show" "plan" "check"; do
    # shellcheck disable=SC2086
    out="$(env_sh $sub)"
    check "T8: server: writable store: $sub is blocked" "$(kv "$out" STATUS)" "blocked"
    contains "T8: server: writable store: $sub says why" "$out" "read-only"
  done
  chmod u+w "$(dirname "$SERVER_ENTRY")"; chmod a-w "$SERVER_ENTRY"
  out="$(env_sh show --origin)"
  check "T8: server: writable entry directory is blocked" "$(kv "$out" STATUS)" "blocked"
  chmod -R a-w "$SERVER_STORE"
fi

# T9 — with no store entry the doors still read origin's default branch.
chmod -R u+w "$SERVER_STORE"; rm -rf "$SERVER_STORE"
mkdir -p .devlead
envelope false > .devlead/envelope.yml
git add .devlead/envelope.yml && git commit -q -m envelope && git push -q origin main 2>/dev/null
envelope true > .devlead/envelope.yml
out="$(env_sh show --origin)"
check "T9: server: no entry: origin's envelope validates" "$(kv "$out" STATUS)" "ok"
check "T9: server: no entry: origin's value, not the working tree's" "$(kv "$out" ENABLED)" "false"

echo ""
echo "unit-envelope-store: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
