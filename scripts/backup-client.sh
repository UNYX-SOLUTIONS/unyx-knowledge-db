#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
if [[ -z "$TENANT_KEY" ]]; then
  echo "Uso: $0 <tenant_key>"
  exit 1
fi

DB_NAME="${TENANT_KEY//-/_}"
STAMP="$(date +%Y%m%d_%H%M%S)"
FILE="/backups/${DB_NAME}_${STAMP}.dump"

docker exec "$CONTAINER" pg_dump \
  -U "$ADMIN_USER" \
  -d "$DB_NAME" \
  --no-owner \
  --no-acl \
  -Fc \
  -f "$FILE"

echo "Backup creado: ./backups/${DB_NAME}_${STAMP}.dump"
