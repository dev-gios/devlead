#!/usr/bin/env bash
# DevLead uninstaller
# Revierte limpiamente lo que hace install.sh:
#   - borra los symlinks devlead bajo ~/.devlead/scripts, ~/.devlead/hooks
#     y ~/.claude/commands (solo si son symlinks que apuntan a ESTE repo),
#   - saca SOLO las entradas de hooks devlead de ~/.claude/settings.json,
#   - PRESERVA ~/.devlead/today.md (es journal del usuario).
# Corré desde el directorio raíz del repo devlead.
# Uso: bash uninstall.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVLEAD_DIR="$HOME/.devlead"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"

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

for _name in state.sh branch.sh ref-resolver.sh forbidden-check.sh devlead-active.sh; do
  _remove_devlead_link "$DEVLEAD_DIR/scripts/$_name" "$REPO_DIR/.devlead/scripts/$_name"
done

# Borrar el directorio scripts solo si quedó vacío.
if [[ -d "$DEVLEAD_DIR/scripts" ]] && [[ -z "$(ls -A "$DEVLEAD_DIR/scripts")" ]]; then
  rmdir "$DEVLEAD_DIR/scripts"
  _ok "borrado directorio vacío ~/.devlead/scripts/"
fi

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
# ~/.devlead/today.md — journal del usuario (NO se borra)
# ---------------------------------------------------------------------------
_section "Journal"

if [[ -e "$DEVLEAD_DIR/today.md" ]]; then
  _warn "journal preservado en ~/.devlead/today.md — es data tuya"
  _info "si querés borrarlo: rm ~/.devlead/today.md"
else
  _info "journal ~/.devlead/today.md no existe — nada que preservar"
fi

# Borrar ~/.devlead solo si quedó completamente vacío (sin journal ni nada).
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
