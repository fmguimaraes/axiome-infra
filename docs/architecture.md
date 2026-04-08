# Architecture

## Infrastructure Topology

```
                    ┌─────────────────────────────────────────┐
                    │           Public Internet                │
                    └──────┬──────────────┬───────────────────┘
                           │              │
                    ┌──────▼──────┐ ┌─────▼──────┐
                    │  Frontend   │ │  Backend   │
                    │  (Static/   │ │  (NestJS)  │
                    │  Container) │ │  Port 3000 │
                    └─────────────┘ └──────┬─────┘
                                           │ Private Network
                    ┌──────────────────────┼──────────────────┐
                    │                      │                   │
                    │               ┌──────▼──────┐           │
                    │               │  Biocompute  │           │
                    │               │  (Python)    │           │
                    │               │  Port 8000   │           │
                    │               └──────────────┘           │
                    │                                          │
                    │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │
                    │  │ Postgres │ │ MongoDB  │ │ Object  │ │
                    │  │   15     │ │    7     │ │ Storage │ │
                    │  └──────────┘ └──────────┘ └─────────┘ │
                    │           Private Network                │
                    └──────────────────────────────────────────┘
```

## Services

| Service | Technology | Port | Privacy | Purpose |
|---------|-----------|------|---------|---------|
| Backend | NestJS (Node.js 20) | 3000 | Public | API orchestration, business logic |
| Biocompute | Python 3.12 (FastAPI) | 8000 | Private | Scientific computation, analysis |
| Frontend | React (Vite) | 80/5173 | Public | User interface |
| Postgres | PostgreSQL 15 | 5432 | Private | Relational persistence (system of record) |
| MongoDB | MongoDB 7 | 27017 | Private | Document-oriented storage |
| Object Storage | S3-compatible | 9000 | Private | Artifacts, uploads, exports |

## Network Design

- Each environment (dev, staging, production) has its own isolated private network
- Backend and biocompute communicate via private network only
- Only backend API and frontend are publicly accessible
- Databases and object storage are accessible only within the private network

## Storage Layout

Artifact path convention:
```
<bucket>/<workspace-id>/<project-id>/<dataset-version>/<artifact-type>/<filename>
```

Buckets per environment:
- `axiome-<env>-artifacts` — Generated outputs (plots, matrices, exports). Versioning enabled.
- `axiome-<env>-uploads` — User uploads, raw data
- `axiome-<env>-system` — Migrations, backups, internal files
- `axiome-<env>-frontend` — Static frontend assets (when using static hosting)

## Module Structure

```
axiome-infra/
├── main.tf                    # Root module, wires everything together
├── variables.tf               # Input variables
├── outputs.tf                 # Output values
├── versions.tf                # Provider version constraints
├── backend.tf                 # Remote state configuration
├── Makefile                   # Operational shortcuts
├── docker-compose.yml         # Local development stack
├── .env.example               # Environment variable template
├── environments/
│   ├── dev/
│   │   ├── terraform.tfvars   # Dev-specific configuration
│   │   └── backend.hcl        # Dev state backend config
│   ├── staging/
│   └── production/
├── modules/
│   ├── network/               # Private network / VPC
│   ├── compute/               # Container services (backend, biocompute, frontend)
│   ├── database/              # Postgres, MongoDB
│   ├── storage/               # Object storage buckets
│   ├── registry/              # Container registry
│   └── secrets/               # Secret management
├── providers/
│   ├── aws/                   # AWS-specific module implementations (future)
│   └── scaleway/              # Scaleway is the primary provider
├── .github/workflows/
│   ├── ci.yml                 # Build, test, deploy to dev
│   ├── promote.yml            # Promote to staging/production
│   ├── terraform.yml          # Terraform plan/apply
│   └── secrets-check.yml      # Plaintext secrets detection
└── docs/
    ├── architecture.md         # This file
    ├── environments.md
    ├── deployment.md
    ├── secrets.md
    ├── providers.md
    ├── disaster-recovery.md
    └── runbooks.md
```
