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

## Production backend deploy (AWS — authoritative) — FR9/AC8

> **A green CI `promote-to-production` run is NOT a production deploy.** This is
> the single most-confused point in shipping the backend; read this before you
> ship. (The `promote.yml`/Scaleway sections above describe the **dev** flow and
> are not the production path.)

Production runs on **AWS**, and it **pins the `:stable` image tag**
(`use_ssm_image_tags = false`). Two mechanisms are routinely confused; they are
different things:

| Mechanism | What it actually does | What it does **not** do |
|---|---|---|
| **CI `promote-to-production` job** (runs on push to `axiome-back` `main`) | Bumps the image tag in `providers/aws/environments/production/images.tfvars` — a **manifest record**, committed by `ci-bot` (e.g. `b9355cc`). | It does **not** change what production runs. Because prod pins `:stable`, a manifest bump alone is **inert** on the running system. |
| **`:stable` retag** (manual, **authoritative**) | Retags the chosen backend image to `:stable` in ECR (`axiome/backend`), then `docker compose pull` + `up -d` on the production EC2 host over SSM, and runs migrations. **This is the only thing that changes the running production backend.** | — |

So: a green `promote-to-production` means *"the manifest was recorded"*, **not**
*"production was deployed"*. During the ~5-week CI outage this gap is exactly why
production sat frozen on a June image while promote jobs looked green.

### The real production backend deploy

Prereqs: AWS creds; `aws` CLI + Session Manager plugin; production powered on
(`cd providers/aws && make turn-on ENV=production YES=1`). Never pass a secret as
a literal to SSM — fetch it on the box.

1. **Choose the image**: a green `axiome-back` `main` build that passed the now-
   **blocking** `scan-image` gate (AXI-1345). Its tag is the 8-char commit SHA.
2. **Advance `:stable`** in ECR: retag that SHA image to `:stable` in the
   `axiome/backend` repo (this is what prod pulls).
3. **Swap + migrate on the box** via `scripts/ssm-exec.sh -e production` running
   `scripts/roll-service.sh` (or `docker compose -f /opt/axiome/docker-compose.yml
   pull backend && … up -d`): `roll-service.sh` pulls `:stable`, runs
   `prisma migrate deploy` (baselining first if `_prisma_migrations` is absent),
   and **fails closed** (old containers keep serving) if migrate fails.
4. **Verify**: `/api/v1/health` is 200 and `migrate diff` shows zero drift.
5. **Rollback**: retag `:stable` back to the previous known-good SHA and re-pull;
   for schema, restore the pre-deploy RDS snapshot (see the catch-up plan).

> **First-time catch-up is special.** Production's DB is months behind and its
> `organization_svc` has **no migration ledger at all**, so the naive baseline is
> unsafe — do not run a routine deploy for it. Follow the one-time reviewed plan:
> [`AXI-1347-production-catch-up-plan.md`](AXI-1347-production-catch-up-plan.md).

## Deployment Steps

### Deploy a new version

1. Merge code to `main`
2. CI automatically deploys to dev
3. Verify in dev environment
4. Go to Actions → "Promote" → Run workflow
5. Enter the image tag and select staging
6. After staging validation, promote to production

### Rollback

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

| Service | Endpoint | Expected | Timeout |
|---------|----------|----------|---------|
| Backend | GET /health | 200 OK | 5min (30 retries x 10s) |
| Biocompute | GET /health | 200 OK | 5min (30 retries x 10s) |

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
