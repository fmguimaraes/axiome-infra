# Pilot-tenant data segregation (AXI-1004 / FR10 / NFR2 / AC8 / AC9)

Minimal **single-tenant** segregation for the MIPP (APHM) pilot's data, inside the
AXI-916 HDS environment. Per NFR2 this is deliberately **pilot-grade, not full
multi-tenant isolation** — full multi-tenant isolation (per-tenant keys, row-level
tenancy) is deferred to annual licensing. Two boundaries, one per data layer:

## 1. Object store — dedicated namespace (already enforced by AXI-916/AXI-957)

Each environment gets its own, exclusively-named S3 bucket set:
`${naming_prefix}-artifacts`, `${naming_prefix}-uploads`, `${naming_prefix}-system`
(`naming_prefix = axiome-<environment>` — see `modules/storage`). For the pilot,
`production` **is** the MIPP tenant's environment, so these three buckets **are**
its dedicated object-store namespace — no other tenant's data can land in them.

Least-privilege is enforced at the IAM layer: both the EC2 instance role and the
runtime IAM user are scoped to `arn:aws:s3:::${naming_prefix}-*` only (see
`modules/compute-ec2/main.tf` `aws_iam_role_policy.s3` /
`aws_iam_user_policy.runtime`) — never a bare `arn:aws:s3:::*`. A compromised app
credential cannot reach a dev/staging bucket, let alone another provider's/tenant's
resources. No further prefixing is applied *within* a bucket — the bucket boundary
**is** the tenant boundary today, since the pilot is the sole occupant of the
production buckets.

## 2. Database — dedicated role scoped to the pilot tenant's schemas

The RDS instance (`modules/database-rds`) is itself already dedicated (one instance
per environment, no cross-environment sharing). What was missing before AXI-1004:
application containers received the **RDS master credentials** — full
instance-level privileges, not scoped to the pilot's own data — for
`DATABASE_URL` / `USER_DATABASE_URL` / `ORGANIZATION_DATABASE_URL` alike.

`01_pilot_tenant_app_role.sql` creates `axiome_app`: a login role with `SELECT` /
`INSERT` / `UPDATE` / `DELETE` on exactly the two schemas that make up the pilot
tenant's data — `user_svc`, `organization_svc` — and nothing else. No `CREATE`, no
`DROP`, no superuser, no grant on any schema outside that boundary (e.g. a future
second tenant's schema, or the `metabase_ro` analytics role in
`../../analytics/funnels/00_metabase_readonly_role.sql`). Terraform generates this
role's password (`modules/database-rds` `random_password.app_runtime`) and wires it
into `DATABASE_URL`/`USER_DATABASE_URL`/`ORGANIZATION_DATABASE_URL` via
`modules/secrets` (`postgres_app_url`) — the RDS **master** connection string
(`rds_connection_string_admin` output) never reaches a running container; it is
for one-off admin/migration use only.

### One-time setup per environment (after `terraform apply` and after Prisma has
### applied migrations, so `user_svc`/`organization_svc` exist)

```bash
cd providers/aws
psql "$(terraform output -raw rds_connection_string_admin)" \
  -v app_password="$(terraform output -raw rds_app_runtime_password)" \
  -f db/01_pilot_tenant_app_role.sql
```

Re-running is safe — the script is idempotent (creates the role only if missing,
always re-applies grants). Re-run it after rotating `app_runtime_password` (a fresh
`terraform apply` regenerates the password only if the resource is tainted/replaced;
routine applies leave it stable) or after any manual grant drift.

Then restart the app containers (or redeploy) so they pick up the new SSM values —
Terraform writes the SSM parameters, but running containers only read them at boot.

## Residency (NFR5)

Both boundaries inherit residency from the AXI-916 environment: the RDS instance and
S3 buckets are provisioned in the HDS-certified French region (`eu-west-3`) selected
by that environment — see `providers/CONTRACT.md` §1. No separate region assertion
is needed here; AXI-1004 does not introduce a new data store.

## What this is not

This is **not** full multi-tenant isolation. There is one Postgres instance and one
bucket set per environment, one pilot-tenant DB role, and no per-tenant encryption
keys or row-level security. If a second tenant is ever onboarded onto the same
environment, this boundary must be revisited (NFR2 explicitly defers that to annual
licensing) — do not present this as more than pilot-grade segregation.
