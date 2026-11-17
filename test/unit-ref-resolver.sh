#!/usr/bin/env bash
# unit-ref-resolver.sh — ref-resolver.sh keeps issue spec paths inside the repo
#
#   bash test/unit-ref-resolver.sh
#
# The `Spec:` and `Design:` lines come from an issue body, which anyone who
# can open an issue writes (GOVERNANCE.md §untrusted-content). ref-resolver
# copies the spec into ~/.devlead/run/ for the pipeline to read, so a path
# like `../../home/me/.devlead/gh-token` would hand the token to the model.
# Pins: an absolute path, a '..' component and a symlink that resolves
# outside the repository are rejected with nothing copied and a stderr
# message; a legitimate in-repo spec resolves exactly as before.
#
# SAFETY: $HOME and the repo are throwaway /tmp sandboxes; `gh` is a fake.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
RESOLVER="$REPO_ROOT/.devlead/scripts/ref-resolver.sh"
SANDBOX="$(mktemp -d /tmp/devlead-ref-resolver.XXXXXX)"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
FAKEBIN="$SANDBOX/fakebin"
FAKE_HOME="$SANDBOX/home"
WORK="$SANDBOX/work"
BODIES="$SANDBOX/bodies"
export BODIES
mkdir -p "$FAKEBIN" "$FAKE_HOME" "$BODIES"

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

# Fake gh: authenticated; `issue view N --json body -q .body` serves body-N.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status") exit 0 ;;
  "issue view "*" --json body -q .body") cat "$BODIES/body-$3" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

# The secret that must never be copied, outside the repository.
mkdir -p "$SANDBOX/outside"
echo "ghp_SECRET_VALUE" > "$SANDBOX/outside/gh-token"

git init -q "$WORK"
mkdir -p "$WORK/docs" "$WORK/design"
printf '# Spec\nThe intended behaviour.\n' > "$WORK/docs/spec.md"
ln -s ../../outside/gh-token "$WORK/docs/escape.md"

# resolve <issue> <body> — sets OUT, ERR, RC.
resolve() {
  printf '%s\n' "$2" > "$BODIES/body-$1"
  OUT="$(cd "$WORK" && HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" bash "$RESOLVER" "$1" 2>"$SANDBOX/err")"
  RC=$?
  ERR="$(cat "$SANDBOX/err")"
}
copied() { [[ -f "$FAKE_HOME/.devlead/run/issue-$1-spec.md" ]] && echo yes || echo no; }
leaked() { grep -rl "ghp_SECRET_VALUE" "$FAKE_HOME" 2>/dev/null | wc -l | tr -d ' '; }

# --- a legitimate in-repo spec resolves exactly as before --------------------
resolve 1 $'Please add retries.\nSpec: docs/spec.md\nDesign: design/mock.pdf'
check "in-repo spec: output unchanged" "$OUT" "DESIGN: design/mock.pdf
SPEC:   $FAKE_HOME/.devlead/run/issue-1-spec.md
SOURCE: docs/spec.md"
check "in-repo spec: exit 0" "$RC" "0"
check "in-repo spec: nothing on stderr" "$ERR" ""
check "in-repo spec: content copied" "$(cat "$FAKE_HOME/.devlead/run/issue-1-spec.md")" "$(cat "$WORK/docs/spec.md")"

resolve 2 $'Spec: ./docs/spec.md'
check "in-repo spec with ./: still resolves" "$(sed -n 1p <<<"$OUT")" "SPEC:   $FAKE_HOME/.devlead/run/issue-2-spec.md"

resolve 3 $'Spec: docs/missing.md'
check "in-repo spec that does not exist: not found, as before" "$OUT" "SPEC:   none
SOURCE: docs/missing.md
GAP:    file not found at $WORK/docs/missing.md"

# --- rejections ----------------------------------------------------------------
rejected() { # <label> <issue> <body>
  resolve "$2" "$3"
  check "$1: SPEC none" "$(sed -n 's/^SPEC:[[:space:]]*//p' <<<"$OUT")" "none"
  contains "$1: GAP says why" "$OUT" "GAP:    spec path rejected"
  contains "$1: stderr says why" "$ERR" "ref-resolver: Spec: path rejected"
  check "$1: nothing copied" "$(copied "$2")" "no"
  check "$1: the secret is nowhere under HOME" "$(leaked)" "0"
  check "$1: exit 0" "$RC" "0"
}
rejected "relative path with '..'"       11 $'Spec: ../outside/gh-token'
rejected "deeper '..' path"               12 "Spec: docs/../../outside/gh-token"
rejected "'..' that would stay inside"    13 "Spec: docs/../docs/spec.md"
rejected "absolute path"                  14 "Spec: $SANDBOX/outside/gh-token"
rejected "symlink escaping the repo"      15 "Spec: docs/escape.md"
lacks "rejected path is not echoed on stdout" "$OUT" "escape.md"

# --- Design: is checked the same way (it is only emitted, never copied) ------
resolve 21 $'Spec: docs/spec.md\nDesign: ../outside/gh-token'
lacks "design with '..': not emitted" "$OUT" "DESIGN:"
contains "design with '..': stderr says why" "$ERR" "ref-resolver: Design: path rejected"
contains "design with '..': a valid spec still resolves" "$OUT" "SOURCE: docs/spec.md"
resolve 22 "Design: $SANDBOX/outside/mock.pdf"
lacks "absolute design: not emitted" "$OUT" "DESIGN:"
resolve 23 $'Design: docs/escape.md'
lacks "design symlink escaping the repo: not emitted" "$OUT" "DESIGN:"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
[[ "$FAIL_COUNT" -eq 0 ]]
