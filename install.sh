#!/usr/bin/env bash
# DevLead installer
# Crea symlinks desde este repo a sus ubicaciones globales.
# Corré desde el directorio raíz del repo devlead.
# Uso: bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVLEAD_DIR="$HOME/.devlead"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"

_info()    { echo "  → $*"; }
_ok()      { echo "  ✓ $*"; }
_warn()    { echo "  ⚠ $*"; }
_section() { echo ""; echo "── $* ──"; }

echo "DevLead installer"
echo "Repo: $REPO_DIR"

# ---------------------------------------------------------------------------
# ~/.devlead/scripts/
# ---------------------------------------------------------------------------
_section "Scripts"

mkdir -p "$DEVLEAD_DIR/scripts"
_info "mkdir ~/.devlead/scripts/"

ln -sf "$REPO_DIR/.devlead/scripts/state.sh" "$DEVLEAD_DIR/scripts/state.sh"
chmod +x "$REPO_DIR/.devlead/scripts/state.sh"
_ok "~/.devlead/scripts/state.sh → $REPO_DIR/.devlead/scripts/state.sh"

# ---------------------------------------------------------------------------
# ~/.devlead/today.md — journal (no sobreescribir si ya existe)
# ---------------------------------------------------------------------------
_section "Journal"

if [[ -f "$DEVLEAD_DIR/today.md" ]]; then
  _warn "~/.devlead/today.md ya existe — no se sobreescribe"
else
  cp "$REPO_DIR/.devlead/today.md" "$DEVLEAD_DIR/today.md"
  _ok "~/.devlead/today.md creado desde plantilla"
fi

# ---------------------------------------------------------------------------
# ~/.claude/commands/arranquemos.md
# ---------------------------------------------------------------------------
_section "Slash command"

if [[ ! -d "$CLAUDE_COMMANDS_DIR" ]]; then
  mkdir -p "$CLAUDE_COMMANDS_DIR"
  _info "mkdir ~/.claude/commands/"
fi

ln -sf "$REPO_DIR/.claude/commands/arranquemos.md" "$CLAUDE_COMMANDS_DIR/arranquemos.md"
_ok "~/.claude/commands/arranquemos.md → $REPO_DIR/.claude/commands/arranquemos.md"

# ---------------------------------------------------------------------------
# Verificar dependencias
# ---------------------------------------------------------------------------
_section "Dependencias"

_missing=()
for _cmd in git gh jq; do
  if command -v "$_cmd" &>/dev/null; then
    _ok "$_cmd encontrado"
  else
    _warn "$_cmd NO encontrado — instalalo para funcionalidad completa"
    _missing+=("$_cmd")
  fi
done

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#_missing[@]} -eq 0 ]]; then
  echo "✓ DevLead instalado. Abrí Claude Code en cualquier repo y corré /arranquemos."
else
  echo "⚠ DevLead instalado con advertencias."
  echo "  Faltan: ${_missing[*]}"
  echo "  El comando va a degradar graciosamente sin ellas."
fi

echo ""
echo "  Journal: ~/.devlead/today.md"
echo "  Script:  ~/.devlead/scripts/state.sh"
echo "  Comando: ~/.claude/commands/arranquemos.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
