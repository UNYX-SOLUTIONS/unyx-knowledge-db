\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS kb_versions (
    id              bigserial PRIMARY KEY,
    version         text NOT NULL UNIQUE,
    description     text,
    status          text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','active','archived')),
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    activated_at    timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_kb_versions_one_active
ON kb_versions ((status))
WHERE status = 'active';

CREATE TABLE IF NOT EXISTS products (
    id              bigserial PRIMARY KEY,
    external_id     text,
    sku             text,
    name            text NOT NULL,
    category        text,
    subcategory     text,
    description     text,
    price           numeric(12,2),
    stock           integer,
    currency        text NOT NULL DEFAULT 'USD',
    keywords        text[] NOT NULL DEFAULT ARRAY[]::text[],
    url             text,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    source          text,
    source_version  text,
    content_hash    text,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_products_sku
ON products (sku) WHERE sku IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active);
CREATE INDEX IF NOT EXISTS idx_products_metadata ON products USING gin(metadata);
CREATE INDEX IF NOT EXISTS idx_products_keywords ON products USING gin(keywords);

CREATE TABLE IF NOT EXISTS documents (
    id              bigserial PRIMARY KEY,
    external_id     text,
    title           text,
    content         text NOT NULL,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    embedding       vector(:dim),
    source          text,
    source_version  text,
    content_hash    text,
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_documents_metadata ON documents USING gin(metadata);
CREATE INDEX IF NOT EXISTS idx_documents_active ON documents(is_active);
CREATE INDEX IF NOT EXISTS idx_documents_embedding
ON documents USING hnsw (embedding vector_cosine_ops);

CREATE TABLE IF NOT EXISTS n8n_chat_histories (
    id          bigserial PRIMARY KEY,
    session_id  varchar(255) NOT NULL,
    message     jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_histories_session
ON n8n_chat_histories(session_id);

CREATE TABLE IF NOT EXISTS processed_outgoing_messages (
    message_id    text PRIMARY KEY,
    lead_id       text NOT NULL,
    processed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_processed_outgoing_lead
ON processed_outgoing_messages(lead_id);

CREATE OR REPLACE FUNCTION match_documents(
    query_embedding vector(:dim),
    match_count integer DEFAULT 5,
    filter jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    id bigint,
    content text,
    metadata jsonb,
    similarity double precision
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        d.id,
        d.content,
        d.metadata,
        1 - (d.embedding <=> query_embedding) AS similarity
    FROM documents d
    WHERE d.is_active = true
      AND d.embedding IS NOT NULL
      AND d.metadata @> filter
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
$$;

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_updated_at ON products;
CREATE TRIGGER trg_products_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_documents_updated_at ON documents;
CREATE TRIGGER trg_documents_updated_at
BEFORE UPDATE ON documents
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
