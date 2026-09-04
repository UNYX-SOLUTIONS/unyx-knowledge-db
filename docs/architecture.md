# UNYX Knowledge DB Architecture

UNYX Knowledge DB is a reusable PostgreSQL + pgvector infrastructure for AI Knowledge Base projects.

## Architecture

```text
unyx_knowledge
├── unyx_core
├── altosa
├── meditec
└── client_x
```

Each client receives an isolated PostgreSQL schema.

## Client schema

Each client receives:

- `products`
- `documents`
- `kb_versions`
- `match_documents()`

Universal fields are relational columns. Client-specific attributes are stored in `metadata JSONB`.

## Isolation and portability

Each client has its own schema and PostgreSQL role. A client can be exported independently using `pg_dump -n client_schema`.

## Docker networks

- `unyx-ai`: n8n and AI services
- `unyx-db-admin`: global pgAdmin

PostgreSQL is not exposed publicly.
