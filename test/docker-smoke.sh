#!/usr/bin/env bash
# docker-smoke.sh — builds the DevLead server image and checks its limits from
# inside a container (F1: S7-S10, S12, S15, S20; F2: S11, S16-S19; F3: S13,
# S14).
#
#   make docker-test
#
# NOT part of `make test`: it needs Docker and the network (the firewall
# resolves Anthropic and GitHub, the probe reaches api.github.com, and the
# clone of the enrolled repo comes from github.com: octocat/Hello-World, a
# small public repository, read without credentials).
#
# The Claude sessions below run against a small mock of the Messages API on
# 127.0.0.1 (ANTHROPIC_BASE_URL), so they exercise Claude Code's real settings,
# hooks and tool calls without a real token. The mock always answers the first
# turn with one Bash tool call (MOCK_CMD) and logs the tool result it gets back.
#
# SAFETY: dummy secrets only, written to a scratch env file outside the repo.
# No environment value is ever printed. The compose project, the image tag and
# the scratch directory are unique to this run and removed at the end; a
# running `devlead` project and its image are never touched.
# shellcheck disable=SC2088 # "~/..." in labels is display text, not a path
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WANT_CLAUDE_VERSION="2.1.326"
TEMPLATE="docker/devlead.env.example"

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
TZ=America/Bogota
DEVLEAD_MAX_SESSIONS_PER_DAY=50
DEVLEAD_WORKSPACE=/home/smoke/Work
DEVLEAD_REPOS=/home/smoke/Work/hello=octocat/Hello-World
DEVLEAD_LOOP_REPO=
DEVLEAD_GIT_NAME=Smoke Bot
DEVLEAD_GIT_EMAIL=smoke-bot@example.com
EOF
)
# The workspace path of this run: compose mounts the clones volume there.
WORKSPACE=/home/smoke/Work
CLONE="$WORKSPACE/hello"
# A stand-in for the host's ~/.devlead (S14): the state subdirectories and the
# inbox compose mounts, and decoys of what it must never mount.
HOST_STATE="$SCRATCH/host-devlead"
mkdir -p "$HOST_STATE"/{agenda,audit,decisions,journals,learn,outcomes,reports,run-state}
touch "$HOST_STATE/inbox.tsv" "$HOST_STATE/inbox.read.tsv"
( umask 077
  echo "github_pat_DECOY_host_token" > "$HOST_STATE/gh-token"
  echo "DEVLEAD_NTFY_URL=https://decoy.invalid/host-topic" > "$HOST_STATE/notify.env"
  echo "DEVLEAD_LOOP_CLAUDE_ARGS=--decoy" > "$HOST_STATE/loop.env" )
echo "DEVLEAD_STATE_DIR=$HOST_STATE" >> "$ENV_FILE"
# The image is built from this checkout's commit (doctor.sh's install stamp).
SOURCE_REV="$(git -C "$REPO_ROOT" rev-parse HEAD)"
# Interpolation values for compose.yaml, so neither a real .env in the repo
# nor the caller's shell decides what this run builds or reads.
COMPOSE_ENV="$SCRATCH/compose.env"
printf 'DEVLEAD_UID=%s\nDEVLEAD_GID=%s\nDEVLEAD_IMAGE=%s\nDEVLEAD_ENV_FILE=%s\nDEVLEAD_SOURCE_REV=%s\nDEVLEAD_WORKSPACE=%s\nDEVLEAD_STATE_DIR=%s\n' \
  "$HOST_UID" "$HOST_GID" "$IMAGE" "$ENV_FILE" "$SOURCE_REV" "$WORKSPACE" "$HOST_STATE" > "$COMPOSE_ENV"

# SERVICE_ENV, when set, replaces the env file (the F2 service section).
compose() {
  DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_IMAGE="$IMAGE" \
  DEVLEAD_ENV_FILE="${SERVICE_ENV:-$ENV_FILE}" DEVLEAD_SOURCE_REV="$SOURCE_REV" DEVLEAD_WORKSPACE="$WORKSPACE" \
  DEVLEAD_STATE_DIR="$HOST_STATE" \
    docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" \
      -p "$PROJECT" --env-file "$COMPOSE_ENV" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1
  docker image rm -f "$IMAGE" >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "=== the env template and compose's inputs ==="
check "$TEMPLATE exists" "$([[ -f "$REPO_ROOT/$TEMPLATE" ]] && echo yes || echo no)" "yes"
check "$TEMPLATE is not git-ignored" \
  "$(git -C "$REPO_ROOT" check-ignore -q "$TEMPLATE" && echo ignored || echo tracked)" "tracked"
check ".env (the secrets) is git-ignored" \
  "$(git -C "$REPO_ROOT" check-ignore -q .env && echo ignored || echo tracked)" "ignored"
_tpl="$(cat "$REPO_ROOT/$TEMPLATE" 2>/dev/null)"
for var in DEVLEAD_UID DEVLEAD_GID CLAUDE_CODE_OAUTH_TOKEN DEVLEAD_CLAUDE_TOKEN_ISSUED GH_TOKEN \
           DEVLEAD_CLAUDE_ACCOUNT_1 DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED \
           DEVLEAD_NTFY_URL DEVLEAD_NTFY_TOKEN DEVLEAD_NOTIFY_DETAIL DEVLEAD_LOOP_CLAUDE_ARGS \
           DEVLEAD_DISCOVER_CLAUDE_ARGS DEVLEAD_EGRESS_ALLOW TZ DEVLEAD_CRON_MORNING DEVLEAD_CRON_LOOP \
           DEVLEAD_CRON_FLEET DEVLEAD_CRON_DISCOVER DEVLEAD_CRON_POLL DEVLEAD_CRON_ENDOFDAY \
           DEVLEAD_MAX_SESSIONS_PER_DAY DEVLEAD_SESSION_TIMEOUT \
           DEVLEAD_AUDIT_RETENTION_DAYS DEVLEAD_WORKSPACE DEVLEAD_REPOS DEVLEAD_LOOP_REPO DEVLEAD_LOOP_PLAN \
           DEVLEAD_STATE_DIR DEVLEAD_GIT_NAME DEVLEAD_GIT_EMAIL; do
  check "the template lists $var" "$(grep -cE "^#?${var}=" <<<"$_tpl")" "1"
done
for line in "Contents        Read and write" "Pull requests   Read and write" \
            "Issues          Read and write" "Metadata        Read-only" \
            "Do NOT grant Workflows, Administration" "branch protection"; do
  contains "the template states the PAT rule: $line" "$_tpl" "$line"
done
check "the template leaves DEVLEAD_UID for you to fill in" "$(grep -cx 'DEVLEAD_UID=' <<<"$_tpl")" "1"
out="$(env -u DEVLEAD_UID DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_WORKSPACE="$WORKSPACE" DEVLEAD_STATE_DIR="$HOST_STATE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_UID (no silent 1000)" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"
contains "compose says what to set" "$out" "DEVLEAD_UID"
out="$(env -u DEVLEAD_GID DEVLEAD_UID="$HOST_UID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_WORKSPACE="$WORKSPACE" DEVLEAD_STATE_DIR="$HOST_STATE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_GID" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"
out="$(env -u DEVLEAD_WORKSPACE DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_STATE_DIR="$HOST_STATE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_WORKSPACE" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"
contains "compose says what to set (workspace)" "$out" "DEVLEAD_WORKSPACE"
out="$(env -u DEVLEAD_STATE_DIR DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_WORKSPACE="$WORKSPACE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_STATE_DIR" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"
contains "compose says what to set (state)" "$out" "DEVLEAD_STATE_DIR"
_mounts="$(DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_WORKSPACE="$WORKSPACE" DEVLEAD_STATE_DIR="$HOST_STATE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config --format json 2>/dev/null \
  | jq -r '.services.devlead.volumes[] | select(.type == "bind" and (.target | startswith("/home/devlead/.devlead/"))) | .source' | sed "s|^$HOST_STATE/||" | sort | paste -sd, -)"
check "compose mounts only the state subdirectories and the inbox of ~/.devlead (S14)" "$_mounts" \
  "agenda,audit,decisions,inbox.read.tsv,inbox.tsv,journals,learn,outcomes,reports,run-state"
_planbind="$(DEVLEAD_UID="$HOST_UID" DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" DEVLEAD_WORKSPACE="$WORKSPACE" DEVLEAD_STATE_DIR="$HOST_STATE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config --format json 2>/dev/null \
  | jq -c '[.services.devlead.volumes[] | select(.type == "bind" and (.target | startswith("/home/devlead/") | not)) | [.source, .target, .read_only]]')"
check "the only other bind: the loop's plan stand-in, read-only, at its staging path (L21 A2)" "$_planbind" \
  "[[\"$REPO_ROOT/docker/no-loop-plan.yml\",\"/run/devlead/host-plan.yml\",true]]"

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
# guard <json payload> [env assignments...] -> first line of guard.sh's stderr, or "allowed"
guard() {
  local payload="$1" err; shift
  err="$(printf '%s' "$payload" | env "$@" bash /opt/devlead/hooks/guard.sh 2>&1 >/dev/null)" && { echo allowed; return; }
  printf '%s' "$err" | head -n 1 | cut -c1-28
}
bashcall() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp/work"}'; }
M=/etc/claude-code/managed-settings.json
C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p /tmp/work && git -C /tmp/work init -q -b feat/work && git -C /tmp/work -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

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
p ms_mcp "$(jq -c '[.allowManagedMcpServersOnly, .allowedMcpServers]' "$M")"
p ms_env "$(jq -c '.env | [.DEVLEAD_GUARD, .BASH_ENV, .ENV, .NODE_OPTIONS, .LD_PRELOAD, .PROMPT_COMMAND]' "$M")"
p skill_sweep_execute "$(yn test -f /etc/claude-code/.claude/skills/sweep-execute/SKILL.md)"
p opt_writable "$(yn test -w /opt/devlead)"
p opt_touch "$(yn touch /opt/devlead/x)"
p opt_script_touch "$(yn touch /opt/devlead/scripts/x.sh)"
p opt_hook_append "$(yn sh -c 'echo x >> /opt/devlead/hooks/guard.sh')"
p writable_in_install "$(find /opt/devlead /etc/claude-code /etc/devlead -writable 2>/dev/null | wc -l)"
p not_root_owned_in_install "$(find /opt/devlead /etc/claude-code /etc/devlead ! -user root 2>/dev/null | wc -l)"
p scripts_link "$(readlink "$HOME/.devlead/scripts")"
p hooks_link "$(readlink "$HOME/.devlead/hooks")"
p link_replace "$(yn ln -sfn /tmp "$HOME/.devlead/scripts")"
p link_remove "$(yn rm -f "$HOME/.devlead/hooks")"
p devlead_rename "$(yn mv "$HOME/.devlead" "$HOME/.devlead-moved")"
p devlead_new_file "$(yn touch "$HOME/.devlead/secrets-allow")"
p bashrc_overwrite "$(yn sh -c "echo 'bash() { :; }' > $HOME/.bashrc")"
p bashrc_rename "$(yn mv "$HOME/.bashrc" "$HOME/.bashrc-moved")"
p links_after "$(readlink "$HOME/.devlead/scripts") $(readlink "$HOME/.devlead/hooks")"
p home_owner "$(stat -c '%U:%G %a' "$HOME")"
p home_file "$(yn touch "$HOME/made-by-the-user")"
p home_claude_json "$(yn sh -c "echo '{}' > $HOME/.claude.json")"
p cache_dir "$(yn touch "$HOME/.cache/probe")"
p state_dir "$(yn touch "$HOME/.devlead/reports/probe")"
# Claude Code's config dir: root-owned; only its runtime state is the user's.
p cc_dir "$C $(stat -c '%U:%G %a' "$C")"
p cc_settings_write "$(yn sh -c "echo '{\"env\":{\"DEVLEAD_GUARD\":\"0\"}}' > $C/settings.json")"
p cc_settings_rename "$(yn mv "$C/settings.json" "$C/settings.json.x")"
p cc_settings_local "$(yn sh -c "echo '{}' > $C/settings.local.json")"
p cc_claude_md "$(yn sh -c "echo PLANTED >> $C/CLAUDE.md")"
p cc_remote_settings "$(yn sh -c "echo '{}' > $C/remote-settings.json")"
p cc_new_skill "$(yn mkdir "$C/skills/planted")"
p cc_new_agent "$(yn touch "$C/agents/planted.md")"
p cc_new_rule "$(yn sh -c "mkdir -p $C/rules && touch $C/rules/planted.md")"
p cc_new_top "$(yn touch "$C/keybindings.json")"
p cc_settings_after "$(cat "$C/settings.json") $(stat -c %U "$C/settings.json")"
p cc_runtime "$(yn touch "$C/projects/probe")"
p cc_state_file "$(stat -c '%U %a' "$C/.claude.json")"
p cc_state_write "$(yn sh -c "echo '{\"env\":{\"VF_PROBE\":\"x\"}}' > $C/.claude.json")"
# git: one root-owned global config; nothing the user can write is read.
p git_global "$GIT_CONFIG_GLOBAL $(stat -c '%U %a' "$GIT_CONFIG_GLOBAL") nosystem=${GIT_CONFIG_NOSYSTEM:-}"
p git_config_global_set "$(yn git config --global core.fsmonitor 'touch /tmp/mark-fsmonitor')"
p git_dotfile "$(yn sh -c "printf '[core]\n\tfsmonitor = touch /tmp/mark-fsmonitor\n' > $HOME/.gitconfig")"
p git_xdg "$(yn mkdir -p "$HOME/.config/git")"
git -C /tmp/work status >/dev/null 2>&1
p git_fsmonitor_ran "$(yn test -e /tmp/mark-fsmonitor)"
p git_helper "$(git config --get-all credential.https://github.com.helper | tail -n 1)"
p marker "$(stat -c '%U %a' /etc/devlead/server-mode)"
p marker_remove "$(yn rm -f /etc/devlead/server-mode)"
bash "$HOME/.devlead/scripts/notify.sh" send info smoke-check "the smoke test ran" >/dev/null 2>&1
p notify_inbox "$(bash "$HOME/.devlead/scripts/notify.sh" list 2>/dev/null | grep -c 'smoke-check')"
p notify_env "$(stat -c '%u %a' "$HOME/.devlead/notify.env" 2>/dev/null)"
p ntfy_in_env "$(if [ -n "${DEVLEAD_NTFY_URL:-}${DEVLEAD_NTFY_TOKEN:-}" ]; then echo yes; else echo no; fi)"
p guard_self_config "$(guard '{"tool_name":"Write","tool_input":{"file_path":"/home/devlead/.devlead/scripts/merge.sh"},"cwd":"/home/devlead"}')"
p guard_off_env "$(guard "$(bashcall 'printenv GH_TOKEN')" DEVLEAD_GUARD=0)"
p guard_unset_env "$(guard "$(bashcall 'printenv GH_TOKEN')" -u DEVLEAD_GUARD)"
p guard_credential_fill "$(guard "$(bashcall "printf 'protocol=https\nhost=github.com\n' | git credential fill")")"
p guard_push "$(guard "$(bashcall 'git push -u origin feat/x')")"
for t in git gh jq yq shellcheck flock; do p "tool_$t" "$(yn command -v "$t")"; done
p yq_flavour "$(yq --version 2>&1 | grep -c mikefarah)"
p iptables_flush "$(yn iptables -F OUTPUT)"
# Names: the user resolves only the allowlist, from /etc/hosts.
p dns_allowed "$(yn getent ahostsv4 api.github.com) $(yn getent ahostsv4 api.anthropic.com)"
p dns_other "$(yn getent ahostsv4 example.com)"
p dns_resolver "$(yn timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.11/53')"
p direct_dns "$(yn timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/53')"
p egress_ip "$(yn curl -fsS --max-time 10 -o /dev/null https://1.1.1.1/)"
p egress_github "$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://api.github.com/ 2>/dev/null)"
p gh_reaches "$(gh api /zen 2>&1 | grep -c 'HTTP 401')"
p claude_reaches "$(cd /tmp/work && timeout 90 claude -p hi </dev/null 2>&1 | grep -c '401')"
# The real API refused the dummy token, so the wrapper rested the single
# token's account until a restart (S22). The probe's later sessions use the
# mock: clear the mark, as a restart after renewing the token would.
p reach_mark "$(grep -v '^#' /var/lib/devlead/accounts.tsv | cut -f1-3,7 | tr '\t' '|')"
head -n 1 /var/lib/devlead/accounts.tsv > /tmp/marks-header && cat /tmp/marks-header > /var/lib/devlead/accounts.tsv

# --- F2: the runner's files and limits (S11, S16-S18) -------------------------
p supercronic "$(supercronic -version 2>&1 | head -n 1)"
p crontab_meta "$(stat -c '%U %a' /etc/devlead/crontab /etc/devlead/runner.conf /etc/devlead/install-stamp | paste -sd, -)"
p crontab_write "$(yn sh -c 'echo "* * * * * id" >> /etc/devlead/crontab')"
p conf_write "$(yn sh -c 'echo MAX_SESSIONS_PER_DAY=999 >> /etc/devlead/runner.conf')"
p runner_state_dir "$(stat -c '%U:%G %a' /var/lib/devlead)"
p ledger_meta "$(stat -c '%u %a' /var/lib/devlead/sessions.tsv)"
p locks_meta "$(stat -c '%U %a' /var/lib/devlead/session.lock /var/lib/devlead/job.lock | paste -sd, -)"
p ledger_remove "$(yn rm -f /var/lib/devlead/sessions.tsv)"
p ledger_replace "$(yn mv /var/lib/devlead/sessions.tsv /var/lib/devlead/old.tsv)"
p state_new_file "$(yn touch /var/lib/devlead/x)"
p ledger_header "$(head -n 1 /var/lib/devlead/sessions.tsv | cut -c1-24)"
p ledger_volume "$(awk '$5 == "/var/lib/devlead" {print "mounted"}' /proc/self/mountinfo)"
p job_limits "$(grep -E '^JOB_' /etc/devlead/runner.conf | paste -sd, -)"
p pause_create "$(yn touch "$HOME/.devlead/PAUSE")"
p tz_offset "$(date +%z)"
p doctor_report "$(bash "$HOME/.devlead/scripts/doctor.sh" 2>&1 | grep -E '^(STATUS|MATCHES|NOTE)' | paste -sd'|' -)"
p doctor_rc "$(bash "$HOME/.devlead/scripts/doctor.sh" >/dev/null 2>&1; echo $?)"
p refuse_resume "$(claude --resume x -p hi </dev/null >/dev/null 2>&1; echo $?)"
p refuse_continue "$(claude -c -p hi </dev/null >/dev/null 2>&1; echo $?)"
p refuse_bg "$(claude --bg -p hi </dev/null >/dev/null 2>&1; echo $?)"

# --- Claude sessions against the mock ----------------------------------------
cat > /tmp/mock.js <<'JS'
const http = require('http'), fs = require('fs');
const log = s => fs.appendFileSync(process.env.MOCK_LOG, s + '\n');
function reply(res, stream, blocks, stop) {
  const msg = { id: 'msg_mock', type: 'message', role: 'assistant', model: 'mock', content: [],
                stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } };
  if (!stream) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ...msg, content: blocks, stop_reason: stop }));
  }
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  const ev = (e, d) => res.write(`event: ${e}\ndata: ${JSON.stringify(d)}\n\n`);
  ev('message_start', { type: 'message_start', message: msg });
  blocks.forEach((b, i) => {
    if (b.type === 'tool_use') {
      ev('content_block_start', { type: 'content_block_start', index: i, content_block: { ...b, input: {} } });
      ev('content_block_delta', { type: 'content_block_delta', index: i, delta: { type: 'input_json_delta', partial_json: JSON.stringify(b.input) } });
    } else {
      ev('content_block_start', { type: 'content_block_start', index: i, content_block: { type: 'text', text: '' } });
      ev('content_block_delta', { type: 'content_block_delta', index: i, delta: { type: 'text_delta', text: b.text } });
    }
    ev('content_block_stop', { type: 'content_block_stop', index: i });
  });
  ev('message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 1 } });
  ev('message_stop', { type: 'message_stop' });
  res.end();
}
http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    if (!/\/v1\/messages(\?|$)/.test(req.url)) { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{}'); }
    let j = {}; try { j = JSON.parse(body); } catch (e) {}
    if (body.includes('PLANTED')) log('PLANTED_IN_PROMPT');
    const last = (j.messages || []).slice(-1)[0] || {};
    const results = Array.isArray(last.content) ? last.content.filter(c => c.type === 'tool_result') : [];
    if (results.length) { results.forEach(r => log('TOOL_RESULT ' + JSON.stringify(r.content))); return reply(res, j.stream, [{ type: 'text', text: 'done' }], 'end_turn'); }
    if ((j.tools || []).some(t => t.name === 'Bash')) {
      const calls = [{ type: 'tool_use', id: 'toolu_mock', name: 'Bash', input: { command: process.env.MOCK_CMD, description: 'probe' } }];
      if (process.env.MOCK_WRITE) calls.push({ type: 'tool_use', id: 'toolu_write', name: 'Write', input: { file_path: process.env.MOCK_WRITE, content: process.env.MOCK_WRITE_CONTENT || '' } });
      return reply(res, j.stream, calls, 'tool_use');
    }
    reply(res, j.stream, [{ type: 'text', text: 'ok' }], 'end_turn');
  });
}).listen(8099, '127.0.0.1', () => log('LISTEN'));
JS
# sess <label> <command for the mock to run> — SESS_ENV and SESS_ARGS add
# launch variables and claude flags, SESS_BIN picks the binary (default: the
# `claude` on PATH, the image's wrapper). Prints the logged tool result.
REAL_CLAUDE=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
sess() {
  local label="$1" log="/tmp/mock-$1.log" i mp
  : > "$log"
  MOCK_LOG="$log" MOCK_CMD="$2" node /tmp/mock.js & mp=$!
  for i in $(seq 1 30); do grep -q LISTEN "$log" && break; sleep 0.2; done
  ( cd /tmp/work && env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL=http://127.0.0.1:8099 \
      ANTHROPIC_API_KEY=sk-ant-api03-DUMMY "${SESS_ENV[@]}" \
      timeout 120 "${SESS_BIN:-claude}" -p probe --permission-mode acceptEdits --allowedTools Bash "${SESS_ARGS[@]}" \
      </dev/null >"/tmp/out-$label.txt" 2>&1 )
  kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null
  grep -m1 '^TOOL_RESULT ' "$log" | cut -c13-200
}
printf '%s\n' 'case "$0" in */guard.sh) exit 0 ;; esac' > /tmp/benv
# The wrapper refuses --settings, so the two sessions that pass overrides with
# it call the real binary: they test the managed env and the marker, not the
# wrapper.
SESS_BIN="$REAL_CLAUDE"
SESS_ENV=(DEVLEAD_GUARD=0 BASH_ENV=/tmp/benv)
SESS_ARGS=(--settings '{"env":{"DEVLEAD_GUARD":"0","BASH_ENV":"/tmp/benv","ENV":"/tmp/benv","NODE_OPTIONS":"--require=/tmp/none.js","LD_PRELOAD":"/tmp/none.so","PROMPT_COMMAND":"touch /tmp/mark-pc","CLAUDE_CODE_DISABLE_AUTO_MEMORY":"0"}}')
p s_env "$(sess env 'echo "g=$DEVLEAD_GUARD b=[$BASH_ENV] e=[$ENV] n=[$NODE_OPTIONS] l=[$LD_PRELOAD] p=[$PROMPT_COMMAND] m=$CLAUDE_CODE_DISABLE_AUTO_MEMORY"')"
# B1 end to end: session 1 tries to plant a guard override for later sessions;
# session 2, started with the override in its environment and flags, still
# gets the guard's denial.
SESS_BIN=claude; SESS_ENV=(); SESS_ARGS=()
p s_plant "$(sess plant "node -e 'require(\"fs\").writeFileSync((process.env.CLAUDE_CONFIG_DIR||process.env.HOME+\"/.claude\")+\"/settings.json\", JSON.stringify({env:{DEVLEAD_GUARD:\"0\",BASH_ENV:\"/tmp/benv\"}}))' 2>&1 | grep -o EACCES | head -n 1")"
p s_plant_after "$(cat "$C/settings.json")"
SESS_BIN="$REAL_CLAUDE"
SESS_ENV=(DEVLEAD_GUARD=0 BASH_ENV=/tmp/benv)
SESS_ARGS=(--settings '{"env":{"DEVLEAD_GUARD":"0","BASH_ENV":"/tmp/benv"}}')
p s_guarded "$(sess guarded 'printenv GH_TOKEN | wc -c')"
SESS_BIN=claude; SESS_ENV=(); SESS_ARGS=()

# The `claude` on PATH is the image's wrapper: it always loads only the user
# and managed settings, and refuses flags that would load anything else.
p claude_on_path "$(command -v claude) $(type -ap claude | wc -l) $(stat -c '%U %a' "$(command -v claude)") $(grep -q 'DevLead server image' "$(command -v claude)" && echo 1 || echo 0)"
p claude_wrapper_write "$(yn sh -c 'echo x >> /usr/local/bin/claude')"
refused() { local out rc; out="$(claude "$@" -p hi </dev/null 2>&1)"; rc=$?; echo "rc=$rc $(printf '%s' "$out" | grep -c 'loads only the user and managed settings')"; }
p refuse_sources "$(refused --setting-sources project,local)"
p refuse_sources_eq "$(refused --setting-sources=user,project,local)"
p refuse_settings "$(refused --settings '{}')"
p refuse_settings_eq "$(refused --settings=/tmp/x.json)"
p s_cmdline "$(sess cmdline 'p=$PPID; while [ "$p" -gt 1 ]; do case "$(readlink /proc/$p/exe)" in */claude.exe) tr "\0" " " < /proc/$p/cmdline | cut -d" " -f2-; break;; esac; p=$(cut -d" " -f4 /proc/$p/stat); done')"

# B2 through the writable clone: session 1 plants repo-level settings (local
# or shared), session 2 on the same clone must not run any of it.
mkdir -p /tmp/work/.claude
plant() { # plant <label> <file> <json>
  local b64; b64="$(printf '%s' "$3" | base64 -w0)"
  sess "$1" "node -e 'require(\"fs\").writeFileSync(\"$2\", Buffer.from(\"$b64\", \"base64\")); console.log(\"planted\")'"
}
rm -f /tmp/mark-akh /tmp/mark-gitenv
p s_repo_akh "$(plant repo-akh-1 .claude/settings.local.json '{"apiKeyHelper":"touch /tmp/mark-akh; echo sk-ant-api03-DUMMY"}') $(sess repo-akh-2 'echo second') akh=$(yn test -e /tmp/mark-akh)"
rm -f /tmp/work/.claude/settings.local.json /tmp/mark-akh
p s_repo_akh_shared "$(plant repo-akh-3 .claude/settings.json '{"apiKeyHelper":"touch /tmp/mark-akh; echo sk-ant-api03-DUMMY"}') $(sess repo-akh-4 'echo second') akh=$(yn test -e /tmp/mark-akh)"
rm -f /tmp/work/.claude/settings.json
p s_repo_git "$(plant repo-git-1 .claude/settings.local.json '{"env":{"GIT_CONFIG_COUNT":"1","GIT_CONFIG_KEY_0":"core.fsmonitor","GIT_CONFIG_VALUE_0":"touch /tmp/mark-gitenv; false"}}') $(sess repo-git-2 'git status >/dev/null 2>&1; echo "count=[$GIT_CONFIG_COUNT]"') git=$(yn test -e /tmp/mark-gitenv)"
rm -f /tmp/work/.claude/settings.local.json

# Claude Code reads an env block from its state file (.claude.json), even under
# --setting-sources user, so the file is root-owned. env, apiKeyHelper and MCP
# servers written there must stay out of the next session.
node -e 'const f=(process.env.CLAUDE_CONFIG_DIR||process.env.HOME)+"/.claude.json";let j={};try{j=JSON.parse(require("fs").readFileSync(f))}catch(e){};const s={type:"stdio",command:"sh",args:["-c","touch /tmp/mark-mcp; sleep 2"]};j.mcpServers={planted:s};j.env={VF_PROBE:"from-state-file",GIT_CONFIG_COUNT:"1",GIT_CONFIG_KEY_0:"core.fsmonitor",GIT_CONFIG_VALUE_0:"touch /tmp/mark-gitenv-json; false"};j.apiKeyHelper="touch /tmp/mark-akh-json; echo sk-ant-api03-DUMMY";j.projects=j.projects||{};j.projects["/tmp/work"]=Object.assign(j.projects["/tmp/work"]||{},{mcpServers:{planted:s}});require("fs").writeFileSync(f,JSON.stringify(j))' 2>/dev/null
p s_state "$(sess state 'git status >/dev/null 2>&1; echo "vf=[$VF_PROBE]"') mcp=$(yn test -e /tmp/mark-mcp) akh=$(yn test -e /tmp/mark-akh-json) git=$(yn test -e /tmp/mark-gitenv-json)"

# --- F3: the clones (S13) ----------------------------------------------------
WS=/home/smoke/Work
p ws_meta "$(stat -c '%U:%G %a' "$WS")"
p ws_new_dir "$(yn mkdir "$WS/stray")"
p clone_dir_meta "$(stat -c '%u %a' "$WS/hello")"
p repos_meta "$(stat -c '%U %a' /etc/devlead/repos)"
p repos_lines "$(grep -v '^#' /etc/devlead/repos | tr '\t' ' ')"
p fleet_list "$(cat "$HOME/.devlead/autonomous-repos")"
p fleet_list_meta "$(stat -c '%U %a' "$HOME/.devlead/autonomous-repos")"
p fleet_list_write "$(yn sh -c "echo /etc >> $HOME/.devlead/autonomous-repos")"
p fleet_list_replace "$(yn mv "$HOME/.devlead/autonomous-repos" "$HOME/.devlead/x")"
p sync1 "$(/opt/devlead/docker/sync-repos.sh --all 2>/dev/null | cut -f1,2)"
p sync_head "$(git -C "$WS/hello" rev-parse HEAD) $(git -C "$WS/hello" ls-remote origin HEAD | cut -f1)"
p sync_branch "$(git -C "$WS/hello" rev-parse --abbrev-ref HEAD) $(git -C "$WS/hello" ls-remote --symref origin HEAD | sed -n 's|^ref: refs/heads/\([^[:space:]]*\).*|\1|p')"
p sync_toplevel "$(git -C "$WS/hello/" rev-parse --show-toplevel)"
# A session plants an fsmonitor and a hook in the clone; the next sync drops
# them before git reads the clone again.
git -C "$WS/hello" config core.fsmonitor 'touch /tmp/mark-clone-fsmonitor; false'
mkdir -p "$WS/hello/.git/hooks" && printf '#!/bin/sh\ntouch /tmp/mark-clone-hook\n' > "$WS/hello/.git/hooks/post-checkout" && chmod +x "$WS/hello/.git/hooks/post-checkout"
echo PLANTED > "$WS/hello/README"
rm -f /tmp/mark-clone-fsmonitor /tmp/mark-clone-hook
p sync2 "$(/opt/devlead/docker/sync-repos.sh "$WS/hello" 2>/dev/null | cut -f1)"
git -C "$WS/hello" status >/dev/null 2>&1
p clone_planted_ran "$(yn test -e /tmp/mark-clone-fsmonitor) $(yn test -e /tmp/mark-clone-hook)"
p clone_readme "$(grep -c PLANTED "$WS/hello/README")"
p sync_stray "$(/opt/devlead/docker/sync-repos.sh /home/devlead 2>/dev/null | cut -f1,3)"

# --- F3: the host's state (S14) and the commits' author ------------------------
D="$HOME/.devlead"
p host_decoys "$(yn test -e "$D/gh-token") $(yn test -e "$D/loop.env") $(grep -c decoy.invalid "$D/notify.env" 2>/dev/null || echo 0)"
p state_owners "$(stat -c %u "$D/agenda" "$D/decisions" "$D/inbox.tsv" | sort -u | paste -sd' ' -)"
p learn_ro "$(yn touch "$D/learn/planted")"
( cd "$WS/hello" && bash "$D/scripts/decisions.sh" record probe "the server's key" "same path as on the host" >/dev/null 2>&1 )
p ident "$(git -C "$WS/hello" config user.name)|$(git -C "$WS/hello" config user.email)"
p ident_meta "$(stat -c '%U %a' /etc/devlead/git-identity)"
p ident_write "$(yn sh -c 'echo "[user]" >> /etc/devlead/git-identity')"
p ident_override "$(yn git config --global user.email evil@example.com)"
git -C "$WS/hello" -c core.hooksPath=/dev/null commit -q --allow-empty -m probe >/dev/null 2>&1
p commit_author "$(git -C "$WS/hello" log -1 --format='%an <%ae>|%cn <%ce>')"
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
check "DEVLEAD_GUARD=1 in the container's environment" "$(v devlead_guard)" "1"
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
check "only managed MCP servers, and none of them" "$(v ms_mcp)" '[true,[]]'
check "managed env pins the guard and the shell/loader variables" "$(v ms_env)" '["1","","","","",""]'
check "DevLead's commands are installed as managed skills" "$(v skill_sweep_execute)" "yes"
check "/opt/devlead is not writable by the user" "$(v opt_writable)" "no"
check "the user cannot create files in /opt/devlead" "$(v opt_touch)" "no"
check "the user cannot add a script" "$(v opt_script_touch)" "no"
check "the user cannot change a hook" "$(v opt_hook_append)" "no"
check "nothing under /opt/devlead, /etc/claude-code or /etc/devlead is writable" "$(v writable_in_install)" "0"
check "everything under /opt/devlead, /etc/claude-code and /etc/devlead is root-owned" "$(v not_root_owned_in_install)" "0"
check "~/.devlead/scripts links to /opt/devlead/scripts" "$(v scripts_link)" "/opt/devlead/scripts"
check "~/.devlead/hooks links to /opt/devlead/hooks" "$(v hooks_link)" "/opt/devlead/hooks"
check "the user cannot replace the scripts link" "$(v link_replace)" "no"
check "the user cannot remove the hooks link" "$(v link_remove)" "no"
check "the user cannot rename ~/.devlead" "$(v devlead_rename)" "no"
check "the user cannot add files to ~/.devlead (secrets-allow)" "$(v devlead_new_file)" "no"
check "the user cannot overwrite ~/.bashrc" "$(v bashrc_overwrite)" "no"
check "the user cannot rename ~/.bashrc" "$(v bashrc_rename)" "no"
check "the links are unchanged afterwards" "$(v links_after)" "/opt/devlead/scripts /opt/devlead/hooks"
check "HOME is root-owned 0755" "$(v home_owner)" "root:root 755"
check "the user cannot create files in HOME" "$(v home_file)" "no"
check "the user cannot create ~/.claude.json in HOME" "$(v home_claude_json)" "no"
check "the user can write ~/.cache" "$(v cache_dir)" "yes"
check "the user can write the state subdirectories" "$(v state_dir)" "yes"
check "CLAUDE_CONFIG_DIR is ~/.claude, root-owned 0755" "$(v cc_dir)" "/home/devlead/.claude root:root 755"
check "the user cannot write ~/.claude/settings.json" "$(v cc_settings_write)" "no"
check "the user cannot rename ~/.claude/settings.json" "$(v cc_settings_rename)" "no"
check "the user cannot write ~/.claude/settings.local.json" "$(v cc_settings_local)" "no"
check "the user cannot write ~/.claude/CLAUDE.md" "$(v cc_claude_md)" "no"
check "the user cannot plant a cached server policy (remote-settings.json)" "$(v cc_remote_settings)" "no"
check "the user cannot add a skill" "$(v cc_new_skill)" "no"
check "the user cannot add an agent" "$(v cc_new_agent)" "no"
check "the user cannot add rules" "$(v cc_new_rule)" "no"
check "the user cannot add any other config file" "$(v cc_new_top)" "no"
check "~/.claude/settings.json is still the root-owned {}" "$(v cc_settings_after)" "{} root"
check "Claude Code's runtime state stays writable (projects/)" "$(v cc_runtime)" "yes"
check "Claude Code's state file (.claude.json) is root-owned 0644" "$(v cc_state_file)" "root 644"
check "git reads one root-owned global config, and no system one" "$(v git_global)" "/etc/devlead/gitconfig root 644 nosystem=1"
check "git config --global cannot be changed" "$(v git_config_global_set)" "no"
check "the user cannot create ~/.gitconfig" "$(v git_dotfile)" "no"
check "the user cannot create ~/.config/git" "$(v git_xdg)" "no"
check "no planted fsmonitor runs on git status" "$(v git_fsmonitor_ran)" "no"
check "git authenticates to GitHub through gh" "$(v git_helper)" "!/usr/local/bin/gh auth git-credential"
check "the server-mode marker is root-owned 0644" "$(v marker)" "root 644"
check "the user cannot remove the server-mode marker" "$(v marker_remove)" "no"
check "notify.sh writes ~/.devlead/inbox.tsv in the root-owned ~/.devlead" "$(v notify_inbox)" "1"
check "notify.env belongs to the user, mode 600" "$(v notify_env)" "$HOST_UID 600"
check "the ntfy settings are not in the session's environment" "$(v ntfy_in_env)" "no"
check "guard.sh blocks a write through ~/.devlead/scripts as self-config" "$(v guard_self_config)" "DevLead limit [self-config]:"
check "guard.sh denies printenv GH_TOKEN with DEVLEAD_GUARD=0 (server marker)" "$(v guard_off_env)" "DevLead limit [secrets]: the"
check "guard.sh denies printenv GH_TOKEN with DEVLEAD_GUARD unset (server marker)" "$(v guard_unset_env)" "DevLead limit [secrets]: the"
check "guard.sh denies git credential fill" "$(v guard_credential_fill)" "DevLead limit [secrets]: the"
check "guard.sh still allows git push" "$(v guard_push)" "allowed"
for t in git gh jq yq shellcheck flock; do
  check "$t is installed" "$(v "tool_$t")" "yes"
done
check "yq is mikefarah/yq" "$(v yq_flavour)" "1"
check "the user cannot change the firewall" "$(v iptables_flush)" "no"
check "the user resolves allowlisted names (from /etc/hosts)" "$(v dns_allowed)" "yes yes"
check "the user cannot resolve a name outside the allowlist" "$(v dns_other)" "no"
check "the user cannot reach Docker's resolver" "$(v dns_resolver)" "no"
check "the user cannot reach an outside DNS server directly" "$(v direct_dns)" "no"
check "egress to an address outside the allowlist fails" "$(v egress_ip)" "no"
check "egress to api.github.com works" "$(v egress_github)" "200"
check "gh reaches GitHub (dummy token: HTTP 401)" "$(v gh_reaches)" "1"
check "claude reaches the Anthropic API (dummy token: 401)" "$(v claude_reaches)" "1"
check "the API's refusal of the dummy token rests the account until a restart (S22, the real API's answer)" "$(v reach_mark)" "default|-|auth|auth"
check "settings env cannot change the pinned variables in a session" "$(v s_env)" \
  '"g=1 b=[] e=[] n=[] l=[] p=[] m=1"'
check "session 1 cannot plant a guard override (EACCES)" "$(v s_plant)" '"EACCES"'
check "the planted override never landed" "$(v s_plant_after)" "{}"
contains "session 2 with DEVLEAD_GUARD=0 and BASH_ENV still gets the guard's denial" "$(v s_guarded)" 'DevLead limit [secrets]'
check "claude on PATH is the root-owned wrapper, and the only one" "$(v claude_on_path)" "/usr/local/bin/claude 1 root 755 1"
check "the user cannot change the wrapper" "$(v claude_wrapper_write)" "no"
check "the wrapper refuses --setting-sources project,local" "$(v refuse_sources)" "rc=2 1"
check "the wrapper refuses --setting-sources=user,project,local" "$(v refuse_sources_eq)" "rc=2 1"
check "the wrapper refuses --settings <json>" "$(v refuse_settings)" "rc=2 1"
check "the wrapper refuses --settings=<file>" "$(v refuse_settings_eq)" "rc=2 1"
contains "every session runs with --setting-sources user (the session's own command line)" "$(v s_cmdline)" '"--setting-sources user -p probe'
check "repo settings.local.json apiKeyHelper planted by session 1 does not run in session 2" "$(v s_repo_akh)" '"planted" "second" akh=no'
check "repo settings.json apiKeyHelper planted by session 1 does not run in session 2" "$(v s_repo_akh_shared)" '"planted" "second" akh=no'
check "repo settings env (GIT_CONFIG_*) planted by session 1 does not reach session 2" "$(v s_repo_git)" '"planted" "count=[]" git=no'
check "the user cannot write .claude.json" "$(v cc_state_write)" "no"
check "env, apiKeyHelper and MCP servers aimed at .claude.json stay out of the next session" "$(v s_state)" '"vf=[]" mcp=no akh=no git=no'
# F2
check "supercronic is installed, the pinned version" "$(v supercronic)" "v0.2.51"
check "crontab, runner.conf and the install stamp are root's, 0644" "$(v crontab_meta)" "root 644,root 644,root 644"
check "the user cannot change the schedule" "$(v crontab_write)" "no"
check "the user cannot change the limits" "$(v conf_write)" "no"
check "/var/lib/devlead is root's" "$(v runner_state_dir)" "root:root 755"
check "the session ledger is the user's, 0600" "$(v ledger_meta)" "$HOST_UID 600"
check "the lock files are root's" "$(v locks_meta)" "root 644,root 644"
check "the user cannot remove the ledger" "$(v ledger_remove)" "no"
check "the user cannot replace the ledger" "$(v ledger_replace)" "no"
check "the user cannot add files to /var/lib/devlead" "$(v state_new_file)" "no"
check "the ledger starts with root's header" "$(v ledger_header)" "# DevLead session ledger"
check "/var/lib/devlead is a volume of its own (L18)" "$(v ledger_volume)" "mounted"
check "the job limits have their defaults" "$(v job_limits)" "JOB_TIMEOUT=4h,JOB_KILL_AFTER=30s,JOB_LOCK_WAIT=4h"
check "the user cannot create the pause file" "$(v pause_create)" "no"
check "TZ from the env file is a real zone (tzdata)" "$(v tz_offset)" "-0500"
check "doctor recognizes the image: ok, its revision, no NOTE" "$(v doctor_report)" "STATUS: ok|MATCHES: image @ ${SOURCE_REV:0:12}"
check "doctor exits 0 in the image" "$(v doctor_rc)" "0"
check "the wrapper refuses --resume" "$(v refuse_resume)" "2"
check "the wrapper refuses -c" "$(v refuse_continue)" "2"
check "the wrapper refuses --bg" "$(v refuse_bg)" "2"
# F3: the clones (S13)
check "the workspace is root's, 0755" "$(v ws_meta)" "root:root 755"
check "the user cannot add a directory to the workspace" "$(v ws_new_dir)" "no"
check "the clone's directory is the user's" "$(v clone_dir_meta)" "$HOST_UID 755"
check "the enrolled repos are root's, 0644" "$(v repos_meta)" "root 644"
check "the enrolled repos are the env file's" "$(v repos_lines)" "$CLONE octocat/Hello-World"
check "the fleet list is the enrolled paths" "$(v fleet_list)" "$CLONE"
check "the fleet list is root's, 0644 (Inv 3)" "$(v fleet_list_meta)" "root 644"
check "the user cannot add to the fleet list" "$(v fleet_list_write)" "no"
check "the user cannot replace the fleet list" "$(v fleet_list_replace)" "no"
check "sync clones the enrolled repo from GitHub" "$(v sync1)" "$(printf 'SYNCED\t%s' "$CLONE")"
check "the clone is at origin's HEAD" "$(v sync_head | awk '{print ($1 == $2 && length($1) == 40) ? "same" : $0}')" "same"
check "on origin's default branch" "$(v sync_branch | awk '{print ($1 == $2) ? "same" : $0}')" "same"
check "the clone's toplevel is the repo's host path (the state key)" "$(v sync_toplevel)" "$CLONE"
check "a resync after a session: synced" "$(v sync2)" "SYNCED"
check "a planted fsmonitor and hook never run after the resync" "$(v clone_planted_ran)" "no no"
check "a planted change is gone after the resync" "$(v clone_readme)" "0"
check "sync refuses a path that is not enrolled" "$(v sync_stray)" "$(printf 'FAILED\tnot an enrolled repo (DEVLEAD_REPOS)')"
# F3: the host's state (S14)
check "none of the host's gh-token, loop.env or notify.env is in the container" "$(v host_decoys)" "no no 0"
check "the mounted state is the host user's" "$(v state_owners)" "$HOST_UID"
check "learn/ is read-only in the container" "$(v learn_ro)" "no"
check "what the container writes, the host sees (reports/)" \
  "$(stat -c '%u' "$HOST_STATE/reports/probe" 2>/dev/null || echo missing)" "$HOST_UID"
check "the container's notices land in the host's inbox" "$(grep -c 'smoke-check' "$HOST_STATE/inbox.tsv")" "1"
_key="$(printf '%s' "$CLONE" | sha256sum | cut -c1-20)"
check "same key on both sides: the decision lands where the host's /devlead reads it" \
  "$(cut -f4,5 "$HOST_STATE/decisions/$_key/log.tsv" 2>/dev/null)" "$(printf "probe\tthe server's key")"
check "and names the repo by its host path" "$(cat "$HOST_STATE/decisions/$_key/repo" 2>/dev/null)" "$CLONE"
check "the commits' author is the env file's" "$(v ident)" "Smoke Bot|smoke-bot@example.com"
check "the git identity is root's, 0644" "$(v ident_meta)" "root 644"
check "the user cannot change the git identity" "$(v ident_write)" "no"
check "the user cannot override it in the global config" "$(v ident_override)" "no"
check "a commit in a clone carries that author" "$(v commit_author)" "Smoke Bot <smoke-bot@example.com>|Smoke Bot <smoke-bot@example.com>"

echo "=== the Claude account pool: one token per session, usage limits (S21, S22) ==="
# The real Claude Code 2.1.326 of the image, through the wrapper, against a
# mock of the API that answers the team account's token with the 5-hour
# usage limit (429 and the rate-limit headers the API sends) and any other
# with a reply. Dummy tokens; no real limit is reached.
read -r -d '' POOL_PROBE <<'POOL_EOF'
p() { printf '%s=%s\n' "$1" "$2"; }
M=/home/devlead/.cache/smoke
mkdir -p "$M" /tmp/work && cd /tmp/work && git init -q -b feat/work 2>/dev/null
# The ledger volume keeps the probe's sessions: count from here.
L0="$(wc -l < /var/lib/devlead/sessions.tsv)"
cat > "$M/pool-mock.js" <<'JS'
const http = require('http'), fs = require('fs');
const log = s => fs.appendFileSync('/home/devlead/.cache/smoke/pool-mock.log', s + '\n');
const reset = Math.floor(Date.now() / 1000) + 3 * 3600;
fs.writeFileSync('/home/devlead/.cache/smoke/pool-reset', String(reset));
http.createServer((req, res) => {
  let b = ''; req.on('data', c => b += c);
  req.on('end', () => {
    if (!/\/v1\/messages(\?|$)/.test(req.url)) { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{}'); }
    const a = req.headers.authorization || '';
    const who = a.endsWith('-team') ? 'team' : a.endsWith('-ultra') ? 'ultra' : 'other';
    log('REQ ' + who);
    if (who === 'team') {
      res.writeHead(429, { 'content-type': 'application/json', 'request-id': 'req_mock',
        'anthropic-ratelimit-unified-status': 'rejected', 'anthropic-ratelimit-unified-representative-claim': 'five_hour',
        'anthropic-ratelimit-unified-reset': String(reset), 'anthropic-ratelimit-unified-5h-status': 'rejected',
        'anthropic-ratelimit-unified-5h-reset': String(reset), 'anthropic-ratelimit-unified-overage-status': 'rejected',
        'anthropic-ratelimit-unified-overage-disabled-reason': 'org_level_disabled' });
      return res.end(JSON.stringify({ type: 'error', error: { type: 'rate_limit_error', message: 'This request would exceed your account\'s rate limit. Please try again later.' } }));
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ id: 'msg_mock', type: 'message', role: 'assistant', model: 'mock', content: [{ type: 'text', text: 'ok' }],
      stop_reason: 'end_turn', stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } }));
  });
}).listen(8099, '127.0.0.1', () => log('LISTEN'));
JS
node "$M/pool-mock.js" & mp=$!
for _ in $(seq 1 30); do grep -q LISTEN "$M/pool-mock.log" 2>/dev/null && break; sleep 0.2; done
s() { ANTHROPIC_BASE_URL=http://127.0.0.1:8099 timeout 120 claude -p hi </dev/null >"$M/out$1" 2>"$M/err$1"; echo $?; }
p conf "$(grep '^CLAUDE_ACCOUNTS=' /etc/devlead/runner.conf)"
# A1: the tokens live in root's file, readable by the user's group only; no
# process the user can read the environment of carries one.
p tokens_meta "$(stat -c '%U %a' /etc/devlead/claude-tokens) $([[ "$(stat -c %g /etc/devlead/claude-tokens)" == "$(id -g)" ]] && echo group || echo other)"
p tokens_write "$( (echo x >> /etc/devlead/claude-tokens) 2>/dev/null && echo yes || echo no)"
p tokens_env "$(grep -laE 'DEVLEAD_CLAUDE_ACCOUNT_[0-9]+_TOKEN=' /proc/[0-9]*/environ 2>/dev/null | wc -l)"
p names_env "$(compgen -e | grep -c '^DEVLEAD_CLAUDE_ACCOUNT_[0-9]$')"
p rc1 "$(s 1)"
p rc2 "$(s 2)"
p mock "$(grep '^REQ' "$M/pool-mock.log" | cut -d' ' -f2 | awk '!seen[$0]++' | paste -sd, -)"
p starts "$(tail -n +"$((L0 + 1))" /var/lib/devlead/sessions.tsv | awk -F'\t' '$3 == "start" {print $7}' | paste -sd, -)"
p mark "$(grep -v '^#' /var/lib/devlead/accounts.tsv | cut -f1,2,3,7 | tr '\t' '|')"
p reset "$(cat "$M/pool-reset")"
p err1 "$(grep -c 'the Claude account team rests until .* — its 5-hour limit; the next session uses ultra' "$M/err1")"
p tokens "$(cat /var/lib/devlead/sessions.tsv /var/lib/devlead/accounts.tsv "$M"/err* | grep -c DUMMY)"
p doctor "$(bash /home/devlead/.devlead/scripts/doctor.sh 2>/dev/null | grep -c '^WARN:   the Claude token of account team (DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED=2025-11-01) is 12 months old and has expired')"
printf 'ultra\t%s\tseven_day\tt\ts\tr\treported\n' "$(( $(date +%s) + 86400 ))" >> /var/lib/devlead/accounts.tsv
p rc3 "$(s 3)"
p out3 "$(cat "$M/out3")"
p refused "$(tail -n 1 /var/lib/devlead/sessions.tsv | cut -f3,7 | tr '\t' '|')"
kill "$mp" 2>/dev/null
POOL_EOF
POOL_OUT="$(compose run --rm -T -e CLAUDE_CODE_OAUTH_TOKEN= -e DEVLEAD_CLAUDE_TOKEN_ISSUED= \
  -e DEVLEAD_CLAUDE_ACCOUNT_1=team -e DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN=sk-ant-oat01-DUMMY-team -e DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED=2025-11-01 \
  -e DEVLEAD_CLAUDE_ACCOUNT_2=ultra -e DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN=sk-ant-oat01-DUMMY-ultra -e DEVLEAD_CLAUDE_ACCOUNT_2_ISSUED=2026-11-01 \
  devlead bash -c "$POOL_PROBE" 2>"$SCRATCH/pool.err")"
pv() { sed -n "s/^$1=//p" <<<"$POOL_OUT" | head -n 1; }
check "pool: runner.conf lists the accounts in priority order" "$(pv conf)" \
  "CLAUDE_ACCOUNTS=team=DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN ultra=DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN"
check "pool (A1): the tokens are in root's file, 0640, the user's group" "$(pv tokens_meta)" "root 640 group"
check "pool (A1): the user cannot change the token file" "$(pv tokens_write)" "no"
check "pool (A1): no process the user can read holds a pool token in its environment" "$(pv tokens_env)" "0"
check "pool (A1): the names stay for doctor" "$(pv names_env)" "2"
check "pool: the first session, on team, ends on the 5-hour limit (exit 1)" "$(pv rc1)" "1"
check "pool: the second session runs on ultra (exit 0)" "$(pv rc2)" "0"
check "pool: the API saw team's token first, then ultra's" "$(pv mock)" "team,ultra"
check "pool: the ledger names the accounts" "$(pv starts)" "team,ultra"
check "pool: team rests until the reset the API sent, as Claude Code 2.1.326 reported it" "$(pv mark)" "team|$(pv reset)|five_hour|reported"
check "pool: the wrapper says so and names the next account" "$(pv err1)" "1"
check "pool: no token in the ledger, the marks or the messages" "$(pv tokens)" "0"
check "pool: doctor warns about team's token by name" "$(pv doctor)" "1"
check "pool: every account resting: refused (75)" "$(pv rc3)" "75"
check "pool: every account resting: stdout says claude-limited" "$(pv out3)" "STATUS: claude-limited"
check "pool: every account resting: the ledger says limited" "$(pv refused)" "refused|limited"
[[ -n "$POOL_OUT" ]] || { echo "pool probe stderr:"; tail -n 20 "$SCRATCH/pool.err"; }

echo "=== the long-lived service: scheduler and runner (F2) ==="
# Its own env file: no push channel (the failures below send `need`), a
# morning job every minute (to watch supercronic run one), discovery off, a
# cap of 4 sessions a day and a 20-second session limit.
SERVICE_ENV="$SCRATCH/service.env"
( umask 077
  grep -vE '^(DEVLEAD_NTFY_URL|DEVLEAD_NTFY_TOKEN|DEVLEAD_MAX_SESSIONS_PER_DAY|DEVLEAD_REPOS)=' "$ENV_FILE"
  cat <<'EOF'
DEVLEAD_REPOS=
DEVLEAD_NTFY_URL=
DEVLEAD_CRON_MORNING=* * * * *
DEVLEAD_CRON_DISCOVER=off
DEVLEAD_MAX_SESSIONS_PER_DAY=4
DEVLEAD_SESSION_TIMEOUT=20s
EOF
) > "$SERVICE_ENV"
export SERVICE_ENV
MOCK_JS="$(sed -n "/^cat > \/tmp\/mock.js <<'JS'\$/,/^JS\$/p" <<<"$PROBE" | sed '1d;$d')"
dx() { compose exec -T -u devlead devlead "$@"; }
rx() { compose exec -T -u root devlead "$@"; }
MOCK_ENV=(-e ANTHROPIC_BASE_URL=http://127.0.0.1:8099 -e ANTHROPIC_API_KEY=sk-ant-api03-DUMMY)
# mock <label> <command the mock asks claude to run> — the mock and its log
# live in ~/.cache, out of the /tmp the jobs clean up after themselves. Claude
# Code refuses `sleep N; ...` in a Bash call, so the commands that must take a
# while run `tail -f /dev/null` under `timeout`.
# A third and fourth argument add a Write call of that content to that path
# in the same turn (S23).
mock() {
  dx sh -c "pkill -f '^node /home/devlead/.cache/smoke/mock.js' ; : > /home/devlead/.cache/smoke/mock-$1.log" >/dev/null 2>&1
  for _ in $(seq 1 25); do dx pgrep -f '^node /home/devlead/.cache/smoke/mock.js' >/dev/null 2>&1 || break; sleep 0.2; done
  compose exec -d -u devlead -e "MOCK_LOG=/home/devlead/.cache/smoke/mock-$1.log" -e "MOCK_CMD=$2" \
    -e "MOCK_WRITE=${3:-}" -e "MOCK_WRITE_CONTENT=${4:-}" devlead \
    node /home/devlead/.cache/smoke/mock.js
  for _ in $(seq 1 50); do dx grep -q LISTEN "/home/devlead/.cache/smoke/mock-$1.log" 2>/dev/null && return 0; sleep 0.2; done
  echo "mock $1 did not start" >&2
}
job() { compose exec -T -u devlead "${MOCK_ENV[@]}" devlead env -u CLAUDE_CODE_OAUTH_TOKEN /opt/devlead/docker/run-job.sh "$1"; }
session() { compose exec -T -u devlead "${MOCK_ENV[@]}" devlead env -u CLAUDE_CODE_OAUTH_TOKEN \
  claude -p hi --permission-mode acceptEdits --allowedTools Bash </dev/null; }
# audit <jq filter> — over the month's audit lines of the forced fleet runs.
audit() { dx sh -c 'cat "$HOME/.devlead/audit/$(date +%Y-%m).jsonl"' 2>/dev/null | jq -c -s "map(select(.trigger == \"fleet\")) | $1"; }
starts() { dx sh -c "grep -c \"\$(printf '\\tstart\\t')\" /var/lib/devlead/sessions.tsv" 2>/dev/null; }

# The probe's sessions are in the ledger volume, which outlives a container
# (L18): the service starts on fresh volumes, so its daily cap counts only its
# own sessions.
compose down --volumes --remove-orphans >/dev/null 2>&1
if compose up -d --wait --wait-timeout 180 >"$SCRATCH/up.log" 2>&1; then
  cid="$(compose ps -q devlead)"
  check "the service is healthy" "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" "healthy"
  check "restart policy is unless-stopped" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null)" "unless-stopped"
  check "the main process is supercronic, PID 1's child, as the host UID" \
    "$(compose exec -T devlead ps -o uid=,args= --ppid 1 2>/dev/null | awk '{$1=$1; print}')" \
    "$HOST_UID /usr/local/bin/supercronic -passthrough-logs /etc/devlead/crontab"
  check "the healthcheck passes while the firewall holds" \
    "$(compose exec -T devlead /opt/devlead/docker/init-firewall.sh --check >/dev/null 2>&1; echo $?)" "0"

  # The schedule is the env file's, root's.
  crontab="$(dx cat /etc/devlead/crontab)"
  check "the crontab is root's, 0644" "$(dx stat -c '%U %a' /etc/devlead/crontab)" "root 644"
  check "the crontab: morning as the env file says" "$(grep -c '^\* \* \* \* \* /opt/devlead/docker/run-job.sh morning$' <<<"$crontab")" "1"
  check "the crontab: loop at its default" "$(grep -c '^0 22 \* \* \* /opt/devlead/docker/run-job.sh loop$' <<<"$crontab")" "1"
  check "the crontab: fleet at its default (devlead-fleet.timer, 22:30)" "$(grep -c '^30 22 \* \* \* /opt/devlead/docker/run-job.sh fleet$' <<<"$crontab")" "1"
  check "the crontab: discover off, as the env file says" "$(grep -c 'run-job.sh discover' <<<"$crontab")" "0"
  check "the limits are the env file's" "$(dx grep -E '^(TZ|MAX_SESSIONS_PER_DAY|SESSION_TIMEOUT)=' /etc/devlead/runner.conf | paste -sd, -)" \
    "TZ=America/Bogota,MAX_SESSIONS_PER_DAY=4,SESSION_TIMEOUT=20s"
  check "the single token is a pool of one account, default (S21)" "$(dx grep '^CLAUDE_ACCOUNTS=' /etc/devlead/runner.conf)" \
    "CLAUDE_ACCOUNTS=default=CLAUDE_CODE_OAUTH_TOKEN"

  # Setup, as the operator: an (empty) fleet list, so the fleet job runs.
  rx sh -c 'touch /home/devlead/.devlead/autonomous-repos && chmod 0644 /home/devlead/.devlead/autonomous-repos'
  dx mkdir -p /home/devlead/.cache/smoke
  printf '%s\n' "$MOCK_JS" | dx sh -c 'cat > /home/devlead/.cache/smoke/mock.js'

  # 1. A forced job: one session, its audit line and transcript, and nothing
  #    it left behind survives it. The session also writes the run's report,
  #    which guard.sh refuses (S23): the job writes it.
  REPORT_NAME="$(TZ=America/Bogota date +%F)-execute.md"
  REPORT_TEXT="# DevLead Execute — smoke | #1 | pr-created |"
  mock leftovers 'bash -c "exec -a leftover-a tail -f /dev/null" >/dev/null 2>&1 & setsid bash -c "exec -a leftover-b tail -f /dev/null" >/dev/null 2>&1 & setsid env -i bash -c "exec -a leftover-c tail -f /dev/null >/dev/null 2>&1 &"; echo spawned' \
    "/home/devlead/.devlead/reports/$REPORT_NAME" "$REPORT_TEXT"
  out="$(job fleet 2>&1)"; rc=$?
  check "a forced fleet job exits 0" "$rc" "0"
  contains "the job's audit line reaches the container log" "$out" 'devlead-audit {"run_id":'
  a="$(audit 'last')"
  check "audit: trigger, outcome, exit code" "$(jq -c '[.trigger, .outcome, .exit_code]' <<<"$a")" '["fleet","ok",0]'
  check "audit: one session, not timed out, not refused" "$(jq -c '[(.session_ids | length), .timed_out, .cap_refused]' <<<"$a")" '[1,false,false]'
  check "audit: the mock's Bash call is counted" "$(jq -c '.tool_uses.Bash' <<<"$a")" "1"
  check "audit: nothing notified" "$(jq -c '.notified' <<<"$a")" "false"
  run_id="$(jq -r .run_id <<<"$a")"; sid="$(jq -r '.session_ids[0]' <<<"$a")"
  check "the session's transcript is kept, found by its session id" \
    "$(dx sh -c "grep -q toolu_mock /home/devlead/.devlead/audit/runs/$run_id/$sid.jsonl && echo kept" 2>/dev/null)" "kept"
  contains "the mock's command ran in the session" "$(dx cat /home/devlead/.cache/smoke/mock-leftovers.log)" "spawned"
  check "no process the job left behind survives it (in its session, setsid, setsid env -i)" "$(dx pgrep -fc '^leftover-')" "0"
  check "audit: the leftovers were stopped" "$(jq -c '.leftovers_killed >= 3' <<<"$a")" "true"
  check "the job's private TMPDIR is gone" "$(dx sh -c 'ls -d /tmp/devlead-job.* 2>/dev/null | wc -l')" "0"
  check "S23: guard.sh refused the session's report Write" \
    "$(dx sh -c "grep -q 'DevLead limit \\[self-config\\]' /home/devlead/.devlead/audit/runs/$run_id/$sid.jsonl && echo refused" 2>/dev/null)" "refused"
  check "S23: the job wrote that report, on the host, as the user" \
    "$(cat "$HOST_STATE/reports/$REPORT_NAME" 2>/dev/null)|$(stat -c %u "$HOST_STATE/reports/$REPORT_NAME" 2>/dev/null)" "$REPORT_TEXT|$HOST_UID"
  check "S23: the audit names it" "$(jq -r '.report_kept' <<<"$a")" "$REPORT_NAME"

  # 2. One session at a time: a session started while a job's session runs is
  #    refused; a job started meanwhile waits for the first job.
  mock slow 'timeout 12 tail -f /dev/null; echo slow'
  before="$(starts)"
  compose exec -d -u devlead "${MOCK_ENV[@]}" devlead env -u CLAUDE_CODE_OAUTH_TOKEN /opt/devlead/docker/run-job.sh fleet
  for _ in $(seq 1 100); do [[ "$(starts)" -gt "$before" ]] && break; sleep 0.3; done
  out="$(session 2>&1)"; rc=$?
  check "a second session while one runs: refused (75)" "$rc" "75"
  contains "a second session while one runs: says why" "$out" "another claude session is running"
  out="$(dx /opt/devlead/docker/run-job.sh discover 2>&1)"
  contains "a job started meanwhile waits for the running one" "$out" "another job is running — discover waits for it"
  check "the waiting job's wait is audited" \
    "$(dx sh -c 'cat "$HOME/.devlead/audit/$(date +%Y-%m).jsonl"' | jq -s 'map(select(.trigger == "discover")) | last | .lock_wait_seconds >= 1')" "true"
  check "the first job finished first" "$(audit 'length')" "2"

  # 3. The time limit stops a session, is audited and sends `need`.
  mock late 'timeout 60 tail -f /dev/null; echo late'
  start="$(date +%s)"
  out="$(job fleet 2>&1)"; rc=$?
  elapsed=$(( $(date +%s) - start ))
  a="$(audit 'last')"
  check "timeout: the run is reported failed (exit 1)" "$rc" "1"
  check "timeout: stopped at the 20s limit, not after the 60s command" "$([[ $elapsed -lt 55 ]] && echo stopped || echo "ran ${elapsed}s")" "stopped"
  check "timeout: audited" "$(jq -c '[.outcome, .timed_out, .notify_codes]' <<<"$a")" '["timeout",true,["job-timeout"]]'
  check "timeout: need job-timeout in the inbox" "$(dx bash /home/devlead/.devlead/scripts/notify.sh list | grep -c 'job-timeout')" "1"
  check "timeout: the session's command did not survive" "$(dx pgrep -fc '^tail -f /dev/null')" "0"

  # 4. The daily cap: 3 sessions so far; the 4th runs, the 5th is refused and
  #    a job that needs one is audited and sends `need`.
  mock cap 'echo capped'
  session >/dev/null 2>&1; rc=$?
  check "cap: the 4th session of the day runs" "$rc" "0"
  out="$(session 2>&1)"; rc=$?
  check "cap: the 5th session is refused (75)" "$rc" "75"
  contains "cap: says the daily limit is reached" "$out" "the daily limit of 4 claude sessions is reached"
  job fleet >/dev/null 2>&1
  a="$(audit 'last')"
  check "cap: the job's session refused, audited" "$(jq -c '[.outcome, .cap_refused, .refusals, .notify_codes]' <<<"$a")" '["refused",true,["cap"],["job-refused"]]'
  check "cap: need job-refused in the inbox" "$(dx bash /home/devlead/.devlead/scripts/notify.sh list | grep -c 'job-refused')" "1"

  # 4b. The day's count survives a recreated container (L18): the ledger is
  #     a volume, not the container's own layer.
  compose down >/dev/null 2>&1
  if compose up -d --wait --wait-timeout 180 >>"$SCRATCH/up.log" 2>&1; then
    check "recreated: a new container" "$([[ "$(compose ps -q devlead)" != "$cid" ]] && echo new || echo same)" "new"
    check "recreated: the ledger kept the day's sessions" "$(starts)" "4"
    out="$(session 2>&1)"; rc=$?
    check "recreated: the cap still holds (75)" "$rc" "75"
    contains "recreated: says the daily limit is reached" "$out" "the daily limit of 4 claude sessions is reached"
  else
    tail -n 20 "$SCRATCH/up.log"
    check "the service comes back up after a recreate" "no" "yes"
  fi

  # 5. The pause file: the operator's; it stops jobs and sessions.
  rx touch /home/devlead/.devlead/PAUSE
  dx rm -f /home/devlead/.devlead/PAUSE >/dev/null 2>&1
  check "pause: the user cannot remove the pause file" "$(dx sh -c 'test -e /home/devlead/.devlead/PAUSE && echo kept || echo removed')" "kept"
  before="$(starts)"
  job fleet >/dev/null 2>&1
  check "pause: a job does not run" "$(audit 'last | .outcome')" '"paused"'
  out="$(session 2>&1)"; rc=$?
  check "pause: a session is refused (75)" "$rc" "75"
  contains "pause: says DevLead is paused" "$out" "DevLead is paused"
  check "pause: no session started" "$(starts)" "$before"
  rx rm -f /home/devlead/.devlead/PAUSE

  # 5b. Never as root: neither a session nor a job; --version still answers.
  fleet_runs="$(audit 'length')"
  out="$(compose exec -T -u root "${MOCK_ENV[@]}" devlead claude -p hi </dev/null 2>&1)"; rc=$?
  check "root: a claude session is refused (75)" "$rc" "75"
  contains "root: says why" "$out" "never starts a claude session as root"
  out="$(rx /opt/devlead/docker/run-job.sh fleet 2>&1)"; rc=$?
  check "root: a job is refused (1)" "$rc" "1"
  contains "root: says to run it as devlead" "$out" "never runs a job as root"
  check "root: the refused job left no audit line" "$(audit 'length')" "$fleet_runs"
  check "root: claude --version still answers" "$(rx claude --version 2>/dev/null)" "2.1.326 (Claude Code)"

  # 5c. One writer at a time across the container boundary (S14): a host
  #     process holding the inbox lock makes the container's notify.sh wait.
  flock -o "$HOST_STATE/inbox.tsv" sleep 4 & holder=$!
  sleep 0.5
  t0="$(date +%s)"
  dx bash /home/devlead/.devlead/scripts/notify.sh send info lock-probe "waits for the host" >/dev/null 2>&1
  waited=$(( $(date +%s) - t0 ))
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  check "a host process holding the inbox lock makes the container wait" "$([[ $waited -ge 3 ]] && echo waited || echo "did not wait (${waited}s)")" "waited"
  check "then the container writes the host's inbox" "$(grep -c 'lock-probe' "$HOST_STATE/inbox.tsv")" "1"

  # 6. Retention: an old run's transcripts are pruned.
  dx mkdir -p /home/devlead/.devlead/audit/runs/20200101T000000Z-fleet-aaaaaa
  dx /opt/devlead/docker/run-job.sh --prune >/dev/null 2>&1
  check "prune: a run from 2020 is removed" "$(dx sh -c 'ls /home/devlead/.devlead/audit/runs | grep -c 20200101')" "0"

  # 7. supercronic itself ran the morning job (every minute here), as devlead.
  for _ in $(seq 1 45); do
    dx sh -c 'cat "$HOME/.devlead/audit/$(date +%Y-%m).jsonl"' 2>/dev/null | jq -e -s 'any(.trigger == "morning")' >/dev/null && break
    sleep 2
  done
  check "supercronic ran the scheduled morning job" \
    "$(dx sh -c 'cat "$HOME/.devlead/audit/$(date +%Y-%m).jsonl"' | jq -s -c 'map(select(.trigger == "morning")) | first | [.outcome, .exit_code]')" '["ok",0]'
else
  tail -n 20 "$SCRATCH/up.log"
  check "the service starts and turns healthy" "no" "yes"
fi
compose down --volumes --remove-orphans >/dev/null 2>&1
unset SERVICE_ENV

echo "=== startup fails closed ==="
out="$(docker run --rm --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "without NET_ADMIN the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo "started (rc=0)")" "refused"
check "without NET_ADMIN the command never runs" "$(printf '%s\n' "$out" | grep -cx "$HOST_UID")" "0"
contains "without NET_ADMIN it says why" "$out" "the egress firewall could not be applied"

out="$(compose run --rm -T -e 'DEVLEAD_EGRESS_ALLOW=not_a_host!' devlead id -u 2>&1)"; rc=$?
check "a malformed DEVLEAD_EGRESS_ALLOW entry stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the malformed entry is named" "$out" "'not_a_host!' is not a valid host name"

out="$(compose run --rm -T -e 'DEVLEAD_CRON_LOOP=61 22 * * *' devlead id -u 2>&1)"; rc=$?
check "an invalid cron expression stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the invalid expression is named" "$out" "DEVLEAD_CRON_LOOP='61 22 * * *' is not a valid schedule"
check "the command never runs on an invalid schedule" "$(printf '%s\n' "$out" | grep -cx "$HOST_UID")" "0"

out="$(compose run --rm -T -e 'TZ=Mars/Olympus' devlead id -u 2>&1)"; rc=$?
check "an unknown time zone stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the time zone is named" "$out" "TZ='Mars/Olympus' is not a time zone"

out="$(compose run --rm -T -e DEVLEAD_CLAUDE_BIN=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe devlead id -u 2>&1)"; rc=$?
check "DEVLEAD_CLAUDE_BIN set to the real binary stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it says the binary is not the wrapper" "$out" "is not the claude wrapper"

out="$(compose run --rm -T -e 'DEVLEAD_REPOS=/home/smoke/Secret/x=octocat/Hello-World' devlead id -u 2>&1)"; rc=$?
check "a repo outside the workspace stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the entry is named" "$out" "DEVLEAD_REPOS entry 1: the path is not inside DEVLEAD_WORKSPACE"
check "the path is not echoed" "$(grep -c 'Secret' <<<"$out")" "0"
out="$(compose run --rm -T -e "DEVLEAD_LOOP_REPO=$WORKSPACE/other" devlead id -u 2>&1)"; rc=$?
check "a loop repo that is not enrolled stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it says the loop works only in the clones" "$out" "DEVLEAD_LOOP_REPO must be one of the paths in DEVLEAD_REPOS"
out="$(compose run --rm -T -e 'DEVLEAD_WORKSPACE=/home/elsewhere' -e 'DEVLEAD_REPOS=/home/elsewhere/x=octocat/Hello-World' devlead id -u 2>&1)"; rc=$?
check "a workspace that is not where compose mounted the clones stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it says nothing is mounted there" "$out" "nothing is mounted at DEVLEAD_WORKSPACE"

out="$(compose run --rm -T -e 'DEVLEAD_GIT_EMAIL=not an address' devlead id -u 2>&1)"; rc=$?
check "an invalid git email stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "the variable is named" "$out" "DEVLEAD_GIT_EMAIL must be an email address"
check "the value is not echoed" "$(grep -c 'not an address' <<<"$out")" "0"
out="$(compose run --rm -T -e 'DEVLEAD_GIT_NAME=' -e 'DEVLEAD_GIT_EMAIL=' devlead id -u 2>&1)"; rc=$?
check "repos without a git identity stop the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
# L21 A2: the loop's plan, bound read-only from the host and installed by
# root; an invalid one stops the start; DEVLEAD_LOOP_REPO without one warns.
PLAN="$SCRATCH/plan.local.yml"
printf 'tasks:\n  - id: t1\n    title: one\n    type: feat\n  - id: t2\n    title: two\n    type: fix\n' > "$PLAN"
out="$(DEVLEAD_LOOP_PLAN="$PLAN" compose run --rm -T -e "DEVLEAD_LOOP_PLAN=$PLAN" -e "DEVLEAD_LOOP_REPO=$CLONE" devlead \
  sh -c 'stat -c "%U %a" ~/.devlead/plan.local.yml; sha256sum < ~/.devlead/plan.local.yml; (echo x >> ~/.devlead/plan.local.yml) 2>/dev/null && echo writable || echo read-only' 2>&1)"; rc=$?
check "a plan: the container starts" "$rc" "0"
contains "a plan: installed root-owned 0644" "$out" "root 644"
contains "a plan: the same bytes as the host's" "$out" "$(sha256sum < "$PLAN")"
contains "a plan: the session cannot change it" "$out" "read-only"
contains "a plan: the start log counts its tasks" "$out" "the loop's plan from DEVLEAD_LOOP_PLAN is installed (2 task(s))"
printf 'tasks:\n  - title: no id\n' > "$PLAN"
out="$(DEVLEAD_LOOP_PLAN="$PLAN" compose run --rm -T -e "DEVLEAD_LOOP_PLAN=$PLAN" devlead id -u 2>&1)"; rc=$?
check "an invalid plan stops the start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it names DEVLEAD_LOOP_PLAN" "$out" "DEVLEAD_LOOP_PLAN does not name a plan the loop can read"
out="$(compose run --rm -T -e "DEVLEAD_LOOP_REPO=$CLONE" devlead sh -c 'test -e ~/.devlead/plan.local.yml && echo plan || echo no-plan' 2>&1)"; rc=$?
check "no plan, a loop repo: the container starts" "$rc" "0"
contains "no plan, a loop repo: there is no plan" "$out" "no-plan"
contains "no plan, a loop repo: the start warns" "$out" "WARNING: DEVLEAD_LOOP_REPO is set but there is no plan"
mv "$HOST_STATE/run-state" "$HOST_STATE/run-state.away"
out="$(compose run --rm -T devlead id -u 2>&1)"; rc=$?
check "a state subdirectory missing on the host stops the start (compose does not create it)" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
check "and nothing was created in its place on the host" "$([[ -e "$HOST_STATE/run-state" ]] && echo created || echo absent)" "absent"
mv "$HOST_STATE/run-state.away" "$HOST_STATE/run-state"
# Without compose's mounts, or with learn/ writable, the entrypoint refuses.
_net=(--cap-add NET_ADMIN --cap-add NET_RAW --sysctl net.ipv6.conf.all.disable_ipv6=1)
out="$(docker run --rm "${_net[@]}" --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "without the host's state mounted the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it names what is not mounted" "$out" "~/.devlead/agenda is not mounted from the host's DEVLEAD_STATE_DIR"
_v=()
for _d in agenda audit decisions journals learn outcomes reports run-state inbox.tsv inbox.read.tsv; do
  _v+=(-v "$HOST_STATE/$_d:/home/devlead/.devlead/$_d")
done
out="$(docker run --rm "${_net[@]}" "${_v[@]}" --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "learn/ mounted writable: the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"
contains "it says learn/ must be read-only" "$out" "~/.devlead/learn must be mounted read-only"

out="$(docker run --rm --user "$HOST_UID" --cap-add NET_ADMIN --env-file "$ENV_FILE" "$IMAGE" id -u 2>&1)"; rc=$?
check "started as a non-root user, the container does not start" "$([[ $rc -ne 0 ]] && echo refused || echo started)" "refused"

out="$(DOCKER_BUILDKIT=1 docker build -q --build-arg DEVLEAD_UID=0 --build-arg DEVLEAD_SOURCE_REV="$SOURCE_REV" \
  -f "$REPO_ROOT/docker/Dockerfile" "$REPO_ROOT" 2>&1)"; rc=$?
check "the image refuses to build for UID 0" "$([[ $rc -ne 0 ]] && echo refused || echo built)" "refused"
[[ $rc -eq 0 && -n "$out" ]] && docker image rm -f "$out" >/dev/null 2>&1

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
