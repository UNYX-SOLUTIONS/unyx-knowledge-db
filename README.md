# UNYX Knowledge DB

Reusable Knowledge Base infrastructure for UNYX AI solutions using PostgreSQL 16 + pgvector.

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

## Create a client

```bash
chmod +x scripts/*.sh
set -a
source .env
set +a
./scripts/create-client.sh altosa "ALTOSA Mobiliario" 1536
```

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
./scripts/restore-client.sh ./backups/altosa_TIMESTAMP.dump
```

Never commit `.env`, database dumps, backups or client data.
