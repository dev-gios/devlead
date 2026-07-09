#!/usr/bin/env bash
# DevLead installer
# Publica copias versionadas de este repo en sus ubicaciones globales (ya no
# symlinks — ver REQ-01/README de devlead-pinned-release). Corré desde el
# directorio raíz del repo devlead.
# Uso: bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVLEAD_DIR="$HOME/.devlead"
LOCAL_BIN="$HOME/.local/bin"

# Shared bootstrap primitives (symlinks, systemd units, gh-token seed) — the
# same functions envelope.sh init calls, so "prepare my machine" logic exists
# once. install.sh already knows its own $REPO_DIR (line above), so it passes
# it explicitly rather than relying on the lib's self-resolution fallback.
source "$REPO_DIR/.devlead/scripts/bootstrap-lib.sh"

_info()    { echo "  → $*"; }
_ok()      { echo "  ✓ $*"; }
_warn()    { echo "  ⚠ $*"; }
_section() { echo ""; echo "── $* ──"; }

echo "DevLead installer"
echo "Repo: $REPO_DIR"

# ---------------------------------------------------------------------------
# ~/.devlead/SOURCE_REPO — durable anchor recording this checkout's absolute
# path. Written EARLY, before any copy, mirroring `devlead upgrade`/`init`'s
# ordering invariant (see bootstrap-lib.sh's _bootstrap_source_repo ADR):
# install.sh is the ONLY caller that can seed this anchor with ZERO prior
# state on a genuinely fresh machine, because it derives its own $REPO_DIR
# (line ~9) directly rather than reading an anchor that doesn't exist yet —
# tier-3 self-resolve in _bootstrap_source_repo is effectively dead code once
# bootstrap-lib.sh itself is published as a copy, so this explicit tier-1
# write is the sole first-anchor path (see devlead-pinned-release design).
# ---------------------------------------------------------------------------
_section "Source anchor"
mkdir -p "$DEVLEAD_DIR"
_SRC_REPO="$(_bootstrap_source_repo "$REPO_DIR")"
printf '%s\n' "$_SRC_REPO" > "$DEVLEAD_DIR/SOURCE_REPO"
_ok "~/.devlead/SOURCE_REPO → $_SRC_REPO"

# ---------------------------------------------------------------------------
# ~/.devlead/scripts/, ~/.local/bin/devlead, ~/.claude/commands/, ~/.devlead/hooks/
# Delegated to bootstrap-lib.sh (shared with `devlead init`/`devlead upgrade`)
# — ONE copy-and-migrate primitive, one place to fix. Atomic temp+mv per
# file, content-skip when unchanged, safe to re-run.
# ---------------------------------------------------------------------------
_section "Scripts"
bootstrap_symlinks "$REPO_DIR"
# bootstrap_symlinks ALWAYS returns 0 by design (degradation goes to stderr,
# not the exit code — see bootstrap-lib.sh's return-0 contract ADR), so the
# call above can never signal failure on its own. Spot-check one
# representative file actually published as a REAL file (not a leftover
# symlink) before claiming success, mirroring the gh-token check below
# (install.sh:~100).
_scripts_ok=false
if [[ -f "$DEVLEAD_DIR/scripts/state.sh" && ! -L "$DEVLEAD_DIR/scripts/state.sh" ]]; then
  _ok "~/.devlead/scripts/*.sh → publicado (state, branch, ref-resolver, forbidden-check, devlead-active, envelope, sweep)"
  _scripts_ok=true
else
  _warn "~/.devlead/scripts/state.sh no se publicó como archivo real — revisá warnings arriba"
fi

_section "CLI"
_ok "~/.local/bin/devlead → copia publicada desde $REPO_DIR/.devlead/bin/devlead"

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
# ~/.claude/commands/*.md — ya publicados por bootstrap_symlinks arriba
# ---------------------------------------------------------------------------
_section "Slash command"
_ok "~/.claude/commands/*.md → publicado (arranquemos, cerremos, batch, sweep-execute)"

# ---------------------------------------------------------------------------
# ~/.devlead/hooks/ — ya publicados por bootstrap_symlinks arriba
# ---------------------------------------------------------------------------
_section "Hooks"
_ok "~/.devlead/hooks/*.sh → publicado (post-edit, gate-check)"

# ---------------------------------------------------------------------------
# systemd user units — Nivel 2 sweep timer (opt-in; NOT auto-enabled)
# ---------------------------------------------------------------------------
_section "systemd"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
bootstrap_systemd "$REPO_DIR"
# Same reasoning as the Scripts section above: bootstrap_systemd ALWAYS
# returns 0, so verify the actual end-state (one representative unit
# published as a REAL file, not a leftover symlink) before printing _ok.
_systemd_ok=false
if [[ -f "$SYSTEMD_USER_DIR/devlead-sweep.timer" && ! -L "$SYSTEMD_USER_DIR/devlead-sweep.timer" ]]; then
  _ok "~/.config/systemd/user/devlead-sweep.{service,timer} → publicado"
  _systemd_ok=true
else
  _warn "~/.config/systemd/user/devlead-sweep.timer no se publicó como archivo real — revisá warnings arriba"
fi

# ---------------------------------------------------------------------------
# ~/.devlead/VERSION — written LAST, only if the Scripts + systemd publish
# above both passed their spot-check (mirrors `devlead upgrade`'s set-level
# atomicity: a failed/partial publish must never advance the version stamp;
# a subsequent `devlead upgrade` retries and heals it). REQ-06.
# ---------------------------------------------------------------------------
_section "Version"
if [[ "$_scripts_ok" == "true" && "$_systemd_ok" == "true" ]]; then
  _HEAD_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -n "$_HEAD_SHA" ]]; then
    _HEAD_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ -z "$_HEAD_BRANCH" ]] && _HEAD_BRANCH="HEAD"
    _STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
      echo "SHA: $_HEAD_SHA"
      echo "BRANCH: $_HEAD_BRANCH"
      echo "STAMPED: $_STAMP"
    } > "$DEVLEAD_DIR/VERSION"
    _ok "~/.devlead/VERSION → $_HEAD_SHA ($_STAMP)"
  else
    _warn "no se pudo resolver el HEAD sha de $REPO_DIR — ~/.devlead/VERSION no se escribió (correrá devlead upgrade después)"
  fi
else
  _warn "publish incompleto — ~/.devlead/VERSION no se escribió (correrá devlead upgrade después)"
fi

_warn "Timer NOT auto-enabled (opt-in). Para activar el sweep diario a las 07:00:"
_warn "  systemctl --user enable --now devlead-sweep.timer"
_warn "  Cadencia: editá OnCalendar= en $SYSTEMD_USER_DIR/devlead-sweep.timer"
_warn "  Sesiones headless: loginctl enable-linger \$USER"

# ---------------------------------------------------------------------------
# ~/.devlead/gh-token — headless auth seed for sweep.sh's _ensure_auth
# ---------------------------------------------------------------------------
_section "gh-token"

bootstrap_token_seed
if [[ -f "$DEVLEAD_DIR/gh-token" ]]; then
  _ok "~/.devlead/gh-token listo (usado por sweep.sh _ensure_auth)"
else
  _warn "~/.devlead/gh-token no seedeado — ver warning de gh arriba, si lo hay"
fi

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
echo "  CLI:       ~/.local/bin/devlead → devlead <init|upgrade|plan|check|show|sweep>"
echo "  Hooks:     ~/.devlead/hooks/post-edit.sh"
echo "             ~/.devlead/hooks/gate-check.sh"
echo "  Systemd:   ~/.config/systemd/user/devlead-sweep.service"
echo "             ~/.config/systemd/user/devlead-sweep.timer (NOT enabled — opt-in)"
echo "  Comandos:  ~/.claude/commands/arranquemos.md"
echo "             ~/.claude/commands/cerremos.md"
echo "             ~/.claude/commands/batch.md"
echo "             ~/.claude/commands/sweep-execute.md"
echo "  Settings:  ~/.claude/settings.json (hooks mergeados)"
echo "  Version:   ~/.devlead/SOURCE_REPO, ~/.devlead/VERSION (devlead upgrade re-publica y re-estampa)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
