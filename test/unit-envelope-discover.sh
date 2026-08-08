#!/usr/bin/env bash
# unit-envelope-discover.sh — discover{} block validation in envelope.sh
#
#   bash test/unit-envelope-discover.sh
#
# The discover block is the envelope-schema half of DevLead's upcoming
# DISCOVERY stage: it explores declared modules against their specs and
# FILES issues for gaps. It never executes from discovery — the issue is
# the artifact that crosses the boundary, and the existing envelope policy
# (select.exclude_labels, etc.) already governs which issues get worked
# later. These cases pin: the block is OPTIONAL and backward compatible,
# every field is validated, paths are repo-relative (ADR-3), and the
# coupling rule that keeps discovery from filing work and immediately
# executing it (discover.label must be excluded by select.exclude_labels).
#
# SAFETY: every scenario runs inside a throwaway /tmp git repo with a local
# bare remote. Never reads or writes the real repo or ~/.devlead.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ENVELOPE_SH="$REPO_ROOT/.devlead/scripts/envelope.sh"
SANDBOX="$(mktemp -d /tmp/devlead-envdiscover.XXXXXX)"

PASS_COUNT=0
FAIL_COUNT=0

contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected substring: [$3]"
    echo "        actual:             [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

lacks() {
  if [[ "$2" != *"$3"* ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        unexpected substring: [$3]"
    echo "        actual:               [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS  $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $1"
    echo "        expected: [$3]"
    echo "        actual:   [$2]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Sandbox repo with a resolvable default branch -------------------------
git init -q --bare "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work" 2>/dev/null
cd "$SANDBOX/work" || exit 1
git config user.email smoke@example.com
git config user.name "Smoke Test"
git checkout -q -b main
mkdir -p .devlead
echo seed > seed.txt
git add seed.txt
git commit -q -m seed
git push -q -u origin main 2>/dev/null
git remote set-head origin main 2>/dev/null

# Fake `gh`: none of these scenarios exercise merge.mode: integration-branch
# (they all pin merge.mode: never), so _resolve_default_branch is never
# reached — but a real `gh` on $PATH could still stall on an auth prompt in
# a CI sandbox. Fail closed and fast instead.
FAKEBIN_GH="$(mktemp -d /tmp/devlead-envdiscover-fakebin.XXXXXX)"
cat > "$FAKEBIN_GH/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKEBIN_GH/gh"
export PATH="$FAKEBIN_GH:$PATH"

# Writes an envelope with the given exclude_labels literal and an optional
# discover: block appended verbatim (already YAML-indented, or empty for
# "no discover block at all").
write_envelope() {
  local excl="$1" disc="$2"
  {
    echo "version: 1"
    echo "enabled: true"
    echo "select:"
    echo "  bucket: nuevo-entrante"
    echo "  exclude_labels: $excl"
    echo "  require_readiness: true"
    echo "order:"
    echo "  by: [priority-label, created-asc]"
    echo "budget:"
    echo "  max_issues: 3"
    echo "  stop_at: null"
    echo "base:"
    echo "  strategy: nearest-tag"
    if [[ -n "$disc" ]]; then
      printf '%s\n' "$disc"
    fi
    echo "forbidden_zones: inherit"
    echo "on_failure:"
    echo "  policy: park-and-continue"
    echo "  skip_dependents: true"
    echo "merge:"
    echo "  mode: never"
    echo "report:"
    echo "  to: journal-per-repo"
  } > .devlead/envelope.yml
}

DISC_FULL=$'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src/auth\n      spec: docs/auth.md'

# --- no discover block at all -----------------------------------------------
write_envelope "[blocked]" ""
out="$(bash "$ENVELOPE_SH" show 2>&1)"
lacks "no discover block: envelope stays valid" "$out" "STATUS: blocked"
contains "no discover block: DISCOVER_ENABLED defaults to false" "$out" "DISCOVER_ENABLED: false"
lacks "no discover block: DISCOVER_LABEL is not emitted" "$out" "DISCOVER_LABEL"

# --- enabled: false with nothing else ---------------------------------------
write_envelope "[blocked]" $'discover:\n  enabled: false'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
lacks "enabled:false alone: envelope stays valid" "$out" "STATUS: blocked"
contains "enabled:false alone: DISCOVER_ENABLED is false" "$out" "DISCOVER_ENABLED: false"
lacks "enabled:false alone: DISCOVER_LABEL is not emitted" "$out" "DISCOVER_LABEL"

# --- valid full block, label excluded ---------------------------------------
write_envelope "[blocked, discuss]" "$DISC_FULL"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
lacks "valid full block: envelope is accepted" "$out" "STATUS: blocked"
contains "valid full block: DISCOVER_ENABLED true" "$out" "DISCOVER_ENABLED: true"
contains "valid full block: DISCOVER_LABEL emitted" "$out" "DISCOVER_LABEL: discuss"
contains "valid full block: module path emitted" "$out" "DISCOVER_MODULE_PATHS: src/auth"
contains "valid full block: module spec emitted" "$out" "DISCOVER_MODULE_SPECS: docs/auth.md"

# --- coupling rule: label NOT excluded --------------------------------------
write_envelope "[blocked]" "$DISC_FULL"
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "label not excluded is blocked" "$out" "STATUS: blocked"
contains "label not excluded names the coupling" "$out" "must appear in select.exclude_labels"

# --- enabled: true, label missing -------------------------------------------
write_envelope "[blocked]" $'discover:\n  enabled: true\n  modules:\n    - path: src/auth\n      spec: docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "missing label is blocked" "$out" "STATUS: blocked"
contains "missing label names discover.label" "$out" "discover.label"

# --- enabled: true, label empty ---------------------------------------------
write_envelope "[blocked]" $'discover:\n  enabled: true\n  label: ""\n  modules:\n    - path: src/auth\n      spec: docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "empty label is blocked" "$out" "STATUS: blocked"
contains "empty label names discover.label" "$out" "discover.label must be non-empty"

# --- enabled: true, modules empty -------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules: []'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "empty modules is blocked" "$out" "STATUS: blocked"
contains "empty modules names discover.modules" "$out" "discover.modules must be a non-empty list"

# --- module missing path -----------------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - spec: docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "module missing path is blocked" "$out" "STATUS: blocked"
contains "module missing path names 'path'" "$out" "missing or has an empty 'path'"

# --- module missing spec -----------------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src/auth'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "module missing spec is blocked" "$out" "STATUS: blocked"
contains "module missing spec names 'spec'" "$out" "missing or has an empty 'spec'"

# --- module path is absolute -------------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: /abs/src/auth\n      spec: docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "absolute module path is blocked" "$out" "STATUS: blocked"
contains "absolute module path says repo-relative" "$out" "must be repo-relative, not absolute"

# --- module spec is absolute -------------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src/auth\n      spec: /abs/docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "absolute module spec is blocked" "$out" "STATUS: blocked"
contains "absolute module spec says repo-relative" "$out" "must be repo-relative, not absolute"

# --- enabled non-boolean ------------------------------------------------------
write_envelope "[blocked, discuss]" $'discover:\n  enabled: yes-please\n  label: discuss\n  modules:\n    - path: src/auth\n      spec: docs/auth.md'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "non-boolean enabled is blocked" "$out" "STATUS: blocked"
contains "non-boolean enabled names discover.enabled" "$out" "discover.enabled must be a YAML boolean"

# --- unknown key inside discover: proves the closed schema still closes ----
write_envelope "[blocked, discuss]" $'discover:\n  enabled: true\n  label: discuss\n  modules:\n    - path: src/auth\n      spec: docs/auth.md\n  extra: nope'
out="$(bash "$ENVELOPE_SH" show 2>&1)"
contains "unknown key inside discover is blocked" "$out" "STATUS: blocked"
contains "unknown key inside discover names the key" "$out" "unknown key 'extra' under discover"

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SANDBOX) ==="
cd /tmp || exit 1
rm -rf "$SANDBOX" "$FAKEBIN_GH"
[[ "$FAIL_COUNT" -eq 0 ]]
