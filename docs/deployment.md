# Deployment

## CI/CD Pipeline

### Automatic Deployment to Dev (ci.yml)

Triggered on merge to `main`:

1. **Test** — Run backend (npm test), biocompute (pytest), frontend (npm test + tsc) in parallel
2. **Build** — Create Docker images tagged with git SHA
3. **Push** — Push images to Scaleway Container Registry
4. **Deploy** — Update container services with new image, deploy frontend to object storage
5. **Health Check** — Verify `/health` endpoints return 200

### Manual Promotion (promote.yml)

Triggered via GitHub Actions UI:

1. Select the **image tag** (git SHA from a successful dev deploy)
2. Select the **target environment** (staging or production)
3. Optionally enable **database migrations**
4. Pipeline validates image exists, runs migrations if requested, deploys, health checks

### Infrastructure Changes (terraform.yml)

- On PR with `.tf` or `.tfvars` changes: automatic plan
- Manual trigger: plan or apply to any environment

## Production deploy (AWS — authoritative) — FR9/AC8, FR14/AC19

> **A green CI `promote-to-production` run is NOT a production deploy.** This is
> the single most-confused point in shipping any service; read this before you
> ship. (The `promote.yml`/Scaleway sections above describe the **dev** flow and
> are not the production path.)
>
> This section originally documented the backend-only path (AXI-1347/FR9); it now
> covers **all three services** — backend, frontend, and bio-compute — at parity
> (AXI-1350/FR14/AC19), reusing the exact same script and workflow, unchanged,
> with `--service`/`SERVICE` selecting which one to move.

Production runs on **AWS**, and it **pins the `:stable` image tag**
(`use_ssm_image_tags = false`). Two mechanisms are routinely confused; they are
different things:

| Mechanism | What it actually does | What it does **not** do |
|---|---|---|
| **CI `promote-to-production` job** (runs on push to `axiome-back` `main`) | Bumps the image tag in `providers/aws/environments/production/images.tfvars` — a **manifest record**, committed by `ci-bot` (e.g. `b9355cc`). | It does **not** change what production runs. Because prod pins `:stable`, a manifest bump alone is **inert** on the running system. It is **never** a deploy. |
| **The one-command deploy — `make deploy-prod`** (the **single authoritative path**) | Advances the chosen image to `:stable` in ECR (`axiome/backend`, `axiome/frontend`, or `axiome/biocompute` — per `--service`), then `docker compose pull` + `prisma migrate deploy` + `up -d` on the production EC2 host over SSM, health-checks, and records the action. **This is the only thing that changes what production actually runs, for any of the three services.** | — |

So: a green `promote-to-production` means *"the manifest was recorded"*, **not**
*"production was deployed"*. During the ~5-week CI outage this gap is exactly why
production sat frozen on a June image while promote jobs looked green.

### The real production deploy — one command (AXI-1349/FR12; AXI-1350/FR14/AC19)

There is now **one** command that performs the authoritative deploy end-to-end,
for **any of the three services** — `deploy-prod.sh` is already service-generic
(`--service backend|frontend|biocompute`, default `backend`) and needed **no
changes** to gain frontend/bio-compute coverage. Do not do the ECR retag / SSM
roll by hand — run this:

```bash
cd axiome-infra
make deploy-prod ENV=production TAG=<sha>                                  # backend (default)
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend                 # frontend
make deploy-prod ENV=production TAG=<sha> SERVICE=biocompute               # bio-compute
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend DRY_RUN=1       # print the plan, mutate nothing
# equivalently: scripts/deploy-prod.sh --tag <sha> --service frontend|biocompute [--dry-run]
```

**Rewritten end-to-end by AXI-1954 (epic AXI-1944) — this section describes the
CURRENT `scripts/deploy-prod.sh`; the full operator runbook (every refusal,
the migration gate, locks, baselining, restore behaviour) lives in
[`platform-lifecycle-operations.md` §3](../docs/platform-lifecycle-operations.md#3-deploy-scriptsdeploy-prodsh--make-deploy-prod).**
`make deploy-prod` does, in order:

1. **Locks** — refuses if the `data-tier` lock is held/unknown (a park may be
   in progress); acquires the `deploy` lock (auto-released on exit).
2. **Preflight** — verifies `axiome/<service>:<sha>` exists in ECR and
   resolves its digest; for backend, also reads `migrate-gate status` on the
   box (read-only) to learn pending migrations and the box's current tag.
   Fails closed if the source image is missing, the box is unreachable, or
   the box predates the AXI-1950 asset-sync conversion (names the one-time
   conversion command).
3. **Pre-deploy RDS snapshot** — backend, pending migrations, production
   only — taken and verified `available` BEFORE anything is migrated.
4. **Roll the box** — [`scripts/roll-service.sh`](../scripts/roll-service.sh)
   over [`scripts/ssm-exec.sh -e production`](../scripts/ssm-exec.sh):
   `docker compose pull` then `up -d`, which runs the baked-in migration
   gate (`migrate-gate apply`, `axiome-back docker/migrate-gate/`) against the
   NEW image BEFORE swapping any backend container — the OLD containers keep
   serving until the gate passes. **No baselining happens automatically** —
   a ledger-less service REFUSES and the deploy restores the previous tag;
   baselining is a separate, explicit operator act (see the runbook §2).
5. **Readiness poll** — backend polls the JSON `/api/v1/health/ready`
   endpoint (`services[].reason` on a 503); frontend/bio-compute poll their
   own 2xx path. On failure, the previous tag is restored and confirmed; the
   schema is NOT reverted (the gate is forward-only) — see the runbook for
   the exact "schema may be ahead" wording this prints.
6. **Advance `:stable`** — the LAST mutation, only on readiness PASS, and only
   if the tag's digest has not moved since preflight.
7. **Read-only baseline verification** (`seed-environment.sh --check`,
   backend only) — warning only, never rolls back.
8. **Record** — writes `reports/<ts>-production-deploy-<service>.md` + a row in
   `reports/deploy-operations.md` (SHA + digest + timestamp + actor).

Prereqs: AWS creds; `aws` CLI (+ Session Manager plugin for interactive sessions
— `deploy-prod.sh` itself uses `ssm send-command`, no plugin needed); production
powered on (`cd providers/aws && make turn-on ENV=production YES=1`). Never pass a
secret as a literal to SSM — the on-box roll fetches everything from
`/opt/axiome/.env`.

**Choosing the image:** a green `main` build (in `axiome-back`, `axiome-front`, or
`axiome-bio-compute` per the service being deployed) that passed CI's scan/test
gates. Its tag is the 8-char commit SHA.

**Rollback:** `:stable` is only ever advanced **after** the readiness poll
passes, so there is never a `:stable`-level rollback to perform. If readiness
fails first, `deploy-prod.sh` itself restores automatically: it re-rolls the
box to the **prior tag** (`restore_previous_tag`, via `roll-service.sh`) —
`:stable` is left untouched the whole time, since it was never advanced. This
restore only reverts the running image, never the schema (the migration gate
is forward-only, see
[`migration-authoring-guide.md`](migration-authoring-guide.md)) — a migration
that already applied stays applied, which is the "schema may now be ahead of
the restored image" caveat the script prints
(`report_rollback_caveat`/`Migrations may have PARTIALLY applied before this
failure`/`The migration gate completed successfully before this failure`, see
[`platform-lifecycle-operations.md §3`](platform-lifecycle-operations.md#3-deploy-scriptsdeploy-prodsh--make-deploy-prod)).
To roll back **manually** later (e.g. after `:stable` already advanced on a
deploy that looked healthy but regressed), re-run `make deploy-prod` with the
previous known-good `<sha>` (and the same `SERVICE`); for schema issues
(backend only), restore the pre-deploy RDS snapshot (see the catch-up plan).

### Gated one-click CD (AXI-1349, FR13; AXI-1350, FR14/AC19)

The same deploy is available as a **gated continuous-deployment** GitHub Actions
workflow, [`.github/workflows/deploy-production.yml`](../.github/workflows/deploy-production.yml):

- **Triggers:** the `image-published` `repository_dispatch` a green `main` build
  emits — from **any of the three repos** (`axiome-back`, `axiome-front`,
  `axiome-bio-compute`, each via their own `reusable-build.yml` call), or a
  manual `workflow_dispatch` (choose the service + tag).
- **The gate:** the deploy job declares `environment: production`. Configure that
  as a **protected** GitHub environment with required reviewers, so a green `main`
  becomes a deployed prod only after **one-click human approval** — never
  automatically. This applies identically to all three services; there is no
  backend-only carve-out.
- It runs the exact same `scripts/deploy-prod.sh`, so it inherits the idempotent +
  fail-closed guarantees (NFR6). The workflow overrides `HEALTH_URL` per service
  before invoking the script (bio-compute → `/api/v1/version`, frontend → `/`,
  backend → the script's own default) — see [Health Checks](#health-checks).

> **Required human setup** (one-time): create the protected `production` environment
> with reviewers; add `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets; power
> prod on before approving a run; make sure `axiome-front` and `axiome-bio-compute`
> each carry the `GH_PAT` secret their `reusable-build.yml` call needs to fire the
> `image-published` dispatch (same mechanism the backend already relies on). See
> the note at the foot of the workflow file.

> **First-time catch-up is special.** Production's DB is months behind and its
> `organization_svc` has **no migration ledger at all**, so the naive baseline is
> unsafe — do not run a routine deploy for it. Follow the one-time reviewed plan:
> [`AXI-1347-production-catch-up-plan.md`](AXI-1347-production-catch-up-plan.md).

## Deployment Steps

> **Production deploys use `make deploy-prod` (or the gated CD workflow) — see
> [The real production deploy — one command](#the-real-production-deploy--one-command-axi-1349fr12-axi-1350fr14ac19)
> above.** The steps below describe the **dev-provider (Scaleway) promote flow**
> and staging validation; they are **not** the production path. The old
> "Go to Actions → Promote" route only bumps the manifest for AWS production and
> is **inert** on the running system (prod pins `:stable`).

### Deploy a new version (dev / staging — legacy Scaleway flow)

1. Merge code to `main`
2. CI automatically deploys to dev
3. Verify in dev environment
4. Go to Actions → "Promote" → Run workflow
5. Enter the image tag and select staging
6. For **production**, use `make deploy-prod ENV=production TAG=<sha>` (above)

### Rollback

**Production:** re-run `make deploy-prod ENV=production TAG=<previous-good-sha>` for a
manual rollback (e.g. after `:stable` already advanced on a deploy that passed
health checks but regressed later). A **failed** deploy restores itself
automatically mid-run (re-roll to the prior tag, see
[Rollback](#the-real-production-deploy--one-command-axi-1349fr12-axi-1350fr14ac19)
above) — `:stable` is never advanced until after readiness passes, so there is
no `:stable` state to roll back in that case. For dev/staging on the
Scaleway provider:

1. Go to Actions → "Promote" → Run workflow
2. Enter the **previous known-good image tag**
3. Select the target environment
4. The previous version is redeployed

### Database Migrations

- Migrations run as part of the promotion pipeline when enabled
- If a migration fails, the deployment is aborted
- Always test migrations in dev and staging before production
- Migration scripts live in the axiome-back repository

## Health Checks

The **dev-provider (Scaleway) CI health check** (`ci.yml`, above) polls `/health`
for backend and bio-compute — that path is unrelated to and does not change the
production `deploy-prod.sh`/`deploy-production.yml` paths below.

| Service | Endpoint (dev CI, Scaleway) | Expected | Timeout |
|---------|-----------------------------|----------|---------|
| Backend | GET /health | 200 OK | 5min (30 retries x 10s) |
| Biocompute | GET /health | 200 OK | 5min (30 retries x 10s) |

**Production deploy health check** (`deploy-prod.sh` / `deploy-production.yml`,
AWS — AXI-1349/AXI-1350): each service has its own path against the production
FQDN (`https://platform.axiomebio.com`), polled up to `HEALTH_RETRIES` (default
30) times at 10s intervals (~5min):

| Service | Endpoint | Expected | Notes |
|---------|----------|----------|-------|
| Backend | GET `/api/v1/health/ready` | 200 OK | **Disagreement fixed (AXI-1955): this doc previously said `/api/v1/health`.** `deploy-prod.sh`'s own `default_health_path()` uses the real readiness check (`/api/v1/health/ready`) for the backend specifically — a 503 is treated as "not ready yet" and retried, not a hard failure, until `HEALTH_RETRIES` is exhausted. No override needed. |
| Frontend | GET `/` | 200 OK | Static SPA has no dedicated health endpoint; a 2xx on the root document is the signal. `HEALTH_URL` override in `deploy-production.yml`. `default_health_path()`'s non-backend fallback is the plain `/api/v1/health` path, but the frontend overrides it to `/` anyway. |
| Bio-compute | GET `/api/v1/version` | 200 OK | `HEALTH_URL` override in `deploy-production.yml`. |

## Required GitHub Secrets

Configure per environment in GitHub repository settings:

| Secret | Description |
|--------|-------------|
| SCW_ACCESS_KEY | Scaleway API access key |
| SCW_SECRET_KEY | Scaleway API secret key |
| SCW_REGISTRY_ENDPOINT | Container registry endpoint |
| SCW_BACKEND_CONTAINER_ID | Backend container resource ID |
| SCW_BIOCOMPUTE_CONTAINER_ID | Biocompute container resource ID |
| BACKEND_URL | Backend public URL |
| BIOCOMPUTE_URL | Biocompute URL (for health checks) |
| DATABASE_URL | Database connection string (for migrations) |
| GH_PAT | GitHub personal access token (for cross-repo access) |
