#!/usr/bin/env bash
# docker-smoke.sh — builds the DevLead server image and checks its limits from
# inside a container (F1: S7-S10, S12, S15, S20).
#
#   make docker-test
#
# NOT part of `make test`: it needs Docker and the network (the firewall
# resolves Anthropic and GitHub, and the probe reaches api.github.com).
#
# SAFETY: dummy secrets only, written to a scratch env file outside the repo.
# No environment value is ever printed. The compose project, the image tag and
# the scratch directory are unique to this run and removed at the end; a
# running `devlead` project and its image are never touched.
# shellcheck disable=SC2088 # "~/..." in labels is display text, not a path
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WANT_CLAUDE_VERSION="2.1.326"

command -v docker >/dev/null 2>&1 || { echo "docker-smoke: docker is not installed" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker-smoke: docker compose is not available" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/devlead-docker-smoke.XXXXXX")"
PROJECT="devlead-smoke-$$"
IMAGE="devlead-server:smoke-$$"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

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

# Dummy values in the shape the real ones have. The ntfy host is real so the
# firewall resolves it; nothing is pushed (the probe only sends level info).
ENV_FILE="$SCRATCH/smoke.env"
( umask 077; cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-DUMMY-not-a-real-token
DEVLEAD_CLAUDE_TOKEN_ISSUED=2026-11-01
GH_TOKEN=github_pat_DUMMY_not_a_real_token
DEVLEAD_NTFY_URL=https://ntfy.sh/devlead-smoke-dummy-topic
DEVLEAD_NTFY_TOKEN=tk_DUMMY_not_a_real_token
DEVLEAD_LOOP_CLAUDE_ARGS=--permission-mode acceptEdits --allowedTools Bash,Read,Edit,Write,Glob,Grep,Agent
DEVLEAD_EGRESS_ALLOW=
EOF
)
# Interpolation values for compose.yaml, so neither a real .env in the repo
# nor the caller's shell decides what this run builds or reads.
COMPOSE_ENV="$SCRATCH/compose.env"
printf 'DEVLEAD_UID=%s\nDEVLEAD_GID=%s\nDEVLEAD_IMAGE=%s\nDEVLEAD_ENV_FILE=%s\n' \
  "$HOST_UID" "$HOST_GID" "$IMAGE" "$ENV_FILE" > "$COMPOSE_ENV"

compose() {
  DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_IMAGE="$IMAGE" DEVLEAD_ENV_FILE="$ENV_FILE" \
    docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" \
      -p "$PROJECT" --env-file "$COMPOSE_ENV" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1
  docker image rm -f "$IMAGE" >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "=== build (project $PROJECT, image $IMAGE) ==="
if ! compose build >"$SCRATCH/build.log" 2>&1; then
  tail -n 40 "$SCRATCH/build.log"
  echo "FAIL  the image builds"
  exit 1
fi
echo "PASS  the image builds"
PASS_COUNT=$((PASS_COUNT + 1))

# --- Probe: runs through the real entrypoint, as the devlead user -------------
# Prints key=value lines. yn <cmd> says whether <cmd> succeeded.
read -r -d '' PROBE <<'PROBE_EOF'
p()  { printf '%s=%s\n' "$1" "$2"; }
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
M=/etc/claude-code/managed-settings.json
p uid "$(id -u)"
p gid "$(id -g)"
p claude_version "$(claude --version 2>/dev/null | head -n 1)"
p disable_autoupdater "${DISABLE_AUTOUPDATER:-}"
p devlead_guard "${DEVLEAD_GUARD:-}"
p cap_eff "$(awk '/^CapEff/ {print $2}' /proc/self/status)"
p cap_bnd "$(awk '/^CapBnd/ {print $2}' /proc/self/status)"
p no_new_privs "$(awk '/^NoNewPrivs/ {print $2}' /proc/self/status)"
p ms_owner "$(stat -c %U:%G "$M")"
p ms_mode "$(stat -c %a "$M")"
p ms_writable "$(yn test -w "$M")"
p ms_overwrite "$(yn sh -c "echo '{}' > $M")"
p ms_dropin "$(yn mkdir /etc/claude-code/managed-settings.d)"
p ms_bypass "$(jq -r '.permissions.disableBypassPermissionsMode' "$M")"
p ms_managed_hooks_only "$(jq -r '.allowManagedHooksOnly' "$M")"
p ms_hooks "$(jq -r '[.hooks.PreToolUse[].hooks[].command, .hooks.PostToolUse[].hooks[].command, .hooks.Stop[].hooks[].command] | join(",")' "$M")"
p ms_deny "$(jq -r '[.permissions.deny[] | select(. == "Edit(//etc/claude-code/**)" or . == "Edit(//opt/devlead/**)")] | length' "$M")"
p skill_sweep_execute "$(yn test -f /etc/claude-code/.claude/skills/sweep-execute/SKILL.md)"
p opt_writable "$(yn test -w /opt/devlead)"
p opt_touch "$(yn touch /opt/devlead/x)"
p opt_script_touch "$(yn touch /opt/devlead/scripts/x.sh)"
p opt_hook_append "$(yn sh -c 'echo x >> /opt/devlead/hooks/guard.sh')"
p writable_in_install "$(find /opt/devlead /etc/claude-code -writable 2>/dev/null | wc -l)"
p not_root_owned_in_install "$(find /opt/devlead /etc/claude-code ! -user root 2>/dev/null | wc -l)"
p scripts_link "$(readlink "$HOME/.devlead/scripts")"
p hooks_link "$(readlink "$HOME/.devlead/hooks")"
p link_replace "$(yn ln -sfn /tmp "$HOME/.devlead/scripts")"
p link_remove "$(yn rm -f "$HOME/.devlead/hooks")"
p devlead_rename "$(yn mv "$HOME/.devlead" "$HOME/.devlead-moved")"
p devlead_new_file "$(yn touch "$HOME/.devlead/secrets-allow")"
p bashrc_overwrite "$(yn sh -c "echo 'bash() { :; }' > $HOME/.bashrc")"
p bashrc_rename "$(yn mv "$HOME/.bashrc" "$HOME/.bashrc-moved")"
p links_after "$(readlink "$HOME/.devlead/scripts") $(readlink "$HOME/.devlead/hooks")"
p home_file "$(yn touch "$HOME/made-by-the-user")"
p claude_dir "$(yn touch "$HOME/.claude/probe")"
p state_dir "$(yn touch "$HOME/.devlead/reports/probe")"
bash "$HOME/.devlead/scripts/notify.sh" send info smoke-check "the smoke test ran" >/dev/null 2>&1
p notify_inbox "$(bash "$HOME/.devlead/scripts/notify.sh" list 2>/dev/null | grep -c 'smoke-check')"
p notify_env "$(stat -c '%u %a' "$HOME/.devlead/notify.env" 2>/dev/null)"
p ntfy_in_env "$(if [ -n "${DEVLEAD_NTFY_URL:-}${DEVLEAD_NTFY_TOKEN:-}" ]; then echo yes; else echo no; fi)"
p guard_self_config "$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/home/devlead/.devlead/scripts/merge.sh"},"cwd":"/home/devlead"}' | bash /opt/devlead/hooks/guard.sh 2>&1 >/dev/null | head -n 1 | cut -c1-28)"
for t in git gh jq yq shellcheck flock; do p "tool_$t" "$(yn command -v "$t")"; done
p yq_flavour "$(yq --version 2>&1 | grep -c mikefarah)"
p iptables_flush "$(yn iptables -F OUTPUT)"
p dns_example "$(yn getent ahostsv4 example.com)"
p egress_example "$(yn curl -fsS --max-time 10 -o /dev/null https://example.com)"
p direct_dns "$(yn timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/53')"
p egress_github "$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://api.github.com/ 2>/dev/null)"
PROBE_EOF

echo "=== inside the container, as the devlead user ==="
OUT="$(compose run --rm -T devlead bash -c "$PROBE" 2>"$SCRATCH/probe.err")"
rc=$?
check "the probe container ran" "$rc" "0"
[[ $rc -eq 0 ]] || tail -n 20 "$SCRATCH/probe.err"
v() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }

check "runs as the host UID" "$(v uid)" "$HOST_UID"
check "runs as the host GID" "$(v gid)" "$HOST_GID"
check "the UID is not root" "$(u="$(v uid)"; [[ -n "$u" && "$u" != 0 ]] && echo non-root || echo "root or unknown")" "non-root"
check "no effective capabilities" "$(v cap_eff)" "0000000000000000"
check "empty capability bounding set" "$(v cap_bnd)" "0000000000000000"
check "no_new_privs is set" "$(v no_new_privs)" "1"
check "Claude Code is the pinned version (S15)" "$(v claude_version)" "$WANT_CLAUDE_VERSION (Claude Code)"
check "DISABLE_AUTOUPDATER=1 (S15)" "$(v disable_autoupdater)" "1"
check "DEVLEAD_GUARD=1: guard.sh is on in every session" "$(v devlead_guard)" "1"
check "managed settings are root-owned" "$(v ms_owner)" "root:root"
check "managed settings are 0644" "$(v ms_mode)" "644"
check "managed settings are not writable by the user" "$(v ms_writable)" "no"
check "the user cannot overwrite managed settings" "$(v ms_overwrite)" "no"
check "the user cannot add a managed-settings.d drop-in" "$(v ms_dropin)" "no"
check "bypass permissions mode is disabled" "$(v ms_bypass)" "disable"
check "only managed hooks run" "$(v ms_managed_hooks_only)" "true"
check "managed hooks: guard, post-edit, gate-check from /opt/devlead" "$(v ms_hooks)" \
  "/bin/bash /opt/devlead/hooks/guard.sh,/bin/bash /opt/devlead/hooks/post-edit.sh,/bin/bash /opt/devlead/hooks/gate-check.sh"
check "deny rules cover /etc/claude-code and /opt/devlead" "$(v ms_deny)" "2"
check "DevLead's commands are installed as managed skills" "$(v skill_sweep_execute)" "yes"
check "/opt/devlead is not writable by the user" "$(v opt_writable)" "no"
check "the user cannot create files in /opt/devlead" "$(v opt_touch)" "no"
check "the user cannot add a script" "$(v opt_script_touch)" "no"
check "the user cannot change a hook" "$(v opt_hook_append)" "no"
check "nothing under /opt/devlead or /etc/claude-code is writable" "$(v writable_in_install)" "0"
check "everything under /opt/devlead and /etc/claude-code is root-owned" "$(v not_root_owned_in_install)" "0"
check "~/.devlead/scripts links to /opt/devlead/scripts" "$(v scripts_link)" "/opt/devlead/scripts"
check "~/.devlead/hooks links to /opt/devlead/hooks" "$(v hooks_link)" "/opt/devlead/hooks"
check "the user cannot replace the scripts link" "$(v link_replace)" "no"
check "the user cannot remove the hooks link" "$(v link_remove)" "no"
check "the user cannot rename ~/.devlead" "$(v devlead_rename)" "no"
check "the user cannot add files to ~/.devlead (secrets-allow)" "$(v devlead_new_file)" "no"
check "the user cannot overwrite ~/.bashrc" "$(v bashrc_overwrite)" "no"
check "the user cannot rename ~/.bashrc" "$(v bashrc_rename)" "no"
check "the links are unchanged afterwards" "$(v links_after)" "/opt/devlead/scripts /opt/devlead/hooks"
check "the user can create its own files in HOME" "$(v home_file)" "yes"
check "the user can write ~/.claude" "$(v claude_dir)" "yes"
check "the user can write the state subdirectories" "$(v state_dir)" "yes"
check "notify.sh writes ~/.devlead/inbox.tsv in the root-owned ~/.devlead" "$(v notify_inbox)" "1"
check "notify.env belongs to the user, mode 600" "$(v notify_env)" "$HOST_UID 600"
check "the ntfy settings are not in the session's environment" "$(v ntfy_in_env)" "no"
check "guard.sh blocks a write through ~/.devlead/scripts as self-config" "$(v guard_self_config)" "DevLead limit [self-config]:"
for t in git gh jq yq shellcheck flock; do
  check "$t is installed" "$(v "tool_$t")" "yes"
done
check "yq is mikefarah/yq" "$(v yq_flavour)" "1"
check "the user cannot change the firewall" "$(v iptables_flush)" "no"
check "DNS works for the user (through Docker's resolver)" "$(v dns_example)" "yes"
check "egress to a host outside the allowlist fails (example.com)" "$(v egress_example)" "no"
check "the user cannot reach an outside DNS server directly" "$(v direct_dns)" "no"
check "egress to api.github.com works" "$(v egress_github)" "200"

echo "=== the long-lived service ==="
if compose up -d --wait --wait-timeout 180 >"$SCRATCH/up.log" 2>&1; then
  cid="$(compose ps -q devlead)"
  check "the service is healthy" "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" "healthy"
  check "restart policy is unless-stopped" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null)" "unless-stopped"
  check "the main process runs as the host UID" \
    "$(compose exec -T devlead ps -o uid=,args= --ppid 1 2>/dev/null | awk '{$1=$1; print}')" "$HOST_UID sleep infinity"
  check "the healthcheck passes while the firewall holds" \
    "$(compose exec -T devlead /opt/devlead/docker/init-firewall.sh --check >/dev/null 2>&1; echo $?)" "0"
else
  tail -n 20 "$SCRATCH/up.log"
  check "the service starts and turns healthy" "no" "yes"
fi
compose down --volumes --remove-orphans >/dev/null 2>&1

echo "=== startup fails closed ==="
out="$(docker run --rm --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "without NET_ADMIN the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo "started (rc=0)")" "refused"
check "without NET_ADMIN the command never runs" "$(printf '%s\n' "$out" | grep -cx "$HOST_UID")" "0"
contains "without NET_ADMIN it says why" "$out" "the egress firewall could not be applied"

out="$(compose run --rm -T -e 'DEVLEAD_EGRESS_ALLOW=not_a_host!' devlead id -u 2>&1)"; rc=$?
check "a malformed DEVLEAD_EGRESS_ALLOW entry stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the malformed entry is named" "$out" "'not_a_host!' is not a valid host name"

out="$(docker run --rm --user "$HOST_UID" --cap-add NET_ADMIN --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "started as a non-root user, the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"

out="$(DOCKER_BUILDKIT=1 docker build -q --build-arg DEVLEAD_UID=0 -f "$REPO_ROOT/docker/Dockerfile" "$REPO_ROOT" 2>&1)"; rc=$?
check "the image refuses to build for UID 0" "$([[ $rc -ne 0 ]] && echo refused || echo built)" "refused"
[[ $rc -eq 0 && -n "$out" ]] && docker image rm -f "$out" >/dev/null 2>&1

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
