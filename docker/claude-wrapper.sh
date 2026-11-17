#!/bin/bash
# claude — the only `claude` on PATH in the DevLead server image (installed as
# /usr/local/bin/claude, root-owned). Every session started here, by the
# launchers or by hand, loads only the user and managed settings:
#
#   - the user settings live in CLAUDE_CONFIG_DIR, which root owns, so no
#     session can change them;
#   - the project and local settings of a repository live in the clone, which
#     the session can write. Loaded, a file planted by one session would run
#     in the next — an apiKeyHelper at start, an env block that reaches every
#     command — outside every hook. So they are never loaded.
#
# --setting-sources user is always passed. A caller's own --setting-sources is
# refused rather than merged: Claude Code takes the last one given, so it would
# win. --settings is refused too: it loads settings on top of the user's
# (an apiKeyHelper or env included) whatever --setting-sources says.
set -euo pipefail

REAL_CLAUDE=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe

for arg in "$@"; do
  case "$arg" in
    --setting-sources|--setting-sources=*|--settings|--settings=*)
      echo "claude: ${arg%%=*} is not accepted here: in the DevLead server image every session loads only the user and managed settings (--setting-sources user), which root owns" >&2
      exit 2
      ;;
  esac
done

exec "$REAL_CLAUDE" --setting-sources user "$@"
