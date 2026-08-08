#!/usr/bin/env bash
# smoke-pinned-release.sh — formal sandboxed smoke evidence for the
# devlead-pinned-release change (REQ-01..REQ-11, see the SDD spec/design/
# tasks artifacts for sdd/devlead-pinned-release in engram).
#
# NOT wired into any CI/test runner. Run manually:
#   bash test/smoke-pinned-release.sh
#
# SAFETY: every operation below targets a throwaway /tmp clone of this repo
# plus /tmp fake $HOME directories. This script NEVER touches the real
# machine's $HOME, ~/.devlead, ~/.local/bin, or ~/.config/systemd. It never
# invokes the real `systemctl` (a fake one is put first on $PATH).
#
# Re-run any time bootstrap-lib.sh / envelope.sh / the devlead CLI / install.sh
# change, to catch a regression in the copy-not-symlink publish model.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SMOKE_ROOT="$(mktemp -d /tmp/devlead-smoke.XXXXXX)"
SANDBOX_SRC="$SMOKE_ROOT/src-master"
FAKEBIN="$SMOKE_ROOT/fakebin"
RESULTS_FILE="$SMOKE_ROOT/results.txt"
KEEP_TMP="${SMOKE_KEEP_TMP:-0}"

mkdir -p "$SMOKE_ROOT/homes" "$SMOKE_ROOT/srcs" "$FAKEBIN"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo "SMOKE_KEEP_TMP=1 — sandbox left at $SMOKE_ROOT"
  else
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS  $1" | tee -a "$RESULTS_FILE"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL  $1" | tee -a "$RESULTS_FILE"; FAIL_COUNT=$((FAIL_COUNT+1)); }
note() { echo "NOTE  $1" | tee -a "$RESULTS_FILE"; }

# Clone the CURRENT HEAD of the repo running this script (working tree state
# is NOT copied — only what is committed — so uncommitted local noise in the
# real checkout never leaks into the sandbox).
git clone -q "$REPO_ROOT" "$SANDBOX_SRC" >/dev/null
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
git -C "$SANDBOX_SRC" checkout -q "$CURRENT_BRANCH" 2>/dev/null || true

fresh_home() { local d="$SMOKE_ROOT/homes/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s\n' "$d"; }
fresh_src_copy() {
  local d="$SMOKE_ROOT/srcs/$1"
  rm -rf "$d"
  git clone -q "$SANDBOX_SRC" "$d" >/dev/null
  git -C "$d" checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
  printf '%s\n' "$d"
}
seed_source_repo() { mkdir -p "$1/.devlead"; printf '%s\n' "$2" > "$1/.devlead/SOURCE_REPO"; }

cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$FAKEBIN/systemctl"

envelope() {
  local home="$1" src="$2" cmd="$3"
  (cd "$src" && HOME="$home" PATH="$FAKEBIN:$PATH" bash .devlead/scripts/envelope.sh "$cmd")
}
envelope_noninteractive() {
  local home="$1" src="$2" cmd="$3"
  (cd "$src" && HOME="$home" PATH="$FAKEBIN:$PATH" bash .devlead/scripts/envelope.sh "$cmd" < /dev/null)
}

all_publish_targets() {
  cat <<'EOF'
.devlead/scripts/bootstrap-lib.sh
.devlead/scripts/state.sh
.devlead/scripts/branch.sh
.devlead/scripts/ref-resolver.sh
.devlead/scripts/forbidden-check.sh
.devlead/scripts/devlead-active.sh
.devlead/scripts/envelope.sh
.devlead/scripts/envelope-auth.sh
.devlead/scripts/sweep.sh
.devlead/scripts/run-state.sh
.devlead/scripts/sweep-loop.sh
.devlead/scripts/doctor.sh
.local/bin/devlead
.devlead/hooks/post-edit.sh
.devlead/hooks/gate-check.sh
.claude/commands/arranquemos.md
.claude/commands/cerremos.md
.claude/commands/batch.md
.claude/commands/sweep-execute.md
.claude/commands/sweep-discover.md
.config/systemd/user/devlead-sweep.service
.config/systemd/user/devlead-sweep.timer
.config/systemd/user/devlead-loop.service
.config/systemd/user/devlead-loop.timer
EOF
}
all_source_paths() {
  cat <<'EOF'
.devlead/scripts/bootstrap-lib.sh
.devlead/scripts/state.sh
.devlead/scripts/branch.sh
.devlead/scripts/ref-resolver.sh
.devlead/scripts/forbidden-check.sh
.devlead/scripts/devlead-active.sh
.devlead/scripts/envelope.sh
.devlead/scripts/envelope-auth.sh
.devlead/scripts/sweep.sh
.devlead/scripts/run-state.sh
.devlead/scripts/sweep-loop.sh
.devlead/scripts/doctor.sh
.devlead/bin/devlead
.claude/hooks/post-edit.sh
.claude/hooks/gate-check.sh
.claude/commands/arranquemos.md
.claude/commands/cerremos.md
.claude/commands/batch.md
.claude/commands/sweep-execute.md
.claude/commands/sweep-discover.md
.devlead/systemd/devlead-sweep.service
.devlead/systemd/devlead-sweep.timer
.devlead/systemd/devlead-loop.service
.devlead/systemd/devlead-loop.timer
EOF
}

# ===========================================================================
# S1 — REQ-01 + REQ-02: fresh publish via `upgrade` (anchor pre-seeded,
# simulating a machine that already went through install.sh once).
# ===========================================================================
s1_fresh_publish() {
  local home; home="$(fresh_home s1)"
  seed_source_repo "$home" "$SANDBOX_SRC"
  local expect_sha; expect_sha="$(git -C "$SANDBOX_SRC" rev-parse --short HEAD)"

  local out rc
  out="$(envelope "$home" "$SANDBOX_SRC" upgrade)"; rc=$?

  [[ $rc -eq 0 ]] && pass "S1 exit code 0" || fail "S1 exit code was $rc"
  echo "$out" | grep -q "^STATUS: ok" && pass "S1 STATUS: ok" || fail "S1 missing STATUS: ok — got: $out"
  echo "$out" | grep -q "^VERSION: $expect_sha (" && pass "S1 stdout reports sha+date" || fail "S1 stdout did not report sha+date — got: $out"

  local -a rel_list src_list
  local i=0 all_real=true all_match=true
  mapfile -t rel_list < <(all_publish_targets)
  mapfile -t src_list < <(all_source_paths)
  for i in "${!rel_list[@]}"; do
    local dst="$home/${rel_list[$i]}" src="$SANDBOX_SRC/${src_list[$i]}"
    if [[ -L "$dst" ]]; then all_real=false; note "S1 $dst is STILL a symlink"; fi
    if [[ ! -f "$dst" ]]; then all_real=false; note "S1 $dst missing entirely"; fi
    if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then all_match=false; note "S1 $dst content mismatch vs $src"; fi
  done
  $all_real  && pass "S1 REQ-01: all 18 targets are real files (test -L false)" || fail "S1 REQ-01: at least one target is a symlink or missing"
  $all_match && pass "S1 REQ-01: all 18 targets content-match source" || fail "S1 REQ-01: content mismatch on at least one target"

  local vf="$home/.devlead/VERSION"
  if [[ -f "$vf" ]] && grep -q "^SHA: $expect_sha$" "$vf" && grep -qE '^STAMPED: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$vf"; then
    pass "S1 REQ-02: VERSION has correct SHA + UTC ISO timestamp"
  else
    fail "S1 REQ-02: VERSION malformed or missing — $(cat "$vf" 2>&1)"
  fi
}

# ===========================================================================
# S2 — REQ-03: idempotent re-run at same HEAD is a true no-op.
# ===========================================================================
s2_idempotent_noop() {
  local home; home="$(fresh_home s2)"
  seed_source_repo "$home" "$SANDBOX_SRC"
  envelope "$home" "$SANDBOX_SRC" upgrade >/dev/null
  local expect_sha; expect_sha="$(git -C "$SANDBOX_SRC" rev-parse --short HEAD)"

  local -a rel_list; mapfile -t rel_list < <(all_publish_targets)
  local snap="$SMOKE_ROOT/s2-mtimes-before.txt"; : > "$snap"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap"; done

  local out rc
  out="$(envelope "$home" "$SANDBOX_SRC" upgrade)"; rc=$?
  [[ $rc -eq 0 ]] && pass "S2 exit code 0" || fail "S2 exit code was $rc"
  echo "$out" | grep -q "^STATUS: up-to-date" && echo "$out" | grep -q "$expect_sha" \
    && pass "S2 REQ-03: STATUS: up-to-date names correct sha" \
    || fail "S2 REQ-03: missing up-to-date message — got: $out"

  local snap2="$SMOKE_ROOT/s2-mtimes-after.txt"; : > "$snap2"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap2"; done
  if diff -q "$snap" "$snap2" >/dev/null; then
    pass "S2 REQ-03: zero mtime changes on any published target (true no-op)"
  else
    fail "S2 REQ-03: mtimes changed on a no-op re-run — $(diff "$snap" "$snap2")"
  fi
}

# ===========================================================================
# S3 — REQ-04: conditional daemon-reload (unit-changed vs script-only-changed)
# ===========================================================================
s3a_unit_changed_reload_fires() {
  local src; src="$(fresh_src_copy s3a)"
  local home; home="$(fresh_home s3a)"
  seed_source_repo "$home" "$src"
  envelope "$home" "$src" upgrade >/dev/null

  echo "# smoke-test content change $(date +%s)" >> "$src/.devlead/systemd/devlead-sweep.timer"
  (cd "$src" && git commit -qam "test: mutate timer content for S3a")

  local log="$SMOKE_ROOT/s3a-systemctl.log"
  local out rc
  out="$(SYSTEMCTL_LOG="$log" envelope "$home" "$src" upgrade)"; rc=$?
  [[ $rc -eq 0 ]] && pass "S3a exit code 0" || fail "S3a exit code was $rc"

  local calls; calls="$(grep -c "daemon-reload" "$log" 2>/dev/null || echo 0)"
  [[ "$calls" -eq 1 ]] && pass "S3a REQ-04: daemon-reload invoked exactly once on unit content change" \
    || fail "S3a REQ-04: expected exactly 1 daemon-reload call, got $calls"
}

s3b_script_only_reload_skipped() {
  local src; src="$(fresh_src_copy s3b)"
  local home; home="$(fresh_home s3b)"
  seed_source_repo "$home" "$src"
  envelope "$home" "$src" upgrade >/dev/null

  echo "# smoke-test comment $(date +%s)" >> "$src/.devlead/scripts/sweep.sh"
  (cd "$src" && git commit -qam "test: mutate sweep.sh only for S3b")

  local log="$SMOKE_ROOT/s3b-systemctl.log"
  local out rc
  out="$(SYSTEMCTL_LOG="$log" envelope "$home" "$src" upgrade)"; rc=$?
  [[ $rc -eq 0 ]] && pass "S3b exit code 0" || fail "S3b exit code was $rc"
  echo "$out" | grep -q "^STATUS: ok" || fail "S3b expected STATUS: ok — got: $out"

  if [[ ! -s "$log" ]]; then
    pass "S3b REQ-04: daemon-reload NOT invoked when only a script changed"
  else
    fail "S3b REQ-04: daemon-reload was invoked when it should not have been: $(cat "$log")"
  fi
}

# ===========================================================================
# S4 — REQ-05 [CARDINAL]: dirty-tree honest-gap, no partial state.
# ===========================================================================
s4_dirty_tree_blocks() {
  local src; src="$(fresh_src_copy s4)"
  local home; home="$(fresh_home s4)"
  seed_source_repo "$home" "$src"

  envelope "$home" "$src" upgrade >/dev/null
  local vf="$home/.devlead/VERSION"
  local before_sha before_hash
  before_sha="$(awk -F': ' '/^SHA:/{print $2}' "$vf")"
  before_hash="$(md5sum "$vf" | cut -d' ' -f1)"
  local -a rel_list; mapfile -t rel_list < <(all_publish_targets)
  local snap="$SMOKE_ROOT/s4-mtimes-before.txt"; : > "$snap"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap"; done

  echo "# uncommitted dirty change" >> "$src/.devlead/scripts/sweep.sh"

  local out rc
  out="$(envelope "$home" "$src" upgrade)"; rc=$?
  [[ $rc -eq 0 ]] && pass "S4 exit code 0 (honest-gap idiom, not a hard error)" || fail "S4 exit code was $rc"
  echo "$out" | grep -q "^STATUS: blocked" && echo "$out" | grep -qi "GAP:.*dirty\|uncommitted" \
    && pass "S4 REQ-05: STATUS: blocked + GAP names dirty tree" \
    || fail "S4 REQ-05: missing blocked/GAP dirty-tree message — got: $out"

  local after_hash after_sha
  after_hash="$(md5sum "$vf" | cut -d' ' -f1)"
  after_sha="$(awk -F': ' '/^SHA:/{print $2}' "$vf")"
  [[ "$before_hash" == "$after_hash" && "$before_sha" == "$after_sha" ]] \
    && pass "S4 REQ-05: VERSION byte-for-byte unchanged after blocked run" \
    || fail "S4 REQ-05: VERSION changed after a blocked run"

  local snap2="$SMOKE_ROOT/s4-mtimes-after.txt"; : > "$snap2"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap2"; done
  diff -q "$snap" "$snap2" >/dev/null \
    && pass "S4 REQ-05: no live path modified — no partial state" \
    || fail "S4 REQ-05: a live path was modified during a blocked (dirty-tree) run"
}

# ===========================================================================
# S5 — REQ-06/07: init first-time-publish vs already-versioned-skip.
# ===========================================================================
s5_init_first_time_and_versioned() {
  local src; src="$(fresh_src_copy s5)"
  local home; home="$(fresh_home s5)"
  seed_source_repo "$home" "$src"

  [[ ! -f "$home/.devlead/VERSION" ]] && pass "S5 precondition: no VERSION before first init" \
    || fail "S5 precondition failed: VERSION already present"

  local out
  out="$(envelope_noninteractive "$home" "$src" init)"
  local expect_sha; expect_sha="$(git -C "$src" rev-parse --short HEAD)"

  [[ -f "$home/.devlead/VERSION" ]] && grep -q "^SHA: $expect_sha$" "$home/.devlead/VERSION" \
    && pass "S5 REQ-06: init (no VERSION) performed the same publish as upgrade, VERSION written" \
    || fail "S5 REQ-06: VERSION not written correctly by first-time init"
  [[ -f "$home/.devlead/scripts/state.sh" && ! -L "$home/.devlead/scripts/state.sh" ]] \
    && pass "S5 REQ-06: scripts published as real files during first-time init" \
    || fail "S5 REQ-06: scripts not published during first-time init"
  echo "$out" | grep -q "^STATUS: created" && pass "S5 REQ-06: envelope.yml scaffolded on first init" \
    || fail "S5 REQ-06: envelope.yml scaffold status missing — got: $out"
  echo "$out" | grep -q "not enrolled (non-interactive)" && pass "S5 REQ-06: opt-in ran non-interactively" \
    || fail "S5 REQ-06: opt-in question did not run — got: $out"

  local -a rel_list; mapfile -t rel_list < <(all_publish_targets)
  local snap="$SMOKE_ROOT/s5-mtimes-before.txt"; : > "$snap"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap"; done
  local vf_hash_before; vf_hash_before="$(md5sum "$home/.devlead/VERSION" | cut -d' ' -f1)"

  local out2
  out2="$(envelope_noninteractive "$home" "$src" init)"

  local snap2="$SMOKE_ROOT/s5-mtimes-after.txt"; : > "$snap2"
  for r in "${rel_list[@]}"; do stat -c '%n %Y' "$home/$r" >> "$snap2"; done
  local vf_hash_after; vf_hash_after="$(md5sum "$home/.devlead/VERSION" | cut -d' ' -f1)"

  diff -q "$snap" "$snap2" >/dev/null && [[ "$vf_hash_before" == "$vf_hash_after" ]] \
    && pass "S5 REQ-07: already-versioned init does NOT republish (zero mtime changes, VERSION unchanged)" \
    || fail "S5 REQ-07: a republish happened when VERSION already existed"
  echo "$out2" | grep -q "^STATUS: exists" && pass "S5 REQ-07: envelope.yml scaffold still runs (STATUS: exists)" \
    || fail "S5 REQ-07: envelope scaffold step missing on second init — got: $out2"
}

# ===========================================================================
# S6 — REQ-08 [GATE]: symlink migration via BOTH upgrade and init, across
# scripts/CLI/hooks/commands.
# ===========================================================================
_seed_leftover_symlinks() {
  local home="$1" src="$2"
  mkdir -p "$home/.devlead/scripts" "$home/.devlead/hooks" "$home/.local/bin" "$home/.claude/commands"
  ln -sf "$src/.devlead/scripts/state.sh"       "$home/.devlead/scripts/state.sh"
  ln -sf "$src/.devlead/bin/devlead"            "$home/.local/bin/devlead"
  ln -sf "$src/.claude/hooks/post-edit.sh"      "$home/.devlead/hooks/post-edit.sh"
  ln -sf "$src/.claude/commands/arranquemos.md" "$home/.claude/commands/arranquemos.md"
}

s6a_migration_via_upgrade() {
  local src; src="$(fresh_src_copy s6a)"
  local home; home="$(fresh_home s6a)"
  seed_source_repo "$home" "$src"
  _seed_leftover_symlinks "$home" "$src"

  local before_ok=true
  for p in .devlead/scripts/state.sh .local/bin/devlead .devlead/hooks/post-edit.sh .claude/commands/arranquemos.md; do
    [[ -L "$home/$p" ]] || before_ok=false
  done
  $before_ok && pass "S6a precondition: all 4 sample paths ARE symlinks before upgrade" \
    || fail "S6a precondition failed: not all sample paths were pre-seeded as symlinks"

  envelope "$home" "$src" upgrade >/dev/null

  local after_ok=true
  for p in .devlead/scripts/state.sh .local/bin/devlead .devlead/hooks/post-edit.sh .claude/commands/arranquemos.md; do
    [[ -L "$home/$p" ]] && after_ok=false
    [[ -f "$home/$p" ]] || after_ok=false
  done
  $after_ok && pass "S6a REQ-08: all 4 sample paths (script/CLI/hook/command) migrated symlink->real-file via upgrade" \
    || fail "S6a REQ-08: at least one sample path is still a symlink or missing after upgrade"
  [[ -f "$home/.devlead/VERSION" ]] && pass "S6a REQ-08: VERSION written after migration" \
    || fail "S6a REQ-08: VERSION not written after successful migration"
}

s6b_migration_via_init() {
  local src; src="$(fresh_src_copy s6b)"
  local home; home="$(fresh_home s6b)"
  seed_source_repo "$home" "$src"
  _seed_leftover_symlinks "$home" "$src"
  [[ ! -f "$home/.devlead/VERSION" ]] || fail "S6b precondition: VERSION should not exist yet"

  envelope_noninteractive "$home" "$src" init >/dev/null

  local after_ok=true
  for p in .devlead/scripts/state.sh .local/bin/devlead .devlead/hooks/post-edit.sh .claude/commands/arranquemos.md; do
    [[ -L "$home/$p" ]] && after_ok=false
    [[ -f "$home/$p" ]] || after_ok=false
  done
  $after_ok && pass "S6b REQ-08: all 4 sample paths (script/CLI/hook/command) migrated symlink->real-file via init" \
    || fail "S6b REQ-08: at least one sample path is still a symlink or missing after init"
}

# ===========================================================================
# S7 — REQ-09 [CARDINAL]: gh-token/autonomous-repos/repo-envelope.yml
# untouched by upgrade AND init (byte-for-byte + mtime).
# ===========================================================================
s7_out_of_scope_guard() {
  local src; src="$(fresh_src_copy s7)"
  local home; home="$(fresh_home s7)"
  seed_source_repo "$home" "$src"

  mkdir -p "$home/.devlead"
  printf 'ghp_smoketestFAKEtoken1234\n' > "$home/.devlead/gh-token"
  chmod 600 "$home/.devlead/gh-token"
  printf '/tmp/some/other/repo\n' > "$home/.devlead/autonomous-repos"
  mkdir -p "$src/.devlead"
  cat > "$src/.devlead/envelope.yml" <<'YML'
version: 1
enabled: false
select: {bucket: nuevo-entrante, exclude_labels: [], require_readiness: false}
order: {by: [priority-label, created-asc]}
budget: {max_issues: 1, stop_at: null}
base: {strategy: dev}
forbidden_zones: inherit
on_failure: {policy: park-and-continue, skip_dependents: true}
merge: {mode: never}
report: {to: journal-per-repo}
YML
  (cd "$src" && git add -A && git commit -qm "test: seed repo envelope.yml for S7")

  local gh_before ar_before env_before
  gh_before="$(md5sum "$home/.devlead/gh-token" | cut -d' ' -f1)-$(stat -c %Y "$home/.devlead/gh-token")"
  ar_before="$(md5sum "$home/.devlead/autonomous-repos" | cut -d' ' -f1)-$(stat -c %Y "$home/.devlead/autonomous-repos")"
  env_before="$(md5sum "$src/.devlead/envelope.yml" | cut -d' ' -f1)-$(stat -c %Y "$src/.devlead/envelope.yml")"

  envelope "$home" "$src" upgrade >/dev/null
  envelope_noninteractive "$home" "$src" init >/dev/null

  local gh_after ar_after env_after
  gh_after="$(md5sum "$home/.devlead/gh-token" | cut -d' ' -f1)-$(stat -c %Y "$home/.devlead/gh-token")"
  ar_after="$(md5sum "$home/.devlead/autonomous-repos" | cut -d' ' -f1)-$(stat -c %Y "$home/.devlead/autonomous-repos")"
  env_after="$(md5sum "$src/.devlead/envelope.yml" | cut -d' ' -f1)-$(stat -c %Y "$src/.devlead/envelope.yml")"

  [[ "$gh_before" == "$gh_after" ]] && pass "S7 REQ-09: gh-token byte+mtime unchanged after upgrade+init" \
    || fail "S7 REQ-09: gh-token was touched (before=$gh_before after=$gh_after)"
  [[ "$ar_before" == "$ar_after" ]] && pass "S7 REQ-09: autonomous-repos byte+mtime unchanged after upgrade+init" \
    || fail "S7 REQ-09: autonomous-repos was touched (before=$ar_before after=$ar_after)"
  [[ "$env_before" == "$env_after" ]] && pass "S7 REQ-09: repo envelope.yml byte+mtime unchanged after upgrade+init" \
    || fail "S7 REQ-09: repo envelope.yml was touched (before=$env_before after=$env_after)"
}

# ===========================================================================
# S8 — REQ-10: detached HEAD, zero reachable tags, no tag-fallback source.
# ===========================================================================
s8_no_tag_fallback() {
  local src; src="$(fresh_src_copy s8)"
  local home; home="$(fresh_home s8)"
  (cd "$src" && git tag -l | xargs -r git tag -d >/dev/null 2>&1)
  (cd "$src" && git checkout -q --detach HEAD)
  seed_source_repo "$home" "$src"

  local tag_count; tag_count="$(cd "$src" && git tag -l | wc -l)"
  [[ "$tag_count" -eq 0 ]] && pass "S8 precondition: zero reachable tags" \
    || fail "S8 precondition failed: $tag_count tags still reachable"

  local out rc
  out="$(envelope "$home" "$src" upgrade)"; rc=$?
  [[ $rc -eq 0 ]] && pass "S8 REQ-10: upgrade succeeds (exit 0) on detached HEAD with no tags" \
    || fail "S8 REQ-10: upgrade failed (exit $rc) on detached HEAD"
  echo "$out" | grep -q "^STATUS: ok" && pass "S8 REQ-10: STATUS: ok on detached HEAD publish" \
    || fail "S8 REQ-10: expected STATUS: ok — got: $out"

  # NOTE: "nearest-tag" also appears as an UNRELATED, pre-existing envelope.yml
  # v1 schema value (base.strategy: nearest-tag|dev — an issue-branch base-ref
  # strategy predating this whole change) — nothing to do with devlead's own
  # version-pin mechanism, so lines containing "strategy" are excluded here.
  local hits
  hits="$(rg -n "git describe|--tags" \
      "$src/.devlead/scripts/envelope.sh" "$src/.devlead/scripts/bootstrap-lib.sh" \
      "$src/.devlead/bin/devlead" "$src/install.sh" 2>/dev/null \
      | grep -v "strategy" || true)"
  if [[ -n "$hits" ]]; then
    fail "S8 REQ-10: found a git-describe/tag-fallback reference — $hits"
  else
    pass "S8 REQ-10: no git-describe/--tags call found in the 4 touched files (excluding the unrelated pre-existing base.strategy: nearest-tag envelope schema value)"
  fi
}

# ===========================================================================
# S9 — REQ-11 [GATE, LOAD-BEARING]: fault-injected mid-copy failure ->
# SOURCE_REPO still recorded, VERSION NOT advanced, honest GAP reported ->
# re-run heals to full success.
# ===========================================================================
s9_fault_injection_heal_on_rerun() {
  local src; src="$(fresh_src_copy s9)"
  local home; home="$(fresh_home s9)"
  seed_source_repo "$home" "$src"

  mkdir -p "$home/.devlead/hooks"
  chmod 555 "$home/.devlead/hooks"

  local out1 rc1
  out1="$(envelope "$home" "$src" upgrade)"; rc1=$?
  [[ $rc1 -eq 0 ]] && pass "S9 run1 exit code 0 (honest-gap idiom, not a hard error)" || fail "S9 run1 exit code was $rc1"
  echo "$out1" | grep -q "^STATUS: blocked" && pass "S9 REQ-11 run1: STATUS: blocked on fault-injected failure" \
    || fail "S9 REQ-11 run1: expected STATUS: blocked — got: $out1"
  echo "$out1" | grep -q "GAP:.*hooks/post-edit.sh\|GAP:.*hooks/gate-check.sh" \
    && pass "S9 REQ-11 run1: GAP: names the specific failed hook file(s)" \
    || fail "S9 REQ-11 run1: GAP did not name the failed file — got: $out1"

  [[ -f "$home/.devlead/SOURCE_REPO" ]] && [[ "$(cat "$home/.devlead/SOURCE_REPO")" == "$src" ]] \
    && pass "S9 REQ-11 run1: SOURCE_REPO still written correctly despite mid-run failure" \
    || fail "S9 REQ-11 run1: SOURCE_REPO missing or wrong after fault-injected run"
  [[ ! -f "$home/.devlead/VERSION" ]] && pass "S9 REQ-11 run1: VERSION NOT advanced on partial failure" \
    || fail "S9 REQ-11 run1: VERSION was written despite a partial-failure run"

  [[ -f "$home/.devlead/scripts/state.sh" && ! -L "$home/.devlead/scripts/state.sh" ]] \
    && pass "S9 REQ-11 run1: unaffected targets (e.g. scripts/state.sh) still published (hybrid state proof)" \
    || fail "S9 REQ-11 run1: an unaffected target did not publish — copy loop may have aborted early"

  chmod 755 "$home/.devlead/hooks"
  local expect_sha; expect_sha="$(git -C "$src" rev-parse --short HEAD)"
  local out2 rc2
  out2="$(envelope "$home" "$src" upgrade)"; rc2=$?
  [[ $rc2 -eq 0 ]] && pass "S9 run2 (heal) exit code 0" || fail "S9 run2 exit code was $rc2"
  echo "$out2" | grep -q "^STATUS: ok" && pass "S9 REQ-11 run2: STATUS: ok — full successful publish after heal" \
    || fail "S9 REQ-11 run2: expected STATUS: ok after heal — got: $out2"
  [[ -f "$home/.devlead/VERSION" ]] && grep -q "^SHA: $expect_sha$" "$home/.devlead/VERSION" \
    && pass "S9 REQ-11 run2: VERSION now written/advanced to current HEAD (heal-on-rerun)" \
    || fail "S9 REQ-11 run2: VERSION missing or wrong after heal run"
  [[ -f "$home/.devlead/hooks/post-edit.sh" && ! -L "$home/.devlead/hooks/post-edit.sh" ]] \
    && [[ -f "$home/.devlead/hooks/gate-check.sh" && ! -L "$home/.devlead/hooks/gate-check.sh" ]] \
    && pass "S9 REQ-11 run2: previously-failed hook files now published as real files" \
    || fail "S9 REQ-11 run2: hook files still missing/symlinked after heal run"
  [[ -f "$home/.devlead/SOURCE_REPO" ]] && [[ "$(cat "$home/.devlead/SOURCE_REPO")" == "$src" ]] \
    && pass "S9 REQ-11 run2: SOURCE_REPO re-written on this run too (self-healing, not stale)" \
    || fail "S9 REQ-11 run2: SOURCE_REPO missing/stale on heal run"
}

main() {
  : > "$RESULTS_FILE"
  s1_fresh_publish
  s2_idempotent_noop
  s3a_unit_changed_reload_fires
  s3b_script_only_reload_skipped
  s4_dirty_tree_blocks
  s5_init_first_time_and_versioned
  s6a_migration_via_upgrade
  s6b_migration_via_init
  s7_out_of_scope_guard
  s8_no_tag_fallback
  s9_fault_injection_heal_on_rerun

  echo ""
  echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed (sandbox: $SMOKE_ROOT) ==="
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
