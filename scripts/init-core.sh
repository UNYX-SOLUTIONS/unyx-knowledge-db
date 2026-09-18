#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
CONTAINER="${DB_CONTAINER:-unyx-knowledge-db}"
ADMIN_DB="${POSTGRES_DB:-unyx}"
ADMIN_USER="${POSTGRES_USER:-unyx_admin}"

echo "==> Esperando PostgreSQL..."
for i in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U "$ADMIN_USER" -d "$ADMIN_DB" -q && break
  [[ "$i" == "30" ]] && { echo "ERROR: PostgreSQL no está disponible."; exit 1; }
  sleep 2
done

docker exec -i "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
  < "$ROOT/database/init/01_extensions.sql"
docker exec -i "$CONTAINER" psql -U "$ADMIN_USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 \
  < "$ROOT/database/init/02_core.sql"

echo "Core UNYX inicializado correctamente."
