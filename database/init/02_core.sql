CREATE SCHEMA IF NOT EXISTS unyx_core;

CREATE TABLE IF NOT EXISTS unyx_core.tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_key TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    schema_name TEXT UNIQUE NOT NULL,
    app_role TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive', 'migrated')),
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION unyx_core.touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;
