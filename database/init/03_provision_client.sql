CREATE OR REPLACE FUNCTION unyx_core.provision_client(

    p_tenant_key TEXT,
    p_display_name TEXT,
    p_schema_name TEXT,
    p_app_role TEXT,
    p_app_password TEXT,
    p_embedding_dim INTEGER DEFAULT 1536

)

RETURNS VOID

LANGUAGE plpgsql

AS $$

BEGIN

    --------------------------------------------------
    -- VALIDACIONES
    --------------------------------------------------

    IF p_tenant_key !~ '^[a-z][a-z0-9_]{1,62}$' THEN
        RAISE EXCEPTION 'tenant_key inválido';
    END IF;

    IF p_schema_name !~ '^[a-z][a-z0-9_]{1,62}$' THEN
        RAISE EXCEPTION 'schema_name inválido';
    END IF;

    IF p_app_role !~ '^[a-z][a-z0-9_]{1,62}$' THEN
        RAISE EXCEPTION 'app_role inválido';
    END IF;

    IF p_embedding_dim < 1 OR p_embedding_dim > 16000 THEN
        RAISE EXCEPTION 'embedding_dim inválido';
    END IF;


    --------------------------------------------------
    -- USUARIO DEL CLIENTE
    --------------------------------------------------

    IF NOT EXISTS (

        SELECT 1
        FROM pg_roles
        WHERE rolname = p_app_role

    )
    THEN

        EXECUTE FORMAT(

            'CREATE ROLE %I LOGIN PASSWORD %L',

            p_app_role,
            p_app_password

        );

    ELSE

        EXECUTE FORMAT(

            'ALTER ROLE %I LOGIN PASSWORD %L',

            p_app_role,
            p_app_password

        );

    END IF;


    --------------------------------------------------
    -- SCHEMA DEL CLIENTE
    --------------------------------------------------

    EXECUTE FORMAT(

        'CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- KB VERSIONS
    --------------------------------------------------

    EXECUTE FORMAT($sql$

        CREATE TABLE IF NOT EXISTS %I.kb_versions (

            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

            version TEXT NOT NULL,

            source_name TEXT,

            source_file_id TEXT,

            source_hash TEXT,

            status TEXT NOT NULL DEFAULT 'draft'
                CHECK (
                    status IN (
                        'draft',
                        'published',
                        'archived'
                    )
                ),

            notes TEXT,

            published_at TIMESTAMPTZ,

            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()

        )

    $sql$, p_schema_name);


    --------------------------------------------------
    -- PRODUCTS
    --------------------------------------------------

    EXECUTE FORMAT($sql$

        CREATE TABLE IF NOT EXISTS %I.products (

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

        )

    $sql$, p_schema_name);


    --------------------------------------------------
    -- DOCUMENTS / RAG
    --------------------------------------------------

    EXECUTE FORMAT($sql$

        CREATE TABLE IF NOT EXISTS %I.documents (

            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

            entity_type TEXT NOT NULL,

            entity_id TEXT,

            title TEXT,

            content TEXT NOT NULL,

            metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

            embedding VECTOR(%s),

            embedding_model TEXT,

            source TEXT,

            source_id TEXT,

            source_version TEXT,

            content_hash TEXT,

            is_active BOOLEAN NOT NULL DEFAULT TRUE,

            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()

        )

    $sql$, p_schema_name, p_embedding_dim);


    --------------------------------------------------
    -- OWNERSHIP DE TABLAS
    --------------------------------------------------

    EXECUTE FORMAT(

        'ALTER TABLE %I.kb_versions OWNER TO %I',

        p_schema_name,
        p_app_role

    );

    EXECUTE FORMAT(

        'ALTER TABLE %I.products OWNER TO %I',

        p_schema_name,
        p_app_role

    );

    EXECUTE FORMAT(

        'ALTER TABLE %I.documents OWNER TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- ÍNDICES PRODUCTS
    --------------------------------------------------

    EXECUTE FORMAT(

        'CREATE INDEX IF NOT EXISTS %I
        ON %I.products(category)',

        p_schema_name || '_products_category_idx',

        p_schema_name

    );


    EXECUTE FORMAT(

        'CREATE INDEX IF NOT EXISTS %I
        ON %I.products USING GIN(keywords)',

        p_schema_name || '_products_keywords_idx',

        p_schema_name

    );


    EXECUTE FORMAT(

        'CREATE INDEX IF NOT EXISTS %I
        ON %I.products USING GIN(metadata)',

        p_schema_name || '_products_metadata_idx',

        p_schema_name

    );


    --------------------------------------------------
    -- VECTOR INDEX
    --------------------------------------------------

    EXECUTE FORMAT(

        'CREATE INDEX IF NOT EXISTS %I
        ON %I.documents
        USING hnsw (embedding vector_cosine_ops)',

        p_schema_name || '_documents_embedding_idx',

        p_schema_name

    );


    --------------------------------------------------
    -- VECTOR SEARCH FUNCTION
    --------------------------------------------------

    EXECUTE FORMAT($function$

        CREATE OR REPLACE FUNCTION %I.match_documents(

            query_embedding VECTOR(%s),

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

        AS $body$

            SELECT

                d.id,

                d.entity_type,

                d.entity_id,

                d.title,

                d.content,

                d.metadata,

                1 - (
                    d.embedding <=> query_embedding
                ) AS similarity

            FROM %I.documents d

            WHERE

                d.is_active = TRUE

                AND d.embedding IS NOT NULL

                AND (

                    filter_metadata = '{}'::jsonb

                    OR d.metadata @> filter_metadata

                )

            ORDER BY

                d.embedding <=> query_embedding

            LIMIT GREATEST(match_count, 1);

        $body$

    $function$,

        p_schema_name,

        p_embedding_dim,

        p_schema_name

    );


    --------------------------------------------------
    -- OWNERSHIP DE FUNCIÓN
    --------------------------------------------------

    EXECUTE FORMAT(

        'ALTER FUNCTION %I.match_documents(vector, integer, jsonb)
        OWNER TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- SEGURIDAD DEL SCHEMA
    --------------------------------------------------

    EXECUTE FORMAT(

        'REVOKE ALL ON SCHEMA %I FROM PUBLIC',

        p_schema_name

    );


    EXECUTE FORMAT(

        'GRANT USAGE ON SCHEMA %I TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- PERMISOS TABLAS
    --------------------------------------------------

    EXECUTE FORMAT(

        'GRANT SELECT, INSERT, UPDATE, DELETE
        ON ALL TABLES IN SCHEMA %I
        TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- PERMISOS SECUENCIAS
    --------------------------------------------------

    EXECUTE FORMAT(

        'GRANT USAGE, SELECT
        ON ALL SEQUENCES IN SCHEMA %I
        TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- PERMISOS FUNCIONES
    --------------------------------------------------

    EXECUTE FORMAT(

        'GRANT EXECUTE
        ON ALL FUNCTIONS IN SCHEMA %I
        TO %I',

        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- DEFAULT PRIVILEGES
    --------------------------------------------------

    EXECUTE FORMAT(

        'ALTER DEFAULT PRIVILEGES
        FOR ROLE %I
        IN SCHEMA %I
        GRANT SELECT, INSERT, UPDATE, DELETE
        ON TABLES TO %I',

        p_app_role,
        p_schema_name,
        p_app_role

    );


    EXECUTE FORMAT(

        'ALTER DEFAULT PRIVILEGES
        FOR ROLE %I
        IN SCHEMA %I
        GRANT USAGE, SELECT
        ON SEQUENCES TO %I',

        p_app_role,
        p_schema_name,
        p_app_role

    );


    EXECUTE FORMAT(

        'ALTER DEFAULT PRIVILEGES
        FOR ROLE %I
        IN SCHEMA %I
        GRANT EXECUTE
        ON FUNCTIONS TO %I',

        p_app_role,
        p_schema_name,
        p_app_role

    );


    --------------------------------------------------
    -- REGISTRO DEL TENANT
    --------------------------------------------------

    INSERT INTO unyx_core.tenants (

        tenant_key,
        display_name,
        schema_name,
        app_role,
        config

    )

    VALUES (

        p_tenant_key,

        p_display_name,

        p_schema_name,

        p_app_role,

        jsonb_build_object(

            'embedding_dim',
            p_embedding_dim

        )

    )

    ON CONFLICT (tenant_key)

    DO UPDATE SET

        display_name = EXCLUDED.display_name,

        schema_name = EXCLUDED.schema_name,

        app_role = EXCLUDED.app_role,

        config =
            unyx_core.tenants.config
            || EXCLUDED.config,

        updated_at = NOW();

END;

$$;