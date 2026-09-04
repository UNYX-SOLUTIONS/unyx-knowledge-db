#!/usr/bin/env bash
set -euo pipefail

DUMP_FILE="${1:-}"
if [[ -z "$DUMP_FILE" ]]; then
  echo "Uso: $0 <dump>"
  exit 1
fi

FILE_NAME="$(basename "$DUMP_FILE")"

docker cp "$DUMP_FILE" "unyx-knowledge-db:/tmp/$FILE_NAME"

docker exec unyx-knowledge-db pg_restore \
  -U "${POSTGRES_USER:-unyx_admin}" \
  -d "${POSTGRES_DB:-unyx_knowledge}" \
  --no-owner \
  --no-acl \
  "/tmp/$FILE_NAME"

docker exec unyx-knowledge-db rm -f "/tmp/$FILE_NAME"

echo "Restore completado."
