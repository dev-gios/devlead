#!/usr/bin/env bash
# envelope-auth.sh — resolves GH_TOKEN internally (same 4-step chain as sweep.sh
# _ensure_auth) and execs envelope.sh with it exported IN-PROCESS. The token
# value never appears on any caller-visible command line.
set -uo pipefail
TOKEN_FILE="$HOME/.devlead/gh-token"
ENVELOPE_BIN="$HOME/.devlead/scripts/envelope.sh"
_auth_token=""
if [[ -n "${GH_TOKEN:-}" ]]; then
  _auth_token="$GH_TOKEN"
elif [[ -f "$TOKEN_FILE" ]]; then
  _perm="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo "")"
  if [[ "$_perm" == "600" ]]; then
    if [[ -s "$TOKEN_FILE" ]]; then
      _auth_token="$(cat "$TOKEN_FILE")"
    else
      echo "envelope-auth: WARNING: $TOKEN_FILE is 600 but empty — not used" >&2
    fi
  else
    echo "envelope-auth: WARNING: $TOKEN_FILE has permissions $_perm (not 600) — not used (security gate)" >&2
  fi
fi
if [[ -z "$_auth_token" ]] && command -v gh &>/dev/null; then
  _auth_token="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "$_auth_token" ]]; then
  echo "STATUS: blocked" ; echo "GAP:    auth-unavailable — no GH_TOKEN, no valid gh-token file, no gh auth token" ; exit 0
fi
exec env GH_TOKEN="$_auth_token" bash "$ENVELOPE_BIN" "$@"
