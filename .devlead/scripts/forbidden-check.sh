#!/usr/bin/env bash
# forbidden-check.sh — DevLead zone guard for batch mode
# Checks whether given file paths touch any of the 4 forbidden zones.
# Structured stdout contract (KEY: value). Always exits 0 on normal operation.
#
# Usage: forbidden-check.sh <path> [<path>...]
#    or: <paths-newline-separated> | forbidden-check.sh
#
# Output:
#   STATUS: clear                         → no path matched any zone (exit 0)
#   STATUS: blocked                       → at least one match found (exit 0)
#   ZONE:   <db-migrations|prod-config|auth-security|ci-cd>
#   PATH:   <first matching path>
#
# Exit codes:
#   0 — normal operation (clear or blocked)
#   1 — misuse (no arguments and no stdin)

set -uo pipefail

# ---------------------------------------------------------------------------
# Input handling: args take priority, else read stdin
# ---------------------------------------------------------------------------
PATHS=()

if [[ $# -gt 0 ]]; then
  PATHS=("$@")
else
  # If stdin is a TTY with no data → usage error
  if [[ -t 0 ]]; then
    echo "Usage: forbidden-check.sh <path> [<path>...]" >&2
    echo "   or: <paths-newline-separated> | forbidden-check.sh" >&2
    exit 1
  fi
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && PATHS+=("$_line")
  done
fi

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "Usage: forbidden-check.sh <path> [<path>...]" >&2
  echo "   or: <paths-newline-separated> | forbidden-check.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Zone pattern matching (case-insensitive)
# Outputs: "blocked {zone}" or "clear" to caller-readable variable
# ---------------------------------------------------------------------------
shopt -s nocasematch

_match_zone() {
  local p="$1"

  # --- Zone: db-migrations ---
  for pat in \
    "*/migrations/*" "*migrations/*" \
    "*_migration.*" \
    "*.sql" \
    "*/schema.prisma" "*schema.prisma" \
    "*/db/migrate/*" \
    "*/alembic/*" \
    ; do
    if [[ "$p" == $pat ]]; then
      echo "db-migrations"
      return 0
    fi
  done

  # --- Zone: prod-config ---
  for pat in \
    "*.prod.*" \
    "*/config/production*" "config/production*" \
    ".env.production" "*.env.production" \
    "*/deploy/*" "deploy/*" \
    "*.tf" "*.tfvars" \
    "*/k8s/*" "k8s/*" \
    "*/helm/*" "helm/*" \
    "*/terraform/*" "terraform/*" \
    ; do
    if [[ "$p" == $pat ]]; then
      echo "prod-config"
      return 0
    fi
  done

  # --- Zone: auth-security ---
  for pat in \
    "*/auth/*" \
    "*/security/*" \
    "*middleware*auth*" "*auth*middleware*" \
    "*.pem" "*.key" \
    "*secret*" \
    "*/rbac/*" \
    "*/permissions/*" \
    "*/oauth/*" \
    ; do
    if [[ "$p" == $pat ]]; then
      echo "auth-security"
      return 0
    fi
  done

  # --- Zone: ci-cd ---
  for pat in \
    ".github/workflows/*" "*/.github/workflows/*" \
    ".gitlab-ci.yml" "*/.gitlab-ci.yml" \
    "Jenkinsfile" "*/Jenkinsfile" \
    ".circleci/*" "*/.circleci/*" \
    "azure-pipelines.yml" "*/azure-pipelines.yml" \
    ; do
    if [[ "$p" == $pat ]]; then
      echo "ci-cd"
      return 0
    fi
  done

  echo ""
  return 1
}

# ---------------------------------------------------------------------------
# Main loop: check each path, emit first match and stop
# ---------------------------------------------------------------------------
for _path in "${PATHS[@]}"; do
  _zone=$(_match_zone "$_path")
  if [[ -n "$_zone" ]]; then
    shopt -u nocasematch
    echo "STATUS: blocked"
    echo "ZONE:   $_zone"
    echo "PATH:   $_path"
    exit 0
  fi
done

shopt -u nocasematch

echo "STATUS: clear"
exit 0
