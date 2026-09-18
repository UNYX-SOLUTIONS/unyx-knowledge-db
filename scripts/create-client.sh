#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; source "$ROOT/.env"; set +a

CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
DISPLAY_NAME="${2:-}"
EMBEDDING_DIM="${3:-1536}"

[[ -n "$TENANT_KEY" && -n "$DISPLAY_NAME" ]] || {
  echo 'Uso: ./scripts/create-client.sh <tenant_key> "<display_name>" [embedding_dim]'
  exit 1
}
[[ "$TENANT_KEY" =~ ^[a-z][a-z0-9-]{1,50}$ ]] || { echo "tenant_key inválido."; exit 1; }
[[ "$EMBEDDING_DIM" =~ ^[0-9]+$ ]] || { echo "embedding_dim inválido."; exit 1; }

DB_NAME="${TENANT_KEY//-/_}"
APP_ROLE="${DB_NAME}_app"

DB_EXISTS="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[[ "$DB_EXISTS" != "1" ]] || { echo "ERROR: La DB '$DB_NAME' ya existe."; exit 1; }

ROLE_EXISTS="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='$APP_ROLE'")"
[[ "$ROLE_EXISTS" != "1" ]] || {
  echo "ERROR: El rol '$APP_ROLE' ya existe. No se rotará su contraseña automáticamente."
  exit 1
}

APP_PASSWORD="$(openssl rand -hex 24)"

docker exec -i "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 -v role="$APP_ROLE" -v password="$APP_PASSWORD" <<'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'password';
SQL

rollback() {
  echo "ERROR: creación incompleta. Limpiando DB/rol..."
  docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);" >/dev/null 2>&1 || true
  docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -c "DROP ROLE IF EXISTS \"$APP_ROLE\";" >/dev/null 2>&1 || true
}
trap rollback ERR

docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$APP_ROLE\";"

docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  -c "REVOKE CONNECT ON DATABASE \"$DB_NAME\" FROM PUBLIC; GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$APP_ROLE\";"

docker exec -i "$CONTAINER" psql -U "$APP_ROLE" -d "$DB_NAME" \
  --single-transaction -v ON_ERROR_STOP=1 -v dim="$EMBEDDING_DIM" \
  < "$ROOT/database/client/schema.sql"

TENANT_SCHEMA="$ROOT/database/tenants/$TENANT_KEY/schema.sql"
if [[ -f "$TENANT_SCHEMA" ]]; then
  echo "==> Aplicando extensión específica de $TENANT_KEY"
  docker exec -i "$CONTAINER" psql -U "$APP_ROLE" -d "$DB_NAME" \
    --single-transaction -v ON_ERROR_STOP=1 \
    < "$TENANT_SCHEMA"
fi

docker exec -i "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
  -v ON_ERROR_STOP=1 \
  -v tenant="$TENANT_KEY" -v display="$DISPLAY_NAME" \
  -v db="$DB_NAME" -v role="$APP_ROLE" -v dim="$EMBEDDING_DIM" <<'SQL'
SELECT unyx_core.upsert_tenant(
  :'tenant', :'display', :'db', :'role',
  jsonb_build_object('embedding_dim', :dim::integer)
);
SQL

trap - ERR
echo ""
echo "Cliente creado correctamente."
echo "TENANT_KEY=$TENANT_KEY"
echo "DB_NAME=$DB_NAME"
echo "DB_USER=$APP_ROLE"
echo "DB_PASSWORD=$APP_PASSWORD"
echo "DB_HOST=$CONTAINER"
echo "DB_PORT=5432"
echo "EMBEDDING_DIM=$EMBEDDING_DIM"
echo ""
echo "GUARDE DB_PASSWORD: no se volverá a mostrar."
