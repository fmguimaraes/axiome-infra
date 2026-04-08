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
