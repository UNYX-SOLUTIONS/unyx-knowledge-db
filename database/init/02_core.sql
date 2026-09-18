CREATE SCHEMA IF NOT EXISTS unyx_core;

CREATE TABLE IF NOT EXISTS unyx_core.tenants (
    tenant_key      text PRIMARY KEY,
    display_name    text NOT NULL,
    database_name   text NOT NULL UNIQUE,
    app_role        text NOT NULL UNIQUE,
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','disabled','migrated')),
    settings        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION unyx_core.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_updated_at ON unyx_core.tenants;
CREATE TRIGGER trg_tenants_updated_at
BEFORE UPDATE ON unyx_core.tenants
FOR EACH ROW EXECUTE FUNCTION unyx_core.touch_updated_at();

CREATE OR REPLACE FUNCTION unyx_core.upsert_tenant(
    p_tenant_key text,
    p_display_name text,
    p_database_name text,
    p_app_role text,
    p_settings jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO unyx_core.tenants
        (tenant_key, display_name, database_name, app_role, settings)
    VALUES
        (p_tenant_key, p_display_name, p_database_name, p_app_role, p_settings)
    ON CONFLICT (tenant_key) DO UPDATE SET
        display_name  = EXCLUDED.display_name,
        database_name = EXCLUDED.database_name,
        app_role      = EXCLUDED.app_role,
        settings      = EXCLUDED.settings,
        status        = 'active',
        updated_at    = now();
END;
$$;
