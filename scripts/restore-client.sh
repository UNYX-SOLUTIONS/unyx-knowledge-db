#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

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
STAGING_DB="${DB_NAME}_staging"
OLD_DB="${DB_NAME}_old"
LIVE_RENAMED=0

cleanup() {
  if [[ "$LIVE_RENAMED" == "1" ]]; then
    echo "==> Revertiendo intercambio de bases"
    docker exec "$CONTAINER" psql \
      -U "$ADMIN_USER" -d "$ADMIN_DB" \
      -c "ALTER DATABASE $OLD_DB RENAME TO $DB_NAME;" >/dev/null 2>&1 || true
  fi
  docker exec "$CONTAINER" psql \
    -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -c "DROP DATABASE IF EXISTS $STAGING_DB WITH (FORCE);" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Verificando disponibilidad de PostgreSQL"
for i in $(seq 1 30); do
  if docker exec "$CONTAINER" pg_isready -U "$ADMIN_USER" -d "$ADMIN_DB" -q; then
    break
  fi
  if [[ "$i" == "30" ]]; then
    echo "ERROR: PostgreSQL no está disponible."
    exit 1
  fi
  sleep 1
done

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

echo "==> Restaurando dump en base temporal: $STAGING_DB"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $STAGING_DB WITH (FORCE);"

docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE $STAGING_DB OWNER $APP_ROLE;"

docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$STAGING_DB" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

docker cp "$DUMP_FILE" "$CONTAINER:/tmp/unyx_restore.dump"

docker exec "$CONTAINER" pg_restore \
  -U "$APP_ROLE" \
  -d "$STAGING_DB" \
  --single-transaction \
  --no-owner \
  --no-acl \
  --no-comments \
  /tmp/unyx_restore.dump

docker exec "$CONTAINER" rm -f /tmp/unyx_restore.dump

echo "==> Validando restauración en $STAGING_DB"
TABLE_COUNT="$(docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$STAGING_DB" \
  -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('products', 'documents', 'kb_versions')")"

if [[ "$TABLE_COUNT" != "3" ]]; then
  echo "ERROR: la restauración no contiene el esquema completo (products, documents, kb_versions)."
  echo "Se cancela el restore; la base actual '$DB_NAME' no fue modificada."
  exit 1
fi

echo "==> Intercambiando bases (staging -> $DB_NAME)"
LIVE_EXISTS="$(docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")"

if [[ "$LIVE_EXISTS" == "1" ]]; then
  docker exec "$CONTAINER" psql \
    -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true

  docker exec "$CONTAINER" psql \
    -U "$ADMIN_USER" \
    -d "$ADMIN_DB" \
    -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $OLD_DB WITH (FORCE);"

  docker exec "$CONTAINER" psql \
    -U "$ADMIN_USER" \
    -d "$ADMIN_DB" \
    -v ON_ERROR_STOP=1 \
    -c "ALTER DATABASE $DB_NAME RENAME TO $OLD_DB;"
  LIVE_RENAMED=1
fi

docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "ALTER DATABASE $STAGING_DB RENAME TO $DB_NAME;"

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

echo "==> Eliminando base anterior ($OLD_DB)"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $OLD_DB WITH (FORCE);"
LIVE_RENAMED=0

echo "Restore completado."
