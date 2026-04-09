# CI/CD Pipeline

## Architecture

Trunk-based development with per-service independent CI and GitOps deployment.

```
axiome-back ──push──> CI: test → build → push ──> repository_dispatch ──┐
axiome-front ─push──> CI: test → build → push ──> repository_dispatch ──┤
axiome-bio-compute ─> CI: test → build → push ──> repository_dispatch ──┤
                                                                        │
axiome-infra <──────────────────────────────────────────────────────────┘
  ├── Receive event → update dev/images.tfvars → git commit+push
  └── Manual Deploy (promote.yml) → gate check → terraform apply → health check
```

### Key principles

- **Each service owns its CI.** Tests, Dockerfile, and build run in the service repo.
- **Infra owns deployment.** Terraform, promotion gates, and environment manifests live here.
- **Services are orthogonal.** Backend failing does not block frontend.
- **Cloud provider is polymorphic.** Switching from Scaleway to AWS requires only changing secrets — no code changes.

---

## Workflows

### Per-service CI (lives in each service repo)

File: `.github/workflows/ci.yml`

Each service defines its own **test** job, then calls the shared **reusable-build.yml** from this repo.

| Trigger | What runs |
|---------|-----------|
| PR to `main` | Test only |
| Push to `main` | Test → Build → Push to registry → Notify infra |

The reusable workflow handles registry login, docker build, docker push, and `repository_dispatch` to infra. Provider-specific logic (AWS ECR vs Scaleway) is resolved via the `REGISTRY_PROVIDER` secret.

### Receive — Update Dev Manifest (this repo)

File: `.github/workflows/ci.yml`

Triggered by `repository_dispatch` from any service CI. Updates the service's image tag in `environments/dev/images.tfvars` and commits.

### Deploy — Promote Service to Environment (this repo)

File: `.github/workflows/promote.yml`

Manual trigger (`workflow_dispatch`) with inputs:

| Input | Options | Description |
|-------|---------|-------------|
| `service` | backend, biocompute, frontend | Which service to deploy |
| `environment` | dev, staging, production | Target environment |
| `image_tag` | string | Git short SHA from the CI build |
| `run_migrations` | boolean | Run DB migrations (backend only) |

Pipeline: validate image → promotion gate → update manifest → optional migrations → terraform apply → health check.

**Sequential gate enforcement:** staging requires the tag to be in dev first; production requires it to be in staging first. Checked per-service independently.

---

## Provider Polymorphism

The build and deploy workflows support both **Scaleway** and **AWS** without code changes. The `REGISTRY_PROVIDER` secret controls which path executes.

### How it works

Provider-specific logic is isolated in two places:

1. **`reusable-build.yml`** — registry URL resolution and docker login
2. **`promote.yml`** — image validation and terraform credential export

Both use the same pattern:

```bash
case "$REGISTRY_PROVIDER" in
  aws)      # AWS ECR login + URL
  scaleway) # Scaleway registry login + URL
esac
```

Everything else (docker build, docker push, terraform, git, health checks) is provider-agnostic.

### Switching providers

Set these secrets at the GitHub organization or repository level:

**Always required:**

| Secret | Description |
|--------|-------------|
| `REGISTRY_PROVIDER` | `aws` or `scaleway` |
| `GH_PAT` | GitHub PAT with repo scope |

**For Scaleway (`REGISTRY_PROVIDER=scaleway`):**

| Secret | Description |
|--------|-------------|
| `SCW_REGISTRY_ENDPOINT` | Registry URL (e.g. `rg.fr-par.scw.cloud/axiome`) |
| `SCW_ACCESS_KEY` | API access key |
| `SCW_SECRET_KEY` | API secret key |

**For AWS (`REGISTRY_PROVIDER=aws`):**

| Secret | Description |
|--------|-------------|
| `AWS_ACCOUNT_ID` | AWS account ID (e.g. `123456789012`) |
| `AWS_REGION` | ECR region (e.g. `eu-west-1`) |
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |

**Per-environment secrets** (set in GitHub environment settings):

| Secret | Description |
|--------|-------------|
| `DATABASE_URL` | Postgres connection string |
| `BACKEND_URL` | Backend base URL for health checks |
| `BIOCOMPUTE_URL` | Biocompute base URL for health checks |
| `FRONTEND_URL` | Frontend URL for health checks |

---

## Files

### Workflows

| File | Purpose |
|------|---------|
| `.github/workflows/ci.yml` | Receives `repository_dispatch` from service CIs, updates dev manifest |
| `.github/workflows/reusable-build.yml` | Reusable workflow: build, push, notify. Called by all service CIs |
| `.github/workflows/promote.yml` | Manual deploy: gate → manifest → terraform → health check |
| `.github/workflows/secrets-check.yml` | Pre-commit secret scanning |

### Scripts

| Script | Usage | Description |
|--------|-------|-------------|
| `scripts/update-manifest.sh` | `<service> <env> <tag>` | Updates one service tag in `images.tfvars`, commits and pushes |
| `scripts/check-promotion-gate.sh` | `<service> <env> <tag>` | Verifies tag exists in previous environment |
| `scripts/deploy.sh` | `<env> [--plan-only]` | Reads `images.tfvars`, runs terraform init + plan + apply |

### Environment manifests

| File | Updated by |
|------|-----------|
| `environments/dev/images.tfvars` | CI receiver (automatic on push to main) |
| `environments/staging/images.tfvars` | Manual promote workflow |
| `environments/production/images.tfvars` | Manual promote workflow |

Format:

```hcl
backend_image_tag    = "abc12345"
biocompute_image_tag = "def67890"
frontend_image_tag   = "abc12345"
```

Each service tag is independent — they do not need to match.

---

## Reusable workflow access

For `secrets: inherit` to work across repos, the infra repo must allow workflow access from sibling repos:

**Settings → Actions → General → Access → "Accessible from repositories owned by the user"**

---

## Example: deploying a backend fix

```
1. Developer pushes fix to axiome-back main
2. axiome-back CI runs: npm test → docker build → push backend:a1b2c3d4 → notify infra
3. axiome-infra receives dispatch → updates dev/images.tfvars → commits
4. Operator runs promote.yml: service=backend, env=dev, tag=a1b2c3d4
5. Gate: passes (dev has no gate)
6. Terraform apply → container updated → health check passes
7. Operator runs promote.yml: service=backend, env=staging, tag=a1b2c3d4
8. Gate: checks dev has a1b2c3d4 → passes
9. Terraform apply → staging deployed
10. Operator runs promote.yml: service=backend, env=production, tag=a1b2c3d4
11. Gate: checks staging has a1b2c3d4 → passes
12. Terraform apply → production deployed
```

Frontend and biocompute remain untouched throughout this process.
