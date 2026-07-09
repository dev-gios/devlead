#!/usr/bin/env bash
# DevLead uninstaller
# Revierte limpiamente lo que hace install.sh:
#   - borra los symlinks devlead bajo ~/.devlead/scripts, ~/.devlead/hooks
#     y ~/.claude/commands (solo si son symlinks que apuntan a ESTE repo),
#   - saca SOLO las entradas de hooks devlead de ~/.claude/settings.json,
#   - PRESERVA ~/.devlead/journals/ (son journals del usuario, uno por repo).
# Corré desde el directorio raíz del repo devlead.
# Uso: bash uninstall.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVLEAD_DIR="$HOME/.devlead"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
LOCAL_BIN="$HOME/.local/bin"

_info()    { echo "  → $*"; }
_ok()      { echo "  ✓ $*"; }
_warn()    { echo "  ⚠ $*"; }
_section() { echo ""; echo "── $* ──"; }

echo "DevLead uninstaller"
echo "Repo: $REPO_DIR"

# _remove_devlead_link <ruta_del_link> <target_esperado>
# Borra la ruta SOLO si es un symlink que apunta al target esperado dentro de
# este repo. Nunca borra un archivo real ni un link ajeno. Idempotente: si ya
# no existe, lo informa y sigue.
_remove_devlead_link() {
  local link="$1"
  local expected="$2"
  if [[ -L "$link" ]]; then
    local resolved
    resolved="$(readlink "$link")"
    if [[ "$resolved" == "$expected" ]]; then
      rm -f "$link"
      _ok "borrado $link"
    else
      _warn "$link es un symlink pero apunta a '$resolved' (no a este repo) — se deja intacto"
    fi
  elif [[ -e "$link" ]]; then
    _warn "$link existe pero NO es un symlink — se deja intacto (no se borra un archivo real)"
  else
    _info "$link ya no existe — nada que hacer"
  fi
}

# ---------------------------------------------------------------------------
# ~/.devlead/scripts/
# ---------------------------------------------------------------------------
_section "Scripts"

for _name in state.sh branch.sh ref-resolver.sh forbidden-check.sh devlead-active.sh envelope.sh envelope-auth.sh sweep.sh; do
  _remove_devlead_link "$DEVLEAD_DIR/scripts/$_name" "$REPO_DIR/.devlead/scripts/$_name"
done

# Borrar el directorio scripts solo si quedó vacío.
if [[ -d "$DEVLEAD_DIR/scripts" ]] && [[ -z "$(ls -A "$DEVLEAD_DIR/scripts")" ]]; then
  rmdir "$DEVLEAD_DIR/scripts"
  _ok "borrado directorio vacío ~/.devlead/scripts/"
fi

# ---------------------------------------------------------------------------
# ~/.local/bin/devlead — front-door CLI
# ---------------------------------------------------------------------------
_section "CLI"

_remove_devlead_link "$LOCAL_BIN/devlead" "$REPO_DIR/.devlead/bin/devlead"

# ---------------------------------------------------------------------------
# ~/.devlead/hooks/
# ---------------------------------------------------------------------------
_section "Hooks"

for _name in post-edit.sh gate-check.sh; do
  _remove_devlead_link "$DEVLEAD_DIR/hooks/$_name" "$REPO_DIR/.claude/hooks/$_name"
done

if [[ -d "$DEVLEAD_DIR/hooks" ]] && [[ -z "$(ls -A "$DEVLEAD_DIR/hooks")" ]]; then
  rmdir "$DEVLEAD_DIR/hooks"
  _ok "borrado directorio vacío ~/.devlead/hooks/"
fi

# ---------------------------------------------------------------------------
# systemd user units — devlead-sweep.service + devlead-sweep.timer
# ---------------------------------------------------------------------------
_section "systemd"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# FIX 6: Disable the timer before removing unit symlinks to avoid dangling
# systemd state. Idempotent: if the timer was never enabled this is a no-op.
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now devlead-sweep.timer 2>/dev/null || true
  _ok "timer deshabilitado (o ya estaba inactivo)"
fi

_remove_devlead_link "$SYSTEMD_USER_DIR/devlead-sweep.service" \
  "$REPO_DIR/.devlead/systemd/devlead-sweep.service"
_remove_devlead_link "$SYSTEMD_USER_DIR/devlead-sweep.timer" \
  "$REPO_DIR/.devlead/systemd/devlead-sweep.timer"

# ---------------------------------------------------------------------------
# ~/.devlead/gh-token + ~/.devlead/autonomous-repos — sweep credential y enrollment
# ---------------------------------------------------------------------------
_section "Sweep enrollment"

# gh-token es una CREDENCIAL: nunca debe sobrevivir al uninstall. El `rm` vive
# SOLO acá (nunca en init/sweep/lib) — la creación es de bootstrap_token_seed,
# la destrucción es exclusiva de este flujo. rm -f es idempotente por sí mismo.
if [[ -f "$DEVLEAD_DIR/gh-token" ]]; then
  rm -f "$DEVLEAD_DIR/gh-token"
  _ok "credencial ~/.devlead/gh-token borrada"
else
  _info "archivo ~/.devlead/gh-token no existe — nada que borrar"
fi

# De-enrollar ESTE repo de autonomous-repos, dejando el resto de las entradas
# intactas. Mismo idioma dedup que devlead-active.sh `off` (grep -vxF + mktemp +
# mv). La resolución de root DEBE coincidir con la que _do_optin usó al escribir
# la línea: `git rev-parse --show-toplevel 2>/dev/null || pwd` (envelope.sh:15).
_repos_file="$DEVLEAD_DIR/autonomous-repos"
_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -f "$_repos_file" ]] && grep -qxF "$_root" "$_repos_file" 2>/dev/null; then
  _tmp="$(mktemp)"
  grep -vxF "$_root" "$_repos_file" > "$_tmp" 2>/dev/null || true
  mv "$_tmp" "$_repos_file"
  _ok "repo de-enrolled de ~/.devlead/autonomous-repos"
else
  _info "repo no estaba enrolled en autonomous-repos — nada que hacer"
fi

# ---------------------------------------------------------------------------
# ~/.claude/commands/
# ---------------------------------------------------------------------------
_section "Slash commands"

for _name in arranquemos.md cerremos.md batch.md; do
  _remove_devlead_link "$CLAUDE_COMMANDS_DIR/$_name" "$REPO_DIR/.claude/commands/$_name"
done

# ---------------------------------------------------------------------------
# ~/.claude/settings.json — sacar SOLO los hooks devlead (dedup por command)
# ---------------------------------------------------------------------------
_section "Claude settings"

GLOBAL_SETTINGS="$HOME/.claude/settings.json"
POST_EDIT_CMD="bash ~/.devlead/hooks/post-edit.sh"
GATE_CHECK_CMD="bash ~/.devlead/hooks/gate-check.sh"

# Programa jq que saca SOLO las entradas devlead identificadas por su command:
# - De cada grupo de PostToolUse/Stop filtra los hooks cuyo command sea el
#   nuestro; si un grupo queda con .hooks vacío, se descarta el grupo entero.
# - Cualquier otro hook preexistente queda intacto.
# - Limpia arrays/objeto .hooks vacíos para no dejar basura.
JQ_PRUNE_PROGRAM='
  def prune($cmd):
    map( .hooks |= map(select(.command != $cmd)) )
    | map(select((.hooks | length) > 0)) ;
  if (.hooks | type) == "object" then
    ( if (.hooks.PostToolUse | type) == "array"
        then .hooks.PostToolUse |= prune($pe) else . end ) |
    ( if (.hooks.Stop | type) == "array"
        then .hooks.Stop |= prune($gc) else . end ) |
    ( if (.hooks.PostToolUse? | type) == "array" and (.hooks.PostToolUse | length) == 0
        then del(.hooks.PostToolUse) else . end ) |
    ( if (.hooks.Stop? | type) == "array" and (.hooks.Stop | length) == 0
        then del(.hooks.Stop) else . end ) |
    ( if (.hooks | length) == 0 then del(.hooks) else . end )
  else . end
'

if [[ -f "$GLOBAL_SETTINGS" ]]; then
  if command -v jq &>/dev/null; then
    _tmp=$(mktemp)
    if jq --arg pe "$POST_EDIT_CMD" --arg gc "$GATE_CHECK_CMD" "$JQ_PRUNE_PROGRAM" "$GLOBAL_SETTINGS" > "$_tmp"; then
      mv "$_tmp" "$GLOBAL_SETTINGS"
      _ok "Hooks devlead removidos de ~/.claude/settings.json (otros hooks intactos)"
    else
      rm -f "$_tmp"
      _warn "jq falló — hooks NO removidos. Editá ~/.claude/settings.json manualmente."
      _warn "Sacá las entradas con command: '$POST_EDIT_CMD' y '$GATE_CHECK_CMD'"
    fi
  else
    _warn "jq no encontrado — hooks NO removidos de settings.json. Editá manualmente."
    _warn "Sacá las entradas con command: '$POST_EDIT_CMD' y '$GATE_CHECK_CMD'"
  fi
else
  _info "settings.json no existe (~/.claude/settings.json) — nada que limpiar"
fi

# ---------------------------------------------------------------------------
# ~/.devlead/journals/ — journals per-repo del usuario (NO se borran)
# ---------------------------------------------------------------------------
_section "Journal"

if [[ -d "$DEVLEAD_DIR/journals" ]] && [[ -n "$(ls -A "$DEVLEAD_DIR/journals")" ]]; then
  _warn "journals preservados en ~/.devlead/journals/ — son data tuya"
  _info "si querés borrarlos: rm -rf ~/.devlead/journals/"
elif [[ -d "$DEVLEAD_DIR/journals" ]]; then
  rmdir "$DEVLEAD_DIR/journals"
  _ok "borrado directorio vacío ~/.devlead/journals/"
else
  _info "directorio ~/.devlead/journals/ no existe — nada que preservar"
fi

# ---------------------------------------------------------------------------
# ~/.devlead/reports/ — sweep digests del usuario (NO se borran)
# ---------------------------------------------------------------------------
_section "Reports"

if [[ -d "$DEVLEAD_DIR/reports" ]] && [[ -n "$(ls -A "$DEVLEAD_DIR/reports")" ]]; then
  _warn "reports preservados en ~/.devlead/reports/ — son data tuya (sweep digests)"
  _info "si querés borrarlos: rm -rf ~/.devlead/reports/"
elif [[ -d "$DEVLEAD_DIR/reports" ]]; then
  rmdir "$DEVLEAD_DIR/reports"
  _ok "borrado directorio vacío ~/.devlead/reports/"
else
  _info "directorio ~/.devlead/reports/ no existe — nada que preservar"
fi

# Borrar ~/.devlead solo si quedó completamente vacío.
if [[ -d "$DEVLEAD_DIR" ]] && [[ -z "$(ls -A "$DEVLEAD_DIR")" ]]; then
  rmdir "$DEVLEAD_DIR"
  _ok "borrado directorio vacío ~/.devlead/"
fi

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ DevLead desinstalado."
echo "  Para reinstalar: bash install.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
