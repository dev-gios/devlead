#!/usr/bin/env bash
# DevLead installer
# Crea symlinks desde este repo a sus ubicaciones globales.
# Corré desde el directorio raíz del repo devlead.
# Uso: bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVLEAD_DIR="$HOME/.devlead"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
LOCAL_BIN="$HOME/.local/bin"

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

ln -sf "$REPO_DIR/.devlead/scripts/branch.sh" "$DEVLEAD_DIR/scripts/branch.sh"
chmod +x "$REPO_DIR/.devlead/scripts/branch.sh"
_ok "~/.devlead/scripts/branch.sh → symlinked"

ln -sf "$REPO_DIR/.devlead/scripts/ref-resolver.sh" "$DEVLEAD_DIR/scripts/ref-resolver.sh"
chmod +x "$REPO_DIR/.devlead/scripts/ref-resolver.sh"
_ok "~/.devlead/scripts/ref-resolver.sh → symlinked"

ln -sf "$REPO_DIR/.devlead/scripts/forbidden-check.sh" "$DEVLEAD_DIR/scripts/forbidden-check.sh"
chmod +x "$REPO_DIR/.devlead/scripts/forbidden-check.sh"
_ok "~/.devlead/scripts/forbidden-check.sh → symlinked"

ln -sf "$REPO_DIR/.devlead/scripts/devlead-active.sh" "$DEVLEAD_DIR/scripts/devlead-active.sh"
chmod +x "$REPO_DIR/.devlead/scripts/devlead-active.sh"
_ok "~/.devlead/scripts/devlead-active.sh → symlinked"

ln -sf "$REPO_DIR/.devlead/scripts/envelope.sh" "$DEVLEAD_DIR/scripts/envelope.sh"
chmod +x "$REPO_DIR/.devlead/scripts/envelope.sh"
_ok "~/.devlead/scripts/envelope.sh → symlinked"

ln -sf "$REPO_DIR/.devlead/scripts/sweep.sh" "$DEVLEAD_DIR/scripts/sweep.sh"
chmod +x "$REPO_DIR/.devlead/scripts/sweep.sh"
_ok "~/.devlead/scripts/sweep.sh → symlinked"

# ---------------------------------------------------------------------------
# ~/.local/bin/devlead — front-door CLI
# ---------------------------------------------------------------------------
_section "CLI"

mkdir -p "$LOCAL_BIN"
_info "mkdir ~/.local/bin/"

ln -sf "$REPO_DIR/.devlead/bin/devlead" "$LOCAL_BIN/devlead"
chmod +x "$REPO_DIR/.devlead/bin/devlead"
_ok "~/.local/bin/devlead → $REPO_DIR/.devlead/bin/devlead"

if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
  _warn "~/.local/bin no está en tu PATH — agregá esta línea a tu shell rc:"
  _warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ---------------------------------------------------------------------------
# ~/.devlead/journals/ — directorio de journals per-repo
# ---------------------------------------------------------------------------
_section "Journal"

mkdir -p "$DEVLEAD_DIR/journals"
_ok "~/.devlead/journals/ listo (journal per-repo, se crea al primer /cerremos)"

mkdir -p "$DEVLEAD_DIR/reports"
_ok "~/.devlead/reports/ listo (sweep digests, se crean al primer devlead sweep)"

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

ln -sf "$REPO_DIR/.claude/commands/cerremos.md" "$CLAUDE_COMMANDS_DIR/cerremos.md"
_ok "~/.claude/commands/cerremos.md → $REPO_DIR/.claude/commands/cerremos.md"

ln -sf "$REPO_DIR/.claude/commands/batch.md" "$CLAUDE_COMMANDS_DIR/batch.md"
_ok "~/.claude/commands/batch.md → symlinked"

# ---------------------------------------------------------------------------
# ~/.devlead/hooks/ — post-edit.sh + gate-check.sh
# ---------------------------------------------------------------------------
_section "Hooks"

mkdir -p "$DEVLEAD_DIR/hooks"
_info "mkdir ~/.devlead/hooks/"

ln -sf "$REPO_DIR/.claude/hooks/post-edit.sh" "$DEVLEAD_DIR/hooks/post-edit.sh"
chmod +x "$REPO_DIR/.claude/hooks/post-edit.sh"
_ok "~/.devlead/hooks/post-edit.sh → $REPO_DIR/.claude/hooks/post-edit.sh"

ln -sf "$REPO_DIR/.claude/hooks/gate-check.sh" "$DEVLEAD_DIR/hooks/gate-check.sh"
chmod +x "$REPO_DIR/.claude/hooks/gate-check.sh"
_ok "~/.devlead/hooks/gate-check.sh → $REPO_DIR/.claude/hooks/gate-check.sh"

# ---------------------------------------------------------------------------
# systemd user units — Nivel 2 sweep timer (opt-in; NOT auto-enabled)
# ---------------------------------------------------------------------------
_section "systemd"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
_info "mkdir ~/.config/systemd/user/"

ln -sf "$REPO_DIR/.devlead/systemd/devlead-sweep.service" "$SYSTEMD_USER_DIR/devlead-sweep.service"
_ok "~/.config/systemd/user/devlead-sweep.service → symlinked"

ln -sf "$REPO_DIR/.devlead/systemd/devlead-sweep.timer" "$SYSTEMD_USER_DIR/devlead-sweep.timer"
_ok "~/.config/systemd/user/devlead-sweep.timer → symlinked"

_warn "Timer NOT auto-enabled (opt-in). Para activar el sweep diario a las 07:00:"
_warn "  systemctl --user enable --now devlead-sweep.timer"
_warn "  Cadencia: editá OnCalendar= en $SYSTEMD_USER_DIR/devlead-sweep.timer"
_warn "  Sesiones headless: loginctl enable-linger \$USER"

# ---------------------------------------------------------------------------
# ~/.claude/settings.json — registrar hooks (merge, no sobreescribir)
# ---------------------------------------------------------------------------
_section "Claude settings"

GLOBAL_SETTINGS="$HOME/.claude/settings.json"
HOOKS_FRAGMENT='{"hooks":{"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"bash ~/.devlead/hooks/post-edit.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"bash ~/.devlead/hooks/gate-check.sh"}]}]}}'

# Comandos que identifican unívocamente a los hooks de devlead. Sirven para
# deduplicar: si ya existe una entrada con el mismo command, no se vuelve a
# agregar (idempotente). Deben coincidir con los commands del fragmento.
POST_EDIT_CMD="bash ~/.devlead/hooks/post-edit.sh"
GATE_CHECK_CMD="bash ~/.devlead/hooks/gate-check.sh"

# Programa jq idempotente: parte del settings existente ($base, primer input) y
# le agrega SOLO las entradas devlead que falten, dedup por command string.
# - Defaults: .hooks, .hooks.PostToolUse y .hooks.Stop arrancan en [] si faltan.
# - PostToolUse: append del matcher "Write|Edit" -> post-edit.sh solo si ningún
#   grupo existente ya contiene ese command.
# - Stop: append de gate-check.sh solo si ningún grupo existente lo contiene.
# Cualquier otro hook preexistente queda intacto.
JQ_MERGE_PROGRAM='
  .hooks //= {} |
  .hooks.PostToolUse //= [] |
  .hooks.Stop //= [] |
  ( [ .hooks.PostToolUse[]?.hooks[]?.command ] ) as $postCmds |
  ( [ .hooks.Stop[]?.hooks[]?.command ] ) as $stopCmds |
  ( if ($postCmds | index($pe)) then . else
      .hooks.PostToolUse += [ { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": $pe } ] } ]
    end ) |
  ( if ($stopCmds | index($gc)) then . else
      .hooks.Stop += [ { "hooks": [ { "type": "command", "command": $gc } ] } ]
    end )
'

if [[ -f "$GLOBAL_SETTINGS" ]]; then
  if command -v jq &>/dev/null; then
    _tmp=$(mktemp)
    if jq --arg pe "$POST_EDIT_CMD" --arg gc "$GATE_CHECK_CMD" "$JQ_MERGE_PROGRAM" "$GLOBAL_SETTINGS" > "$_tmp"; then
      mv "$_tmp" "$GLOBAL_SETTINGS"
      _ok "Hooks devlead asegurados en ~/.claude/settings.json (sin duplicar)"
    else
      rm -f "$_tmp"
      _warn "jq merge falló — hooks NO registrados. Agregálos manualmente."
      _warn "Fragmento: $HOOKS_FRAGMENT"
    fi
  else
    _warn "jq no encontrado — hooks NO registrados en settings.json. Agregálos manualmente."
    _warn "Fragmento a agregar: $HOOKS_FRAGMENT"
  fi
else
  if command -v jq &>/dev/null; then
    echo "$HOOKS_FRAGMENT" | jq . > "$GLOBAL_SETTINGS"
    _ok "~/.claude/settings.json creado con hooks"
  else
    echo "$HOOKS_FRAGMENT" > "$GLOBAL_SETTINGS"
    _ok "~/.claude/settings.json creado con hooks (sin pretty-print — jq ausente)"
  fi
fi

# ---------------------------------------------------------------------------
# Verificar dependencias
# ---------------------------------------------------------------------------
_section "Dependencias"

_missing=()
for _cmd in git gh jq shellcheck yq; do
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
echo "  Journal:   ~/.devlead/journals/<repo-key>.md (per-repo)"
echo "  Reports:   ~/.devlead/reports/YYYY-MM-DD.md (sweep digests)"
echo "  Scripts:   ~/.devlead/scripts/state.sh"
echo "             ~/.devlead/scripts/branch.sh"
echo "             ~/.devlead/scripts/ref-resolver.sh"
echo "             ~/.devlead/scripts/forbidden-check.sh"
echo "             ~/.devlead/scripts/envelope.sh"
echo "             ~/.devlead/scripts/sweep.sh"
echo "  CLI:       ~/.local/bin/devlead → devlead <init|plan|check|show|sweep>"
echo "  Hooks:     ~/.devlead/hooks/post-edit.sh"
echo "             ~/.devlead/hooks/gate-check.sh"
echo "  Systemd:   ~/.config/systemd/user/devlead-sweep.service"
echo "             ~/.config/systemd/user/devlead-sweep.timer (NOT enabled — opt-in)"
echo "  Comandos:  ~/.claude/commands/arranquemos.md"
echo "             ~/.claude/commands/cerremos.md"
echo "             ~/.claude/commands/batch.md"
echo "  Settings:  ~/.claude/settings.json (hooks mergeados)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
