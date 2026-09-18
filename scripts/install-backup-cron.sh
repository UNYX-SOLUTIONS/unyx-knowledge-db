#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$ROOT/logs"
LINE="0 2 * * * $SCRIPT_DIR/backup-all.sh >> $ROOT/logs/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "$SCRIPT_DIR/backup-all.sh" || true; echo "$LINE" ) | crontab -
echo "Backup diario instalado para las 02:00."
