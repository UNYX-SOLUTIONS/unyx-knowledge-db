#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

TENANT_KEY="${1:-}"
DUMP_FILE="${2:-}"
[[ -n "$TENANT_KEY" && -n "$DUMP_FILE" ]] || {
  echo "Uso: ./scripts/restore-client.sh <tenant_key> <dump>"
  exit 1
}
[[ -f "$DUMP_FILE" ]] || { echo "No existe: $DUMP_FILE"; exit 1; }

DB_NAME="${TENANT_KEY//-/_}"
APP_ROLE="${DB_NAME}_app"
STAGING="${DB_NAME}_staging"
OLD="${DB_NAME}_old"
TMP="/tmp/unyx_restore_${DB_NAME}.dump"

ROLE_EXISTS="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='$APP_ROLE'")"
if [[ "$ROLE_EXISTS" != "1" ]]; then
  NEW_PASSWORD="$(openssl rand -hex 24)"
  docker exec -i "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -v ON_ERROR_STOP=1 -v role="$APP_ROLE" -v password="$NEW_PASSWORD" <<'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'password';
SQL
  echo "NUEVO_DB_PASSWORD=$NEW_PASSWORD"
fi

docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
  -c "DROP DATABASE IF EXISTS \"$STAGING\" WITH (FORCE);"
docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
  -c "CREATE DATABASE \"$STAGING\" OWNER \"$APP_ROLE\";"
docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$STAGING" \
  -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;"

docker cp "$DUMP_FILE" "$CONTAINER:$TMP"
trap 'docker exec "$CONTAINER" rm -f "$TMP" >/dev/null 2>&1 || true' EXIT

docker exec "$CONTAINER" pg_restore -U "$ADMIN_USER" -d "$STAGING" \
  --single-transaction --no-owner --no-acl --exit-on-error "$TMP"

TABLE_COUNT="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$STAGING" -tAc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('kb_versions','products','documents');")"
[[ "$TABLE_COUNT" == "3" ]] || {
  docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -c "DROP DATABASE \"$STAGING\" WITH (FORCE);" >/dev/null
  echo "ERROR: dump inválido/incompleto. La DB productiva no fue modificada."
  exit 1
}

LIVE="$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"

if [[ "$LIVE" == "1" ]]; then
  docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -c "DROP DATABASE IF EXISTS \"$OLD\" WITH (FORCE);"
  docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$OLD\";"
fi

if ! docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" \
    -c "ALTER DATABASE \"$STAGING\" RENAME TO \"$DB_NAME\";"; then
  if [[ "$LIVE" == "1" ]]; then
    docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -c "ALTER DATABASE \"$OLD\" RENAME TO \"$DB_NAME\";" || true
  fi
  exit 1
fi

docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" \
  -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$APP_ROLE\"; GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$APP_ROLE\";"
docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" \
  -c "GRANT USAGE, CREATE ON SCHEMA public TO \"$APP_ROLE\"; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$APP_ROLE\"; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$APP_ROLE\";"

[[ "$LIVE" == "1" ]] && docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -c "DROP DATABASE \"$OLD\" WITH (FORCE);"

echo "Restore completado: $DB_NAME"
