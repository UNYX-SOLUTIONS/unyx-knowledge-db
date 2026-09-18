#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
DISPLAY_NAME="${2:-}"
EMBEDDING_DIM="${3:-1536}"

if [[ -z "$TENANT_KEY" || -z "$DISPLAY_NAME" ]]; then
  echo "Uso: $0 <tenant_key> <display_name> [embedding_dim]"
  echo 'Ejemplo: ./scripts/create-client.sh altosa "ALTOSA Mobiliario" 1536'
  exit 1
fi

if [[ ! "$TENANT_KEY" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
  echo "tenant_key inválido (solo minúsculas, números y guiones)."
  exit 1
fi

if [[ ! "$EMBEDDING_DIM" =~ ^[0-9]+$ ]] || (( EMBEDDING_DIM < 1 || EMBEDDING_DIM > 16000 )); then
  echo "embedding_dim inválido."
  exit 1
fi

DB_NAME="${TENANT_KEY//-/_}"
APP_ROLE="${DB_NAME}_app"
APP_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"

echo "==> Creando rol de aplicación: $APP_ROLE"
docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -v role="$APP_ROLE" \
  -v password="$APP_PASSWORD" <<'SQL'
SELECT unyx_core.ensure_role(:'role', :'password');
SQL

DB_EXISTS="$(docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")"

if [[ "$DB_EXISTS" != "1" ]]; then
  echo "==> Creando base de datos: $DB_NAME"
  docker exec "$CONTAINER" psql \
    -U "$ADMIN_USER" \
    -d "$ADMIN_DB" \
    -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $DB_NAME OWNER $APP_ROLE"
else
  echo "==> La base de datos $DB_NAME ya existe; se reutilizará"
fi

echo "==> Instalando extensiones en $DB_NAME"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "==> Aplicando permisos de conexión en $DB_NAME"
docker exec "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c "REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC; GRANT CONNECT ON DATABASE $DB_NAME TO $APP_ROLE;"

echo "==> Aplicando esquema base en $DB_NAME"
docker exec -i "$CONTAINER" psql \
  -U "$APP_ROLE" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -v dim="$EMBEDDING_DIM" \
  < "$SCRIPT_DIR/../database/client/schema.sql"

echo "==> Registrando tenant en unyx_core.tenants"
docker exec -i "$CONTAINER" psql \
  -U "$ADMIN_USER" \
  -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -v tenant="$TENANT_KEY" \
  -v display="$DISPLAY_NAME" \
  -v db="$DB_NAME" \
  -v role="$APP_ROLE" \
  -v dim="$EMBEDDING_DIM" <<'SQL'
SELECT unyx_core.upsert_tenant(
  :'tenant',
  :'display',
  :'db',
  :'role',
  jsonb_build_object('embedding_dim', :dim::integer)
);
SQL

echo ""
echo "Cliente creado correctamente."
echo "TENANT_KEY=$TENANT_KEY"
echo "DB_NAME=$DB_NAME"
echo "DB_USER=$APP_ROLE"
echo "DB_PASSWORD=$APP_PASSWORD"
echo "DB_HOST=$CONTAINER"
echo "DB_PORT=5432"
echo ""
echo "Guarde la contraseña en un lugar seguro."
