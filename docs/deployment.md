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

`make deploy-prod` (→ [`scripts/deploy-prod.sh`](../scripts/deploy-prod.sh)) does, in order:

1. **Preflight** — verifies `axiome/<service>:<sha>` exists in ECR (`axiome/backend`,
   `axiome/frontend`, or `axiome/biocompute`), resolves its digest, and captures
   the current `:stable` digest for rollback. Fails closed (nothing deployed) if
   the source image is missing.
2. **Advance `:stable`** — a server-side manifest retag (no docker pull) so prod
   pulls the chosen image. Idempotent (a no-op if `:stable` already points there).
3. **Roll the box** — pipes [`scripts/roll-service.sh`](../scripts/roll-service.sh)
   over [`scripts/ssm-exec.sh -e production`](../scripts/ssm-exec.sh): `docker
   compose pull` → `prisma migrate deploy` (baselining first if `_prisma_migrations`
   is absent — a no-op for frontend/bio-compute, which have no Prisma schema of
   their own) → `up -d`. **Fails closed** — a failed migration never swaps the
   image; the old containers keep serving.
4. **Health-check** — polls the service's health URL until 2xx (see
   [Health Checks](#health-checks) below for the per-service path — the script's
   own default is backend-shaped `/api/v1/health`; the gated CD workflow overrides
   `HEALTH_URL` for frontend/bio-compute, see below). On an unhealthy result it
   **auto-rolls `:stable` back** to the prior image (so the prior image keeps
   serving) and aborts non-zero.
5. **Record** — writes `reports/<ts>-production-deploy-<service>.md` + a row in
   `reports/deploy-operations.md` (SHA + digest + timestamp + actor).

Prereqs: AWS creds; `aws` CLI (+ Session Manager plugin for interactive sessions
— `deploy-prod.sh` itself uses `ssm send-command`, no plugin needed); production
powered on (`cd providers/aws && make turn-on ENV=production YES=1`). Never pass a
secret as a literal to SSM — the on-box roll fetches everything from
`/opt/axiome/.env`.

**Choosing the image:** a green `main` build (in `axiome-back`, `axiome-front`, or
`axiome-bio-compute` per the service being deployed) that passed CI's scan/test
gates. Its tag is the 8-char commit SHA.

**Rollback:** the health-check step auto-rolls `:stable` back to the prior image
on failure. To roll back manually later, re-run `make deploy-prod` with the
previous known-good `<sha>` (and the same `SERVICE`); for schema (backend only),
restore the pre-deploy RDS snapshot (see the catch-up plan).

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

**Production:** re-run `make deploy-prod ENV=production TAG=<previous-good-sha>` (the
health-check step also auto-rolls back on a failed deploy). For dev/staging on the
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
| Backend | GET `/api/v1/health` | 200 OK | `deploy-prod.sh`'s own default (no override needed) |
| Frontend | GET `/` | 200 OK | Static SPA has no dedicated health endpoint; a 2xx on the root document is the signal. `HEALTH_URL` override in `deploy-production.yml`. |
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
