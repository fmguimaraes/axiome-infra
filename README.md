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

## Cloud Environments

```bash
# Initialize (one-time per environment)
make init ENV=dev

# Preview changes
make plan ENV=dev

# Apply changes
make apply ENV=dev
```

## Environments

| Environment | Purpose | Deploy Method |
|------------|---------|---------------|
| local | Development | docker-compose |
| dev | Integration | Auto on merge to main |
| staging | Pre-production | Manual promotion |
| production | Live | Manual promotion |

## Documentation

- [Bootstrapping](docs/bootstrapping.md) — full setup guide for local, Scaleway, and AWS
- [GitOps Lifecycle](docs/gitops-lifecycle.md) — GitHub Flow, CI/CD, promotion, audit trail
- [Architecture](docs/architecture.md) — topology, services, storage layout
- [Environments](docs/environments.md) — configuration, promotion flow
- [Deployment](docs/deployment.md) — CI/CD pipelines, rollback
- [Secrets](docs/secrets.md) — management, rotation, local dev
- [Providers](docs/providers.md) — Scaleway/AWS portability
- [Disaster Recovery](docs/disaster-recovery.md) — backups, restore, RTO/RPO
- [Runbooks](docs/runbooks.md) — operational procedures
