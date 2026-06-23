# Provider Contract (AWS / OVH / Scaleway)

> Owner: AXI-916 (MIPP Hosting) · Story AXI-951 · Feature FR12, NFR2, NFR3, NFR7.
> This is the **common contract** every provider root under `providers/<provider>/`
> MUST satisfy so the platform deploys identically on any provider with **no
> AWS-proprietary runtime lock-in**. It is the source of truth for the per-provider
> interface; `terraform validate`/`plan` must stay green for every provider (AC8).

Supported providers: **`aws`**, **`ovh`**, **`scaleway`** (plus `onprem`, which is
Docker-Compose/Ansible, not Terraform). Select with `PROVIDER=<provider> scripts/deploy.sh <env>`.

## 1. Region / sovereignty (NFR2)

Each provider exposes its own region variable, but the value MUST be an
**HDS-certified French region**:

| Provider | Region var | HDS French region(s) |
|----------|-----------|----------------------|
| aws      | `aws_region`      | `eu-west-3` (Paris) |
| ovh      | `ovh_region`      | `GRA*` (Gravelines), `SBG*` (Strasbourg), `RBX*` (Roubaix) |
| scaleway | `scaleway_region` | `fr-par` (Paris) |

No data store, cache, broker, key, log, or compute may resolve outside the chosen
French region.

## 2. Required root input variables (common across all providers)

Every provider root `variables.tf` MUST declare these with identical names/semantics:

- `environment` — `dev | staging | production` (validated)
- `project_name` — default `axiome`
- `domain` — base DNS zone (e.g. `axiomebio.com`)
- `subdomain` — environment host prefix (e.g. `platform`)
- `backend_image_tag`, `biocompute_image_tag`, `frontend_image_tag`
- `neon_project_region_id`, `neon_compute_min_cu`, `neon_compute_max_cu`, `neon_autosuspend_seconds`
- `atlas_org_id`, `atlas_cluster_tier`, `atlas_cloud_provider`, `atlas_region`, `atlas_mongo_version`
- `tags` — `list(string)` (AWS adapts to `common_tags` `map(string)` internally)

Provider-specific compute sizing/identity vars (e.g. `lightsail_bundle_id`,
`instance_type`, `ovh_instance_flavor`, `ovh_cloud_project_id`) are allowed **in
addition**, never instead.

## 3. Required root outputs (common across all providers)

Every provider root `outputs.tf` MUST expose:

- `fqdn`
- `public_ip` (the edge/instance public address)
- `registry_endpoint`
- `neon_connection_string` (sensitive) *(until S4/S5 move data in-region)*
- `atlas_connection_string` (sensitive) *(until S5 moves data in-region)*
- `s3_endpoint`, `s3_artifacts_bucket`, `s3_uploads_bucket`, `s3_system_bucket`

Provider-specific extras (e.g. AWS `ssm_parameter_prefix`, `cloudfront_*`) are allowed.

## 4. Required module set (per provider) and owning story

Each provider implements these modules under `providers/<provider>/modules/`:

| Module | Purpose | Owning story |
|--------|---------|--------------|
| `network`        | private network + subnets + firewall/SG (default-deny) | AXI-951 / AXI-953 |
| `compute`        | provider-native instances running the container stack  | AXI-953 |
| `storage`        | S3-compatible object storage (`artifacts`/`uploads`/`system`) | AXI-957 |
| `registry`       | container registry                                      | AXI-953 |
| `secrets`        | runtime secrets store + least-privilege access          | AXI-952 |
| `database-neon`  | PostgreSQL (managed-Postgres target replaces this in S4) | AXI-954 |
| `database-atlas` | event store (self-hosted in-region replaces this in S5)  | AXI-955 |
| `dns`            | DNS records for `fqdn`                                   | AXI-958 |
| `logging`        | native log sink + retention (in-region, FR9/NFR8)        | AXI-953 |

Module **input/output interfaces** MUST match across providers (same names) so the
root composition is provider-agnostic.

### 4.1 Logging (FR9 / NFR8)

Each provider ships **container stdout/stderr + host bootstrap logs** to a native,
in-region sink via an agent on the compute VM. The `json-file` Docker driver is **kept**
(so `docker logs` keeps working for SSM/console debugging) — the agent tails it; no
cloud log-driver is used. Sinks: **AWS** CloudWatch Logs (CMK-encrypted), **Scaleway**
Cockpit, **OVH** Logs Data Platform, **on-prem** the portable Loki/Promtail/Grafana
stack (works air-gapped). No secrets/PII in logs. Logs never leave the French region
(§1). On-prem uses Docker-Compose (`providers/onprem/compose/docker-compose.logging.yml`),
not Terraform, consistent with the rest of that provider.

## 5. Network isolation policy (NFR7, AC11)

Every provider's `network` module MUST:
- create a **private network/subnet**; data stores (Postgres, Mongo-compatible,
  Redis, RabbitMQ) bind **only** to it;
- **default-deny** ingress;
- expose publicly **only** `80`/`443` to the edge/reverse-proxy;
- **never** open `0.0.0.0/0` to a data/broker/cache port.

## 6. Encryption policy (FR6, NFR5, AC7)

All data stores are encrypted **at rest with provider customer-managed keys (CMK)**
via the provider KMS (AWS KMS / OVH KMS / Scaleway Key Manager) and **in transit**
(TLS 1.2+). Keys live in the chosen French region.

## 7. Portable Terraform state backend (FR12)

State uses an **S3-compatible** backend per provider, configured via
`environments/<env>/backend.hcl`:

| Provider | Bucket | Endpoint | Lock |
|----------|--------|----------|------|
| aws      | `axiome-<env>-tfstate` | (native S3, `eu-west-3`) | DynamoDB `axiome-<env>-tflock` |
| ovh      | `axiome-<env>-tfstate` | `https://s3.<region>.io.cloud.ovh.net` | (S3 lockfile / none) |
| scaleway | `axiome-<env>-tfstate` | `https://s3.<region>.scw.cloud` | (S3 lockfile / none) |

`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars carry the **provider's** S3
keys for state ops (OVH/Scaleway Object-Storage keys, not AWS).

## 8. Conformance (AC8)

- `terraform fmt -recursive -check` passes for all providers.
- `terraform validate` (`init -backend=false`) passes for every provider root.
- OVH and Scaleway must `validate`/`plan` green in CI even though the **live** pilot
  runs on one chosen provider; standing up live OVH/Scaleway prod stacks is out of scope.
- **100% Terraform, no click-ops.** Any manual console step is a contract violation.
