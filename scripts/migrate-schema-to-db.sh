#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
DISPLAY_NAME="${2:-$TENANT_KEY}"
EMBEDDING_DIM="${3:-1536}"

if [[ -z "$TENANT_KEY" ]]; then
  echo "Uso: $0 <tenant_key> [display_name] [embedding_dim]"
  echo 'Ejemplo: ./scripts/migrate-schema-to-db.sh altosa "ALTOSA Mobiliario" 1536'
  exit 1
fi

if [[ ! "$TENANT_KEY" =~ ^[a-z][a-z0-9_]{1,62}$ ]]; then
  echo "tenant_key inválido (solo minúsculas, números y guiones bajos)."
  exit 1
fi

DB_NAME="${TENANT_KEY//-/_}"
SCHEMA_NAME="$TENANT_KEY"

echo "==> Aplicando estructura de registro actualizada (unyx_core)"
docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'unyx_core'
          AND table_name = 'tenants'
          AND column_name = 'schema_name'
    ) THEN
        ALTER TABLE unyx_core.tenants
            RENAME COLUMN schema_name TO database_name;
    END IF;
END
$$;
SQL

docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  < "$SCRIPT_DIR/../database/init/02_core.sql"

echo "==> Creando base de datos y esquema para $TENANT_KEY"
"$SCRIPT_DIR/create-client.sh" "$TENANT_KEY" "$DISPLAY_NAME" "$EMBEDDING_DIM"

echo "==> Exportando datos del schema $SCHEMA_NAME (base $ADMIN_DB)"
docker exec "$CONTAINER" pg_dump \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -n "$SCHEMA_NAME" \
  --data-only \
  --no-owner \
  --no-acl \
  -f /tmp/unyx_migrate.sql

echo "==> Reescribiendo calificadores de schema"
docker exec "$CONTAINER" bash -c \
  "sed -i 's/^SET search_path = .*/SET search_path = public;/' /tmp/unyx_migrate.sql && sed -i 's/${SCHEMA_NAME}\\./public./g' /tmp/unyx_migrate.sql"

echo "==> Importando datos en la base $DB_NAME"
docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -f /tmp/unyx_migrate.sql

docker exec "$CONTAINER" rm -f /tmp/unyx_migrate.sql

echo ""
echo "Migración de datos completada."
echo "Verifique los datos en la base '$DB_NAME' antes de eliminar el schema '$SCHEMA_NAME'."
echo ""
echo "Para eliminar el schema antiguo (acción manual, una vez verificado):"
echo "  docker exec $CONTAINER psql -U $ADMIN_USER -d $ADMIN_DB -c 'DROP SCHEMA $SCHEMA_NAME CASCADE;'"
echo "  docker exec $CONTAINER psql -U $ADMIN_USER -d $ADMIN_DB -c \"UPDATE unyx_core.tenants SET status = 'migrated' WHERE tenant_key = '$TENANT_KEY';\""
