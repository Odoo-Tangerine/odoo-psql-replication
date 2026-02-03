-- Create a role for Odoo
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'odoo') THEN
        CREATE ROLE odoo LOGIN PASSWORD 'odoo' CREATEDB CREATEROLE;
    END IF;
END$$;
