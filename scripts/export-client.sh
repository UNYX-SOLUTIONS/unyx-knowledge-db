#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"
TENANT_KEY="${1:-}"
[[ -n "$TENANT_KEY" ]] || { echo "Uso: ./scripts/export-client.sh <tenant_key>"; exit 1; }
DB_NAME="${TENANT_KEY//-/_}"
STAMP="$(date +%Y%m%d_%H%M%S)"
FILE="${DB_NAME}_${STAMP}.dump"

mkdir -p "$ROOT/exports"
docker exec "$CONTAINER" pg_dump -U "$ADMIN_USER" -d "$DB_NAME" \
  --no-owner --no-acl -Fc -f "/tmp/$FILE"
docker cp "$CONTAINER:/tmp/$FILE" "$ROOT/exports/$FILE"
docker exec "$CONTAINER" rm -f "/tmp/$FILE"
echo "Export portable creado: $ROOT/exports/$FILE"
