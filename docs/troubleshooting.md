# Troubleshooting

Operational troubleshooting for deployed environments. For *how to connect* to a
host, see [connect-and-debug.md](connect-and-debug.md). For Day-0 setup, see
[bootstrapping.md](bootstrapping.md).

---

## Admin login returns 401 (and the gateway shows "unhealthy")

**First documented:** 2026-06-23, production. The two symptoms below look related
but are independent — one is cosmetic, one is the real blocker.

### Symptom A — gateway container is `unhealthy` (cosmetic, not an outage)

`docker compose ps` shows `axiome-gateway ... (unhealthy)` while every other
container is healthy and the app actually serves traffic.

**Cause.** The compose healthcheck probes `http://localhost:3000/health`, but the
NestJS gateway mounts all routes under the `api/v1` global prefix. The real health
endpoint is **`/api/v1/health`**. `/health` returns 404, so the healthcheck fails
forever. You can see it in the logs as a steady stream of:

```
WARN [AllExceptionsFilter] GET /health - 404: Cannot GET /health
```

**Confirm the app is actually up:**

```bash
scripts/platform-debug.sh health     # hits /api/v1/health → {"status":"ok",...}
```

**Fix (open).** Point the healthcheck at `/api/v1/health` in the cloud-init
`docker-compose.yml` (gateway service `healthcheck.test`). Until then, treat
gateway `unhealthy` as a false alarm and verify with the command above.

### Symptom B — `POST /api/v1/auth/login → 401 Invalid credentials`

The login request reaches the server (you see the 401 in the gateway logs), the
route works, user-service is healthy — but the password is rejected.

**Historical root cause (fixed — G5/FR9, AXI-983): the bootstrap admin password
used to be re-applied on every start.** `AdminBootstrapService` used to run
`onApplicationBootstrap` and **upsert** the admin user from the SSM parameter
`BOOTSTRAP_ADMIN_PASSWORD` every time user-service started, so:

- Whatever value was in SSM was the effective password, always.
- Any password set **in the UI silently reverted** on the next user-service
  restart — including every EC2 stop/start.

`AdminBootstrapService` is now **create-only**: it seeds the admin once, and a
restart never touches an existing admin's password/profile again. The
`BOOTSTRAP_ADMIN_PASSWORD` SSM parameter is **deleted** after the admin is
seeded/rotated (see `scripts/reset-admin-password.sh`), so there is no
replayable bootstrap secret left in SSM. If you still see a 401 today, the cause
is a genuinely wrong/stale password, not a bootstrap replay — rotate it through
the product's forgot-password / reset-password flow, or (only if no admin exists
yet) seed one:

**Diagnose:**

```bash
scripts/platform-debug.sh login-test <admin-email>   # only works right after
                                                       # reset-admin-password.sh -k;
                                                       # otherwise errors cleanly
                                                       # because SSM has no lingering
                                                       # bootstrap secret (by design)
```

**Fix — seed the admin (only if it does not exist yet):**

```bash
scripts/reset-admin-password.sh                 # prod, auto-generates a strong pw
scripts/reset-admin-password.sh -p 'My-Pass'    # or set a specific one
```

This writes SSM → refreshes the on-box `.env` → recreates user-service → verifies
login = 200 → **blanks the SSM param**, then prints the new password once. Save
it in your password manager. Against an environment that already has an admin,
the login check will correctly fail (create-only skips the seed) — use the
product's reset-password flow to change that admin's password instead.

> ⚠️ **Do not** edit `BOOTSTRAP_ADMIN_PASSWORD` directly in `/opt/axiome/.env` by
> hand with `printf '...\n'` — an unquoted `\n` in `dash` is stripped to a literal
> `n` and gets appended to the password, producing a value that hashes differently
> from what you type (this caused a 45-char vs 44-char mismatch during the original
> incident). Use the script, which writes the line with a quoted `printf '%s\n'`.

### Why connectivity was never the problem

The instance has an **Elastic IP** (`eipassoc-...`), so stop/start does **not**
change the public IP and DNS stays valid. If login attempts show up in the gateway
logs at all, you are reaching the right box — the issue is credentials, not network.

---

## `The column X.Y does not exist in the current database` (Prisma, fresh prod deploy)

**First documented:** 2026-06-23, production. Surfaced as service 500s right after a
fresh deploy, e.g.:

```
The column `workspace_members.role_id` does not exist in the current database.
The column `roles.hierarchy` does not exist in the current database.
Invalid `prisma.workspaceMember.create()` invocation: ...
```

### Root cause — prod schema is provisioned by `db push`, not migrations

The production Postgres (`axiome-production-pg` RDS, schemas `organization_svc` /
`user_svc`) was materialized with **`prisma db push`**, which syncs the schema but
writes **no migration history**. Confirmed by:

- `prisma migrate status` reports **all** migrations "not yet applied" — including
  ones whose tables plainly exist — and the `_prisma_migrations` table is **absent**
  from the schema.
- The table exists but a recently-added column does not (error is *column* missing,
  not *relation* missing).

So every time a column/table is added to a service's `schema.prisma`, the Prisma
**client** ships in the new image and queries the new shape, but **nothing applies
the DDL to prod**. The deploy pipeline has **no `migrate deploy` / `db push` step**.
The DB silently falls behind the code; each feature 500s the first time it's hit.

> ⚠️ **Do NOT run `prisma migrate deploy` against prod here.** With an empty
> `_prisma_migrations`, it would try to replay all migrations from scratch
> (`CREATE TABLE`/`CREATE TYPE` on objects that already exist) and fail partway,
> risking a half-applied schema.

### Fix — diff the live DB against the schema and apply the additive DDL

Open the [SSM port-forward to RDS](connect-and-debug.md#51-private-rds-postgres-via-ssm-port-forward--connect-from-your-laptop),
then for each Postgres service compute the exact forward DDL — **no shadow DB
needed** with `--from-url`:

```bash
cd axiome-back
LOCAL_URL='...@127.0.0.1:55432/axiome?sslmode=require&schema=organization_svc'   # from SSM, host swapped
./node_modules/.bin/prisma migrate diff \
  --from-url "$LOCAL_URL" \
  --to-schema-datamodel apps/organization-service/src/prisma/schema.prisma \
  --script > org_drift.sql
```

Review `org_drift.sql` and **scan for destructive statements** before applying —
`grep -E 'DROP|ALTER COLUMN|SET NOT NULL|ADD COLUMN.*NOT NULL'`. Pure-additive
output (`CREATE TABLE/TYPE/INDEX`, `ADD VALUE`, nullable `ADD COLUMN`) is safe to
apply as-is; anything that drops or adds a `NOT NULL` column to a populated table
needs a backfill plan first. Apply inside a transaction (drive the service's
generated Prisma client — `node_modules/.prisma/<service>-client` — with
`$executeRawUnsafe`; see connect-and-debug.md). Re-run the same `migrate diff` with
`--exit-code` to confirm `IN SYNC`. Repeat per service (`organization`, `user`;
`event` is MongoDB and unaffected).

### Permanent fix — landed (AXI-1003)

`scripts/roll-service.sh` now runs `migrate_organization_schema` on every
`SERVICE=backend` roll, before the image swap: it baselines `_prisma_migrations`
on first run (exactly the `prisma migrate resolve --applied <each>` recipe above,
automated), then `prisma migrate deploy`, verified by a whole-schema row-count
parity check — fail-closed, so a drop in row count or a failed migration skips the
image swap and leaves the old containers serving. `.github/workflows/dev-auto-promote.yml`
binds the result into the FR14 Qualification Record
(`scripts/generate-qualification-record.sh`) via a `MIGRATION_FACTS:` line. See the
script's header comment for the rollback procedure.

This covers `organization_svc` on whichever VM runs `roll-service.sh` (dev via the
auto-promote workflow today; staging/production the same way, run by an operator).
`user_svc` is not wired yet — extend `migrate_organization_schema`'s pattern
(rename to something generic, or add a sibling function) when that becomes urgent;
until then it still needs the manual diff procedure above.

The hand-applied diff procedure above remains the fallback for a migration that
fails the automated path (e.g. a genuinely destructive change needing a backfill
plan first) or for `user_svc`.

---

## Emails not being sent (feedback, @mentions, password reset, welcome, export)

**Symptom:** an action that should email (e.g. the in-app feedback button) succeeds in
the UI, but no email arrives. No error is shown — email sends are best-effort and the
failure is swallowed.

**First check:** `scripts/ssm-exec.sh 'docker logs axiome-user-service --since 1h 2>&1 | grep -i mailjet'`.
- `Mailjet NOT configured — MAILJET_API_KEY=missing, MAILJET_SECRET_KEY=missing` →
  the credentials are absent, `EmailService` is in log-only mode, nothing is sent.
- `Mailjet configured` → the client is up; look instead for `No active admins to notify`
  (no `role=ADMIN`/`status=ACTIVE` recipient) or `Failed to notify admins`.

**Root cause seen in production (2026-08-26):** the Mailjet SSM params were never created
because `terraform-cd.yml` did not inject the `MAILJET_API_KEY`/`SECRET_KEY` GitHub
secrets as `TF_VAR_*`, so the `count`-guarded resources stayed at 0. Full write-up and
the permanent fix: [incidents/2026-08-26-feedback-email-mailjet-not-configured.md](incidents/2026-08-26-feedback-email-mailjet-not-configured.md).

---

## General triage order

1. **Is the app up?** `scripts/platform-debug.sh health` → expect `{"status":"ok"}`.
   Ignore a gateway `unhealthy` flag until this fails (see Symptom A).
2. **What's running?** `scripts/platform-debug.sh status`.
3. **What does the failing service say?** `scripts/platform-debug.sh logs <service> 120`.
4. **Is it auth?** `scripts/platform-debug.sh login-test <email>`.
5. **Anything else** — drop to a raw command: `scripts/ssm-exec.sh '<cmd>'`.
