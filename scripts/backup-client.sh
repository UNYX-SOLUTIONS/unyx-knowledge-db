#!/usr/bin/env bash
set -euo pipefail

TENANT_KEY="${1:-}"
if [[ -z "$TENANT_KEY" ]]; then
  echo "Uso: $0 <tenant_key>"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
FILE="/backups/${TENANT_KEY}_${STAMP}.dump"

docker exec unyx-knowledge-db pg_dump \
  -U "${POSTGRES_USER:-unyx_admin}" \
  -d "${POSTGRES_DB:-unyx_knowledge}" \
  -n "$TENANT_KEY" \
  --no-owner \
  --no-acl \
  -Fc \
  -f "$FILE"

echo "Backup creado: ./backups/${TENANT_KEY}_${STAMP}.dump"
