# Axiome Infrastructure

Terraform-first multi-environment infrastructure for the Axiome platform.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Scaleway CLI](https://www.scaleway.com/en/cli/) (for cloud operations)
- Scaleway account with API credentials

## Quick Start — Local Development

```bash
# 1. Clone repositories (axiome-infra, axiome-back, axiome-front, axiome-biocompute)
# should be siblings in the same parent directory

# 2. Configure environment
cp .env.example .env.local

# 3. Start all services
make local-up

# 4. Access the platform
# Frontend:  http://localhost:5173
# Backend:   http://localhost:3000
# MinIO:     http://localhost:9001 (admin console)

# 5. Stop
make local-down
```

To develop against a git worktree instead of the primary checkout (`backend`,
`frontend`, `biocompute`), copy `docker-compose.override.yml.example` to
`docker-compose.override.yml` (gitignored, machine-local) and point it at the
worktree path — `make local-*` merges it in automatically. Recreate the
affected containers to pick up a new mount (`make local-down && make
local-up`; `make local-restart` alone does not re-read `volumes:`).

## Cloud Environments

```bash
# Initialize (one-time per environment)
make init ENV=dev

# Preview changes
make plan ENV=dev

# Apply changes
make apply ENV=dev
```

## Powering Production On/Off (cost control)

Production compute (EC2) and the data tier (RDS + ElastiCache Redis) are parked
when idle to save cost, so finding production **stopped is normal** — bring it back
with the AWS provider's power controls, run from `providers/aws/`:

```bash
cd providers/aws

# Bring EVERYTHING up (data tier + compute), validated:
make turn-on ENV=production          # 1) dry-run preflight — read-only, makes NO changes
make turn-on ENV=production YES=1    # 2) execute: data tier up + Redis restore, then compute (health-gated)

make status  ENV=production          # show EC2 / RDS / Redis state
make down    ENV=production          # park it again: stop app, stop RDS, snapshot + delete Redis
```

`turn-on` is the safe path (`scripts/power-up-all.sh`): its preflight **aborts if the
Redis final snapshot is missing** — that snapshot is the only copy of Redis data (no
automatic backups) — then it restores the data tier and waits healthy before starting
compute, blocking on `/api/v1/health/live`. Finer-grained controls exist too:
compute-only `make power-up` / `power-down` (safe, daily, never touches storage) and
data-tier-only `make data-up` / `data-down` (long idle only; destructive for Redis).

> **‼ Keep `terraform-cd` gated for the entire down→up window.** Redis is recreated
> outside Terraform's view, so an apply mid-window fights the restore.

Full detail, timings, and the safety rationale: [AWS power runbook](providers/aws/docs/power-runbook.md).

## Environments

| Environment | Purpose | Deploy Method |
|------------|---------|---------------|
| local | Development | docker-compose |
| dev | Integration | Auto on merge to main |
| staging | Pre-production | Manual promotion |
| production | Live | Gated one-click approval — `deploy-production` (app) / `terraform-cd` (infra); see [Deploy Procedure](docs/deploy-procedure.md) |

## Documentation

- **[Deploy Procedure](docs/deploy-procedure.md) — operator quick reference: which path ships what, and where to approve a gated production deploy** ← start here to deploy
- [Bootstrapping](docs/bootstrapping.md) — full setup guide for local, Scaleway, and AWS
- [GitOps Lifecycle](docs/gitops-lifecycle.md) — GitHub Flow, CI/CD, promotion, audit trail
- [Architecture](docs/architecture.md) — topology, services, storage layout
- [Environments](docs/environments.md) — configuration, promotion flow
- [Deployment](docs/deployment.md) — CI/CD pipelines, rollback
- [Secrets](docs/secrets.md) — management, rotation, local dev
- [Providers](docs/providers.md) — Scaleway/AWS portability
- [Disaster Recovery](docs/disaster-recovery.md) — backups, restore, RTO/RPO
- [Runbooks](docs/runbooks.md) — operational procedures
- [AWS Power Runbook](providers/aws/docs/power-runbook.md) — powering production compute/data on and off (cost control)
