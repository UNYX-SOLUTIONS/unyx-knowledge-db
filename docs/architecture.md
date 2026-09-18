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

## Docker networks

- `unyx-ai`: n8n and AI services
- `unyx-db-admin`: global pgAdmin

PostgreSQL is not exposed publicly.
