# MIPP Hosting — Operator Runbook (AXI-916)

Operational guide + per-story status for the HDS-certified, provider-portable,
Terraform-only hosting. See `providers/CONTRACT.md` for the cross-provider contract
and `05 - product/features/MIPP-Hosting-Environment.md` (axiome-docs) for requirements.

## Deploy

```
PROVIDER=aws bash scripts/deploy.sh <env> [--plan-only]
```

New HDS stack is gated (strangler — runs alongside the live Lightsail/Neon stack):

| Toggle | Default | Effect |
|---|---|---|
| `use_hds_data_stack` | `false` | provision VPC + 3-tier SGs + RDS + ElastiCache (CMK-encrypted) |
| `use_ec2_compute`    | `false` | run the app stack on EC2 in the VPC (Elastic IP) instead of Lightsail |
| `use_legacy_stack`   | `true`  | keep Lightsail + Neon + Atlas. Set `false` for greenfield / after cutover (destroys/skip them; secrets repoint to RDS / in-region Mongo / ElastiCache) |
| `redis_num_cache_clusters` | `1` | ElastiCache nodes. `1` = single (pilot, cheapest); `2+` = Multi-AZ failover |
| `enable_nat_gateway` (network module) | `false` | NAT for private-subnet egress. Off by default — RDS/ElastiCache need none and EC2 is in a public subnet. On adds ~$33/mo |

After apply: `terraform output ec2_public_ip` and `rds_endpoint`.

## Monthly cost (estimate)

AWS list prices, eu-west-3, USD (before EUR/VAT). Greenfield production = `use_hds_data_stack=true`, `use_ec2_compute=true`, `use_legacy_stack=false`.

| Item | Config | ~$/mo |
|---|---|---|
| EC2 | `t3.medium` + 40 GB gp3 | ~$39 |
| RDS Postgres | `db.t3.micro` single-AZ + 20 GB | ~$16 |
| ElastiCache | 1× `cache.t3.micro` (`redis_num_cache_clusters=1`) | ~$14 |
| KMS / ECR / S3 / DynamoDB / SSM | CMK + images + near-empty buckets | ~$3 |
| NAT Gateway | **disabled** (`enable_nat_gateway=false`) | $0 |
| **Total** | pilot sizing | **≈ $75–85 / mo** |

- **Cost-optimized for the pilot:** NAT Gateway off (−~$33) and single-node Redis (−~$14) vs. the HA default.
- **Scale levers:** bump `redis_num_cache_clusters=2` (Multi-AZ, +~$14), larger `rds_instance_class` / `ec2_instance_type`, set `enable_nat_gateway=true` only if a private workload needs egress.
- Excludes data-transfer-out at scale, backups beyond free allotment, and the Microsoft 365 domain. Observability (Prometheus/Grafana/Loki) runs as containers on the EC2 → no extra AWS line item. Neon/Atlas/Lightsail are **$0** here (gated off).

## S8 — TLS + DNS (FR7)

- **TLS:** Caddy + Let's Encrypt on the compute (rendered from `cloud-init/Caddyfile.tftpl`; reused by the EC2 module). Portable across providers.
- **DNS:** managed **manually in the Microsoft 365 zone** (no first-class Terraform support). Create the A record:
  `platform.axiomebio.com  A  <terraform output ec2_public_ip>`
  This is the single documented manual step (FR12 carve-out).

## S6 — Messaging & cache (FR4 / FR5)

- **RabbitMQ:** runs as a **container** on the compute host (cloud-init compose) — FR4. Not a managed service (no Amazon MQ).
- **Redis:** **managed via AWS ElastiCache** (FR5) — private subnets + data SG, CMK at-rest + TLS in transit; wire the `rediss://` primary endpoint into `REDIS_URL`. OVH/Scaleway use their managed Redis behind the same `REDIS_URL` (Redis-protocol) contract. Module: `modules/cache-redis`.

## S5 — Event store (FR3)

- **Pilot (active):** self-hosted, in-region **MongoDB-compatible** store (container/dedicated), migrated off Atlas SaaS by `scripts/migrate-data.sh` (mongodump/restore). MongoDB compatibility is preserved (non-destructive).
- **Additive:** a **DynamoDB adapter** behind the event-service repository interface — optional, never the sole backend (NFR3).
- **Remaining (backend code, axiome-back):** introduce the provider-neutral repository interface in `event-service` with shared contract tests. This is application code (TypeScript) and is the substantive open work for AXI-955.

## Pilot-tenant data segregation (AXI-1004 / FR10 / NFR2)

Minimal single-tenant object-store + DB segregation — see `providers/aws/db/README.md`
for the full picture. Short version:

- **Object store:** the per-environment S3 bucket set (`artifacts`/`uploads`/`system`)
  and its IAM scoping already are the pilot tenant's dedicated namespace — no
  further action needed.
- **DB:** run `providers/aws/db/01_pilot_tenant_app_role.sql` once per environment
  (after `terraform apply` + Prisma migrations) to create the least-privilege
  `axiome_app` role. `terraform apply` alone is not sufficient — the SQL step is a
  **manual, one-time follow-up** per environment (same pattern as
  `analytics/funnels/00_metabase_readonly_role.sql`), and app containers need a
  restart afterward to pick up the new `DATABASE_URL`/`USER_DATABASE_URL`/
  `ORGANIZATION_DATABASE_URL` SSM values.

## Evidence & qualification (FR13 / FR14)

- `scripts/generate-hds-report.sh <provider> <env>` — HDS evidence report → `axiome-docs/reports/infra/` (sensitive outputs redacted, fail-closed).
- `scripts/generate-qualification-record.sh <provider> <env>` — IQ/OQ/PQ Qualification Record (fail-closed; exits non-zero on any failed check).
- `scripts/migrate-data.sh <provider> <env>` — migration + parity, then emits the Qualification Record.
- The IEC 62304/82304-1 IQ/OQ/PQ **doc set** is assembled separately per `CLAUDE.md` Workflow 5, referencing these records.

## Per-story status (branch `feat/AXI-916-hosting-portable`)

| Story | Status | Notes |
|---|---|---|
| AXI-951 foundation/contract | ✅ AWS real, validate ✓ | OVH/SCW scaffolds |
| AXI-952 KMS/CMK | ✅ AWS real | OVH/SCW scaffolds |
| AXI-953 network + EC2 compute | ✅ AWS real, validate ✓ | OVH/SCW network scaffolds; OVH/SCW compute pending |
| AXI-954 RDS Postgres | ✅ AWS real, validate ✓ | OVH/SCW managed-PG scaffolds |
| AXI-957 object storage | ✅ AWS real | OVH/SCW scaffolds |
| AXI-958 TLS+DNS | ✅ Caddy + manual Microsoft 365 DNS | — |
| AXI-959 observability | ✅ portable stack | provider-native sinks optional |
| AXI-960 HDS report (FR13) | ✅ tested | secrets redacted |
| AXI-961 Qualification Record (FR14) | ✅ tested | fail-closed |
| AXI-963 cutover/migration | ✅ script | run at cutover |
| AXI-955 event-store | 🟡 infra + plan | **backend repository code pending** |
| AXI-956 RabbitMQ container + ElastiCache Redis | ✅ AWS real, validate ✓ | OVH/SCW managed-Redis scaffolds |
| AXI-962 HDS scope + sign-off | 🟡 checklist | run after deploy (NFR1/NFR6) |

All AWS Terraform is `terraform validate`-clean. OVH/Scaleway modules are scaffolds to refine + validate in the test pass.

---

# Sovereign cutover to Scaleway (AXI-921)

> Reuses this provider-portable IaC via `PROVIDER=scaleway`. The Scaleway root
> (`providers/scaleway`) is now `terraform validate`-clean against provider 2.76, with
> the sovereign IAM domain, Secret Manager, Key Manager (CMK) and private-network +
> 3-tier SG modules implemented and gated. Requirements live in axiome-docs
> `features/Sovereignty-Layer.md`; posture in `04 - architecture/infrastructure/Sovereignty-Posture.md`.
> **Gate:** do not run the live cutover until the MIPP pilot is complete and the
> sovereign Scaleway Organization exists.

## Sovereign toggles (Scaleway root)

| Toggle | Default | Effect |
|---|---|---|
| `scaleway_organization_id` / `scaleway_project_id` | `""` | sovereign tenancy boundary; empty = credential default. Set to the dedicated sovereign project (AXI-990). |
| `use_sovereign_iam` | `false` | provision the deploy IAM identity scoped to the sovereign project (FR2/FR3). |
| `use_secret_manager` | `false` | store runtime config in Scaleway Secret Manager under `/<env>/<prefix>` (FR3). |
| `use_private_network` | `false` | VPC + private network + edge/app/data SGs, default-deny, no `0.0.0.0/0` to data ports (NFR7/AC11). |
| `use_cmk` | `false` | Scaleway Key Manager CMK for data-at-rest (FR6/NFR5). |

## AXI-992 — CI/CD provider cutover (config toggle, not a code flip)

`terraform-cd.yml` already routes on `vars.PROVIDER || vars.REGISTRY_PROVIDER || 'aws'`,
and `reusable-build.yml` routes the registry on `REGISTRY_PROVIDER`. The cutover is an
**ops toggle** (so the running AWS pilot is never silently redirected):

1. Set repository variables: `PROVIDER=scaleway`, `REGISTRY_PROVIDER=scaleway`,
   `SCW_REGISTRY_ENDPOINT=rg.fr-par.scw.cloud`.
2. Set repository secrets: `SCW_ACCESS_KEY` / `SCW_SECRET_KEY` (the sovereign deploy key
   from `module.iam`), and point `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` at the
   **Scaleway Object Storage** keys used for the S3-compatible state backend (CONTRACT §7).
3. State backend is already configured: `providers/scaleway/environments/<env>/backend.hcl`
   (`s3.fr-par.scw.cloud`, bucket `axiome-<env>-tfstate`).
4. `staging`/`production` still require GitHub environment approval; `dev` auto-applies.

## AXI-993 — Data migration & DNS cutover

1. **Provision** (per env): `PROVIDER=scaleway bash scripts/deploy.sh <env>` with the
   sovereign toggles set. Then `PROVIDER=scaleway bash scripts/verify-deploy.sh <env>`
   (provider-aware; resolves `public_ip`).
2. **Lower DNS TTL** on `platform.axiomebio.com` ahead of the window (Microsoft 365 zone).
3. **Migrate** (fail-closed parity): `migrate-data.sh scaleway production` —
   `SOURCE_PG_DSN`=AWS RDS/Neon, `TARGET_PG_DSN`=Scaleway PG; `SOURCE_MONGO_URI`=AWS,
   `TARGET_MONGO_URI`=Scaleway. The script aborts (exit 1) and emits no "complete"
   record on any count/checksum mismatch.
4. **DNS cutover:** point `platform.axiomebio.com A` at the Scaleway `public_ip`
   (manual Microsoft 365, or onboard the zone to Scaleway DNS — `modules/dns`).
5. **Residency audit (AC8):** confirm every store/cache/key/log is in `fr-par`; record in
   the Sovereignty-Posture doc + the generated Scaleway evidence report.

## Rollback

The AWS `eu-west-3` stack stays live and warm until decommission sign-off.

- **Before DNS cutover:** abort is a no-op (traffic still on AWS).
- **After DNS cutover:** repoint `platform.axiomebio.com A` back to the AWS IP (TTL is
  low). Data written to Scaleway during the window must be reconciled before retrying —
  no dual-write is run, so the AWS dataset is the rollback source of truth.
- **CI:** unset the `PROVIDER` / `REGISTRY_PROVIDER` repo variables to fall back to AWS.

## Scaleway monthly cost (estimate, fr-par)

| Item | Config | ~€/mo |
|---|---|---|
| Instance | `DEV1-M` (prod) / `PLAY2-PICO` (dev) | ~€12 / ~€7 |
| Managed PostgreSQL | `DB-DEV-S` (or Neon, interim) | ~€20 |
| Object Storage + Registry | near-empty buckets + images | <€2 |
| Key Manager (CMK) + Secret Manager | per key/secret | ~€1 |
| **Total** | pilot sizing | **≈ €35–55 / mo** |

## Per-story status (AXI-921, branch `feat/AXI-916-hosting-portable`)

| Story | Status | Notes |
|---|---|---|
| AXI-989 decision + posture | ✅ docs (axiome-docs, pushed) | residency audit + IQ/OQ/PQ refresh pending live deploy |
| AXI-990 sovereign IAM + secrets | ✅ modules, validate ✓ | live apply needs sovereign Org + creds |
| AXI-991 KMS + network | ✅ modules, validate ✓ | wired gated (`use_cmk`, `use_private_network`) |
| AXI-992 CI/CD cutover | ✅ documented toggle | flip repo vars/secrets at cutover (above) |
| AXI-993 data + DNS cutover | ✅ tooling + runbook | live migration/DNS gated on pilot + Org |
