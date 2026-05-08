# Bootstrapping Guide

Day-0 setup for the Axiome platform across all supported providers. This document is an **index** — detailed per-provider bootstrap lives next to the Terraform code.

For the **why** (architecture, evolution path, graduation criteria), read these first:

1. [architecture-evolution.md](architecture-evolution.md) — pilot → production-grade phases
2. [graduation-criteria.md](graduation-criteria.md) — observable signals to advance phases
3. [providers.md](providers.md) — cross-provider portability and trade-offs
4. [architecture.md](architecture.md) — current service topology

For the **how** (Day-0 install), pick a provider:

| Target | Bootstrap doc | Time to first deploy |
|---|---|---|
| **Local dev** (laptop) | §1 below | ~5 min |
| **AWS** (Lightsail + Neon + Atlas) | [providers/aws/README.md](../providers/aws/README.md) | ~30 min for first env |
| **Scaleway** (Instance + Neon + Atlas) | [providers/scaleway/README.md](../providers/scaleway/README.md) | ~30 min for first env |
| **On-prem connected** (customer Linux host) | [providers/onprem/README.md](../providers/onprem/README.md) §1 | ~30 min |
| **On-prem air-gapped** (no internet egress) | [providers/onprem/README.md](../providers/onprem/README.md) §2 | ~45 min (bundle build + transfer) |

---

## 1. Local development (laptop)

For developer workflow only. Not used for any deployed environment.

### 1.1. Clone the repos

```bash
mkdir -p ~/dev/axiome && cd ~/dev/axiome
git clone git@github.com:<org>/axiome-infra.git
git clone git@github.com:<org>/axiome-back.git
git clone git@github.com:<org>/axiome-front.git
git clone git@github.com:<org>/axiome-bio-compute.git
```

Sibling layout — required because `docker-compose.yml` mounts `../axiome-back` etc.

### 1.2. Start the local stack

```bash
cd axiome-infra
make local-up
```

Brings up: Postgres 15, MongoDB 7, MinIO (S3-compatible), backend (NestJS hot-reload), biocompute (FastAPI hot-reload), frontend (Vite hot-reload).

### 1.3. Access

| Service | URL |
|---|---|
| Frontend | http://localhost:5173 |
| Backend | http://localhost:3000 |
| Backend health | http://localhost:3000/health |
| Biocompute | http://localhost:8000 |
| Biocompute health | http://localhost:8000/health |
| MinIO console | http://localhost:9001 (`minioadmin` / `minioadmin`) |

### 1.4. Run migrations

```bash
cd ../axiome-back
npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

### 1.5. Daily commands

```bash
cd axiome-infra
make local-up        # Start
make local-down      # Stop
make local-restart   # Restart
make local-logs      # Tail logs
docker compose down -v  # Hard reset including volumes
```

---

## 2. Cloud / on-prem deployments

Each provider has its own bootstrap procedure. The architecture shape is the same; only the underlying compute and provider-specific tooling differ.

| Step | AWS | Scaleway | On-prem connected | On-prem air-gapped |
|---|---|---|---|---|
| 1. Cloud account / host | AWS account + IAM user | Scaleway org + IAM API key | Customer-provisioned Linux host | Customer-provisioned Linux host |
| 2. DNS zone | Route 53 hosted zone | Scaleway DNS zone | Customer DNS | Customer internal DNS |
| 3. Neon + Atlas (managed DBs) | One project per env | Same | Same | **Skipped — self-hosted** |
| 4. State bucket / lock | S3 + DynamoDB | Scaleway Object Storage | N/A (no Terraform per host) | N/A |
| 5. Apply Terraform / installer | `make apply` | `make apply` | `install.sh --mode connected` | `install.sh --mode airgapped` |
| 6. Push images | ECR | Scaleway Container Registry | ECR (pull) | Preloaded tarball |
| 7. Run migrations | Operator-side | Operator-side | Operator-side | On-host Docker run |
| 8. Verify | curl /health | curl /health | curl /health | curl -k /health |

Detailed steps live in the per-provider READMEs linked at the top of this document.

---

## 3. Per-environment lifecycle

After Day-0 bootstrap is done **once**, day-to-day operations across all three environments follow this pattern:

```
┌──────────┐  push to main   ┌──────────┐   manual   ┌──────────┐   manual   ┌──────────────┐
│  local   │ ─────────────►  │   dev    │ ─────────► │ staging  │ ─────────► │  production  │
└──────────┘                  └──────────┘            └──────────┘            └──────────────┘
                              auto-deploy            same image SHA          same image SHA
                              on merge              promoted                 promoted from staging
```

Each environment has:
- Its own Terraform tfvars (`environments/<env>/terraform.tfvars`)
- Its own state bucket / state backend
- Its own Neon project, Atlas cluster, S3 buckets
- Its own DNS subdomain
- Its own image tag(s) tracked in `environments/<env>/images.tfvars`

CI updates the image tags in `images.tfvars` and runs `make apply ENV=<env>`. See [ci-cd.md](ci-cd.md) for the pipeline detail.

---

## 4. Multi-tenancy notes (relevant from Day-0)

The platform is multi-tenant at the application layer — **one shared database per environment with `tenant_id` (or `workspace_id`) discrimination at the row/document/object level**. This is documented in detail in [architecture-evolution.md](architecture-evolution.md) §6.

Day-0 implications:
- **Postgres RLS policies** must exist on every tenant-scoped table from the first migration
- **Mongo data-access layer** must inject the tenant filter on every query — no raw collection access
- **`tenant_id` field** on every log line, metric, and trace span — enforced in the logger wrapper
- **Tenant-scoped delete and export scripts** must be written before the second customer

These are application-layer concerns but interact with the bootstrap because schemas and observability instrumentation are decided early. Skipping them now creates retrofit pain later.

---

## 5. Common Day-0 prerequisites

Tools needed regardless of provider:

| Tool | Version | Purpose |
|---|---|---|
| Git | ≥ 2.30 | Source control |
| Terraform | ≥ 1.5 | Infrastructure provisioning (cloud providers) |
| Docker | ≥ 24.0 | Container runtime |
| Docker Compose | ≥ 2.20 | Local dev stack and on-prem deployment |
| Make | any | Operational shortcuts |
| Node.js | 20 LTS | Backend / frontend tooling (migrations, builds) |
| Python | 3.12 | Biocompute service tooling |

Provider-specific CLIs are documented in each provider's README:
- AWS CLI v2 — [providers/aws/README.md §0.3](../providers/aws/README.md#03-configure-local-aws-cli)
- Scaleway CLI — [providers/scaleway/README.md §0.4](../providers/scaleway/README.md#04-install-and-configure-scaleway-cli)
- Ansible (optional, on-prem) — [providers/onprem/README.md §1.6](../providers/onprem/README.md#16-optional-use-ansible-instead-of-installsh)

---

## 6. Bootstrap order recommendation

For a new platform setup, the suggested order:

1. **Local dev** — get the application stack running on your laptop (validates code-level concerns before any cloud spend)
2. **AWS dev** — first cloud environment; smallest blast radius and fastest iteration loop
3. **AWS staging** — same Terraform module with different tfvars
4. **AWS production** — same module, paid DB tiers
5. **(Optional) Scaleway** — only if EU-residency requirements or cost preference justifies a second cloud
6. **(Optional) On-prem** — only when a customer engagement requires it

Each step builds on the previous: the AWS dev experience validates the toolchain before staging, staging validates against production-shape DB tiers before production.

---

## 7. Post-bootstrap checklist

After the first environment is running:

- [ ] Health endpoint returns 200
- [ ] DNS resolves
- [ ] TLS cert is valid (Let's Encrypt or internal CA)
- [ ] Database migrations have run
- [ ] First admin user is seeded (idempotent script)
- [ ] External uptime monitor configured (UptimeRobot / BetterStack)
- [ ] Billing alerts active
- [ ] Backup verification (Neon / Atlas dashboard or `/var/backups/axiome`)
- [ ] Rebuild runbook tested (`make destroy && make apply` returns to working state)
- [ ] Quarterly DR drill calendar event created
- [ ] Observability instrumentation present (structured JSON logs with `tenant_id`)
- [ ] [graduation-criteria.md](graduation-criteria.md) review schedule set

When all are checked, the environment is ready for tenant onboarding (or promotion to staging/production for non-dev envs).
