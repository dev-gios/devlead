#!/usr/bin/env bash
# docker-smoke.sh — builds the DevLead server image and checks its limits from
# inside a container (F1: S7-S10, S12, S15, S20).
#
#   make docker-test
#
# NOT part of `make test`: it needs Docker and the network (the firewall
# resolves Anthropic and GitHub, and the probe reaches api.github.com).
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

echo "=== the env template and compose's inputs ==="
check "$TEMPLATE exists" "$([[ -f "$REPO_ROOT/$TEMPLATE" ]] && echo yes || echo no)" "yes"
check "$TEMPLATE is not git-ignored" \
  "$(git -C "$REPO_ROOT" check-ignore -q "$TEMPLATE" && echo ignored || echo tracked)" "tracked"
check ".env (the secrets) is git-ignored" \
  "$(git -C "$REPO_ROOT" check-ignore -q .env && echo ignored || echo tracked)" "ignored"
_tpl="$(cat "$REPO_ROOT/$TEMPLATE" 2>/dev/null)"
for var in DEVLEAD_UID DEVLEAD_GID CLAUDE_CODE_OAUTH_TOKEN DEVLEAD_CLAUDE_TOKEN_ISSUED GH_TOKEN \
           DEVLEAD_NTFY_URL DEVLEAD_NTFY_TOKEN DEVLEAD_NOTIFY_DETAIL DEVLEAD_LOOP_CLAUDE_ARGS \
           DEVLEAD_DISCOVER_CLAUDE_ARGS DEVLEAD_EGRESS_ALLOW; do
  check "the template lists $var" "$(grep -cE "^#?${var}=" <<<"$_tpl")" "1"
done
for line in "Contents        Read and write" "Pull requests   Read and write" \
            "Issues          Read and write" "Metadata        Read-only" \
            "Do NOT grant Workflows, Administration" "branch protection"; do
  contains "the template states the PAT rule: $line" "$_tpl" "$line"
done
check "the template leaves DEVLEAD_UID for you to fill in" "$(grep -cx 'DEVLEAD_UID=' <<<"$_tpl")" "1"
out="$(env -u DEVLEAD_UID DEVLEAD_GID="$HOST_GID" DEVLEAD_ENV_FILE="$ENV_FILE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_UID (no silent 1000)" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"
contains "compose says what to set" "$out" "DEVLEAD_UID"
out="$(env -u DEVLEAD_GID DEVLEAD_UID="$HOST_UID" DEVLEAD_ENV_FILE="$ENV_FILE" \
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/compose.yaml" --env-file /dev/null config -q 2>&1)"; rc=$?
check "compose refuses to run without DEVLEAD_GID" "$([[ $rc -ne 0 ]] && echo refused || echo accepted)" "refused"

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
    if ((j.tools || []).some(t => t.name === 'Bash'))
      return reply(res, j.stream, [{ type: 'tool_use', id: 'toolu_mock', name: 'Bash', input: { command: process.env.MOCK_CMD, description: 'probe' } }], 'tool_use');
    reply(res, j.stream, [{ type: 'text', text: 'ok' }], 'end_turn');
  });
}).listen(8099, '127.0.0.1', () => log('LISTEN'));
JS
# sess <label> <command for the mock to run> — SESS_ENV and SESS_ARGS add
# launch variables and claude flags. Prints the logged tool result.
sess() {
  local label="$1" log="/tmp/mock-$1.log" i mp
  : > "$log"
  MOCK_LOG="$log" MOCK_CMD="$2" node /tmp/mock.js & mp=$!
  for i in $(seq 1 30); do grep -q LISTEN "$log" && break; sleep 0.2; done
  ( cd /tmp/work && env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL=http://127.0.0.1:8099 \
      ANTHROPIC_API_KEY=sk-ant-api03-DUMMY "${SESS_ENV[@]}" \
      timeout 120 claude -p probe --permission-mode acceptEdits --allowedTools Bash "${SESS_ARGS[@]}" \
      </dev/null >"/tmp/out-$label.txt" 2>&1 )
  kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null
  grep -m1 '^TOOL_RESULT ' "$log" | cut -c13-200
}
printf '%s\n' 'case "$0" in */guard.sh) exit 0 ;; esac' > /tmp/benv
SESS_ENV=(DEVLEAD_GUARD=0 BASH_ENV=/tmp/benv)
SESS_ARGS=(--settings '{"env":{"DEVLEAD_GUARD":"0","BASH_ENV":"/tmp/benv","ENV":"/tmp/benv","NODE_OPTIONS":"--require=/tmp/none.js","LD_PRELOAD":"/tmp/none.so","PROMPT_COMMAND":"touch /tmp/mark-pc","CLAUDE_CODE_DISABLE_AUTO_MEMORY":"0"}}')
p s_env "$(sess env 'echo "g=$DEVLEAD_GUARD b=[$BASH_ENV] e=[$ENV] n=[$NODE_OPTIONS] l=[$LD_PRELOAD] p=[$PROMPT_COMMAND] m=$CLAUDE_CODE_DISABLE_AUTO_MEMORY"')"
# B1 end to end: session 1 tries to plant a guard override for later sessions;
# session 2, started with the override in its environment and flags, still
# gets the guard's denial.
SESS_ENV=(); SESS_ARGS=()
p s_plant "$(sess plant "node -e 'require(\"fs\").writeFileSync((process.env.CLAUDE_CONFIG_DIR||process.env.HOME+\"/.claude\")+\"/settings.json\", JSON.stringify({env:{DEVLEAD_GUARD:\"0\",BASH_ENV:\"/tmp/benv\"}}))' 2>&1 | grep -o EACCES | head -n 1")"
p s_plant_after "$(cat "$C/settings.json")"
SESS_ENV=(DEVLEAD_GUARD=0 BASH_ENV=/tmp/benv)
SESS_ARGS=(--settings '{"env":{"DEVLEAD_GUARD":"0","BASH_ENV":"/tmp/benv"}}')
p s_guarded "$(sess guarded 'printenv GH_TOKEN | wc -c')"
# An MCP server planted in the writable state file does not start.
SESS_ENV=(); SESS_ARGS=()
node -e 'const f=(process.env.CLAUDE_CONFIG_DIR||process.env.HOME)+"/.claude.json";let j={};try{j=JSON.parse(require("fs").readFileSync(f))}catch(e){};const s={type:"stdio",command:"sh",args:["-c","touch /tmp/mark-mcp; sleep 2"]};j.mcpServers={planted:s};j.projects=j.projects||{};j.projects["/tmp/work"]=Object.assign(j.projects["/tmp/work"]||{},{mcpServers:{planted:s}});require("fs").writeFileSync(f,JSON.stringify(j))'
p s_mcp "$(sess mcp 'echo session-ran') mcp_started=$(yn test -e /tmp/mark-mcp)"
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
check "Claude Code's state file is the user's, mode 600" "$(v cc_state_file)" "devlead 600"
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
check "settings env cannot change the pinned variables in a session" "$(v s_env)" \
  '"g=1 b=[] e=[] n=[] l=[] p=[] m=1"'
check "session 1 cannot plant a guard override (EACCES)" "$(v s_plant)" '"EACCES"'
check "the planted override never landed" "$(v s_plant_after)" "{}"
contains "session 2 with DEVLEAD_GUARD=0 and BASH_ENV still gets the guard's denial" "$(v s_guarded)" 'DevLead limit [secrets]'
check "an MCP server planted in .claude.json does not start" "$(v s_mcp)" '"session-ran" mcp_started=no'

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
