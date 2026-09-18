# UNYX Knowledge DB Architecture

UNYX Knowledge DB is a reusable PostgreSQL + pgvector infrastructure for AI Knowledge Base projects.

## Architecture

```text
UNYX Knowledge DB (PostgreSQL 16, container unyx-knowledge-db)
├── database: unyx              <- admin / registry only
│   └── unyx_core
│       └── tenants             <- company database registry
├── database: altosa
│   └── public
│       ├── products
│       ├── documents
│       ├── kb_versions
│       └── match_documents()
├── database: meditec
│   └── ...
└── database: unyx_solutions
    └── ...
```

Each company receives an isolated PostgreSQL database. The admin database (`unyx`) only stores the tenant registry; it never stores company data.

## Company database

Each company database contains, in its `public` schema:

- `products`
- `documents`
- `kb_versions`
- `match_documents()`

Universal fields are relational columns. Company-specific attributes are stored in `metadata JSONB`.

## Naming

- `tenant_key` identifies the company (e.g. `altosa`, `unyx-solutions`).
- Database names replace `-` with `_`: `unyx-solutions` -> database `unyx_solutions`.
- Application role per database: `<database_name>_app` (e.g. `altosa_app`).

## Isolation and portability

- Each company has its own database and PostgreSQL role.
- The app role owns its database and all its objects.
- A company can be exported independently using `pg_dump -d company_db` and restored with `scripts/restore-client.sh`.

## Registry

`unyx_core.tenants` tracks: `tenant_key`, `display_name`, `database_name`, `app_role`, `status` and `config`.

## Data lifecycle: volatile vs persistent

Persistent (survive restarts and crashes):

- PostgreSQL data files + WAL in the named volume `unyx-knowledge-data`
- Database dumps in `./backups`
- The tenant registry in the admin database

Volatile (lost on restart, by design):

- PostgreSQL `shared_buffers` and OS page cache
- Query/plan caches and connection state
- HNSW index build memory

No critical data lives only in memory: every create/edit/delete is written through a PostgreSQL transaction to WAL + data files before being acknowledged to the application.

## Durability and recovery

- Explicit durability settings in `docker-compose.yml`: `fsync=on`, `synchronous_commit=on`, `full_page_writes=on`.
- Client provisioning applies the whole schema in a single transaction (`--single-transaction`): a failed provisioning never leaves a half-created database.
- Edits to `products` and `documents` auto-maintain `updated_at` via the `touch_updated_at` trigger.
- Restore is staged: the dump is restored into a `_staging` database inside a single transaction, validated (the three core tables must exist), and only then swapped with the live database via rename. The previous database is kept as `_old` until the end, and is restored if anything fails.
- Backups are consistent snapshots (`pg_dump -Fc`) per company database.
- On unexpected crash (power loss, kill), PostgreSQL replays WAL automatically at startup: committed transactions are preserved, uncommitted ones are rolled back.


## Docker networks

- `unyx-ai`: n8n and AI services
- `unyx-db-admin`: global pgAdmin

PostgreSQL is not exposed publicly; port 5432 is published only on `127.0.0.1` so host-side tools (`setup-altosa-db.sh`, `backup.sh`, cron) can reach it from the VPS itself. n8n and other containers reach it by container name on the shared networks.
