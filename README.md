# UNYX Knowledge DB

Reusable Knowledge Base infrastructure for UNYX AI solutions using PostgreSQL 16 + pgvector.

One PostgreSQL server, one isolated database per company.

## Structure

- Server: `unyx-knowledge-db` (PostgreSQL 16 + pgvector)
- Admin database `unyx`: tenant registry (`unyx_core.tenants`) only
- One database per company: `altosa`, `meditec`, `unyx_solutions`, ...

## Requirements

Create the shared Docker networks once:

```bash
docker network create unyx-db-admin
docker network create unyx-ai
```

## Installation

```bash
cp .env.example .env
nano .env
docker compose up -d
docker compose ps
```

`POSTGRES_DB` points to the admin/registry database (`unyx`). On installations that predate the database-per-company model it may still point to `unyx_knowledge`; the scripts read it from `.env`.

## Create a client (company)

```bash
chmod +x scripts/*.sh
set -a
source .env
set +a
./scripts/create-client.sh altosa "ALTOSA Mobiliario" 1536
./scripts/create-client.sh unyx-solutions "UNYX Solutions" 1536
```

This creates: the app role, the company database (`unyx-solutions` -> `unyx_solutions`), the base schema and the registry entry. The generated app password is printed once.

## Backup

```bash
./scripts/backup-client.sh altosa
```

## Export

```bash
./scripts/export-client.sh altosa
```

## Restore

```bash
./scripts/restore-client.sh altosa ./backups/altosa_TIMESTAMP.dump
```

Restores are staged and transactional: the dump is restored into a temporary database, validated, and only then swapped with the live one. A failed or corrupt restore never touches the live database.

## Durability and recovery

- Explicit durability flags in `docker-compose.yml` (`fsync`, `synchronous_commit`, `full_page_writes`)
- Schema provisioning runs in a single transaction
- Staged + validated restores; the previous database is kept until the new one is verified
- Persistent data lives in the `unyx-knowledge-data` volume and `./backups`; only caches/buffers are volatile (see `docs/architecture.md`)

## Migrating from the old schema-per-tenant model

If no data needs to be preserved (tables not yet populated), the easiest path is to recreate the volume from scratch:

```bash
docker compose down -v
docker compose up -d
set -a
source .env
set +a
./scripts/create-client.sh altosa "ALTOSA Mobiliario" 1536
```

For each existing tenant schema (e.g. `altosa` in the `unyx_knowledge` database) with data to preserve:

```bash
./scripts/migrate-schema-to-db.sh altosa "ALTOSA Mobiliario" 1536
```

The script updates the registry, creates the company database, and copies the data. It does not drop the old schema; after verifying, run the commands printed by the script.

Never commit `.env`, database dumps, backups or client data.
