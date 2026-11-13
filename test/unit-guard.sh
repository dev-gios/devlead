#!/usr/bin/env bash
# unit-guard.sh — coverage for .claude/hooks/guard.sh
#
#   bash test/unit-guard.sh
#
# Pins the hard limits: what is blocked (production, a database that is not
# local, credentials outside the user's allow list, writes outside the repo,
# the guard's own configuration), that ordinary work is NOT blocked, that the
# guard is inert outside DevLead, and that it fails closed.
#
# shellcheck disable=SC2016,SC2088 # the commands under test are literal text
#
# SAFETY: HOME is a sandbox and every command is only matched as text — the
# guard never runs what it inspects, so nothing here deploys, connects or
# pushes anywhere.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/.claude/hooks/guard.sh"
# Not under /tmp: the guard lets a session write scratch files there, and the
# scope cases need directories that are outside both the repo and /tmp.
_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$_CACHE"
SANDBOX="$(mktemp -d "$_CACHE/devlead-guard.XXXXXX")"
trap 'cd /tmp && rm -rf "$SANDBOX"' EXIT
export TMPDIR=/tmp

export HOME="$SANDBOX/home"
WORK="$SANDBOX/work/repo"
OTHER="$SANDBOX/work/other"
mkdir -p "$HOME/.devlead" "$HOME/.ssh" "$HOME/.claude/projects/p/memory" "$WORK/src" "$OTHER"
git -C "$WORK" init -q -b feat/work
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WORK" remote add origin "$SANDBOX/none.git"
git -C "$WORK" update-ref refs/remotes/origin/trunk HEAD
git -C "$WORK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

PASS_COUNT=0
FAIL_COUNT=0
_ok()   { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "FAIL  $1"; echo "        $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

ERR="$SANDBOX/err"
# _guard <tool> <field> <value> [cwd]  → exit code; stderr in $ERR
_guard() {
  jq -n --arg t "$1" --arg f "$2" --arg v "$3" --arg c "${4:-$WORK}" \
    '{tool_name: $t, tool_input: {($f): $v}, cwd: $c}' \
    | DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"
}

# blocked <code> <label> <tool> <field> <value> [cwd]
blocked() {
  local code="$1" label="$2"; shift 2
  _guard "$@"; local rc=$?
  if [[ $rc -eq 2 ]] && grep -q "^DevLead limit \[$code\]" "$ERR"; then _ok "blocked [$code] $label"
  else _fail "blocked [$code] $label" "exit=$rc stderr=$(head -1 "$ERR")"; fi
}
# allowed <label> <tool> <field> <value> [cwd]
allowed() {
  local label="$1"; shift
  _guard "$@"; local rc=$?
  if [[ $rc -eq 0 && ! -s "$ERR" ]]; then _ok "allowed $label"
  else _fail "allowed $label" "exit=$rc stderr=$(head -1 "$ERR")"; fi
}
bash_blocked() { blocked "$1" "$2" Bash command "$2"; }
bash_allowed() { allowed "$1" Bash command "$1"; }

echo "=== production ==="
bash_blocked production 'vercel --prod'
bash_blocked production 'npx vercel deploy'
bash_blocked production 'cd app && netlify deploy --prod'
bash_blocked production 'fly deploy'
bash_blocked production 'wrangler deploy'
bash_blocked production 'vercel dev; vercel --prod'
bash_blocked production 'terraform apply -auto-approve'
bash_blocked production 'terraform -chdir=infra destroy'
bash_blocked production 'pulumi up --yes'
bash_blocked production 'kubectl apply -f k8s/'
bash_blocked production 'kubectl -n prod delete pod api-1'
bash_blocked production 'helm upgrade api ./chart'
bash_blocked production 'aws s3 rm s3://bucket/key'
bash_blocked production 'gcloud run deploy api'
bash_blocked production 'ssh deploy@10.0.0.4 "systemctl restart api"'
bash_blocked production 'scp build.tar host:/srv/'
bash_blocked production 'rsync -az dist/ deploy@host.example.com:/var/www/'
bash_blocked production 'npm publish'
bash_blocked production 'pnpm -r publish --access public'
bash_blocked production 'cargo publish'
bash_blocked production 'docker push registry.example.com/api:1'
bash_blocked production 'gh release create v1.0.0'
bash_blocked production 'gh repo delete owner/repo --yes'
bash_blocked production 'NODE_ENV=production npm run migrate'
bash_blocked production 'RAILS_ENV="production" bin/rails db:migrate'
bash_blocked production 'git push origin main'
bash_blocked production 'git push origin HEAD:master'
bash_blocked production 'git push origin feat/x:refs/heads/main'
bash_blocked production 'git push origin trunk'
bash_blocked production 'git push --force origin +feat/x:trunk'
bash_blocked production 'git push --all origin'
bash_blocked production 'git -C . push origin main'

echo "=== production: pushing while the default branch is checked out ==="
git -C "$WORK" checkout -q -b trunk
bash_blocked production 'git push'
git -C "$WORK" checkout -q feat/work

echo "=== merge-door ==="
bash_blocked merge-door 'gh pr merge 12 --merge'
bash_blocked merge-door 'gh pr -R owner/repo merge 12 --squash'

echo "=== database ==="
bash_blocked database 'psql -h db.example.com -U app app'
bash_blocked database 'psql --host=10.2.0.8 app'
bash_blocked database 'mysql -hdb.internal.example.com -u root'
bash_blocked database 'psql "postgres://app:secret@db.example.com:5432/app" -c "select 1"'
bash_blocked database 'DATABASE_URL=postgresql://u:p@aws-0.pooler.supabase.com:6543/postgres npm run seed'
bash_blocked database 'mongosh "mongodb+srv://u:p@cluster0.abcd.mongodb.net/app"'
bash_blocked database 'redis-cli -u rediss://default:p@cache.example.com:6380'
bash_blocked database 'psql "$DATABASE_URL" -f schema.sql'
bash_blocked database 'pg_restore -d "${PROD_DB_URL}" dump.bin'
bash_blocked database 'prisma migrate deploy'
bash_blocked database 'npx prisma migrate deploy'
bash_blocked database 'knex migrate:latest --env production'
bash_blocked database 'alembic -x env=prod upgrade head'
bash_blocked database 'supabase db push'
bash_blocked database 'supabase db reset --linked'
bash_blocked database 'supabase link --project-ref abcd'
bash_blocked database 'turso db shell app'
bash_blocked database 'pscale shell app main'

echo "=== secrets ==="
bash_blocked secrets 'cat .env'
bash_blocked secrets 'grep API_KEY .env.production'
bash_blocked secrets 'source ./.env.local && npm start'
bash_blocked secrets 'cat ~/.ssh/id_ed25519'
bash_blocked secrets 'head -3 ~/.aws/credentials'
bash_blocked secrets 'cat ~/.config/gh/hosts.yml'
bash_blocked secrets 'cat ~/.devlead/notify.env'
bash_blocked secrets 'openssl rsa -in certs/server.key -text'
bash_blocked secrets 'cp config/service-account-prod.json /tmp/x'
bash_blocked secrets 'gh auth token'
bash_blocked secrets 'gh secret set API_KEY'
bash_blocked secrets 'printenv'
bash_blocked secrets 'env'
bash_blocked secrets 'env | grep TOKEN'
blocked secrets 'Read .env'                Read file_path "$WORK/.env"
blocked secrets 'Read relative .env.local' Read file_path '.env.local'
blocked secrets 'Read ~/.ssh/id_rsa'       Read file_path "$HOME/.ssh/id_rsa"
blocked secrets 'Grep path .env'           Grep path "$WORK/.env"
blocked secrets 'Write .env in the repo'   Write file_path "$WORK/.env"
blocked secrets 'Edit a .pem'              Edit file_path "$WORK/certs/server.pem"

echo "=== secrets: the user's allow list ==="
printf '%s\n' '# places DevLead may read keys from' "$WORK/.env.local" '~/.config/app/*.env' > "$HOME/.devlead/secrets-allow"
allowed 'Read of a listed file'                Read file_path "$WORK/.env.local"
bash_allowed "cat $WORK/.env.local"
bash_allowed 'cat ~/.config/app/dev.env'
blocked secrets 'Read of a file NOT listed'    Read file_path "$WORK/.env.production"
bash_blocked secrets 'cat .env.local .env.production'
rm -f "$HOME/.devlead/secrets-allow"

echo "=== scope ==="
blocked scope 'Write in another repo'           Write file_path "$OTHER/a.txt"
blocked scope 'Edit in another repo'            Edit file_path "$OTHER/src/a.ts"
blocked scope 'Write through ..'                Write file_path "$WORK/../other/a.txt"
blocked scope 'Write in the home directory'     Write file_path "$HOME/notes.txt"
blocked scope 'NotebookEdit outside'            NotebookEdit notebook_path "$OTHER/n.ipynb"
ln -s "$OTHER" "$WORK/link-out"
blocked scope 'Write through a symlink that leaves the repo' Write file_path "$WORK/link-out/a.txt"
rm -f "$WORK/link-out"

echo "=== self-config ==="
blocked self-config 'Write ~/.devlead/secrets-allow'   Write file_path "$HOME/.devlead/secrets-allow"
blocked self-config 'Write ~/.devlead/loop.env'        Write file_path "$HOME/.devlead/loop.env"
blocked self-config 'Edit ~/.claude/settings.json'     Edit file_path "$HOME/.claude/settings.json"
blocked self-config 'Edit ~/.claude/settings.local.json' Edit file_path "$HOME/.claude/settings.local.json"
blocked self-config 'Write a hook in ~/.claude/hooks'  Write file_path "$HOME/.claude/hooks/x.sh"
blocked self-config 'Edit the repo .claude/settings.json' Edit file_path "$WORK/.claude/settings.json"
bash_blocked self-config 'echo "/**" >> ~/.devlead/secrets-allow'
bash_blocked self-config 'jq "del(.hooks)" ~/.claude/settings.json > /tmp/s && mv /tmp/s ~/.claude/settings.json'

echo "=== ordinary work is not blocked ==="
bash_allowed 'git status -sb'
bash_allowed 'git push -u origin feat/work'
bash_allowed 'git push origin feat/main-menu'
bash_allowed 'git push --force-with-lease origin feat/work'
bash_allowed 'git commit -m "docs: explain how vercel deploy and terraform apply are blocked"'
bash_allowed 'git commit -m "fix: main branch detection in production builds"'
bash_allowed 'gh pr create --base dev --title "feat: x" --body "y"'
bash_allowed 'gh pr view 12 --json state'
bash_allowed 'gh issue list --label bug'
bash_allowed 'bash ~/.devlead/scripts/merge.sh 12'
bash_allowed 'npm test'
bash_allowed 'npm run build && npm run lint'
bash_allowed 'make test'
bash_allowed 'vercel dev'
bash_allowed 'wrangler dev --port 8787'
bash_allowed 'firebase emulators:start'
bash_allowed 'terraform plan'
bash_allowed 'terraform fmt -check'
bash_allowed 'kubectl get pods'
bash_allowed 'helm template ./chart'
bash_allowed 'docker compose up -d'
bash_allowed 'docker build -t api:dev .'
bash_allowed 'rsync -a src/ build/'
bash_allowed 'psql -h localhost -U app app -c "select 1"'
bash_allowed 'psql app_test -f schema.sql'
bash_allowed 'psql "postgres://app:app@127.0.0.1:5432/app_test"'
bash_allowed 'DATABASE_URL=postgres://app:app@db:5432/app npx prisma migrate dev'
bash_allowed 'mongosh "mongodb://localhost:27017/app"'
bash_allowed 'redis-cli -h 127.0.0.1 ping'
bash_allowed 'npx prisma migrate dev --name add_users'
bash_allowed 'alembic upgrade head'
bash_allowed 'supabase start'
bash_allowed 'supabase db reset'
bash_allowed 'cat .env.example'
bash_allowed 'cp .env.example /tmp/env-example-copy'
bash_allowed 'cat ~/.ssh/id_ed25519.pub'
bash_allowed 'env FOO=bar npm test'
bash_allowed 'grep -rn "process.env.API_KEY" src/'
bash_allowed 'ls -la src/ && wc -l src/*.ts'
allowed 'Write in the repo'              Write file_path "$WORK/src/a.ts"
allowed 'Write with a relative path'     Write file_path 'src/b.ts'
allowed 'Edit in a subdirectory session' Edit file_path "$WORK/src/a.ts" "$WORK/src"
allowed 'Write in /tmp'                  Write file_path "/tmp/devlead-guard-scratch.txt"
allowed 'Write Claude Code memory'       Write file_path "$HOME/.claude/projects/p/memory/note.md"
allowed 'Write .env.example'             Write file_path "$WORK/.env.example"
allowed 'Read a source file'             Read file_path "$WORK/src/a.ts"
allowed 'Read outside the repo'          Read file_path "$OTHER/README.md"
allowed 'Grep without a path'            Grep pattern 'TODO'
allowed 'A tool the guard does not judge' WebSearch query 'how to deploy to production'

echo "=== the reason tells the model to stop, not to route around ==="
_guard Bash command 'vercel --prod'
if grep -q 'cannot be lifted from inside the session' "$ERR" && grep -q 'tell the user' "$ERR"; then
  _ok "a block explains that the limit is not negotiable"
else _fail "a block explains that the limit is not negotiable" "$(cat "$ERR")"; fi

echo "=== fails closed ==="
printf 'not json' | DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 2 ]] && grep -q '^DevLead limit \[unreadable\]' "$ERR"; then _ok "unparseable payload is blocked"
else _fail "unparseable payload is blocked" "exit=$rc"; fi
printf '{}' | DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 2 ]]; then _ok "payload without a tool name is blocked"; else _fail "payload without a tool name is blocked" "exit=$rc"; fi
printf '{"tool_name":"Bash","tool_input":{}}' | DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 2 ]]; then _ok "Bash call without a command is blocked"; else _fail "Bash call without a command is blocked" "exit=$rc"; fi
printf '{"tool_name":"Write","tool_input":{}}' | DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 2 ]]; then _ok "Write call without a path is blocked"; else _fail "Write call without a path is blocked" "exit=$rc"; fi
NOJQ="$SANDBOX/nojq"; mkdir -p "$NOJQ"
for b in bash cat git realpath sed grep tr head; do ln -sf "$(command -v "$b")" "$NOJQ/$b"; done
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="$NOJQ" DEVLEAD_GUARD=1 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 2 ]] && grep -q 'jq is not installed' "$ERR"; then _ok "without jq every call is blocked"
else _fail "without jq every call is blocked" "exit=$rc"; fi

echo "=== inert outside DevLead ==="
_payload='{"tool_name":"Bash","tool_input":{"command":"vercel --prod"},"cwd":"'"$WORK"'"}'
printf '%s' "$_payload" | env -u DEVLEAD_GUARD bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 0 && ! -s "$ERR" ]]; then _ok "no DevLead session and no DEVLEAD_GUARD: nothing is blocked"
else _fail "no DevLead session and no DEVLEAD_GUARD: nothing is blocked" "exit=$rc"; fi
printf '%s' "$_payload" | DEVLEAD_GUARD=0 bash "$GUARD" 2>"$ERR"; rc=$?
if [[ $rc -eq 0 ]]; then _ok "DEVLEAD_GUARD=0 is not an on switch"; else _fail "DEVLEAD_GUARD=0 is not an on switch" "exit=$rc"; fi

echo "=== active in an interactive DevLead session ==="
mkdir -p "$HOME/.devlead/scripts"
cp "$REPO_ROOT/.devlead/scripts/devlead-session.sh" "$HOME/.devlead/scripts/"
( cd "$WORK" && bash "$HOME/.devlead/scripts/devlead-session.sh" on >/dev/null 2>&1 )
( cd "$WORK" && printf '%s' "$_payload" | env -u DEVLEAD_GUARD bash "$GUARD" 2>"$ERR" ); rc=$?
if [[ $rc -eq 2 ]]; then _ok "a repo with a DevLead session is guarded without DEVLEAD_GUARD"
else _fail "a repo with a DevLead session is guarded without DEVLEAD_GUARD" "exit=$rc"; fi
( cd "$OTHER" && printf '%s' "$_payload" | env -u DEVLEAD_GUARD bash "$GUARD" 2>"$ERR" ); rc=$?
if [[ $rc -eq 0 ]]; then _ok "a repo without a session stays unguarded"
else _fail "a repo without a session stays unguarded" "exit=$rc"; fi

echo "=== auth can be checked without reading the token ==="
AUTH="$REPO_ROOT/.devlead/scripts/envelope-auth.sh"
out="$(GH_TOKEN=ghp_sentinel_value bash "$AUTH" auth 2>&1)"
if [[ "$out" == "AUTH: available" ]]; then _ok "auth: a resolvable token reports available and nothing else"
else _fail "auth: a resolvable token reports available and nothing else" "$out"; fi
out="$(env -u GH_TOKEN PATH="$NOJQ" bash "$AUTH" auth 2>&1)"
if [[ "$out" == "AUTH: unavailable" ]]; then _ok "auth: no token anywhere reports unavailable"
else _fail "auth: no token anywhere reports unavailable" "$out"; fi
bash_allowed 'bash ~/.devlead/scripts/envelope-auth.sh auth'

echo "=== the installer registers the guard, once ==="
INST_HOME="$SANDBOX/inst-home"
mkdir -p "$INST_HOME/.claude"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$INST_HOME/.claude/settings.json"
HOME="$INST_HOME" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1
HOME="$INST_HOME" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1
S="$INST_HOME/.claude/settings.json"
n="$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "bash ~/.devlead/hooks/guard.sh")] | length' "$S" 2>/dev/null)"
if [[ "$n" == "1" ]]; then _ok "install twice: exactly one guard entry"; else _fail "install twice: exactly one guard entry" "count=$n"; fi
n="$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "echo mine")] | length' "$S" 2>/dev/null)"
if [[ "$n" == "1" ]]; then _ok "install keeps the user's own PreToolUse hook"; else _fail "install keeps the user's own PreToolUse hook" "count=$n"; fi
m="$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command == "bash ~/.devlead/hooks/guard.sh") | .matcher' "$S" 2>/dev/null)"
if [[ "$m" == "Bash|Read|Grep|Write|Edit|MultiEdit|NotebookEdit" ]]; then _ok "the guard is registered for every tool it judges"
else _fail "the guard is registered for every tool it judges" "matcher=$m"; fi
if [[ -e "$INST_HOME/.devlead/hooks/guard.sh" ]]; then _ok "install publishes guard.sh"; else _fail "install publishes guard.sh" "missing"; fi
HOME="$INST_HOME" bash "$REPO_ROOT/uninstall.sh" >/dev/null 2>&1 </dev/null
n="$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command == "bash ~/.devlead/hooks/guard.sh")] | length' "$S" 2>/dev/null)"
u="$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command == "echo mine")] | length' "$S" 2>/dev/null)"
if [[ "$n" == "0" && "$u" == "1" ]]; then _ok "uninstall removes the guard entry and keeps the user's hook"
else _fail "uninstall removes the guard entry and keeps the user's hook" "guard=$n mine=$u"; fi

echo ""
echo "=== SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ $FAIL_COUNT -eq 0 ]]
