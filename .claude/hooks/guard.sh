#!/usr/bin/env bash
# guard.sh — DevLead's hard limits, checked before a tool runs (PreToolUse).
#
# DevLead starts and carries out work on its own. What it may NOT do is decided
# here, in code, and not by a sentence in a prompt:
#
#   production   deploys, infrastructure changes, cloud CLIs, remote shells,
#                publishing packages or releases, pushing to the default branch
#   merge-door   merging a PR any other way than merge.sh (which reads the
#                envelope the user wrote)
#   database     anything aimed at a database that is not on this machine
#   secrets      reading or writing a credential file outside the places the
#                user allowed, or dumping the environment
#   scope        writing a file outside the repository the session started in
#   self-config  changing the files that configure these limits
#
# Input: the hook payload on stdin
#   {"tool_name": "...", "tool_input": {...}, "cwd": "..."}
# Exit 0 lets the call through. Exit 2 blocks it; the reason on stderr goes
# back to the model. A payload that cannot be read is blocked (fail closed).
#
# When it is active:
#   - in an interactive DevLead session (devlead-session.sh check), and
#   - in every unattended run: the launchers export DEVLEAD_GUARD=1, which the
#     session cannot unset because a hook inherits the environment of the
#     Claude Code process, not of the shell a tool call runs in.
# In any other Claude Code session it does nothing.
#
# The places a credential may be read from are listed by the user, one glob
# per line, in ~/.devlead/secrets-allow. Nothing in DevLead writes that file,
# and this guard blocks a session that tries to.
#
# What this is NOT: a sandbox. A Bash command is matched as text, so a command
# built to hide what it does can get past it. It stops the mistakes an honest
# agent makes; it does not contain a hostile one. The structural defence for
# production is that its credentials are not on this machine — keep it so.

set -uo pipefail

_deny() {
  {
    echo "DevLead limit [$1]: $2"
    echo "This limit cannot be lifted from inside the session. Do not look for another way to reach the same effect: if the task needs it, stop and tell the user exactly what is needed and why."
  } >&2
  exit 2
}

# --- Active? ----------------------------------------------------------------
if [[ "${DEVLEAD_GUARD:-}" != "1" ]]; then
  bash "$HOME/.devlead/scripts/devlead-session.sh" check >/dev/null 2>&1 || exit 0
fi

# --- Payload ----------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || _deny unreadable "jq is not installed, so the call cannot be inspected"
_payload="$(cat)"
_tool="$(jq -r '.tool_name // empty' <<<"$_payload" 2>/dev/null)" || _tool=""
[[ -n "$_tool" ]] || _deny unreadable "the hook payload has no tool_name"

_cwd="$(jq -r '.cwd // empty' <<<"$_payload" 2>/dev/null)"
[[ -n "$_cwd" && -d "$_cwd" ]] || _cwd="$PWD"
_root="$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$_root" ]] || _root="$(cd "$_cwd" && pwd -P)"

ALLOW_FILE="$HOME/.devlead/secrets-allow"

# --- Paths ------------------------------------------------------------------
# Absolute, symlinks resolved, `..` collapsed — a link inside the repo that
# points outside it is judged by where it lands.
_abs() {
  local p="$1"
  # shellcheck disable=SC2088 # a literal leading tilde in the payload, not an expansion
  if [[ "$p" == "~" || "$p" == "~/"* ]]; then p="$HOME${p:1}"; fi
  [[ "$p" == /* ]] || p="$_cwd/$p"
  realpath -m -- "$p" 2>/dev/null || printf '%s\n' "$p"
}

_under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

# Is this (absolute) path a credential?
_is_secret() {
  local p="$1" b="${1##*/}"
  case "$b" in
    *.pub|known_hosts|.env.example|.env.sample|.env.template|.env.dist|.env.defaults) return 1 ;;
  esac
  case "$b" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.kdbx|*.keystore|*.jks) return 0 ;;
    id_rsa*|id_ed25519*|id_ecdsa*|id_dsa*|.netrc|.pgpass|.pypirc) return 0 ;;
    credentials|credentials.json|service-account*.json|secrets.json|secrets.yml|secrets.yaml) return 0 ;;
  esac
  case "$p" in
    "$HOME"/.ssh/*|"$HOME"/.aws/*|"$HOME"/.gnupg/*|"$HOME"/.kube/*|"$HOME"/.azure/*) return 0 ;;
    "$HOME"/.config/gh/hosts.yml|"$HOME"/.config/gcloud/*|"$HOME"/.docker/config.json) return 0 ;;
    "$HOME"/.npmrc|"$HOME"/.devlead/gh-token|"$HOME"/.devlead/*.env) return 0 ;;
  esac
  return 1
}

# Did the user list this path as a place credentials may be read from?
_allowed_secret() {
  local p="$1" glob
  [[ -f "$ALLOW_FILE" ]] || return 1
  while IFS= read -r glob || [[ -n "$glob" ]]; do
    glob="${glob%$'\r'}"
    [[ -z "${glob//[[:space:]]/}" || "$glob" == \#* ]] && continue
    # shellcheck disable=SC2088 # a literal leading tilde in the file, not an expansion
    [[ "$glob" == "~/"* ]] && glob="$HOME${glob:1}"
    # shellcheck disable=SC2053 # the right side is a glob on purpose
    [[ "$p" == $glob ]] && return 0
  done < "$ALLOW_FILE"
  return 1
}

_check_secret_path() {
  local abs
  abs="$(_abs "$1")"
  _is_secret "$abs" || return 0
  _allowed_secret "$abs" && return 0
  _deny secrets "$1 is a credential file and is not listed in ~/.devlead/secrets-allow"
}

# The files that configure these limits. Judged before `scope`, so the reason
# names what the file is.
_check_self_config() {
  local abs
  abs="$(_abs "$1")"
  if _under "$abs" "$HOME/.devlead" \
     || [[ "$abs" == "$HOME"/.claude/settings*.json ]] \
     || _under "$abs" "$HOME/.claude/hooks" \
     || [[ "$abs" == "$_root"/.claude/settings*.json ]]; then
    _deny self-config "$1 configures DevLead's own limits or Claude Code's hooks; only the user changes it"
  fi
}

_check_scope() {
  local abs tmp
  abs="$(_abs "$1")"
  tmp="$(realpath -m -- "${TMPDIR:-/tmp}" 2>/dev/null || echo /tmp)"
  _under "$abs" "$_root" && return 0
  _under "$abs" /tmp && return 0
  _under "$abs" "$tmp" && return 0
  _under "$abs" "$HOME/.claude/projects" && return 0
  _under "$abs" "$HOME/.claude/plans" && return 0
  _deny scope "$1 is outside the repository this session works in ($_root)"
}

# --- File tools -------------------------------------------------------------
case "$_tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    _path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$_payload" 2>/dev/null)"
    [[ -n "$_path" ]] || _deny unreadable "$_tool call without a file path"
    _check_self_config "$_path"
    _check_scope "$_path"
    _check_secret_path "$_path"
    exit 0
    ;;
  Read|Grep)
    _path="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<<"$_payload" 2>/dev/null)"
    [[ -n "$_path" ]] && _check_secret_path "$_path"
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

# --- Bash -------------------------------------------------------------------
_cmd="$(jq -r '.tool_input.command // empty' <<<"$_payload" 2>/dev/null)"
[[ -n "$_cmd" ]] || _deny unreadable "Bash call without a command"

_NL=$'\n'
# Where a command can start: the beginning, or after ; & | ( ` $( or a newline,
# then any number of wrappers (sudo, npx, VAR=value ...) and an optional path
# in front of the program name. Matching only there keeps a word inside a
# commit message from looking like a command.
_CS="(^|[;&|(\`${_NL}]|\\\$\\()[[:space:]]*((sudo|npx|bunx|time|nohup|command|exec)[[:space:]]+|(pnpm|yarn|npm|bun)[[:space:]]+(dlx|exec|x)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?"
_ARGS='([^;&|]*[[:space:]])?'      # options before the subcommand, same simple command
_END='($|[[:space:];&|)])'

# _runs <text> <regex for program + arguments>
_runs() { local re="${_CS}($2)"; [[ "$1" =~ $re ]]; }

# -- self-config
if [[ "$_cmd" =~ secrets-allow ]]; then
  _deny self-config "the command names ~/.devlead/secrets-allow; only the user reads or changes that list"
fi
if [[ "$_cmd" =~ \.claude/settings[^[:space:]]*\.json ]] && [[ "$_cmd" =~ (\>|tee|sed[[:space:]]+-i|mv|cp|rm|jq|install|truncate|dd)[[:space:]] ]]; then
  _deny self-config "the command would change a Claude Code settings file, where the hooks are registered"
fi

# -- production
if [[ "$_cmd" =~ (^|[^A-Za-z0-9_])(NODE_ENV|RAILS_ENV|RACK_ENV|APP_ENV|DJANGO_ENV|FLASK_ENV|ENVIRONMENT|ENV)=[\"\']?prod ]]; then
  _deny production "the command sets a production environment"
fi

# Local forms of the deploy CLIs are fine; take them out before the check so
# `vercel dev` passes and `vercel dev; vercel --prod` still does not.
_scan="$(sed -E 's/(vercel|netlify|wrangler)[[:space:]]+dev([[:space:];&|)]|$)/true\2/g; s/firebase[[:space:]]+emulators:[a-z]+/true/g; s/(serverless|sls)[[:space:]]+offline/true/g' <<<"$_cmd")"
if _runs "$_scan" "(vercel|netlify|firebase|fly|flyctl|wrangler|railway|heroku|serverless|sls|amplify|doctl)${_END}"; then
  _deny production "the command runs a deployment CLI"
fi
if _runs "$_cmd" "(terraform|tofu|terragrunt|pulumi)[[:space:]]+${_ARGS}(apply|destroy|import|up|refresh|state|taint|untaint)${_END}"; then
  _deny production "the command changes infrastructure"
fi
if _runs "$_cmd" "(kubectl|helm|oc)[[:space:]]+${_ARGS}(apply|delete|create|replace|patch|edit|scale|rollout|set|exec|drain|cordon|install|upgrade|uninstall|rollback|run|cp)${_END}"; then
  _deny production "the command changes a cluster"
fi
if _runs "$_cmd" "(aws|gcloud|az)${_END}"; then
  _deny production "the command runs a cloud provider CLI against a real account"
fi
if _runs "$_cmd" "(ssh|scp|sftp)${_END}" \
   || _runs "$_cmd" "rsync[[:space:]]+${_ARGS}[^[:space:]/:]+:[^[:space:]]*"; then
  _deny production "the command reaches another machine"
fi
if _runs "$_cmd" "(npm|pnpm|yarn|bun|cargo)[[:space:]]+${_ARGS}publish${_END}" \
   || _runs "$_cmd" "twine[[:space:]]+${_ARGS}upload${_END}" \
   || _runs "$_cmd" "gem[[:space:]]+${_ARGS}push${_END}" \
   || _runs "$_cmd" "docker[[:space:]]+${_ARGS}push${_END}" \
   || _runs "$_cmd" "gh[[:space:]]+release[[:space:]]+(create|delete|edit|upload)${_END}"; then
  _deny production "the command publishes a package, an image or a release"
fi
if _runs "$_cmd" "gh[[:space:]]+repo[[:space:]]+(delete|archive|rename|edit)${_END}"; then
  _deny production "the command changes the repository itself"
fi

# The default branch is what ships. main/master always count; so does whatever
# the remote names as its default.
_default="$(git -C "$_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
_default="${_default#origin/}"
_defaults="main|master"
[[ -n "$_default" && "$_default" =~ ^[A-Za-z0-9._/-]+$ ]] && _defaults="$_defaults|${_default//./\\.}"
if _runs "$_cmd" "git[[:space:]]+${_ARGS}push${_END}"; then
  _re="push[^;&|]*[[:space:]:+](refs/heads/)?(${_defaults})${_END}"
  if [[ "$_cmd" =~ $_re ]]; then
    _deny production "the command pushes to the default branch"
  fi
  if [[ "$_cmd" =~ push[^\;\&\|]*[[:space:]]--(all|mirror)($|[[:space:]]) ]]; then
    _deny production "the command pushes every branch, the default one included"
  fi
  _current="$(git -C "$_cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  _re="^(${_defaults})$"
  if [[ -n "$_current" && "$_current" =~ $_re ]]; then
    _deny production "the command pushes while the default branch ($_current) is checked out"
  fi
fi

# -- merge-door
if _runs "$_cmd" "gh[[:space:]]+pr[[:space:]]+${_ARGS}merge${_END}"; then
  _deny merge-door "a PR is merged only through merge.sh, which applies the envelope the user wrote"
fi

# -- database
# Local: this machine, or a dotless name (a compose service). Everything else
# is somebody's real database until proven otherwise.
_is_local_host() {
  local h="${1,,}"
  h="${h#[}"; h="${h%]}"
  case "$h" in
    localhost|127.*|::1|0.0.0.0|host.docker.internal|"") return 0 ;;
  esac
  [[ "$h" != *.* && "$h" != *:* ]]
}

# Every database URL in the command, wherever it appears (an argument, an
# inline DATABASE_URL=..., a heredoc).
while IFS= read -r _url; do
  [[ -n "$_url" ]] || continue
  _host="${_url#*://}"
  _host="${_host%%[/?#]*}"
  _host="${_host##*@}"
  if [[ "$_host" == \[* ]]; then _host="${_host%%]*}]"; else _host="${_host%%:*}"; fi
  _is_local_host "$_host" \
    || _deny database "the command names a database that is not on this machine ($_host)"
done < <(grep -oiE '(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|rediss?|sqlserver|mssql|clickhouse|libsql|cockroachdb)://[^[:space:]"'"'"'`<>|;)]+' <<<"$_cmd" || true)

_DB_CLIENTS='psql|mysql|mariadb|mongosh|mongo|redis-cli|sqlcmd|pg_restore|pg_dump|pg_dumpall|mongorestore|mongodump|clickhouse-client|cockroach'
if _runs "$_cmd" "(turso|pscale|neon|neonctl)${_END}"; then
  _deny database "the command runs a hosted-database CLI"
fi
if _runs "$_cmd" "supabase[[:space:]]+${_ARGS}(link|secrets|projects|orgs|--linked|--db-url)${_END}" \
   || _runs "$_cmd" "supabase[[:space:]]+${_ARGS}(db[[:space:]]+push|functions[[:space:]]+deploy)${_END}"; then
  _deny database "the command works on a hosted Supabase project, not the local stack"
fi
if _runs "$_cmd" "(${_DB_CLIENTS})${_END}"; then
  # -h host / --host host / --host=host / -hhost
  _re="[[:space:]](-h[[:space:]]*|--host[=[:space:]]+)([^[:space:];&|]+)"
  _rest="$_cmd"
  while [[ "$_rest" =~ $_re ]]; do
    _h="${BASH_REMATCH[2]}"
    _h="${_h#[\"\']}"; _h="${_h%[\"\']}"
    _is_local_host "$_h" \
      || _deny database "the command connects to a database that is not on this machine ($_h)"
    _rest="${_rest#*"${BASH_REMATCH[0]}"}"
  done
  # A destination held in a variable cannot be judged from here.
  if [[ "$_cmd" =~ \$\{?[A-Za-z_]*(DATABASE|DB|MONGO|REDIS|POSTGRES|PG|MYSQL|SUPABASE)[A-Za-z_]* ]]; then
    _deny database "the command takes its database address from a variable, so the destination is unknown — use an explicit local address"
  fi
fi
if _runs "$_cmd" "prisma[[:space:]]+${_ARGS}migrate[[:space:]]+deploy${_END}"; then
  _deny database "prisma migrate deploy applies migrations to a deployed database"
fi
_MIGRATORS='prisma|drizzle-kit|knex|sequelize|sequelize-cli|typeorm|alembic|flyway|liquibase|dbmate|atlas|rails|rake|artisan|sqlx|diesel|goose|migrate'
if _runs "$_cmd" "(${_MIGRATORS})${_END}" \
   && [[ "$_cmd" =~ (^|[^A-Za-z0-9])(prod|production)($|[^A-Za-z0-9]) ]]; then
  _deny database "the command runs a migration tool and names production"
fi

# -- secrets
if _runs "$_cmd" "gh[[:space:]]+auth[[:space:]]+token${_END}" \
   || _runs "$_cmd" "gh[[:space:]]+(secret|variable)${_END}"; then
  _deny secrets "the command reads or changes stored credentials through gh"
fi
if _runs "$_cmd" "printenv${_END}" || _runs "$_cmd" "(env|export[[:space:]]+-p|declare[[:space:]]+-x)[[:space:]]*($|[;&|)>])"; then
  _deny secrets "the command dumps the environment, credentials included"
fi
# Every word of the command that names a credential file.
while IFS= read -r _tok; do
  [[ -n "$_tok" ]] || continue
  _check_secret_path "$_tok"
done < <(tr -s '[:space:]"'"'"'`=<>|;&()' '\n' <<<"$_cmd" | grep -E '[./~]|^(credentials|id_(rsa|ed25519|ecdsa|dsa))' || true)

exit 0
