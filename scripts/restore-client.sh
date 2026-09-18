#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
DUMP_FILE="${2:-}"

if [[ -z "$TENANT_KEY" || -z "$DUMP_FILE" ]]; then
  echo "Uso: $0 <tenant_key> <dump>"
  echo 'Ejemplo: ./scripts/restore-client.sh altosa ./backups/altosa_20260918_120000.dump'
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "No existe: $DUMP_FILE"
  exit 1
fi

if [[ ! "$TENANT_KEY" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
  echo "tenant_key inválido (solo minúsculas, números y guiones)."
  exit 1
fi

DB_NAME="${TENANT_KEY//-/_}"
APP_ROLE="${DB_NAME}_app"

echo "==> Verificando rol de aplicación: $APP_ROLE"
ROLE_EXISTS="$(docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$APP_ROLE'")"

if [[ "$ROLE_EXISTS" != "1" ]]; then
  APP_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
  echo "==> El rol no existe; creándolo"
  docker exec -i "$CONTAINER" psql \
    -U "$ADMIN_USER" \
    -d "$ADMIN_DB" \
    -v ON_ERROR_STOP=1 \
    -v role="$APP_ROLE" \
    -v password="$APP_PASSWORD" <<'SQL'
SELECT unyx_core.ensure_role(:'role', :'password');
SQL
  echo "NUEVO_APP_PASSWORD=$APP_PASSWORD"
fi

echo "==> Recreando base de datos: $DB_NAME"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);"

docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $DB_NAME OWNER $APP_ROLE;"

echo "==> Instalando extensiones en $DB_NAME"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "==> Restaurando dump"
docker cp "$DUMP_FILE" "$CONTAINER:/tmp/unyx_restore.dump"

docker exec "$CONTAINER" pg_restore \
  -U "$APP_ROLE" \
  -d "$DB_NAME" \
  --no-owner \
  --no-acl \
  --exit-on-error \
  /tmp/unyx_restore.dump

docker exec "$CONTAINER" rm -f /tmp/unyx_restore.dump

echo "==> Registrando tenant (si no existe)"
docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -v tenant="$TENANT_KEY" \
  -v db="$DB_NAME" \
  -v role="$APP_ROLE" <<'SQL'
INSERT INTO unyx_core.tenants (tenant_key, display_name, database_name, app_role)
VALUES (:'tenant', :'tenant', :'db', :'role')
ON CONFLICT (tenant_key) DO NOTHING;
SQL

echo "Restore completado."
