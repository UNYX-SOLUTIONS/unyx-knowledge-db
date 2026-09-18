CREATE TABLE IF NOT EXISTS public.kb_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version TEXT NOT NULL,
    source_name TEXT,
    source_file_id TEXT,
    source_hash TEXT,
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'published', 'archived')),
    notes TEXT,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id TEXT,
    sku TEXT,
    name TEXT NOT NULL,
    category TEXT,
    subcategory TEXT,
    description TEXT,
    price NUMERIC(14,4),
    stock NUMERIC(14,4),
    currency TEXT NOT NULL DEFAULT 'USD',
    keywords TEXT[] NOT NULL DEFAULT '{}',
    url TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    source TEXT,
    source_version TEXT,
    content_hash TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type TEXT NOT NULL,
    entity_id TEXT,
    title TEXT,
    content TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    embedding VECTOR(:dim),
    embedding_model TEXT,
    source TEXT,
    source_id TEXT,
    source_version TEXT,
    content_hash TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS products_category_idx
    ON public.products (category);

CREATE INDEX IF NOT EXISTS products_keywords_idx
    ON public.products USING GIN (keywords);

CREATE INDEX IF NOT EXISTS products_metadata_idx
    ON public.products USING GIN (metadata);

CREATE INDEX IF NOT EXISTS documents_embedding_idx
    ON public.documents USING hnsw (embedding vector_cosine_ops);

CREATE OR REPLACE FUNCTION public.match_documents(
    query_embedding VECTOR(:dim),
    match_count INTEGER DEFAULT 8,
    filter_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    id UUID,
    entity_type TEXT,
    entity_id TEXT,
    title TEXT,
    content TEXT,
    metadata JSONB,
    similarity DOUBLE PRECISION
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
        d.id,
        d.entity_type,
        d.entity_id,
        d.title,
        d.content,
        d.metadata,
        1 - (d.embedding <=> query_embedding) AS similarity
    FROM public.documents d
    WHERE
        d.is_active = TRUE
        AND d.embedding IS NOT NULL
        AND (
            filter_metadata = '{}'::jsonb
            OR d.metadata @> filter_metadata
        )
    ORDER BY d.embedding <=> query_embedding
    LIMIT GREATEST(match_count, 1);
$$;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS products_touch_updated_at ON public.products;
CREATE TRIGGER products_touch_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW
    EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS documents_touch_updated_at ON public.documents;
CREATE TRIGGER documents_touch_updated_at
    BEFORE UPDATE ON public.documents
    FOR EACH ROW
    EXECUTE FUNCTION public.touch_updated_at();

