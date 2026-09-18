# README-SETUP — Postgres EXISTENTE del VPS (sin Docker, sin migración)

El proyecto ya **no** levanta un Postgres nuevo en Docker ni migra datos desde
Supabase (Supabase estaba vacío). Se usa el **Postgres que ya existe en el VPS**
con la base definida en el `.env` del proyecto (`DB_NAME`, esperado: `altosa_db`).

## 1. Qué hay en esta carpeta

| Archivo | Propósito |
|---|---|
| `setup-altosa-db.sh` | Script principal: verifica conexión, instala pgvector, crea esquema + tablas + índices + función `match_documents`, ajusta secuencias y verifica todo. **Idempotente.** |
| `backup.sh` | Backup diario con `pg_dump` del Postgres existente (usa las variables del `.env`). |
| `.env` | Variables reales del proyecto (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `TENANT_KEY`). Nunca se sube a git. |
| `.env.example` | Plantilla de las variables. |
| `*.obsoleto` | Archivos del enfoque anterior (dockerizar Postgres / migrar Supabase). NO usar. |
| `../Documentación/README-FIXES.md` | Fixes previos de workflows (C1, C2, I1, I2). |
| `../Documentación/ALTOSA 01 - ASESOR COMERCIAL (updated).json` | Workflow con el nodo RAG ya migrado a **PGVector**. |
| `update-n8n-credential.md` | Cómo actualizar la credencial de n8n. |

## 2. Requisitos

- VPS Ubuntu/Debian con acceso SSH.
- El Postgres existente corriendo y accesible desde el VPS en `DB_HOST:DB_PORT`.
- La base `DB_NAME` ya creada (vacía). Si no existe, créala antes:
  ```bash
  sudo -u postgres psql -c "CREATE DATABASE altosa_db;"   # ejemplo si corre local
  ```
- El usuario `DB_USER` con permisos de creación en esa base (para `CREATE EXTENSION`, tablas y funciones).
- `postgresql-client` (el script lo instala solo si falta).

## 3. Paso a paso

### 3.1 Subir el kit al VPS

```bash
# Desde tu máquina
scp IA/migracion-postgres/setup-altosa-db.sh root@IP_DEL_VPS:/opt/altosa/
scp IA/migracion-postgres/backup.sh        root@IP_DEL_VPS:/opt/altosa/
scp IA/migracion-postgres/.env             root@IP_DEL_VPS:/opt/altosa/   # si aún no está

# En el VPS
ssh root@IP_DEL_VPS
cd /opt/altosa
sed -i 's/\r$//' *.sh      # normalizar finales de línea
chmod +x *.sh
chmod 600 .env
```

### 3.2 Verificar el .env

```bash
grep -E '^(DB_HOST|DB_PORT|DB_NAME|DB_USER)=' .env
# DB_HOST, DB_PORT, DB_NAME, DB_USER deben estar definidos y sin espacios.
# DB_PASSWORD y TENANT_KEY también deben existir (no los imprimas).
```

### 3.3 Ejecutar el setup

```bash
./setup-altosa-db.sh
# o con otro .env:
./setup-altosa-db.sh --env-file=/ruta/al/.env
```

Qué hace: valida variables → asegura `psql` → verifica conexión (5 reintentos) →
`CREATE EXTENSION IF NOT EXISTS vector` → crea las tablas en el esquema `public`
(`n8n_chat_histories`, `documents`, `processed_outgoing_messages`,
`products` con 41 columnas) → índices (HNSW en `documents.embedding`,
índices de products) → `match_documents` → `setval` de secuencias → verificación
y resumen. **Es idempotente: puedes re-ejecutarlo sin riesgo.**

Si `documents` ya existiera con otra estructura, el script NO la toca: avisa y
te da el comando exacto para recrearla manualmente.

### 3.4 Verificar manualmente

```bash
PGPASSWORD='LA_DEL_.env' psql -h "$(grep '^DB_HOST=' .env | cut -d= -f2)" \
  -U "$(grep '^DB_USER=' .env | cut -d= -f2)" \
  -d "$(grep '^DB_NAME=' .env | cut -d= -f2)" -c "\dt *.*"
```

Deben aparecer: `n8n_chat_histories`, `documents`, `products`,
`processed_outgoing_messages`.

### 3.5 Cargar datos del catálogo (pendiente del cliente)

La tabla `products` queda creada pero vacía. Cuando ALTOSA entregue el
catálogo (CSV/Excel), se carga con:

```bash
PGPASSWORD='...' psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
  -c "\copy products (sku, producto_actual, nombre_catalogo, ...) FROM '/ruta/catalogo.csv' CSV HEADER"
# Ajustar las columnas del \copy a las columnas reales del archivo.
```

La base de conocimiento RAG (`documents`) se carga después mediante el flujo de
ingesta (embeddings con `text-embedding-3-small`, dimensión 1536).

### 3.6 Backups automáticos

```bash
./backup.sh install-cron   # diario a las 02:00 (ver: crontab -l)
./backup.sh backup         # backup manual
./backup.sh list
./backup.sh restore altosa_db_20260918_020000.sql.gz   # pide "SI" para confirmar
```

Los backups quedan en `/opt/altosa/backups/` (retención 7 días). Recomendado:
copiar fuera del VPS (rclone/scp) para no depender de un solo disco.

### 3.7 Actualizar n8n

1. Importar `ALTOSA 01 - ASESOR COMERCIAL (updated).json` (el id coincide, así
   que n8n actualiza el workflow existente en lugar de duplicarlo).
2. Actualizar la credencial y, si hace falta, crear la credencial PGVector del
   nodo RAG: ver `update-n8n-credential.md`.
3. Probar: ALTOSA TOOL - BUSCAR PRODUCTOS, ALTOSA 01 (mensaje simple), flujo
   completo por WhatsApp/Kommo.

## 4. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `No se pudo conectar a Postgres` | Postgres caído / firewall / .env mal | Verifica `DB_HOST:DB_PORT`, `ss -lnt | grep 5432`, firewall |
| `permission denied for database` | `DB_USER` sin permisos en `DB_NAME` | `GRANT ALL ON DATABASE ... TO ...` o usa un usuario con permisos |
| `pgvector NO está disponible` | Extensión no instalada en el servidor | `apt install postgresql-16-pgvector` (o la versión de tu PG) y reinicia Postgres |
| `CREATE EXTENSION` sin permisos | Usuario sin privilegio de superuser | Crear la extensión como superuser una vez, o pedirla al admin |
| Falta `psql` y no hay apt | Corriendo dentro de un contenedor mínimo | Instala el cliente manualmente o ejecuta el script desde el host |
| `documents` con estructura distinta | Tabla previa de otro proyecto | El script avisa; re-créala con el comando que imprime |
| Backup no corre | cron sin PATH o .env no encontrado | La línea de cron incluye PATH y `--env-file`; revisa `logs/backup_cron.log` |

## 5. Preguntas frecuentes del diseño

- **¿Y si DB_HOST es "localhost" y el script se ejecuta dentro de un contenedor?**
  El script lo detecta (`.dockerenv`) y avisa: usa `host.docker.internal`, la IP
  del host o el nombre del contenedor de Postgres. Para n8n en Docker aplica lo
  mismo (ver `update-n8n-credential.md`).
- **¿Y si pgvector ya está instalado?** `CREATE EXTENSION IF NOT EXISTS vector`
  es no-op y el script verifica la versión activa.
- **¿Y si `documents` ya existe con otra estructura?** No se borra nada: aviso +
  comando explícito de recreación.
- **¿Cómo se detecta la secuencia de `altosa.products`?** Dinámicamente vía
  `information_schema` (serial o identity), sin depender del nombre de la PK.
- **¿Y si el usuario ejecuta sin .env?** Error claro indicando usar
  `--env-file` o exportar las 4 variables obligatorias.
