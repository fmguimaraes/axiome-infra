# Provider Portability

The Axiome platform is designed to deploy on three providers — AWS, Scaleway, and on-prem (customer datacenter) — without architectural changes. The single property that makes this real is **state-and-compute decoupling**: stateful services (Postgres, MongoDB, object storage) are reached via connection strings, so swapping providers is a configuration exercise rather than a redesign.

## Implemented providers

| Provider | Path | Status | Reference |
|---|---|---|---|
| **AWS** (Lightsail + Neon + Atlas + S3 + ECR + Route 53) | [`providers/aws/`](../providers/aws/) | Production-ready | [providers/aws/README.md](../providers/aws/README.md) |
| **Scaleway** (Instance + Neon + Atlas + Object Storage + Container Registry + DNS) | [`providers/scaleway/`](../providers/scaleway/) | Production-ready | [providers/scaleway/README.md](../providers/scaleway/README.md) |
| **On-prem** (Linux host + docker-compose; connected or air-gapped modes) | [`providers/onprem/`](../providers/onprem/) | Production-ready | [providers/onprem/README.md](../providers/onprem/README.md) |

A legacy Scaleway-managed-services variant (RDB + Managed MongoDB + Serverless Containers) exists at the repo root level (`main.tf`, `modules/*`) and is **deprecated** in favor of `providers/scaleway/`. Do not use the legacy code for new deployments.

## Architectural shape, all providers

```
┌──────────────────┐
│   Single VM      │   (Lightsail / Scaleway Instance / customer host)
│   Caddy + TLS    │   Reverse proxy with Let's Encrypt or internal CA
│   docker-compose │   backend, biocompute, frontend
└────────┬─────────┘
         │
   ┌─────┼──────┬───────────┐
   │     │      │           │
┌──▼─┐ ┌─▼──┐ ┌─▼──────┐ ┌──▼─────┐
│Neon│ │Atlas│ │ Object │ │Registry│
│Pg  │ │Mongo│ │Storage │ │  ECR / │
└────┘ └────┘ │ S3-compat│ │Scaleway│
              └────────┘ └────────┘
```

The boxes marked Neon, Atlas, S3-compatible, and Registry are the **portable layer**. They look identical to the application regardless of which compute provider hosts the VM.

## Service-by-service mapping

| Concern | AWS | Scaleway | On-prem (connected) | On-prem (air-gapped) |
|---|---|---|---|---|
| Compute | Lightsail Instance | Scaleway Instance | Customer Linux host | Customer Linux host |
| Postgres | Neon (managed) | Neon (managed) | Neon (managed) | Self-hosted Postgres container |
| MongoDB | Atlas (managed) | Atlas (managed) | Atlas (managed) | Self-hosted MongoDB container |
| Object storage | AWS S3 | Scaleway Object Storage (S3-compatible) | AWS S3 or Scaleway Object Storage | MinIO container (S3-compatible) |
| Container registry | ECR | Scaleway Container Registry | ECR (pull) | Image tarball preloaded |
| TLS | Caddy + Let's Encrypt | Caddy + Let's Encrypt | Caddy + Let's Encrypt | Caddy + customer's internal CA |
| DNS | Route 53 | Scaleway DNS | Customer DNS | Customer internal DNS |
| Secrets | SSM Parameter Store | Cloud-init injection | `.env` file (root-only) | `.env` file (root-only) |
| State backend (TF) | S3 + DynamoDB lock | Scaleway Object Storage (no lock) | N/A — provisioned by install.sh | N/A |

## Why MongoDB lives on Atlas everywhere (not DocumentDB, not Scaleway Mongo)

MongoDB Atlas is the only **wire- and feature-compatible** managed Mongo on every cloud. AWS DocumentDB and Scaleway Managed MongoDB are wire-compatible but feature-divergent in ways that surface unpredictably (aggregation, change streams, transactions). Atlas runs on AWS or Azure, supports EU regions (Frankfurt, Paris, Ireland), and survives provider migration as a connection-string change.

This is a hard architectural constraint, restated in [architecture-evolution.md](architecture-evolution.md) §6: **no DocumentDB, ever**.

## Why Postgres also lives on Neon by default

Postgres has true wire-compatibility everywhere — RDS, Cloud SQL, Scaleway RDB, Neon, Supabase, self-hosted are all real Postgres. Neon is chosen as the default because:

1. **Free tier supports the dev environment** at €0
2. **Same Neon project survives a compute-provider switch** (AWS → Scaleway → on-prem-connected)
3. **Symmetric with Atlas** — both managed, both portable
4. **Branchable databases** — useful for ephemeral PR environments later

Neon can be replaced with any real Postgres (RDS, Scaleway RDB, self-hosted) by changing `DATABASE_URL`. The architecture does not depend on Neon-specific features.

## Air-gapped on-prem — the one structural exception

Air-gapped deployments cannot reach Neon or Atlas. In this mode, the on-prem provider runs **self-hosted Postgres and MongoDB containers** on the same host as the application. Trade-offs:

- Customer (or their ops team) owns backups, HA, and upgrades
- Daily logical backup cron is installed by `install.sh`
- Same application code runs unchanged — only `DATABASE_URL` and `MONGODB_URL` point at localhost containers
- TLS uses the customer's internal CA (Let's Encrypt requires internet egress)

This mode is documented in [providers/onprem/README.md](../providers/onprem/README.md) §"Mode 2 — Air-gapped install".

## When to choose which provider

| Situation | Provider |
|---|---|
| Lowest operational complexity, default | **AWS** — broadest tooling, predictable Lightsail pricing |
| EU data residency emphasized, native EU vendor | **Scaleway** — fr-par, EU-only company |
| Customer's datacenter, internet egress acceptable | **On-prem (connected)** |
| Customer's datacenter, no internet egress (regulated) | **On-prem (air-gapped)** |
| Existing AWS billing relationship and ecosystem | **AWS** |
| Existing French/EU billing relationship | **Scaleway** |

Mixing providers across environments is supported (e.g., dev on Scaleway, prod on AWS) but multiplies operational learning curves. **Default to one provider per organization unless there is a clear reason to mix.**

## Cost comparison (Phase 1, single environment)

| Layer | AWS | Scaleway | On-prem (connected) | On-prem (air-gapped) |
|---|---|---|---|---|
| Compute | $12 (Lightsail ARM 4 GB) | €7–12 (PLAY2-PICO / DEV1-M) | Customer's hardware cost | Customer's hardware cost |
| Postgres | $0 dev / $19 prod (Neon) | $0 dev / $19 prod (Neon) | $0–$19 (Neon) | $0 (self-hosted) |
| MongoDB | $0 dev / $60 prod (Atlas) | $0 dev / $60 prod (Atlas) | $0–$60 (Atlas) | $0 (self-hosted) |
| Object storage | <$1 (S3) | <€1 (Scaleway) | <$1 (S3) | $0 (MinIO) |
| Registry | <$1 (ECR) | <€1 (Scaleway) | <$1 (ECR pull) | $0 (preloaded) |
| **Dev env total** | **~$13** | **~€8** | Customer + ~$1 | Customer only |
| **Prod env total** | **~$92** | **~€85** | Customer + ~$80 | Customer only |

Scaleway is ~5–10% cheaper in EU regions. AWS Lightsail wins on tooling maturity. On-prem cost shifts to the customer's hardware and ops time.

## Migration paths

All migrations are **same-day cutovers** because state doesn't move (or moves via standard `pg_dump` / Atlas tier change).

### AWS → Scaleway

1. Provision the same three Scaleway envs in parallel
2. Push images to Scaleway Container Registry
3. Point Scaleway VMs at the **same Neon and Atlas** projects
4. Copy S3 artifacts to Scaleway Object Storage (`aws s3 sync` or `mc mirror`)
5. Cut DNS over to Scaleway public IPs
6. Tear down Lightsail

### Scaleway → AWS

Same in reverse.

### Cloud → on-prem (connected)

1. Customer provisions Linux host
2. Operator runs `install.sh --mode connected` with the **same Neon and Atlas connection strings**
3. Cut customer DNS over

### Cloud → on-prem (air-gapped)

1. Build air-gapped bundle (`build-airgapped-bundle.sh`)
2. Deliver to customer
3. Customer runs `install.sh --mode airgapped`
4. Migrate data: `pg_dump` from Neon → restore on-prem Postgres; `mongodump` from Atlas → restore on-prem MongoDB; copy S3 artifacts → MinIO

This is the **only migration that involves data movement** because air-gapped explicitly forbids the managed services.

## Design principle

Optimize for **topology portability, not naive resource mapping**. The same architectural pattern (single VM, Caddy reverse proxy, docker-compose, externalized state) runs identically on every provider. Specific provider primitives (Lightsail vs. Scaleway Instance vs. customer host) are interchangeable; the architecture is not.
