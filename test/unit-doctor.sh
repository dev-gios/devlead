#!/usr/bin/env bash
# unit-doctor.sh — acceptance coverage for .devlead/scripts/doctor.sh
#
#   bash test/unit-doctor.sh
#
# doctor.sh reports whether the artifacts published to a machine match the
# repo's reviewed trunk. Every scenario below builds its OWN throwaway /tmp
# git sandbox: a bare repo standing in for "origin", a checkout standing in
# for the SOURCE_REPO anchor, and a fake $HOME standing in for the installed
# artifact tree. The real ~/.devlead, the real repo checkout, and the real
# `gh` are never touched — a stub `gh` that always fails auth is put first on
# $PATH so trunk resolution always falls back to the local origin/HEAD
# symref, deterministically, regardless of whether the machine running this
# test has a real, authenticated `gh`.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/.devlead/scripts/doctor.sh"
SANDBOX="$(mktemp -d /tmp/devlead-doctor.XXXXXX)"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected: [$3]"; echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        expected substring: [$3]"; echo "        actual: [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"; echo "        unexpected substring: [$3]"; echo "        actual: [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- A stub `gh` that always fails auth, so trunk resolution deterministically
#     falls back to `git symbolic-ref refs/remotes/origin/HEAD` no matter what
#     `gh` is installed (or authenticated) on the machine running this test. ---
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKEBIN/gh"

doctor() {
  local home="$1"
  ( HOME="$home" PATH="$FAKEBIN:$PATH" bash "$DOCTOR" 2>&1 )
}

# ---------------------------------------------------------------------------
# Sandbox factory: a bare "origin" repo + a checkout with a small, REAL
# bootstrap-lib.sh manifest (two scripts + one command + one systemd unit),
# committed to `main` and pushed, with origin/HEAD pointed at `main`.
# ---------------------------------------------------------------------------
new_repo_sandbox() {
  local name="$1"
  local root="$SANDBOX/$name"
  local bare="$root/origin.git"
  local src="$root/checkout"
  mkdir -p "$root"

  git init --bare -q "$bare"
  git init -q "$src"
  git -C "$src" config user.email test@example.com
  git -C "$src" config user.name "Test"

  mkdir -p "$src/.devlead/scripts" "$src/.claude/commands" "$src/.devlead/systemd"
  cat > "$src/.devlead/scripts/bootstrap-lib.sh" <<'LIB'
bootstrap_symlinks() {
  local repo_dir="${1:-}"
  local devlead_dir="$HOME/.devlead"
  local local_bin="$HOME/.local/bin"
  local claude_commands="$HOME/.claude/commands"
  local -a _pairs=(
    "$repo_dir/.devlead/scripts/bootstrap-lib.sh|$devlead_dir/scripts/bootstrap-lib.sh|"
    "$repo_dir/.devlead/scripts/state.sh|$devlead_dir/scripts/state.sh|x"
    "$repo_dir/.claude/commands/foo.md|$claude_commands/foo.md|"
  )
  return 0
}
bootstrap_systemd() {
  local repo_dir="${1:-}"
  local systemd_dir="$HOME/.config/systemd/user"
  local -a _pairs=(
    "$repo_dir/.devlead/systemd/devlead-sweep.timer|$systemd_dir/devlead-sweep.timer"
  )
  return 0
}
LIB
  echo "state v1" > "$src/.devlead/scripts/state.sh"
  echo "foo v1" > "$src/.claude/commands/foo.md"
  echo "timer v1" > "$src/.devlead/systemd/devlead-sweep.timer"

  git -C "$src" add -A
  git -C "$src" commit -qm "init"
  git -C "$src" branch -M main
  git -C "$src" remote add origin "$bare"
  git -C "$src" push -q -u origin main
  git -C "$src" remote set-head origin main

  printf '%s\n' "$src"
}

install_all_artifacts() {
  local home="$1" src="$2"
  mkdir -p "$home/.devlead/scripts" "$home/.claude/commands" "$home/.config/systemd/user"
  cp "$src/.devlead/scripts/bootstrap-lib.sh" "$home/.devlead/scripts/bootstrap-lib.sh"
  cp "$src/.devlead/scripts/state.sh" "$home/.devlead/scripts/state.sh"
  cp "$src/.claude/commands/foo.md" "$home/.claude/commands/foo.md"
  cp "$src/.devlead/systemd/devlead-sweep.timer" "$home/.config/systemd/user/devlead-sweep.timer"
}

# Installs each artifact's content AT A SPECIFIC REF (branch or sha), rather
# than whatever happens to be checked out in $src's working tree — needed to
# install "an older trunk commit" or "a different branch's tip" without
# disturbing $src's own checkout (new_repo_sandbox leaves it on `main`).
install_from_ref() {
  local home="$1" src="$2" ref="$3"
  mkdir -p "$home/.devlead/scripts" "$home/.claude/commands" "$home/.config/systemd/user"
  git -C "$src" show "$ref:.devlead/scripts/bootstrap-lib.sh" > "$home/.devlead/scripts/bootstrap-lib.sh"
  git -C "$src" show "$ref:.devlead/scripts/state.sh" > "$home/.devlead/scripts/state.sh"
  git -C "$src" show "$ref:.claude/commands/foo.md" > "$home/.claude/commands/foo.md"
  git -C "$src" show "$ref:.devlead/systemd/devlead-sweep.timer" > "$home/.config/systemd/user/devlead-sweep.timer"
}

# A sandbox with a SECOND branch ("feature") pushed to origin, diverging
# from `main` (the trunk) by one file — for the "installed set matches a
# non-trunk branch tip" scenario. Leaves $src checked out on `main`
# afterwards, same as new_repo_sandbox.
new_repo_sandbox_with_branch() {
  local name="$1"
  local src
  src="$(new_repo_sandbox "$name")"
  git -C "$src" checkout -q -b feature
  echo "state FEATURE" > "$src/.devlead/scripts/state.sh"
  git -C "$src" add -A
  git -C "$src" commit -qm "feature: tweak state.sh"
  git -C "$src" push -q -u origin feature
  git -C "$src" checkout -q main
  printf '%s\n' "$src"
}

# ===========================================================================
# Scenario 1: installed set identical to trunk -> STATUS: ok, MATCHES names
# the trunk, no provenance NOTE, exit 0
# ===========================================================================
SRC_1="$(new_repo_sandbox scenario1)"
HOME_1="$SANDBOX/scenario1/home"
mkdir -p "$HOME_1/.devlead"
printf '%s\n' "$SRC_1" > "$HOME_1/.devlead/SOURCE_REPO"
install_all_artifacts "$HOME_1" "$SRC_1"

out="$(doctor "$HOME_1")"
contains "identical install: STATUS: ok" "$out" "STATUS: ok"
contains "identical install: MATCHES names the trunk" "$out" "MATCHES: main @"
contains "identical install: names the trunk" "$out" "TRUNK:  main"
contains "identical install: names the source" "$out" "SOURCE: $SRC_1"
contains "identical install: zero drift reported" "$out" "DRIFT:  0 of"
not_contains "identical install: no provenance note" "$out" "NOTE:"
check "identical install: exits 0" "$(doctor "$HOME_1" >/dev/null 2>&1; echo $?)" "0"

# ===========================================================================
# Scenario 2: one artifact modified -> STATUS: drifted, exit non-zero,
# the differing file named
# ===========================================================================
SRC_2="$(new_repo_sandbox scenario2)"
HOME_2="$SANDBOX/scenario2/home"
mkdir -p "$HOME_2/.devlead"
printf '%s\n' "$SRC_2" > "$HOME_2/.devlead/SOURCE_REPO"
install_all_artifacts "$HOME_2" "$SRC_2"
echo "TAMPERED CONTENT" > "$HOME_2/.devlead/scripts/state.sh"

out="$(doctor "$HOME_2")"
contains "modified artifact: STATUS: drifted" "$out" "STATUS: drifted"
contains "modified artifact: drift count is 1" "$out" "DRIFT:  1 of"
contains "modified artifact: names the differing file" "$out" "$HOME_2/.devlead/scripts/state.sh"
not_contains "modified artifact: never falls back to STATUS: ok" "$out" "STATUS: ok"
not_contains "modified artifact: no MATCHES line" "$out" "MATCHES:"
check "modified artifact: exits non-zero" "$(doctor "$HOME_2" >/dev/null 2>&1; echo $?)" "1"

# ===========================================================================
# Scenario 3: an artifact missing entirely -> drifted, named
# ===========================================================================
SRC_3="$(new_repo_sandbox scenario3)"
HOME_3="$SANDBOX/scenario3/home"
mkdir -p "$HOME_3/.devlead"
printf '%s\n' "$SRC_3" > "$HOME_3/.devlead/SOURCE_REPO"
install_all_artifacts "$HOME_3" "$SRC_3"
rm -f "$HOME_3/.claude/commands/foo.md"

out="$(doctor "$HOME_3")"
contains "missing artifact: STATUS: drifted" "$out" "STATUS: drifted"
contains "missing artifact: names the missing file" "$out" "$HOME_3/.claude/commands/foo.md"
contains "missing artifact: reason says missing" "$out" "missing"
check "missing artifact: exits non-zero" "$(doctor "$HOME_3" >/dev/null 2>&1; echo $?)" "1"

# ===========================================================================
# Scenario 4: SOURCE_REPO absent -> STATUS: unknown, exit non-zero, no guessing
# ===========================================================================
HOME_4="$SANDBOX/scenario4-home"
mkdir -p "$HOME_4"

out="$(doctor "$HOME_4")"
contains "no SOURCE_REPO: STATUS: unknown" "$out" "STATUS: unknown"
contains "no SOURCE_REPO: gap names the missing anchor" "$out" "SOURCE_REPO"
check "no SOURCE_REPO: exits non-zero" "$(doctor "$HOME_4" >/dev/null 2>&1; echo $?)" "1"
check "no SOURCE_REPO: does not fabricate a TRUNK line" "$(printf '%s' "$out" | grep -c '^TRUNK:')" "0"

# ===========================================================================
# Scenario 5: trunk unresolvable -> STATUS: unknown, exit non-zero
# ===========================================================================
SRC_5="$(new_repo_sandbox scenario5)"
git -C "$SRC_5" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
HOME_5="$SANDBOX/scenario5/home"
mkdir -p "$HOME_5/.devlead"
printf '%s\n' "$SRC_5" > "$HOME_5/.devlead/SOURCE_REPO"

out="$(doctor "$HOME_5")"
contains "no trunk: STATUS: unknown" "$out" "STATUS: unknown"
contains "no trunk: gap names the resolution failure" "$out" "cannot resolve the reviewed trunk"
check "no trunk: exits non-zero" "$(doctor "$HOME_5" >/dev/null 2>&1; echo $?)" "1"

# ===========================================================================
# Scenario 6: installed set matches a NON-TRUNK BRANCH TIP -> STATUS: ok,
# MATCHES names that branch, provenance NOTE present, exit 0. This is the
# case the whole feature exists for: developing against a branch must not
# read as "drifted" on every single run.
# ===========================================================================
SRC_6="$(new_repo_sandbox_with_branch scenario6)"
HOME_6="$SANDBOX/scenario6/home"
mkdir -p "$HOME_6/.devlead"
printf '%s\n' "$SRC_6" > "$HOME_6/.devlead/SOURCE_REPO"
install_from_ref "$HOME_6" "$SRC_6" "origin/feature"

out="$(doctor "$HOME_6")"
contains "branch tip install: STATUS: ok" "$out" "STATUS: ok"
contains "branch tip install: MATCHES names the branch" "$out" "MATCHES: feature @"
not_contains "branch tip install: MATCHES does not name the trunk" "$out" "MATCHES: main @"
contains "branch tip install: provenance NOTE present" "$out" "NOTE:"
contains "branch tip install: NOTE says installed from a branch" "$out" "installed from a branch, not the trunk"
contains "branch tip install: NOTE says an unattended run still needs the trunk" "$out" "unattended run still requires the trunk"
check "branch tip install: exits 0" "$(doctor "$HOME_6" >/dev/null 2>&1; echo $?)" "0"

# ===========================================================================
# Scenario 7: installed set matches an OLDER commit ON THE TRUNK (a simple
# re-publish lag, nothing unreviewed) -> STATUS: ok, matched, but this must
# NOT be reported as a branch install — it is stale trunk, not provenance.
# ===========================================================================
SRC_7="$(new_repo_sandbox scenario7)"
OLDER_SHA_7="$(git -C "$SRC_7" rev-parse HEAD)"
echo "state v2" > "$SRC_7/.devlead/scripts/state.sh"
git -C "$SRC_7" add -A && git -C "$SRC_7" commit -qm "bump state.sh"
git -C "$SRC_7" push -q origin main
HOME_7="$SANDBOX/scenario7/home"
mkdir -p "$HOME_7/.devlead"
printf '%s\n' "$SRC_7" > "$HOME_7/.devlead/SOURCE_REPO"
install_from_ref "$HOME_7" "$SRC_7" "$OLDER_SHA_7"

out="$(doctor "$HOME_7")"
contains "older trunk commit: STATUS: ok" "$out" "STATUS: ok"
contains "older trunk commit: MATCHES a commit" "$out" "MATCHES:"
not_contains "older trunk commit: not called a branch install" "$out" "NOTE:"
not_contains "older trunk commit: not reported as MATCHES: main (that's the tip, this is older)" "$out" "MATCHES: main @"
check "older trunk commit: exits 0" "$(doctor "$HOME_7" >/dev/null 2>&1; echo $?)" "0"

# ===========================================================================
# Bonus (not in the required matrix, but load-bearing for the feature's own
# stated purpose): a genuinely drifted install — content that matches
# nothing, anywhere, within the search bound — is still classified as "not
# simply stale", worded honestly (scoped to what was actually searched).
# ===========================================================================
SRC_8="$(new_repo_sandbox scenario8)"
HOME_8="$SANDBOX/scenario8/home"
mkdir -p "$HOME_8/.devlead"
printf '%s\n' "$SRC_8" > "$HOME_8/.devlead/SOURCE_REPO"
install_all_artifacts "$HOME_8" "$SRC_8"
echo "NEVER COMMITTED ANYWHERE" > "$HOME_8/.devlead/scripts/state.sh"

out="$(doctor "$HOME_8")"
contains "branch-like install: STATUS: drifted" "$out" "STATUS: drifted"
contains "branch-like install: classified as not simply stale" "$out" "does not look like simple staleness"
contains "branch-like install: DRIFT line scopes its claim to the search bound" "$out" "matched no commit within the last"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
rm -rf "$SANDBOX"
[[ "$FAIL_COUNT" -eq 0 ]]
