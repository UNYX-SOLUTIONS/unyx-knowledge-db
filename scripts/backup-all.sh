#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANTS="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc \
  "SELECT tenant_key FROM unyx_core.tenants WHERE status='active' ORDER BY tenant_key;")"

while IFS= read -r tenant; do
  [[ -z "$tenant" ]] && continue
  "$SCRIPT_DIR/backup-client.sh" "$tenant"
done <<< "$TENANTS"

echo "Backups de clientes completados."
