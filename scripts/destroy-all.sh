#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

echo "PELIGRO: esto elimina el contenedor y el volumen PostgreSQL de este stack."
echo "Se perderán TODAS las bases de datos almacenadas en ese volumen."
read -r -p "Escribe ELIMINAR TODO para continuar: " CONFIRM
[[ "$CONFIRM" == "ELIMINAR TODO" ]] || { echo "Cancelado."; exit 0; }

docker compose down -v --remove-orphans
echo "Stack PostgreSQL eliminado."
