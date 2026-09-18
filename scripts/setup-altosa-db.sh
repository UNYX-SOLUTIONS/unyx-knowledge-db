#!/usr/bin/env bash
# ============================================================
# ALTOSA - setup-altosa-db.sh
# ------------------------------------------------------------
# Prepara la base de datos EXISTENTE del VPS para el bot ALTOSA.
#
# IMPORTANTE:
#   - NO levanta contenedores Docker.
#   - NO crea un Postgres nuevo: usa el que ya corre en el VPS.
#   - NO migra datos desde Supabase (Supabase estaba vacío).
#   - Lee las credenciales del .env del proyecto:
#       TENANT_KEY (informativa), DB_NAME, DB_USER, DB_PASSWORD,
#       DB_HOST, DB_PORT
#
# Qué hace (TODO idempotente, se puede re-ejecutar):
#   1. Carga el .env (sin pisar variables ya exportadas)
#   2. Valida variables y presencia de psql (lo instala si falta)
#   3. Verifica conexión al Postgres existente
#   4. Instala la extensión pgvector si no está
#   5. Crea las tablas en el esquema public:
#        n8n_chat_histories (memoria del agente)
#        documents (RAG, embedding vector(1536))
#        processed_outgoing_messages (idempotencia legacy)
#        products (catálogo, estructura completa del workflow)
#   6. Crea los índices (HNSW para embeddings + índices de products)
#   7. Crea/reemplaza la función match_documents (RAG)
#   8. Ajusta secuencias SERIAL (idempotente)
#   9. Verifica todo y muestra el resumen para la credencial de n8n
#
# Uso:
#   ./setup-altosa-db.sh                          # usa ./.env
#   ./setup-altosa-db.sh --env-file=/ruta/al/.env
#   DB_HOST=... DB_NAME=... ./setup-altosa-db.sh  # variables en el entorno
#   ./setup-altosa-db.sh --help
#
# Requisitos: bash + psql (postgresql-client). Ubuntu/Debian.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Colores / logs ------------------------------------------------------
ROJO='\033[0;31m'; VERDE='\033[0;32m'; AMARILLO='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${VERDE}[INFO]${NC}  $*"; }
aviso() { echo -e "${AMARILLO}[WARN]${NC} $*"; }
error() { echo -e "${ROJO}[ERROR]${NC} $*" >&2; exit 1; }

# --- Parámetros -----------------------------------------------------------
ENV_FILE="./.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --env-file)  ENV_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Opción desconocida: $1 (usa --help)" ;;
  esac
done

# Si no se pasó --env-file y no existe un ./.env junto al script,
# buscar el .env en la carpeta raíz del proyecto.
if [ "$ENV_FILE" = "./.env" ] && [ ! -f "$ENV_FILE" ] && [ -f "$SCRIPT_DIR/../.env" ]; then
  ENV_FILE="$SCRIPT_DIR/../.env"
fi

# --- 1. Cargar variables del .env (sin pisar las ya exportadas) ----------
cargar_env_file() {
  local archivo="$1" linea clave valor
  [ -f "$archivo" ] || error "No existe el archivo de variables: $archivo
  Pásalo con --env-file=/ruta/al/.env o exporta las variables
  DB_HOST, DB_PORT, DB_NAME, DB_USER y DB_PASSWORD antes de ejecutar."
  info "Cargando variables desde: $archivo"
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

# --- 2. Validar variables --------------------------------------------------
faltan=""
for v in DB_HOST DB_NAME DB_USER DB_PASSWORD; do
  [ -n "${!v:-}" ] || faltan="$faltan $v"
done
if [ -n "$faltan" ]; then
  error "Faltan variables de entorno:$faltan. Defínelas en el .env (--env-file) o expórtalas antes de ejecutar."
fi
DB_PORT="${DB_PORT:-5432}"
if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]]; then
  error "DB_PORT debe ser numérico (valor actual: '$DB_PORT')."
fi
if [ -z "${TENANT_KEY:-}" ]; then
  aviso "TENANT_KEY no está definida. No es obligatoria para este script (solo informativa)."
fi
info "Destino: $DB_HOST:$DB_PORT/$DB_NAME (usuario: $DB_USER)"

# Aviso si se corre dentro de un contenedor y el host es local
if [ -f /.dockerenv ] && { [ "$DB_HOST" = "localhost" ] || [ "$DB_HOST" = "127.0.0.1" ]; }; then
  aviso "Este script parece correr DENTRO de un contenedor y DB_HOST=$DB_HOST."
  echo "       - Si el Postgres corre en el host, usa DB_HOST=host.docker.internal (o la IP del host)."
  echo "       - Si el Postgres corre en otro contenedor, usa su nombre de contenedor o su IP de red Docker."
fi

# --- 3. Asegurar psql -------------------------------------------------------
asegurar_psql() {
  if command -v psql >/dev/null 2>&1; then
    info "psql detectado: $(psql --version | head -n 1)"
    return 0
  fi
  aviso "psql no está instalado. Intentando instalar postgresql-client..."
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -y >/dev/null && apt-get install -y postgresql-client
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null && sudo apt-get install -y postgresql-client
    else
      error "No se puede instalar postgresql-client (sin root/sudo). Instálalo manualmente: apt install postgresql-client"
    fi
  else
    error "psql no está disponible y no hay apt-get. Instala el cliente psql e inténtalo de nuevo."
  fi
  command -v psql >/dev/null 2>&1 || error "No se pudo instalar psql."
  info "psql instalado correctamente."
}
asegurar_psql

# Helpers de psql
psql_ejecutar() {
  PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=15 "$(command -v psql)" \
    -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -v ON_ERROR_STOP=1 "$@"
}
psql_consulta() {
  PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=15 "$(command -v psql)" \
    -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -tAc "$1" 2>/dev/null
}

# --- 4. Verificar conexión (con reintentos) --------------------------------
verificar_conexion() {
  info "Verificando conexión a $DB_HOST:$DB_PORT/$DB_NAME ..."
  local intento
  for intento in 1 2 3 4 5; do
    if psql_consulta "SELECT 1;" | grep -q '^1$'; then
      info "Conexión OK."
      return 0
    fi
    aviso "No responde (intento $intento/5). Reintentando en 10s..."
    sleep 10
  done
  error "No se pudo conectar a Postgres ($DB_HOST:$DB_PORT/$DB_NAME).
  Revisa: que Postgres esté corriendo, el firewall, y los valores de DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD del .env."
}
verificar_conexion

# --- 5. Extensión pgvector -------------------------------------------------
instalar_extension() {
  info "Instalando la extensión pgvector (si falta)..."
  if ! psql_ejecutar -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    local disponible
    disponible="$(psql_consulta "SELECT COUNT(*) FROM pg_available_extensions WHERE name='vector';")"
    if [ "$disponible" = "0" ] || [ -z "$disponible" ]; then
      error "pgvector NO está disponible en este servidor Postgres.
  Instálalo en el servidor (p. ej. Ubuntu: apt install postgresql-16-pgvector)
  y reinicia Postgres, o pídelo a tu administrador."
    fi
    error "pgvector está disponible pero no se pudo crear la extensión (¿faltan permisos?). Revisa el error y reintenta."
  fi
  local version
  version="$(psql_consulta "SELECT extversion FROM pg_extension WHERE extname='vector';")"
  [ -n "$version" ] || error "La extensión vector no quedó activa."
  info "pgvector activo: versión ${version}"
}
instalar_extension

# --- 6. Estructura: esquema + tablas + índices -----------------------------
crear_estructura() {
  info "Creando tablas en el esquema public (idempotente)..."

  # documents: si ya existe con otra estructura, avisar (nunca borrar datos en silencio)
  local existe_docs tipo_emb cols_docs
  existe_docs="$(psql_consulta "SELECT to_regclass('public.documents');")"
  if [ -n "$existe_docs" ]; then
    tipo_emb="$(psql_consulta "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid='public.documents'::regclass AND attname='embedding';")"
    cols_docs="$(psql_consulta "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='documents';")"
    if [ "$tipo_emb" != "vector(1536)" ] || [ "$cols_docs" != "4" ]; then
      aviso "La tabla 'documents' ya existe con otra estructura ($cols_docs columnas, embedding=$tipo_emb)."
      aviso "NO se modificó. Si quieres recrearla (SE PIERDEN LOS DATOS):"
      echo "      psql \"postgresql://$DB_USER:***@$DB_HOST:$DB_PORT/$DB_NAME\" -c 'DROP TABLE documents CASCADE;'"
      echo "      y vuelve a ejecutar este script."
    else
      info "La tabla 'documents' ya existe con la estructura correcta."
    fi
  fi

  psql_ejecutar <<'SQL'
-- Tablas de la aplicación (esquema public)

-- Memoria del agente (nodo "ALTOSA Chat Memory" de n8n)
CREATE TABLE IF NOT EXISTS n8n_chat_histories (
    id         SERIAL PRIMARY KEY,
    session_id VARCHAR(255) NOT NULL,
    message    JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_histories_session
    ON n8n_chat_histories (session_id);

-- Base de conocimiento documental con embeddings (RAG)
-- vector(1536) = text-embedding-3-small de OpenAI.
-- Si se cambia el modelo de embeddings, ajustar la dimensión.
CREATE TABLE IF NOT EXISTS documents (
    id        BIGSERIAL PRIMARY KEY,
    content   TEXT,
    metadata  JSONB,
    embedding VECTOR(1536)
);
CREATE INDEX IF NOT EXISTS idx_documents_embedding
    ON documents USING hnsw (embedding vector_cosine_ops);

-- Idempotencia para ALTOSA 02 (legacy)
CREATE TABLE IF NOT EXISTS processed_outgoing_messages (
    message_id   TEXT PRIMARY KEY,
    lead_id      TEXT NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_processed_outgoing_lead
    ON processed_outgoing_messages (lead_id);

-- Catálogo de productos. Estructura = columnas que consulta el workflow
-- "ALTOSA TOOL - BUSCAR PRODUCTOS" (40 columnas en el SELECT + keyword = 41).
CREATE TABLE IF NOT EXISTS products (
    id_registro            SERIAL PRIMARY KEY,
    sku                    TEXT,
    producto_actual        TEXT,
    nombre_catalogo        TEXT,
    categoria_actual       TEXT,
    categoria_catalogo     TEXT,
    subcategoria_catalogo  TEXT,
    precio_usd             NUMERIC(12,2),
    stock_contifico        INTEGER,
    moneda                 TEXT,
    descripcion_actual     TEXT,
    descripcion            TEXT,
    materiales_detectados  TEXT,
    estructura_material    TEXT,
    tapiceria              TEXT,
    acabado                TEXT,
    proteccion_uv          TEXT,
    resistencia_intemperie TEXT,
    apilable               TEXT,
    giratorio              TEXT,
    rotacion_360           TEXT,
    brazos                 TEXT,
    tipo_brazos            TEXT,
    soporte_lumbar         TEXT,
    detalle_soporte_lumbar TEXT,
    cabecera               TEXT,
    detalle_cabecera       TEXT,
    reclinacion            TEXT,
    detalle_mecanismo      TEXT,
    sistema_hidraulico     TEXT,
    certificacion          TEXT,
    reposapies             TEXT,
    ideal_meson_cm         TEXT,
    uso_recomendado        TEXT,
    mantenimiento          TEXT,
    garantia_meses         INTEGER,
    garantia_especial      TEXT,
    url_actual             TEXT,
    fuente_url             TEXT,
    aprobado               TEXT,
    keyword                TEXT
);
CREATE INDEX IF NOT EXISTS idx_products_aprobado  ON products (aprobado);
CREATE INDEX IF NOT EXISTS idx_products_categoria ON products (categoria_actual);
CREATE INDEX IF NOT EXISTS idx_products_sku       ON products (sku);
SQL

  # Verificación de products preexistente con otra estructura
  local cols_products
  cols_products="$(psql_consulta "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='products';")"
  if [ "$cols_products" != "41" ]; then
    aviso "products quedó con $cols_products columnas (esperadas: 41)."
    aviso "Si ya existía con otra estructura, revisa que las columnas que consulta el workflow coincidan."
  fi

  info "Tablas creadas/verificadas."
}
crear_estructura

# --- 7. Función match_documents (RAG) --------------------------------------
crear_funcion_rag() {
  info "Creando/reemplazando la función match_documents..."
  psql_ejecutar <<'SQL'
CREATE OR REPLACE FUNCTION match_documents(
    query_embedding vector(1536),
    match_count int DEFAULT 5,
    filter jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    id bigint,
    content text,
    metadata jsonb,
    similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        documents.id,
        documents.content,
        documents.metadata,
        1 - (documents.embedding <=> query_embedding) AS similarity
    FROM documents
    WHERE documents.metadata @> filter
    ORDER BY documents.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;
SQL
  local existe_fn
  existe_fn="$(psql_consulta "SELECT COUNT(*) FROM pg_proc WHERE proname='match_documents';")"
  [ "$existe_fn" = "1" ] || error "La función match_documents no quedó creada."
  info "Función match_documents lista."
}
crear_funcion_rag

# --- 8. Ajustar secuencias SERIAL ------------------------------------------
ajustar_secuencias() {
  info "Ajustando secuencias SERIAL (idempotente)..."
  psql_ejecutar <<'SQL'
DO $$
DECLARE
    v_seq TEXT;
    v_col TEXT;
BEGIN
    -- documents
    SELECT pg_get_serial_sequence('public.documents', 'id') INTO v_seq;
    IF v_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, COALESCE((SELECT MAX(id) FROM public.documents), 1), (SELECT MAX(id) FROM public.documents) IS NOT NULL)', v_seq);
    END IF;

    -- n8n_chat_histories
    SELECT pg_get_serial_sequence('public.n8n_chat_histories', 'id') INTO v_seq;
    IF v_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, COALESCE((SELECT MAX(id) FROM public.n8n_chat_histories), 1), (SELECT MAX(id) FROM public.n8n_chat_histories) IS NOT NULL)', v_seq);
    END IF;

    -- products: detectar la columna serial/identity dinámicamente
    IF to_regclass('public.products') IS NOT NULL THEN
        SELECT column_name, pg_get_serial_sequence('public.products', column_name)
          INTO v_col, v_seq
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'products'
          AND (column_default LIKE 'nextval(%' OR is_identity = 'YES')
        ORDER BY ordinal_position
        LIMIT 1;
        IF v_seq IS NOT NULL THEN
            EXECUTE format('SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM public.products), 1), (SELECT MAX(%I) FROM public.products) IS NOT NULL)', v_seq, v_col, v_col);
        END IF;
    END IF;
END $$;
SQL
  info "Secuencias ajustadas."
}
ajustar_secuencias

# --- 9. Verificación final y resumen ---------------------------------------
verificar_final() {
  info "Verificaciones finales..."
  echo ""
  echo "--- Tablas ---"
  psql_ejecutar -c "\dt public.*" 2>/dev/null || true

  echo ""
  echo "--- Conteo de filas ---"
  psql_consulta "SELECT 'n8n_chat_histories', COUNT(*) FROM n8n_chat_histories
                 UNION ALL SELECT 'documents', COUNT(*) FROM documents
                 UNION ALL SELECT 'processed_outgoing_messages', COUNT(*) FROM processed_outgoing_messages
                 UNION ALL SELECT 'products', COUNT(*) FROM products;" | sed 's/^/    /' || true

  echo ""
  echo "--- Embeddings (dimensión esperada: 1536) ---"
  psql_consulta "SELECT vector_dims(embedding) AS dims, COUNT(*) FROM documents WHERE embedding IS NOT NULL GROUP BY 1;" | sed 's/^/    /' || true

  # Smoke test de match_documents (solo si hay embeddings)
  local con_emb
  con_emb="$(psql_consulta "SELECT COUNT(*) FROM documents WHERE embedding IS NOT NULL;")"
  if [ "$con_emb" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "--- Smoke test match_documents ---"
    psql_ejecutar -c "SELECT id, round(similarity::numeric, 4) AS sim, left(content, 80) AS contenido FROM match_documents((SELECT embedding FROM documents WHERE embedding IS NOT NULL LIMIT 1), 3, '{}'::jsonb) LIMIT 3;"
  else
    aviso "documents no tiene embeddings todavía: el smoke test de RAG se omite (normal si aún no se cargó la base de conocimiento)."
  fi
}
verificar_final

echo ""
info "============================================="
info " SETUP COMPLETADO"
info "============================================="
info "Extensión vector: $(psql_consulta "SELECT extversion FROM pg_extension WHERE extname='vector';")"
info "Datos de conexión para la credencial de n8n ('Postgress Supabase' -> 'Postgress ALTOSA'):"
echo "  - Host:     $DB_HOST"
echo "  - Puerto:   $DB_PORT"
echo "  - Database: $DB_NAME"
echo "  - Usuario:  $DB_USER"
echo "  - Password: la de DB_PASSWORD en el .env (no se muestra aquí)"
echo "  - SSL:      disable (red interna) / require (si el Postgres es remoto)"
echo ""
info "Prueba manual de conexión:"
echo "  PGPASSWORD='***' psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c 'SELECT 1;'"
echo ""
info "Siguientes pasos:"
echo "  1) Importar en n8n: 'ALTOSA 01 - ASESOR COMERCIAL (updated).json' (nodo RAG en PGVector)"
echo "  2) Actualizar la credencial de n8n (ver update-n8n-credential.md)"
echo "  3) ./backup.sh install-cron  (backups diarios)"
