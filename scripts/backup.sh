#!/usr/bin/env bash
# ============================================================
# ALTOSA - backup.sh
# ------------------------------------------------------------
# Backups diarios del Postgres EXISTENTE del VPS (NO dockerizado
# por este proyecto). Usa pg_dump/psql del host y las variables
# del .env (DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD).
#
# Acciones:
#   ./backup.sh                    -> ejecuta el backup
#   ./backup.sh backup             -> ejecuta el backup
#   ./backup.sh install-cron       -> programa el backup diario (02:00) en crontab
#   ./backup.sh list               -> lista los backups existentes
#   ./backup.sh restore ARCHIVO    -> restaura un backup (pide confirmación)
#   ./backup.sh --env-file=/ruta   -> usa otro .env (debe ir antes de la acción)
#
# El backup incluye --clean --if-exists: al restaurarlo primero
# elimina y recrea los objetos (dump autocontenido).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ROJO='\033[0;31m'; VERDE='\033[0;32m'; AMARILLO='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${VERDE}[INFO]${NC}  $*"; }
aviso() { echo -e "${AMARILLO}[WARN]${NC} $*"; }
error() { echo -e "${ROJO}[ERROR]${NC} $*" >&2; exit 1; }

# --- Parámetros -----------------------------------------------------------
ENV_FILE="./.env"
ACCION="backup"
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --env-file)  ENV_FILE="$2"; shift 2 ;;
    backup|install-cron|list|restore)
      ACCION="$1"
      shift
      break
      ;;
    *) error "Uso: ./backup.sh [--env-file=./.env] [backup|install-cron|list|restore ARCHIVO]" ;;
  esac
done

# Si no se pasó --env-file y no existe un ./.env junto al script,
# buscar el .env en la carpeta raíz del proyecto.
if [ "$ENV_FILE" = "./.env" ] && [ ! -f "$ENV_FILE" ] && [ -f "$SCRIPT_DIR/../.env" ]; then
  ENV_FILE="$SCRIPT_DIR/../.env"
fi
ARCHIVO="${1:-}"

# --- Cargar variables del .env (sin pisar las ya exportadas) ---------------
cargar_env_file() {
  local archivo="$1" linea clave valor
  [ -f "$archivo" ] || error "No existe el archivo de variables: $archivo
  Pásalo con --env-file=/ruta/al/.env o exporta las variables DB_HOST, DB_PORT, DB_NAME, DB_USER y DB_PASSWORD antes de ejecutar."
  while IFS= read -r linea || [ -n "$linea" ]; do
    linea="$(printf '%s' "$linea" | tr -d '\r')"
    case "$linea" in
      ''|\#*) continue ;;
    esac
    clave="${linea%%=*}"
    valor="${linea#*=}"
    clave="$(printf '%s' "$clave" | tr -d '[:space:]')"
    case "$valor" in
      \"*\") valor="${valor#\"}"; valor="${valor%\"}" ;;
      \'*\') valor="${valor#\'}"; valor="${valor%\'}" ;;
    esac
    if [ -z "${!clave:-}" ]; then
      export "${clave}"="${valor}"
    fi
  done < "$archivo"
}
cargar_env_file "$ENV_FILE"

faltan=""
for v in DB_HOST DB_NAME DB_USER DB_PASSWORD; do
  [ -n "${!v:-}" ] || faltan="$faltan $v"
done
[ -n "$faltan" ] && error "Faltan variables de entorno:$faltan. Revisa el .env."
DB_PORT="${DB_PORT:-5432}"

# --- Requisitos: psql y pg_dump -------------------------------------------
for bin in psql pg_dump; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    aviso "'$bin' no está instalado. Intentando instalar postgresql-client..."
    if command -v apt-get >/dev/null 2>&1; then
      if [ "$(id -u)" -eq 0 ]; then
        apt-get update -y >/dev/null && apt-get install -y postgresql-client
      elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y >/dev/null && sudo apt-get install -y postgresql-client
      else
        error "No se puede instalar postgresql-client (sin root/sudo). Instálalo manualmente."
      fi
    else
      error "'$bin' no está disponible y no hay apt-get. Instala postgresql-client."
    fi
    command -v "$bin" >/dev/null 2>&1 || error "No se pudo instalar '$bin'."
  fi
done

# --- Rutas ----------------------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# --- Ejecutar backup ------------------------------------------------------
ejecutar_backup() {
  local ts archivo
  ts=$(date +%Y%m%d_%H%M%S)
  archivo="altosa_db_${ts}.sql.gz"

  info "Creando backup: $BACKUP_DIR/$archivo"
  info "Origen: $DB_HOST:$DB_PORT/$DB_NAME (usuario: $DB_USER)"
  # 'set -o pipefail' asegura que si pg_dump falla, el script falle.
  PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=15 \
    "$(command -v pg_dump)" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
      --clean --if-exists --no-owner \
    | gzip > "$BACKUP_DIR/$archivo"

  # Verificar que el archivo comprimido sea válido
  gzip -t "$BACKUP_DIR/$archivo" || error "El backup quedó corrupto: $archivo"
  chmod 600 "$BACKUP_DIR/$archivo"

  # Retención: borrar backups con más de N días
  find "$BACKUP_DIR" -name 'altosa_db_*.sql.gz' -mtime +"$RETENTION_DAYS" -delete

  info "Backup OK ($(du -h "$BACKUP_DIR/$archivo" | cut -f1))"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup OK: $archivo" >> "$LOG_DIR/backup.log"
}

# --- Restaurar un backup ---------------------------------------------------
restaurar() {
  local archivo="$1"
  [ -n "$archivo" ] || error "Uso: ./backup.sh restore <archivo>"
  [ -f "$BACKUP_DIR/$archivo" ] || error "No existe el backup: $BACKUP_DIR/$archivo"

  echo "ATENCIÓN: se SOBRESCRIBIRÁ la base '$DB_NAME' con el backup '$archivo'."
  read -r -p "Escribe SI para confirmar: " confirmacion
  if [ "$confirmacion" != "SI" ]; then
    info "Cancelado."
    exit 0
  fi

  info "Restaurando (puede tardar)..."
  gunzip -c "$BACKUP_DIR/$archivo" \
    | PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=15 \
      "$(command -v psql)" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1
  info "Restauración completada."
}

# --- Instalar cron diario ---------------------------------------------------
instalar_cron() {
  # Se incluye PATH explícito porque cron arranca con un entorno mínimo
  local linea
  linea="0 2 * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $SCRIPT_DIR/backup.sh --env-file=$ENV_FILE backup >> $LOG_DIR/backup_cron.log 2>&1"

  if crontab -l 2>/dev/null | grep -Fq "backup.sh"; then
    info "El cron del backup ya estaba instalado."
  else
    ( crontab -l 2>/dev/null; echo "$linea" ) | crontab -
    info "Cron instalado: backup diario a las 02:00. Verifica con: crontab -l"
  fi
}

# --- Despachar acción -------------------------------------------------------
case "$ACCION" in
  backup)       ejecutar_backup ;;
  install-cron) instalar_cron ;;
  list)         ls -lh "$BACKUP_DIR" ;;
  restore)      restaurar "$ARCHIVO" ;;
  *) error "Acción desconocida: $ACCION (backup | install-cron | list | restore)" ;;
esac
