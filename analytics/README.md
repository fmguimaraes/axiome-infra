# Behavior Tracking — Metabase funnel read layer (AXI-1048 / FR10 / AC4)

The **read** half of Behavior Tracking. Capture (front-end `analytics.track`, the
`POST /api/v1/events` ingest, and the generic `organization_svc.analytics_events` table) lands
elsewhere; this directory stands up **Metabase** over that table so the seven target
funnels are queryable — with **no third-party egress**.

- Product approach: `axiome-docs/05 - product/Behavior-Tracking-Product-Approach.md`
- Architecture (events table §5, read layer §6): `axiome-docs/04 - architecture/Behavior-Tracking-Architecture.md`

> **Design principle:** capture is uniform across cloud and on-prem; only *access*
> differs. Metabase is one container next to the deployment DB. Cloud reads today;
> on-prem reads once a deferred access path exists — **no code change**, the events
> are already sitting there in a known shape.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.analytics.yml` | Metabase container overlay + one-shot init that creates Metabase's own app DB on the shared Postgres. |
| `funnels/00_metabase_readonly_role.sql` | Least-privilege `metabase_ro` role — `SELECT` on `organization_svc.analytics_events` only (NFR2 / no egress, no product-data exposure). |
| `funnels/01..06_*.sql` | The six product funnels as Metabase-ready native SQL (distinct-actor, ordered-step, with entry/step conversion %). |
| `funnels/07_admin_governance.sql` | The admin-governance funnel (AXI-2507) — a flat per-event volume breakdown, not a step funnel (see below). |

## 1. Start Metabase

Run as an overlay on the base stack (shares the `axiome-local` network and Postgres):

```bash
docker compose -f docker-compose.yml -f analytics/docker-compose.analytics.yml up -d
```

Metabase comes up at http://localhost:3001 (override with `METABASE_PORT`). First boot
takes ~1–2 min while it migrates its own app DB. Complete the initial admin setup in
the browser.

> **Cloud/on-prem:** set `METABASE_ENCRYPTION_KEY` (encrypts stored DB credentials at
> rest) and `METABASE_PORT` from the secrets store — never ship the dev defaults.

## 2. Add the deployment DB as a read-only data source

Create the read-only role once, **after** the backend has migrated the
`organization_svc.analytics_events` table:

```bash
psql "$DATABASE_URL" -f analytics/funnels/00_metabase_readonly_role.sql
# set a real password for metabase_ro from the secrets store first (see the file header)
```

Then in Metabase → **Admin → Databases → Add database → PostgreSQL**:

| Field | Value |
|---|---|
| Host | `postgres` (in-compose) / the deployment DB host |
| Port | `5432` |
| Database name | `axiome` (the deployment DB) |
| Username | `metabase_ro` |
| Password | (from secrets store) |

For a quick local look you can instead point Metabase at the existing `axiome`
Postgres user — but production/on-prem should use `metabase_ro`.

### Connecting to the production database

`make analytics-connect-prod` opens a **read-only** `psql` shell to the production
database as `metabase_ro` — the prod analogue of the local `docker compose exec
postgres psql`.

The prod RDS is **private** (not internet-reachable) and the EC2 box has no SSH,
so the target (`analytics/connect-prod-db.sh`) tunnels to RDS over **AWS SSM** —
the same access path as `scripts/ssm-exec.sh` — and runs `psql` through the
forwarded local port. It uses only the read-only role, never master/app creds.

Prerequisites (each is checked with a clear message):

| Need | Why |
|---|---|
| `aws` CLI **+ the Session Manager plugin** (`session-manager-plugin`) | opens the SSM port-forward to the private RDS |
| `psql`, `terraform` on `PATH` | the client; resolving the RDS host from state |
| `providers/aws` initialized to the **production** state | `terraform output rds_endpoint` must resolve |
| `metabase_ro` provisioned **on prod** | run `funnels/00_metabase_readonly_role.sql` against production once, with a real password |
| `METABASE_RO_PROD_PASSWORD` set | that real read-only password (see below) |

The prod password is read from `METABASE_RO_PROD_PASSWORD` (falling back to
`METABASE_RO_PASSWORD`), supplied via the environment or the **repo-root
`.env.local`** — the single gitignored file the infra `.env.example` tells you to
create (`cp .env.example .env.local`).

Keep the prod password in its **own** variable, separate from the local one, so
the two never collide — the local `analytics-test` connects to the local DB (role
password `change_me_readonly`), while the prod connect needs the real secret:

```bash
# axiome-infra/.env.local  (never committed — the .env.example copy target)
METABASE_RO_PASSWORD=change_me_readonly                      # LOCAL analytics-test
METABASE_RO_PROD_PASSWORD=<real read-only password from the secrets store>  # analytics-connect-prod
```

Locally the file is optional — `analytics-test` already defaults to `metabase_ro`
/ `change_me_readonly` (what `make analytics-role` creates). The
`change_me_readonly` placeholder must never reach production.

## 3. Build the funnel questions

For each file in `funnels/01..06_*.sql`: Metabase → **+ New → SQL query** → select the
deployment DB → paste the SQL → **Visualization: Funnel** → Save. For
`funnels/07_admin_governance.sql` use **Visualization: Bar** instead (it is a flat
per-event breakdown, not a step funnel — see §4 below). Group all seven saved
questions into a **"Behavior Funnels"** dashboard.

| # | Funnel | Persona | Query | Visualization |
|---|---|---|---|---|
| 1 | Interpretation lifecycle *(headline)* | analyst | `funnels/01_interpretation_lifecycle.sql` | Funnel |
| 2 | Exploration mechanics | analyst | `funnels/02_exploration_mechanics.sql` | Funnel |
| 3 | Provenance navigation | analyst | `funnels/03_provenance_navigation.sql` | Funnel |
| 4 | Export | analyst | `funnels/04_export.sql` | Funnel |
| 5 | Collaboration | analyst | `funnels/05_collaboration.sql` | Funnel |
| 6 | Client engagement | client | `funnels/06_client_engagement.sql` | Funnel |
| 7 | Admin governance (AXI-2507) | admin | `funnels/07_admin_governance.sql` | Bar |

Each query optionally accepts `{{start_date}}` / `{{end_date}}` **Date** variables to
window the funnel; leave them empty for all-time.

## How the funnel queries work

- **Distinct actors, ordered steps.** Identity keys on the **stable `anonymous_id`**
  (falling back to `user_id`). Per FR6 the pre-auth `anonymous_id` is *preserved, not
  rotated* on login — every post-login event carries the same `anonymous_id`, so a
  client counted at `client_connected` before login attributes to the same person
  afterward. An actor counts at step *k* only if they reached every prior step in
  `ts_server` order — `ts_server` is authoritative (the client clock can skew on-prem).
- **Persona split.** Shared events (`chart_opened`, `export_created`,
  `export_downloaded`, `comment_added`) are separated purely by `actor_role`, which is
  what keeps funnel 6 (client) distinct from funnels 2/4/5 (analyst).
- **Output columns:** `step_name`, `users`, `pct_of_entry` (vs step 1), and
  `pct_of_prev_step` (step-to-step drop-off).
- **Schema:** the read layer only touches `organization_svc.analytics_events` and no other
  product table — nothing here obstructs the funnels, satisfying FR10 / AC4.

## 4. Funnel 7 is deliberately flat, not a step funnel

The admin-governance events (role CRUD/assignment, project access/visibility,
org rule access, KG permission CRUD, org/workspace membership add/remove) are 15
independent RBAC/permission-scope operations with no natural order and no shared
entry step — an admin might only ever do one of them. Chaining them like funnels
1-6 would force an arbitrary sequence onto unrelated actions, so
`07_admin_governance.sql` instead groups by `event` and reports volume
(`events`, `distinct_admins`) per action, identity keyed on `user_id` (admin
actions are always authenticated — there is no pre-auth admin persona, so no
`anonymous_id` fallback is needed).
