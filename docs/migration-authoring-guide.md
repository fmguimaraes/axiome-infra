# Migration-authoring guide (NFR9, AC33)

How to write a migration that the gate (`docker/migrate-gate/`, baked into the
backend image, `axiome-back` `docker/migrate-gate/`) will actually accept at
roll/deploy time, without re-deriving the gate's rules from its source. The gate
itself lives in `axiome-back`; this guide is the `axiome-infra`-side half —
what an operator/author needs to know before writing a Prisma migration that
will run through `scripts/roll-service.sh` / `scripts/deploy-prod.sh` on a real
box.

## The one rule: forward-only, expand/contract across TWO deploys

**NFR9 — backward-compatible migrations.** A migration you ship MUST keep the
**previously deployed image** working, because a rollback (`deploy-prod.sh`'s
`restore_previous_tag`, see [`platform-lifecycle-operations.md`](platform-lifecycle-operations.md#5-roll--ssm-exec-exit-codes))
re-points the box at the OLD image but **never reverts the schema** — the gate
is forward-only and has no "down" migration concept at all. If deploy N's
migration is not backward-compatible with image N-1, a restore-to-N-1 after a
readiness failure leaves the OLD code running against the NEW schema, which is
exactly the failure mode `report_rollback_caveat` in `deploy-prod.sh` warns
about ("the schema may now be ahead of the restored image").

The only safe way to make a breaking-looking change (rename a column, change a
type, drop a column, split a table) is **expand, then contract, in two
separate deploys**:

1. **Deploy A (expand):** add the new shape ALONGSIDE the old one. The
   previously-deployed image (N-1, still running during roll, and the one a
   restore would fall back to) must not error against the new shape:
   - Adding a column: it must be **nullable or have a `DEFAULT`** — N-1's
     `INSERT`/`UPDATE` statements, which never mention the new column, must
     still succeed.
   - Renaming a column: do it as **add new column → backfill → dual-write in
     application code** (a separate, app-repo change) — never a bare
     `RENAME COLUMN` in one migration; N-1 is still reading/writing the OLD
     name.
   - Changing a type: add a new column of the new type, backfill, then switch
     readers over in a LATER deploy.
   - Dropping a column/table: never in the SAME deploy that stops writing to
     it. Stop writing first (an app-repo deploy), ship, confirm it is healthy
     and stays healthy for at least one more deploy cycle, THEN drop it in a
     later migration.
2. **Deploy B (contract), a SEPARATE later deploy:** once N-1 is no longer the
   fallback target of any live rollback window (i.e. deploy A has been running
   healthily and no one would restore past it), ship the migration that
   removes the old shape (drop the old column, add the `NOT NULL` constraint,
   etc). A restore from deploy B only ever falls back to deploy A's image,
   which already expects the new shape.

A migration that does both in one deploy is not caught by any automated check
today — the gate validates row counts and ledger state, not backward
compatibility — so this is reviewed by eye. Treat "does this one migration
both add and remove in the same deploy" as a standing review question.

## What the gate actually checks (and does not)

From `axiome-back` `docker/migrate-gate/` (AXI-1946, epic AXI-1944 decision 3)
as observed through the CLI contract `axiome-infra` codes against — read the
gate's own source in `axiome-back` for the full implementation:

- **Row-count pre/post check.** When migrations are pending, `apply` takes an
  exact `count(*)` per table **before** and **after** running them. It fails
  the whole `apply` (no rows applied in the failing service) if any table's
  count **decreased**, a table **vanished**, or a count could not be read —
  unless that exact `<schema>.<table>` is listed in
  `MIGRATE_GATE_ALLOW_ROW_LOSS` (comma-separated, case-sensitive). **What
  trips it:** any migration whose own logic deletes/truncates/drops rows as
  part of a "cleanup", a `DELETE FROM` backfill step that is not idempotent
  against a partially-applied prior run, or a legitimate intentional delete
  the author forgot to allowlist. If your migration is SUPPOSED to delete
  rows (e.g. removing soft-deleted records as a one-off), add the table to
  `MIGRATE_GATE_ALLOW_ROW_LOSS` for that run and say so in the deploy's own
  notes/PR — do not treat the override as routine.
- **Ledger presence.** A migration only "counts" if Prisma's own
  `_prisma_migrations` ledger has it as `finished_at` set, `rolled_back_at`
  null. A service with tables but no ledger at all is a **baselining**
  situation (see
  [the baselining runbook](platform-lifecycle-operations.md#2-baselining--migrate-gate-baseline-service)),
  not a migration-authoring one — do not try to "fix" a missing ledger by
  writing a migration.
- **Facts line.** A successful `apply` with pending work prints
  `MIGRATION_FACTS: SERVICE=<s> SCHEMA_VERSION=<name> APPLIED=<n> PRE_COUNTS=<n> POST_COUNTS=<n>`
  (counts read `skipped` literally when nothing was pending) — this is what
  `generate-qualification-record.sh` anchors on; keep any new migration's
  **service** one of `organization-service`/`user-service` (or whatever
  `MIGRATE_GATE_SERVICES` lists) so it is picked up by that line at all.
- **What it does NOT check:** backward compatibility with the previous image
  (NFR9, above — reviewed by eye), the SQL's own correctness/performance, or
  whether the migration is idempotent if re-run (Prisma's own migration
  history makes a finished migration a no-op on re-run; a migration you hand
  -write outside Prisma's `migrate dev`/`migrate deploy` flow is on you to
  make idempotent).

## `MIGRATION_FACTS` fields — what each one means for the author

| Field | Meaning | Author-relevant note |
|---|---|---|
| `SERVICE` | which service's migrations ran (`organization-service`/`user-service`) | your migration file lives under that service's `src/prisma/migrations/` |
| `SCHEMA_VERSION` | the name of the last-applied migration directory | this is your migration's own directory name once it ships |
| `APPLIED` | count of migrations applied this run | `0` is valid (nothing pending) — do not treat `APPLIED=0` as a failure signal |
| `PRE_COUNTS` / `POST_COUNTS` | total row counts per table, before/after, or the literal `skipped` when `APPLIED=0` | a migration that is SUPPOSED to change a count (backfill, delete) should expect `POST_COUNTS` to differ in exactly the way `MIGRATE_GATE_ALLOW_ROW_LOSS` permits — anything else is a real signal something went wrong |

## Both database URLs — why your migration needs to be aware of two services

The gate runs against **both** `ORGANIZATION_DATABASE_URL` and
`USER_DATABASE_URL` in the same `apply`/`status` invocation (default service
list `organization-service,user-service`, override
`MIGRATE_GATE_SERVICES`). A migration you author for one service's Prisma
schema is scoped to that service's own migrations directory and its own
database URL — Prisma itself enforces this (each service has its own
`schema.prisma` / `migrations/` tree) — but when you reason about "will this
roll succeed", remember **both** services' pending migrations run in the same
`migrate` one-shot container before any backend container starts
(`providers/aws/onbox/docker-compose.yml`'s `migrate` service + `depends_on`,
AXI-1950/1953). A migration that is fine on its own service can still make the
WHOLE roll fail-closed if the OTHER service's migration (or missing ledger)
fails first — `apply` processes services in order and stops at the first
failure (per-service), so check `migrate-gate status` for both services
before shipping, not just the one you touched.

## Checklist before shipping a migration

- [ ] Does this migration add a column with no default/nullable, drop a
      column/table, or rename anything, in a way the **currently-running**
      image does not expect? If yes, split into expand (this deploy) +
      contract (a later deploy).
- [ ] If this migration intentionally reduces a row count for some table,
      is `<schema>.<table>` going to be passed via `MIGRATE_GATE_ALLOW_ROW_LOSS`
      for this run, and is that documented in the deploy's own record?
- [ ] Does `migrate-gate status` show this service's ledger as healthy today
      (no pre-existing REFUSE/undetermined state) — if not, that is a
      baselining question to resolve FIRST, separately from this migration.
  - [ ] Is the migration idempotent if `apply` is interrupted partway and
      re-run (Prisma's own ledger makes a *finished* migration a no-op on
      retry; a migration hand-edited outside the normal `migrate dev` flow is
      not automatically covered by that).
