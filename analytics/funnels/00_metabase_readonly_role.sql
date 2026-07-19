-- Behavior Tracking read layer (AXI-1048 / FR10 / NFR2).
-- Least-privilege read-only role for Metabase's connection to the deployment DB.
-- Metabase only ever needs SELECT on the analytics `events` table — nothing else in
-- the product schema is exposed to the read layer.
--
-- Run ONCE against the deployment database (the `axiome` DB), AFTER the backend has
-- applied its migrations (so `organization_svc.events` exists):
--   psql "$DATABASE_URL" -f analytics/funnels/00_metabase_readonly_role.sql
--
-- Then configure the Metabase data source with user `metabase_ro`. Replace the
-- placeholder password below with a real secret from the secrets store before
-- running in cloud/on-prem — do NOT ship this default.

-- 1. The role (idempotent — safe to re-run).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    CREATE ROLE metabase_ro LOGIN PASSWORD 'change_me_readonly';  -- <-- set from secrets store
  END IF;
END
$$;

-- 2. Connect + read-only on the analytics events table only.
GRANT CONNECT ON DATABASE axiome            TO metabase_ro;
GRANT USAGE   ON SCHEMA   organization_svc  TO metabase_ro;
GRANT SELECT  ON          organization_svc.events TO metabase_ro;

-- 3. Keep read access working if the table is ever recreated by a future migration.
ALTER DEFAULT PRIVILEGES IN SCHEMA organization_svc GRANT SELECT ON TABLES TO metabase_ro;

-- Note: no INSERT/UPDATE/DELETE, no other tables. The read layer cannot mutate data
-- and cannot see product tables outside the analytics events feed.
