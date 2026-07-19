-- Pilot-tenant least-privilege runtime role (AXI-1004 / FR10 / NFR2 / AC8).
--
-- The RDS master role (`aws_db_instance.this.username`, Terraform output
-- `connection_string`) has full instance-level privileges and is admin/migration
-- use only. It must never be handed to a running application container. This
-- script creates the DML-only role that application containers actually use,
-- scoped to exactly the two schemas that make up the MIPP pilot tenant's data
-- (`user_svc`, `organization_svc`) — no CREATE/DROP, no superuser, no access to
-- any schema outside the pilot tenant's own boundary. This is the DB half of the
-- FR10 segregation boundary; the object-store half is the dedicated
-- `${naming_prefix}-{artifacts,uploads,system}` bucket set (see ../README.md).
--
-- Run ONCE per environment against the RDS instance, AFTER Prisma has applied
-- migrations (so `user_svc`/`organization_svc` exist), using the MASTER
-- connection string (admin rights are required to CREATE ROLE / GRANT):
--   psql "$(terraform -chdir=providers/aws output -raw rds_connection_string_admin)" \
--     -v app_password="$(terraform -chdir=providers/aws output -raw rds_app_runtime_password)" \
--     -f providers/aws/db/01_pilot_tenant_app_role.sql
--
-- The role name below must match `app_runtime_username` (default `axiome_app`) and
-- the password must match `random_password.app_runtime` from
-- modules/database-rds — both surfaced as sensitive Terraform outputs. Re-running
-- this script is safe (idempotent): it only creates the role if missing and always
-- re-applies the grants, so it also self-heals if a grant was hand-edited.

-- 1. The role (idempotent — safe to re-run). Login-only, no CREATEDB/CREATEROLE/superuser.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'axiome_app') THEN
    CREATE ROLE axiome_app LOGIN PASSWORD :'app_password';
  ELSE
    ALTER ROLE axiome_app PASSWORD :'app_password';
  END IF;
END
$$;

-- 2. Connect to the deployment DB; USAGE + DML on the pilot tenant's own schemas
--    only. No GRANT on any other schema (e.g. a future second tenant's schema, or
--    Metabase's read-layer role from analytics/funnels/00_metabase_readonly_role.sql)
--    reaches this role — that is the tenant boundary.
GRANT CONNECT ON DATABASE axiome TO axiome_app;

GRANT USAGE ON SCHEMA user_svc         TO axiome_app;
GRANT USAGE ON SCHEMA organization_svc TO axiome_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA user_svc         TO axiome_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA organization_svc TO axiome_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA user_svc         TO axiome_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA organization_svc TO axiome_app;

-- 3. Keep runtime access working across future Prisma migrations (new tables /
--    sequences) without re-running this script by hand each time.
ALTER DEFAULT PRIVILEGES IN SCHEMA user_svc         GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO axiome_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA organization_svc GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO axiome_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA user_svc         GRANT USAGE, SELECT                  ON SEQUENCES TO axiome_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA organization_svc GRANT USAGE, SELECT                  ON SEQUENCES TO axiome_app;

-- Note: no CREATE on either schema (schema changes stay on the master/migration
-- role only — FR8/NFR1 forward-only migrations), no TRUNCATE, no DDL, and no grant
-- on any schema outside user_svc/organization_svc. A compromised app credential
-- can read/write pilot data but cannot alter the schema, drop tables, or reach
-- outside the pilot tenant's boundary.
