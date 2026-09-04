#!/usr/bin/env bash
set -euo pipefail

TENANT_KEY="${1:-}"
DISPLAY_NAME="${2:-}"
EMBEDDING_DIM="${3:-1536}"

if [[ -z "$TENANT_KEY" || -z "$DISPLAY_NAME" ]]; then
  echo "Uso: $0 <tenant_key> <display_name> [embedding_dim]"
  echo 'Ejemplo: ./scripts/create-client.sh altosa "ALTOSA Mobiliario" 1536'
  exit 1
fi

if [[ ! "$TENANT_KEY" =~ ^[a-z][a-z0-9_]{1,62}$ ]]; then
  echo "tenant_key inválido."
  exit 1
fi

SCHEMA_NAME="$TENANT_KEY"
APP_ROLE="${TENANT_KEY}_app"
APP_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"

docker exec -i unyx-knowledge-db psql \
  -U "${POSTGRES_USER:-unyx_admin}" \
  -d "${POSTGRES_DB:-unyx_knowledge}" \
  -v ON_ERROR_STOP=1 \
  -v tenant="$TENANT_KEY" \
  -v display="$DISPLAY_NAME" \
  -v schema="$SCHEMA_NAME" \
  -v role="$APP_ROLE" \
  -v password="$APP_PASSWORD" \
  -v dim="$EMBEDDING_DIM" <<'SQL'
SELECT unyx_core.provision_client(
  :'tenant',
  :'display',
  :'schema',
  :'role',
  :'password',
  :dim::integer
);
SQL

echo ""
echo "Cliente creado correctamente."
echo "TENANT_KEY=$TENANT_KEY"
echo "SCHEMA=$SCHEMA_NAME"
echo "DB_NAME=${POSTGRES_DB:-unyx_knowledge}"
echo "DB_USER=$APP_ROLE"
echo "DB_PASSWORD=$APP_PASSWORD"
echo "DB_HOST=unyx-knowledge-db"
echo "DB_PORT=5432"
echo ""
echo "Guarde la contraseña en un lugar seguro."
