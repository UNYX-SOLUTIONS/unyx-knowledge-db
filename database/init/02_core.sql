CREATE SCHEMA IF NOT EXISTS unyx_core;

CREATE TABLE IF NOT EXISTS unyx_core.tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_key TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    database_name TEXT UNIQUE NOT NULL,
    app_role TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive', 'migrated')),
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION unyx_core.ensure_role(
    p_role TEXT,
    p_password TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_role !~ '^[a-z][a-z0-9_]{1,62}$' THEN
        RAISE EXCEPTION 'rol inválido';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        EXECUTE FORMAT('CREATE ROLE %I LOGIN PASSWORD %L', p_role, p_password);
    ELSE
        EXECUTE FORMAT('ALTER ROLE %I LOGIN PASSWORD %L', p_role, p_password);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION unyx_core.upsert_tenant(
    p_tenant_key TEXT,
    p_display_name TEXT,
    p_database_name TEXT,
    p_app_role TEXT,
    p_config JSONB DEFAULT '{}'::jsonb
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO unyx_core.tenants (
        tenant_key,
        display_name,
        database_name,
        app_role,
        config
    )
    VALUES (
        p_tenant_key,
        p_display_name,
        p_database_name,
        p_app_role,
        p_config
    )
    ON CONFLICT (tenant_key)
    DO UPDATE SET
        display_name = EXCLUDED.display_name,
        database_name = EXCLUDED.database_name,
        app_role = EXCLUDED.app_role,
        config = unyx_core.tenants.config || EXCLUDED.config,
        updated_at = NOW();
END;
$$;
