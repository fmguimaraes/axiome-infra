# AXI-1347 — Production catch-up deploy: reviewed migration & rollback plan

**Status:** proposed — awaiting human sign-off before any prod write (Phase 2).
**Scope:** FR10 / NFR3. One-time. Ships the caught-up `axiome-back` `main` to
production and brings the production database from its months-behind state up to
migration HEAD, safely.

## 1. Current production state (verified 2026-08-25)

- Running backend image: `:stable` = `c6b2a340` (~late June). Prod pins `:stable`
  (`use_ssm_image_tags = false`).
- `organization_svc` has **no `_prisma_migrations` ledger at all**; `user_svc`'s
  ledger stops at `20260218120000` (Feb). No `events`/`analytics_events` and no
  other post-June tables exist. → Production is **months behind** and was
  provisioned by `db push`, never by the migration chain.
- The RDS instance is private (SSM tunnel / on-box only) and is stopped by
  default; it is currently powered on.

## 2. Why the normal deploy is unsafe here

`scripts/roll-service.sh` baselines a ledgerless DB by marking **every** committed
migration `resolve --applied` and then running `migrate deploy`. That is correct
**only if the db-push'd schema already equals migration HEAD**. Production's does
**not** — it is at a June-ish state. Naive "resolve-all" would record dozens of
migrations as applied **without running their DDL**, leaving prod's schema missing
every table/column those migrations create (`analytics_events`,
`comparability_metadata`, the subject-management tables, …) while the ledger
claims they exist. That is silent, hard-to-detect corruption. **Do not run the
routine baseline for this catch-up.**

## 3. The destructive statement (NFR3)

The only data-destroying statement in the pending chain (the
`20260825153000_reconcile_db_push_drift` migration) is:

```sql
ALTER TABLE "workspaces" DROP COLUMN "auto_default_analysis_enabled";
```

**Verified unused:** the column appears **only** in migration files across the
entire backend (`git grep` of `apps/**` + `libs/**` finds zero application-code
references — it is never read or written). Dropping it loses only a stored boolean
that nothing consumes. (Two index drops in the same migration are performance-only,
non-data.) The RDS snapshot in step 4 covers it regardless.

## 4. Procedure (Phase 2 — only after sign-off)

1. **Snapshot** the production RDS (manual snapshot, named
   `axiome-production-pg-pre-AXI1347-<date>`); wait until `available`. This is the
   rollback point.
2. **Introspect** prod (read-only, over the SSM tunnel with master creds) to
   confirm the true schema high-water mark for `organization_svc` and `user_svc`.
3. **Generate the exact catch-up delta per service**, drift-safe, using the same
   pattern that authored the reconcile migrations:
   `prisma migrate diff --from-url "<prod service DB>" --to-schema-datamodel
   apps/<svc>/src/prisma/schema.prisma --script`. This yields the precise SQL to
   bring prod → HEAD (create missing tables, add columns, the one DROP COLUMN).
4. **Review** the generated delta — assert the only destructive statements are the
   verified `DROP COLUMN` + the two index drops; anything else destructive stops
   the deploy for re-review.
5. **Apply** the reviewed delta to prod (single transaction where possible), then
   **baseline the ledger to HEAD** — `prisma migrate resolve --applied <migration>`
   for every migration dir, now that the schema genuinely matches HEAD — so
   subsequent `migrate deploy` runs are clean and the CI drift gate holds.
6. **Advance `:stable`** to the caught-up backend image (a green `main` build that
   passed the blocking scan gate) and `docker compose pull` + `up -d` on the box.
7. **Verify:** `migrate diff` shows **zero drift** for both services; `/api/v1/health`
   is 200; a light smoke check of a couple of endpoints.

## 5. Rollback

- **Schema:** restore the step-1 RDS snapshot.
- **Image:** retag `:stable` back to `c6b2a340` and re-pull on the box.
- `roll-service.sh` already fails closed (old containers keep serving) if
  `migrate deploy` fails, so a failed migrate never leaves prod half-swapped.

## 6. Open confirmations needed before Phase 2

- Sign-off to snapshot + write to production.
- Confirm the maintenance window (prod is powered on; brief backend swap).
- Decision already recorded: the DROP COLUMN is code-unused (safe); proceeding
  drops it.
