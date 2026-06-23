# Environments

> **Current reality (2026-06):** only **production** exists. There is a single live
> platform — that's it. The `dev` and `staging` rows below describe the *intended*
> model and the repo still scaffolds `environments/dev/` and `environments/staging/`
> tfvars, but **no dev or staging infrastructure is provisioned** (no dev/staging
> Terraform state-lock tables, no running instances). Consequently `terraform-cd` only
> targets production: infra pushes run a production **plan**, and applies happen via a
> manual `workflow_dispatch`. Do not assume dev/staging are deployable until they are
> actually stood up.

## Environment Model

| Environment | Purpose | Deployment | Access |
|------------|---------|------------|--------|
| local | Developer workstation | docker-compose | localhost |
| dev | Integration testing | *(not provisioned — scaffold only)* | Team |
| staging | Pre-production validation | *(not provisioned — scaffold only)* | Team + stakeholders |
| production | Live platform — the only real environment | Manual `workflow_dispatch` (plan on push) | End users |

## Configuration

Each environment has its own configuration in `environments/<env>/`:
- `terraform.tfvars` — Environment-specific variable values
- `backend.hcl` — Remote state backend configuration

### Key Differences by Environment

| Setting | Dev | Staging | Production |
|---------|-----|---------|------------|
| Postgres node | DB-DEV-S | DB-DEV-M | DB-GP-XS |
| Backend instances | 1 | 1-2 | 2-4 |
| Backend CPU (mVCPU) | 500 | 1000 | 2000 |
| Backend memory (MB) | 512 | 1024 | 2048 |
| Biocompute instances | 1 | 1-2 | 1-4 |
| Biocompute CPU (mVCPU) | 1000 | 2000 | 4000 |
| Biocompute memory (MB) | 1024 | 2048 | 4096 |

## Promotion Flow

```
local → dev → staging → production
         ↑        ↑          ↑
      auto     manual     manual
    (on merge) (same SHA) (same SHA)
```

1. Developer works locally using docker-compose
2. Merges to main trigger automatic build, test, and deploy to dev
3. Validated dev versions are promoted to staging via `promote.yml` workflow
4. Approved staging versions are promoted to production via the same workflow
5. The same image SHA is used across all environments — no rebuilds

## Working with Environments

### Initialize an environment
```bash
make init ENV=dev
```

### Plan changes
```bash
make plan ENV=staging
```

### Apply changes
```bash
make apply ENV=production
```

## Environment Isolation

- Each environment has its own:
  - Private network
  - Database instances (Postgres, MongoDB)
  - Object storage buckets
  - Secret Manager entries
  - Container registry namespace
  - Terraform state file
- No cross-environment resource sharing
- Production secrets and databases are never accessible from dev or staging
