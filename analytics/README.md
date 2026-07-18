# Behavior Tracking — Metabase funnel read layer (AXI-1048 / FR10 / AC4)

The **read** half of Behavior Tracking. Capture (front-end `analytics.track`, the
`POST /api/v1/events` ingest, and the generic `organization_svc.events` table) lands
elsewhere; this directory stands up **Metabase** over that table so the six target
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
| `funnels/00_metabase_readonly_role.sql` | Least-privilege `metabase_ro` role — `SELECT` on `organization_svc.events` only (NFR2 / no egress, no product-data exposure). |
| `funnels/01..06_*.sql` | The six funnels as Metabase-ready native SQL (distinct-actor, ordered-step, with entry/step conversion %). |

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

Create the read-only role once, **after** the backend has migrated the `events` table:

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

## 3. Build the six funnel questions

For each file in `funnels/01..06_*.sql`: Metabase → **+ New → SQL query** → select the
deployment DB → paste the SQL → **Visualization: Funnel** → Save. Group the six saved
questions into a **"Behavior Funnels"** dashboard.

| # | Funnel | Persona | Query |
|---|---|---|---|
| 1 | Interpretation lifecycle *(headline)* | analyst | `funnels/01_interpretation_lifecycle.sql` |
| 2 | Exploration mechanics | analyst | `funnels/02_exploration_mechanics.sql` |
| 3 | Provenance navigation | analyst | `funnels/03_provenance_navigation.sql` |
| 4 | Export | analyst | `funnels/04_export.sql` |
| 5 | Collaboration | analyst | `funnels/05_collaboration.sql` |
| 6 | Client engagement | client | `funnels/06_client_engagement.sql` |

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
- **Schema:** the read layer only touches `organization_svc.events` and no other
  product table — nothing here obstructs the funnels, satisfying FR10 / AC4.
