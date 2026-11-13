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
# built to hide what it does can get past it, and so does anything inside a
# script of the repo itself (`npm run deploy`, `make deploy`, `./deploy.sh`). It stops the mistakes an honest
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

# --- Payload and activation --------------------------------------------------
_payload="$(cat)"
_have_jq=0
command -v jq >/dev/null 2>&1 && _have_jq=1

_cwd=""
[[ $_have_jq -eq 1 ]] && _cwd="$(jq -r '.cwd // empty' <<<"$_payload" 2>/dev/null)"
[[ -n "$_cwd" && -d "$_cwd" ]] || _cwd="$PWD"

# The session is judged by where the call runs (the payload's cwd), not by
# where the hook process happens to have been started.
if [[ "${DEVLEAD_GUARD:-}" != "1" ]]; then
  ( cd "$_cwd" 2>/dev/null && bash "$HOME/.devlead/scripts/devlead-session.sh" check ) >/dev/null 2>&1 || exit 0
fi

[[ $_have_jq -eq 1 ]] \
  || _deny unreadable "jq is not installed, so the call cannot be inspected"
_tool="$(jq -r '.tool_name // empty' <<<"$_payload" 2>/dev/null)" || _tool=""
[[ -n "$_tool" ]] || _deny unreadable "the hook payload has no tool_name"

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
    id_rsa*|id_ed25519*|id_ecdsa*|id_dsa*|.netrc|.pgpass|.pypirc|.git-credentials) return 0 ;;
    credentials|credentials.json|service-account*.json|secrets.json|secrets.yml|secrets.yaml) return 0 ;;
  esac
  case "$p" in
    "$HOME"/.ssh/*|"$HOME"/.aws/*|"$HOME"/.gnupg/*|"$HOME"/.kube/*|"$HOME"/.azure/*) return 0 ;;
    "$HOME"/.config/gh/hosts.yml|"$HOME"/.config/gcloud/*|"$HOME"/.docker/config.json) return 0 ;;
    "$HOME"/.npmrc|"$HOME"/.devlead/gh-token|"$HOME"/.devlead/*.env) return 0 ;;
    "$HOME"/.config/git/credentials|/proc/*/environ) return 0 ;;
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
  Monitor)
    # Monitor runs a shell command in the background: judged like Bash.
    [[ -n "$(jq -r '.tool_input.command // empty' <<<"$_payload" 2>/dev/null)" ]] || exit 0
    ;;
  *) exit 0 ;;
esac

# --- Bash -------------------------------------------------------------------
_cmd="$(jq -r '.tool_input.command // empty' <<<"$_payload" 2>/dev/null)"
[[ -n "$_cmd" ]] || _deny unreadable "$_tool call without a command"

# What is judged is the command with its prose taken out: heredoc bodies and
# the text of -m / --body / --title arguments. A commit message that mentions
# `.env` or `vercel --prod` is not a command.
_scan="$(awk '
  delim != "" { t = $0; sub(/^[\t ]+/, "", t); if (t == delim) delim = ""; next }
  { print
    if (match($0, /(^|[^<])<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
      d = substr($0, RSTART, RLENGTH)
      sub(/^[^<]?<<-?[ \t]*["\047\\]?/, "", d)
      delim = d
    }
  }' <<<"$_cmd")"
_re="([[:space:]](-m|--message|--body|--title|--notes|--subject)[[:space:]=]+)(\"([^\"\\\\]|\\\\.)*\"|'[^']*')"
while [[ "$_scan" =~ $_re ]]; do
  _scan="${_scan/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}TEXT"}"
done

_NL=$'\n'
# Where a command can start: the beginning, or after ; & | ( ` $( or a newline,
# then any number of wrappers (sudo, npx, bash -c, VAR=value ...) and an
# optional path in front of the program name. Matching only there keeps a word
# that is merely an argument from looking like a command.
_CS="(^|[;&|(\`${_NL}]|\\\$\\()[[:space:]]*((sudo|npx|bunx|time|nohup|command|exec|then|do|else)[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+|xargs[[:space:]]+(-[^[:space:]]+[[:space:]]+)*|(bash|sh|zsh)[[:space:]]+-[a-z]*c[[:space:]]+[\"']?|(python3?|uv|pipx)[[:space:]]+(-m|run|tool run)[[:space:]]+|(pnpm|yarn|npm|bun)[[:space:]]+(dlx|exec|x)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?"
_ARGS='([^;&|]*[[:space:]])?'      # options before the subcommand, same simple command
_END="(\$|[[:space:];&|)\"'])"

# _runs <text> <regex for program + arguments>
_runs() { local re="${_CS}($2)"; [[ "$1" =~ $re ]]; }

# --- Bash: paths --------------------------------------------------------------
# A Bash command is not parsed, only split: into simple commands, then into
# words. Enough to see where an ordinary command writes and what it reads.

# Does this glob, as typed, reach a credential file that exists?
_check_secret_glob() {
  local w="$1" dir base n
  base="${w##*/}"
  dir="${w%"$base"}"
  for n in .env .env.local .env.development .env.production .env.staging .env.test \
           .netrc .pgpass .git-credentials id_rsa id_ed25519 id_ecdsa credentials credentials.json; do
    # A glob does not match a leading dot unless it spells one.
    [[ "$n" == .* && "$base" != .* ]] && continue
    # shellcheck disable=SC2053 # the right side is the glob under test
    [[ "$n" == $base ]] || continue
    [[ -e "$(_abs "${dir}${n}")" ]] && _check_secret_path "${dir}${n}"
  done
  return 0
}

_check_word_secret() {
  local w="$1" part
  # Naming a credential file in order to leave it out is not reading it.
  [[ "$w" == --exclude* || "$w" == --ignore* ]] && return 0
  for part in "$w" "${w##*:}" "${w##*=}"; do
    [[ -n "$part" && "$part" != -* ]] || continue
    if [[ "$part" == *[\*\?\[]* ]]; then _check_secret_glob "$part"; else _check_secret_path "$part"; fi
  done
  return 0
}

_check_write_target() {
  local t="$1"
  [[ -n "$t" ]] || return 0
  case "$t" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*|'&'*|-) return 0 ;; esac
  _check_self_config "$t"
  _check_scope "$t"
  _check_secret_path "$t"
}

# A recursive text search prints whatever it finds, credential files included.
_check_recursive_search() {
  local dir="$1" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    _is_secret "$f" || continue
    _allowed_secret "$f" && continue
    _deny secrets "this search would read ${f#"$_root"/}, a credential file — search with a tool that skips ignored files (rg, git grep) or add --exclude='.env*'"
  done < <(find "$dir" -maxdepth 4 \( -name node_modules -o -name .git -o -name vendor -o -name .venv \) -prune \
             -o -type f \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name '.netrc' -o -name 'credentials.json' \) \
             -print 2>/dev/null | head -50)
  return 0
}

_simple="$(sed -E 's/&&|\|\||[;|&()`]|\$\(/\n/g' <<<"$_scan")"
while IFS= read -r _line || [[ -n "$_line" ]]; do
  _line="${_line//[\"\']/}"
  read -ra _w <<<"$_line" || true
  [[ ${#_w[@]} -gt 0 ]] || continue

  # Leading wrappers and VAR=value assignments are not the program.
  _i=0
  while [[ $_i -lt ${#_w[@]} ]]; do
    case "${_w[$_i]}" in
      sudo|command|exec|time|nohup|then|do|else|env) _i=$((_i + 1)) ;;
      [A-Za-z_]*=*) [[ "${_w[$_i]%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break; _i=$((_i + 1)) ;;
      *) break ;;
    esac
  done
  [[ $_i -lt ${#_w[@]} ]] || continue
  _prog="${_w[$_i]##*/}"
  _args=("${_w[@]:$((_i + 1))}")

  # Redirections: `> file`, `>> file`, `2> file`, attached or not.
  _n=${#_w[@]}
  for ((_k = 0; _k < _n; _k++)); do
    if [[ "${_w[$_k]}" =~ ^[0-9]*\>\>?(.*)$ ]]; then
      _t="${BASH_REMATCH[1]}"
      [[ -z "$_t" && $((_k + 1)) -lt $_n ]] && _t="${_w[$((_k + 1))]}"
      _check_write_target "$_t"
    fi
  done

  # Plain arguments: no options, no redirection operators.
  _plain=()
  for _a in "${_args[@]}"; do
    [[ "$_a" == -* || "$_a" =~ ^[0-9]*[\<\>] ]] && continue
    _plain+=("$_a")
  done

  case "$_prog" in
    cd|pushd)
      _t="${_plain[0]:-$HOME}"
      [[ "$_t" == "-" ]] || _check_scope "$_t"
      ;;
    git)
      for ((_k = 0; _k < ${#_args[@]}; _k++)); do
        case "${_args[$_k]}" in
          -C) _check_scope "${_args[$((_k + 1))]:-}" ;;
          --git-dir=*|--work-tree=*) _check_scope "${_args[$_k]#*=}" ;;
        esac
      done
      ;;
    rm|rmdir|touch|mkdir|chmod|chown|truncate|tee|shred|mv)
      for _a in "${_plain[@]}"; do
        # chmod/chown take a mode or an owner first; neither is a path.
        if [[ "$_prog" == ch* && "$_a" == "${_plain[0]}" ]]; then continue; fi
        _check_write_target "$_a"
      done
      ;;
    cp|ln|install|rsync)
      [[ ${#_plain[@]} -gt 0 ]] && _check_write_target "${_plain[-1]}"
      ;;
    dd)
      for _a in "${_args[@]}"; do [[ "$_a" == of=* ]] && _check_write_target "${_a#of=}"; done
      ;;
    sed|perl)
      _inplace=0
      for _a in "${_args[@]}"; do [[ "$_a" == -i* || "$_a" == --in-place* || "$_a" == -pi* ]] && _inplace=1; done
      if [[ $_inplace -eq 1 ]]; then
        for _a in "${_plain[@]:1}"; do _check_write_target "$_a"; done
      fi
      ;;
  esac

  # Credential files named as arguments. echo/printf only print their words.
  case "$_prog" in
    echo|printf) ;;
    *) for _a in "${_args[@]}"; do _check_word_secret "$_a"; done ;;
  esac

  # Recursive searches.
  _recursive=0
  case "$_prog" in
    grep|egrep|fgrep)
      for _a in "${_args[@]}"; do [[ "$_a" =~ ^-[A-Za-z]*[rR] || "$_a" == --recursive ]] && _recursive=1; done ;;
    rg|ag)
      for _a in "${_args[@]}"; do [[ "$_a" =~ ^-[A-Za-z]*u || "$_a" == --no-ignore* || "$_a" == --hidden || "$_a" == --unrestricted ]] && _recursive=1; done ;;
  esac
  if [[ $_recursive -eq 1 ]]; then
    _excluded=0
    for _a in "${_args[@]}"; do [[ "$_a" == --exclude* || "$_a" == -g || "$_a" == --glob* || "$_a" == --include* ]] && _excluded=1; done
    if [[ $_excluded -eq 0 ]]; then
      _dir="$_cwd"
      if [[ ${#_plain[@]} -gt 1 && -d "$(_abs "${_plain[-1]}")" ]]; then _dir="$(_abs "${_plain[-1]}")"; fi
      _check_recursive_search "$_dir"
    fi
  fi
done <<<"$_simple"

# -- self-config
if [[ "$_scan" =~ secrets-allow ]]; then
  _deny self-config "the command names ~/.devlead/secrets-allow; only the user reads or changes that list"
fi

# -- production
# Local forms are fine; take them out before the check so `vercel dev` passes
# and `vercel dev; vercel --prod` still does not.
_prod="$(sed -E 's/(vercel|netlify|wrangler)[[:space:]]+dev([[:space:];&|)]|$)/true\2/g; s/firebase[[:space:]]+emulators:[a-z]+/true/g; s/(serverless|sls)[[:space:]]+offline/true/g; s/publish[^;&|]*--dry-run/true/g; s/(aws|gcloud|az)[[:space:]]+(--version|version|help|--help)/true/g' <<<"$_scan")"
if _runs "$_prod" "(vercel|netlify|firebase|fly|flyctl|wrangler|railway|heroku|serverless|sls|amplify|doctl)${_END}" \
   || _runs "$_prod" "(cdk|sam)[[:space:]]+${_ARGS}deploy${_END}"; then
  _deny production "the command runs a deployment CLI"
fi
if _runs "$_prod" "(terraform|tofu|terragrunt|pulumi)[[:space:]]+${_ARGS}(apply|destroy|import|up|refresh|state|taint|untaint)${_END}"; then
  _deny production "the command changes infrastructure"
fi
if _runs "$_prod" "(kubectl|helm|oc)[[:space:]]+${_ARGS}(apply|delete|create|replace|patch|edit|scale|rollout|set|exec|drain|cordon|install|upgrade|uninstall|rollback|run|cp)${_END}"; then
  _deny production "the command changes a cluster"
fi
if _runs "$_prod" "(aws|gcloud|az)${_END}"; then
  _deny production "the command runs a cloud provider CLI against a real account"
fi
if _runs "$_prod" "(ssh|scp|sftp)${_END}" \
   || _runs "$_prod" "rsync[[:space:]]+${_ARGS}[^[:space:]/:]+:[^[:space:]]*"; then
  _deny production "the command reaches another machine"
fi
if _runs "$_prod" "(npm|pnpm|yarn|bun|cargo|uv|poetry|flit|hatch)[[:space:]]+${_ARGS}publish${_END}" \
   || _runs "$_prod" "twine[[:space:]]+${_ARGS}upload${_END}" \
   || _runs "$_prod" "gem[[:space:]]+${_ARGS}push${_END}" \
   || _runs "$_prod" "docker[[:space:]]+${_ARGS}(push|--push)${_END}" \
   || _runs "$_prod" "gh[[:space:]]+release[[:space:]]+(create|delete|edit|upload)${_END}"; then
  _deny production "the command publishes a package, an image or a release"
fi
if _runs "$_prod" "gh[[:space:]]+repo[[:space:]]+(delete|archive|rename|edit)${_END}" \
   || _runs "$_prod" "gh[[:space:]]+workflow[[:space:]]+run${_END}"; then
  _deny production "the command changes the repository itself or starts one of its workflows"
fi

# The default branch is what ships. main/master always count; so does whatever
# the remote names as its default.
_default="$(git -C "$_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
_default="${_default#origin/}"
_defaults="main|master"
[[ -n "$_default" && "$_default" =~ ^[A-Za-z0-9._/-]+$ ]] && _defaults="$_defaults|${_default//./\\.}"
if _runs "$_scan" "git[[:space:]]+${_ARGS}push${_END}"; then
  _re="push[^;&|]*[[:space:]:+\"'](refs/heads/)?(${_defaults})${_END}"
  if [[ "$_scan" =~ $_re ]]; then
    _deny production "the command pushes to the default branch"
  fi
  if [[ "$_scan" =~ push[^\;\&\|]*[[:space:]]--(all|mirror)($|[[:space:]]) ]]; then
    _deny production "the command pushes every branch, the default one included"
  fi
  # Which branch is checked out when the push runs? If the command switches
  # branch first, the answer is in the command, not in the working tree.
  _re_sw="git[[:space:]]+${_ARGS}(checkout|switch)[[:space:]]"
  _re_to_default="git[[:space:]]+${_ARGS}(checkout|switch)[[:space:]]+([^;&|]*[[:space:]])?[\"']?(${_defaults})${_END}"
  _re_new="git[[:space:]]+${_ARGS}(checkout|switch)[[:space:]]+([^;&|]*[[:space:]])?(-[bBcC]|--create|--orphan)[[:space:]]"
  if [[ "$_scan" =~ $_re_to_default ]] && ! [[ "$_scan" =~ $_re_new ]]; then
    _deny production "the command checks out the default branch and pushes"
  elif ! [[ "$_scan" =~ $_re_sw ]]; then
    _current="$(git -C "$_cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    _re="^(${_defaults})$"
    if [[ -n "$_current" && "$_current" =~ $_re ]]; then
      _deny production "the command pushes while the default branch ($_current) is checked out"
    fi
  fi
fi

# -- merge-door
if _runs "$_scan" "gh[[:space:]]+pr[[:space:]]+${_ARGS}merge${_END}"; then
  _deny merge-door "a PR is merged only through merge.sh, which applies the envelope the user wrote"
fi
if { _runs "$_scan" "gh[[:space:]]+api${_END}" || [[ "$_scan" =~ api\.github\.com ]]; } \
   && [[ "$_scan" =~ /merges?($|[^A-Za-z0-9_-]) ]]; then
  _deny merge-door "the command calls a GitHub merge endpoint; a PR is merged only through merge.sh"
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
# inline DATABASE_URL=...).
while IFS= read -r _url; do
  [[ -n "$_url" ]] || continue
  _host="${_url#*://}"
  _host="${_host%%[/?#]*}"
  _host="${_host##*@}"
  if [[ "$_host" == \[* ]]; then _host="${_host%%]*}]"; else _host="${_host%%:*}"; fi
  _is_local_host "$_host" \
    || _deny database "the command names a database that is not on this machine ($_host)"
done < <(grep -oiE '(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|rediss?|sqlserver|mssql|clickhouse|libsql|cockroachdb)://[^[:space:]"'"'"'`<>|;)]+' <<<"$_scan" || true)

# A host handed over through the environment.
_re="(^|[^A-Za-z0-9_])(PGHOST|PGHOSTADDR|MYSQL_HOST|MYSQL_TCP_HOST|REDIS_HOST|REDISCLI_HOST|MONGO_HOST|MONGODB_HOST|DB_HOST|DATABASE_HOST)=[\"']?([^[:space:]\"';&|]+)"
_rest="$_scan"
while [[ "$_rest" =~ $_re ]]; do
  _is_local_host "${BASH_REMATCH[3]}" \
    || _deny database "the command points ${BASH_REMATCH[2]} at a database that is not on this machine (${BASH_REMATCH[3]})"
  _rest="${_rest#*"${BASH_REMATCH[0]}"}"
done

_DB_CLIENTS='psql|mysql|mariadb|mongosh|mongo|redis-cli|sqlcmd|pg_restore|pg_dump|pg_dumpall|mongorestore|mongodump|clickhouse-client|cockroach'
if _runs "$_scan" "(turso|pscale|neon|neonctl)${_END}"; then
  _deny database "the command runs a hosted-database CLI"
fi
if _runs "$_scan" "supabase[[:space:]]+${_ARGS}(link|secrets|projects|orgs|--linked|--db-url)${_END}" \
   || _runs "$_scan" "supabase[[:space:]]+${_ARGS}(db[[:space:]]+push|functions[[:space:]]+deploy)${_END}"; then
  _deny database "the command works on a hosted Supabase project, not the local stack"
fi
# A client anywhere in the command, not only at its start: `docker run img
# psql -h remote` connects just the same.
_re="(^|[^A-Za-z0-9_./-])(${_DB_CLIENTS})(\$|[[:space:]\"'])"
if [[ "$_scan" =~ $_re ]]; then
  # -h host / --host host / --host=host / -hhost / host=... in a conninfo string
  _re="([[:space:]](-h[[:space:]]*|--host[=[:space:]]+)|[[:space:]\"']host(addr)?=)[\"']?([^[:space:];&|\"']+)"
  _rest="$_scan"
  while [[ "$_rest" =~ $_re ]]; do
    _is_local_host "${BASH_REMATCH[4]}" \
      || _deny database "the command connects to a database that is not on this machine (${BASH_REMATCH[4]})"
    _rest="${_rest#*"${BASH_REMATCH[0]}"}"
  done
  # A destination held in a variable cannot be judged from here.
  if [[ "$_scan" =~ \$\{?[A-Za-z_]*(DATABASE|DB|MONGO|REDIS|POSTGRES|PG|MYSQL|SUPABASE)[A-Za-z_]* ]]; then
    _deny database "the command takes its database address from a variable, so the destination is unknown — use an explicit local address"
  fi
fi
if _runs "$_scan" "prisma[[:space:]]+${_ARGS}migrate[[:space:]]+deploy${_END}"; then
  _deny database "prisma migrate deploy applies migrations to a deployed database"
fi
_MIGRATORS='prisma|drizzle-kit|knex|sequelize|sequelize-cli|typeorm|alembic|flyway|liquibase|dbmate|atlas|rails|rake|artisan|sqlx|diesel|goose|migrate'
if _runs "$_scan" "(${_MIGRATORS})${_END}" \
   && [[ "$_scan" =~ (^|[^A-Za-z0-9])(prod|production)($|[^A-Za-z0-9]) ]]; then
  _deny database "the command runs a migration tool and names production"
fi

# -- secrets
if _runs "$_scan" "gh[[:space:]]+auth[[:space:]]+token${_END}" \
   || _runs "$_scan" "gh[[:space:]]+(secret|variable)${_END}" \
   || [[ "$_scan" =~ --show-token ]]; then
  _deny secrets "the command reads or changes stored credentials through gh"
fi
if [[ "$_scan" =~ \$\{?(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)($|[^A-Za-z0-9_]) ]]; then
  _deny secrets "the command reads the GitHub token from the environment"
fi
if _runs "$_scan" "printenv${_END}" || _runs "$_scan" "(env|export[[:space:]]+-p|declare[[:space:]]+-x)[[:space:]]*(\$|[;&|)>])"; then
  _deny secrets "the command dumps the environment, credentials included"
fi

exit 0
