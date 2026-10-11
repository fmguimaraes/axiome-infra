# Axiome Infrastructure

Terraform-first multi-environment infrastructure for the Axiome platform.

> **Current reality (AXI-1944/AXI-1977):** the only deployed, live environment is
> **production on AWS** (per `providers/aws/environments/production/terraform.tfvars`:
> EC2 compute + RDS Postgres + ElastiCache Redis + a self-hosted Mongo
> container + S3 + ECR — see [`providers/aws/README.md`](providers/aws/README.md))
> plus the **local docker-compose stack**. Scaleway, on-prem, and OVH provider
> code exists in this repo but is **not deployed anywhere** — see
> [Retired / not-yet-deployed providers](docs/providers.md#retired--not-yet-deployed-providers).
> For day-2 operator procedures against the real, live platform, start at
> [`docs/platform-lifecycle-operations.md`](docs/platform-lifecycle-operations.md),
> not the sections below that still describe Scaleway commands.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [AWS CLI](https://docs.aws.amazon.com/cli/) >= 2.22.3, with credentials for the Axiome AWS account (for production operations — see `docs/platform-lifecycle-operations.md` §0)
- (Only if working on the retired/not-yet-deployed Scaleway provider code) [Scaleway CLI](https://www.scaleway.com/en/cli/) and a Scaleway account with API credentials

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

> **Not yet usable end to end.** The verified-backup power-down, the migration
> gate on boot and the readiness check on power-up need a one-time box
> conversion that has not been done. Follow
> [First live power cycle — step by step](docs/first-live-power-cycle-checklist.md).

## Environments

| Environment | Purpose | Deploy Method |
|------------|---------|---------------|
| local | Development | docker-compose |
| dev | Integration | Auto on merge to main |
| staging | Pre-production | Manual promotion |
| production | Live | Gated one-click approval — `deploy-production` (app) / `terraform-cd` (infra); see [Deploy Procedure](docs/deploy-procedure.md) |

## Documentation

- **[Platform Lifecycle Operations](docs/platform-lifecycle-operations.md) — the current, accurate operator runbook: migration gate, deploy, locks, park/unpark, box conversion, what's not yet done** ← start here for any real AWS production operation
- **[First live power cycle — step by step](docs/first-live-power-cycle-checklist.md) — ordered checklist of what must be done before power-down/up and gated deploys work on the real box** ← do this first
- **[Deploy Procedure](docs/deploy-procedure.md) — operator quick reference: which path ships what, and where to approve a gated production deploy** ← start here to deploy
- [Bootstrapping](docs/bootstrapping.md) — full setup guide for local and AWS (dev/staging and the Scaleway/on-prem provider paths are **not deployed** — see the retired-provider note in each)
- [GitOps Lifecycle](docs/gitops-lifecycle.md) — GitHub Flow, CI/CD, promotion, audit trail
- [Architecture](docs/architecture.md) — topology, services, storage layout
- [Environments](docs/environments.md) — configuration, promotion flow; **only production is actually provisioned**
- [Deployment](docs/deployment.md) — CI/CD pipelines, rollback (the "dev-provider (Scaleway)" sections describe a **retired, inactive** flow — see the note at the top of that doc)
- [Secrets](docs/secrets.md) — management, rotation, local dev
- [Providers](docs/providers.md) — which provider is actually deployed, and which are retired/not-yet-deployed
- [Disaster Recovery](docs/disaster-recovery.md) — backups, restore, RTO/RPO (AWS-current; the Scaleway-specific steps are retired — see its top note)
- [Runbooks](docs/runbooks.md) — **retired** — the commands in this file target the inactive Scaleway path; use [Platform Lifecycle Operations](docs/platform-lifecycle-operations.md) instead
- [AWS Power Runbook](providers/aws/docs/power-runbook.md) — powering production compute/data on and off (cost control)
