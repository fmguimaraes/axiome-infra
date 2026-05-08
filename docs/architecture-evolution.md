# Infrastructure Architecture Evolution

This document describes how the Axiome platform infrastructure evolves from a low-cost pilot architecture to a production-grade, highly-available architecture, and the architectural decisions that keep the migration path open.

---

## 1. Architectural Principle

**State and compute are decoupled.** The application runtime is stateless; all persistent state lives in external services reached via connection strings. This single property enables:

- Cheap pilot deployments on a single VM with zero data risk
- Cross-cloud portability (AWS, Scaleway, on-prem) without redesign
- Compute layer evolution (single VM → orchestrated containers) as an isolated change
- Disaster recovery via stateless rebuild (state survives because it lives elsewhere)

Every architectural decision in this document follows from this principle.

---

## 2. Target Architecture (Steady-state)

The architecture the platform converges toward when business and load requirements demand it.

```
                      ┌──────────────────────────┐
                      │      Public Internet     │
                      └─────────┬────────────────┘
                                │
                      ┌─────────▼────────┐
                      │   Route 53 DNS   │
                      └─────────┬────────┘
                                │
                      ┌─────────▼─────────┐
                      │  ALB (TLS / ACM)  │
                      └───┬──────────┬────┘
                          │          │
                ┌─────────▼─┐    ┌───▼──────────┐
                │  Frontend │    │   Backend    │
                │  (Static  │    │   (Fargate,  │
                │  +S3+CDN) │    │   2+ tasks,  │
                └───────────┘    │   multi-AZ)  │
                                 └──────┬───────┘
                                        │ Service mesh / Cloud Map
                                  ┌─────▼──────┐
                                  │ Biocompute │
                                  │  (Fargate, │
                                  │   private) │
                                  └─────┬──────┘
                                        │
              ┌────────────┬────────────┼────────────┬─────────────┐
              │            │            │            │             │
       ┌──────▼─────┐ ┌────▼─────┐ ┌────▼────┐ ┌────▼─────┐ ┌─────▼─────┐
       │   Neon     │ │  Atlas   │ │   S3    │ │   ECR    │ │  Secrets  │
       │ (Postgres, │ │ (Mongo,  │ │(buckets,│ │ (images) │ │  Manager  │
       │ HA, PITR)  │ │  M10+)   │ │ versioned)│ │          │ │           │
       └────────────┘ └──────────┘ └─────────┘ └──────────┘ └───────────┘
```

**Key properties:**
- Multi-AZ stateless compute, autoscaled
- Managed databases with automatic failover and point-in-time recovery
- Per-tenant data isolation enforced at row/document level (not infra level)
- Per-environment separation at the resource level (separate Neon projects, Atlas clusters, S3 buckets)
- Observability tagged by `tenant_id` for per-tenant troubleshooting

---

## 3. Evolution Phases

The architecture moves through three phases. Each phase is **architecturally compatible** with the next — graduation is a configuration change, not a redesign.

### Phase 1 — Pilot (current target)

**Compute:** Single Lightsail VM per environment (~$12/month each). Docker-compose runs backend, biocompute, frontend, and Caddy reverse proxy on one box.

**State:** Externalized from day one.
- Postgres → Neon (free tier for dev, paid tier for staging/prod)
- MongoDB → Atlas (M0 for dev, M10+ for prod)
- Object storage → S3 (small footprint)
- Container registry → ECR
- Secrets → SSM Parameter Store

**Network:** Public Lightsail static IP. Caddy + Let's Encrypt for TLS. No VPC.

**Three environments:** `dev`, `staging`, `production` — same architecture, different sizing, different DB tiers.

**Cost:** ~€33/month for compute (3× Lightsail) + DB tier choice (free → ~€140/mo).

**Trade-offs accepted:**
- No HA — VM reboot = environment downtime
- 4 GB RAM ceiling — biocompute spikes risk OOM cascades (mitigated by per-container memory limits)
- No autoscaling — vertical resize requires VM reboot
- Deploys are not zero-downtime (~30s gap during `docker compose up`)
- Single region

**What this is for:** Early-stage product validation, demo-grade availability, low tenant counts (single-digit to low double-digit). Not for SLA-bound contracts or compliance audits requiring documented HA.

### Phase 2 — Hardened pilot (intermediate)

Triggered by **production-only** signals (see [graduation-criteria.md](graduation-criteria.md)). Dev and staging stay on Phase 1.

**Compute changes:**
- Production graduates to **ECS Fargate** behind an **ALB**
- 2+ backend tasks, multi-AZ
- Same images from ECR (no rebuild)
- Application Auto Scaling on CPU/request count

**State changes:**
- Neon production tier upgraded (Pro/Scale) for HA + PITR
- Atlas M10+ for production
- S3 versioning + lifecycle policies tightened

**Network changes:**
- VPC + private subnets for production
- ALB + ACM for TLS termination (Caddy retired)
- VPC endpoints for S3, ECR, Secrets Manager (avoid NAT egress costs)

**Observability changes:**
- CloudWatch Logs aggregation
- ALB access logs
- Application metrics with `tenant_id` dimension

**Cost:** Production ~€150–250/month. Dev and staging unchanged.

**What changes for the application:** Nothing in the code. Connection strings stay the same (Neon/Atlas don't move). Image tags promoted from ECR. Health endpoints already exist.

**What changes operationally:**
- Deploys move from `docker compose pull && up` to ECS service updates
- TLS terminates at ALB; backend trusts `X-Forwarded-Proto`
- Logs go to CloudWatch instead of Docker stdout
- Secret refresh triggers task restart (not container restart on a single box)

### Phase 3 — Production-grade (steady-state)

Triggered by **scale or compliance** signals.

**Compute:**
- Backend autoscales 2 → N tasks based on CPU/request count
- Biocompute uses Fargate Spot for cost-optimized batch jobs, on-demand Fargate for interactive
- Frontend static assets served from S3 + CloudFront

**State:**
- Neon at Scale tier with read replicas for analytics queries
- Atlas with sharding if tenant count and data volume require
- S3 cross-region replication for DR
- Logical backups (per-tenant export) on a schedule, in addition to managed backups

**Network:**
- WAF in front of ALB
- Private link / VPC endpoints for all AWS service access
- Service-to-service mTLS (optional)

**Operational:**
- Per-tenant feature flags and rate limits
- Per-tenant observability dashboards (sampled top-N tenants)
- Documented per-tenant export and delete (GDPR) procedures
- Quarterly DR drill (restore from backup, validate)

**Cost:** Sized to load — no upper bound; expect €500–2000+/month for prod depending on tenant count and biocompute job mix. Free tier discounts (Savings Plans, Reserved Instances) apply at this scale.

---

## 4. What Carries Forward Across All Phases

These do not change between Phase 1 and Phase 3 — they're locked in by the architecture.

| Layer | Phase 1 | Phase 3 | Migration step |
|---|---|---|---|
| Container images | ECR | ECR | None — same registry |
| Postgres | Neon free/Launch | Neon Scale (or RDS) | Tier change OR `pg_dump`/`pg_restore` |
| MongoDB | Atlas M0/M10 | Atlas M10+ (or sharded) | Tier change in Atlas console |
| Object storage | S3 | S3 + CloudFront | None — same buckets |
| Application code | Same images | Same images | None |
| Connection strings | Env vars | Env vars (from Secrets Manager) | Source change, not value change |
| DNS | Route 53 | Route 53 | None |

The non-portable phase boundaries are **compute orchestration** (Lightsail → Fargate) and **TLS termination** (Caddy → ALB+ACM). Both are configuration-level changes, not application-level.

---

## 5. Caveats and Honest Trade-offs

### 5.1. Phase 1 (Lightsail) caveats

- **Single point of failure for compute.** Lightsail reboot, region outage, or accidental `terraform destroy` takes the environment down. Mitigated by: rebuild runbook tested quarterly, externalized state, image tags pinned in tfvars.
- **Free-tier database autosuspend.** Neon free and Atlas M0 autosuspend on idle. First request after idle has ~1–2s cold-start. Acceptable for dev and demo, **not acceptable for production-customer-facing workloads** — production must be on paid tiers.
- **4 GB RAM is tight for multi-tenant production.** Biocompute jobs are the risk. Mitigation: hard `mem_limit` in docker-compose per service, with biocompute capped at 1.5 GB.
- **Deploys are not zero-downtime.** ~30s gap during `docker compose up`. For a small number of pilot tenants this is tolerable; once SLA promises exist, this is a graduation trigger.
- **Vertical scale only.** Lightsail tops out at 16 GB / 8 vCPU. Beyond that, you must move off Lightsail.
- **No internal observability.** Single-VM stdout logs are it. External log shipping (CloudWatch, BetterStack) is recommended even at Phase 1.

### 5.2. Phase 2 / 3 caveats

- **Cost cliff.** Phase 2 production is ~10× the cost of Phase 1 production. The decision to graduate is non-trivial — it's a budget conversation with the business.
- **Operational complexity increases.** ALB target groups, ECS task definitions, autoscaling policies, IAM task roles, VPC endpoints — each adds knobs and failure modes. The team's operational maturity must keep pace.
- **CloudWatch Logs ingestion cost** ($0.57/GB) is the most common surprise post-Phase-2 graduation. Structured JSON at INFO level only; debug only when needed.
- **NAT Gateway egress** ($0.05/GB) is the second surprise. VPC endpoints for S3, ECR, Secrets Manager, CloudWatch eliminate most of it — provision them from day one of Phase 2.
- **Multi-AZ database costs ~2×.** Neon and Atlas paid tiers default to HA; budget accordingly.
- **DocumentDB is not a viable substitute for Atlas.** Even at Phase 3, do not migrate to DocumentDB. It is wire-compatible but not feature-compatible, and rolling back from a DocumentDB migration is a data-export operation. Stay on Atlas (or self-hosted MongoDB).

### 5.3. Multi-tenancy caveats (all phases)

- **Single shared DB per environment, not per tenant.** Per-tenant DBs multiply cost and operational burden by N. Tenant isolation is at the row/document level (Postgres RLS, Mongo data-access layer discipline).
- **Tenant-scoped delete and export must be designed early.** Adding GDPR-compliant per-tenant deletion to a sprawling shared-DB schema *after* the fact is painful. Build it before the second customer.
- **Noisy-neighbor risk.** One heavy tenant can exhaust shared DB resources or single-VM compute. Mitigations: per-tenant rate limits, query timeouts, statement-level connection pooling. None of these are infrastructure-level fixes.
- **Schema migrations are atomic across all tenants.** No gradual per-tenant rollouts without feature flags. Use expand-then-contract migrations for breaking schema changes.

### 5.4. Cross-provider caveats

- **Lightsail is AWS-only.** Cross-cloud compute migration replaces the compute Terraform module entirely, but the data layer (Neon, Atlas, S3-compatible) doesn't move.
- **Neon and Atlas are managed third-party services.** They run on AWS or Azure under the hood. For air-gapped on-prem deployments, both must be replaced by self-hosted Postgres and self-hosted MongoDB. Plan for two state-layer variants: managed (cloud) and self-hosted (air-gapped).
- **Compliance certifications transfer with the provider, not with you.** Neon and Atlas SOC 2 reports satisfy most pilots; some regulated buyers require diligence on every external service. Validate before promising on-prem-via-cloud-DBs to such buyers.
- **Region matters for latency.** Neon and Atlas EU regions (Frankfurt, Paris, Ireland) should pair with eu-west-3 / fr-par compute. Cross-region adds 20–50 ms per query.

---

## 6. Decisions Locked in at Phase 1 (Non-negotiable)

These choices are cheap to make at Phase 1 and very expensive to retrofit later. Once committed, they persist across all phases.

1. **`tenant_id` on every tenant-scoped row, document, and S3 path.** No exceptions, never optional.
2. **Postgres Row-Level Security policies on every tenant-scoped table.** Database refuses cross-tenant access, not just the application.
3. **MongoDB data-access layer that injects tenant filter on every query.** No raw collection access from business logic.
4. **Tenant context propagated through every log line, metric, and trace span.** Required for per-tenant debugging and incident response.
5. **All infrastructure dependencies reached via connection strings (env vars).** No hardcoded hostnames, paths, or provider-specific SDK calls. Application code is provider-agnostic.
6. **No DocumentDB-only or Lightsail-specific or Fargate-specific code paths.** App must run identically on docker-compose, Lightsail, and Fargate.
7. **No MinIO in any non-local environment.** Use S3 (or S3-compatible object storage on Scaleway/MinIO on-prem). MinIO is a local-dev-only convenience.
8. **ECR for all image distribution from Phase 1 onward.** Same registry pilot to production.
9. **Health endpoints (`/health`, `/ready`) on every service from day one.** ALB target groups, ECS health checks, and uptime monitors all need them.
10. **Tenant-scoped delete and export scripts written before the second customer.** Defer this and it becomes a data-archaeology project.

---

## 7. Migration Map (Phase 1 → Phase 2)

When [graduation-criteria.md](graduation-criteria.md) signals graduation for production, the migration is:

```
1. Stand up VPC + ECS cluster + ALB + ACM cert + IAM (Terraform: ~30 min apply)
2. Deploy same image tags from ECR onto Fargate (no rebuild)
3. Update DATABASE_URL / MONGODB_URI / S3_* env vars in task definitions
   → point at the same Neon / Atlas / S3 resources used by Phase 1
4. Smoke test against ALB DNS with host-header override
5. Route 53 record flip from Lightsail static IP → ALB
6. Keep Lightsail running for 48–72h as warm rollback target
7. Tear down Lightsail Terraform stack
```

**Total elapsed time: 1–2 days of focused work.** Data does not move. Application code does not change. The cutover is config and DNS.

---

## 8. References

- [graduation-criteria.md](graduation-criteria.md) — observable signals that trigger phase graduation
- [providers.md](providers.md) — cross-provider portability mapping
- [bootstrapping.md](bootstrapping.md) — Day-0 setup per provider per environment
- [architecture.md](architecture.md) — current service topology and data flow
- [disaster-recovery.md](disaster-recovery.md) — backup, restore, RTO/RPO targets
