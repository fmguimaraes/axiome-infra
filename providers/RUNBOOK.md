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
