# Scaleway Provider — Bootstrap Guide

Same architecture as the AWS provider, on Scaleway: a single Scaleway Instance per environment running the docker-compose stack, with Neon (Postgres) and Atlas (MongoDB) as external managed databases, Scaleway Object Storage for files, and Scaleway Container Registry for images.

This guide is run **once per Scaleway organization, then once per environment**.

---

## Architecture summary

| Layer | Service | Per-env cost (Phase 1) |
|---|---|---|
| Compute | Scaleway Instance (PLAY2-PICO ~€7 / DEV1-M ~€12) running docker-compose | €7–12/mo |
| Postgres | Neon (free for dev, Launch+ for staging/prod) | $0–$19/mo |
| MongoDB | Atlas (M0 free for dev, M10+ for prod) | $0–$60/mo |
| Object storage | Scaleway Object Storage (S3-compatible, 3 buckets per env) | <€1/mo |
| Container registry | Scaleway Container Registry (per-env namespace) | <€1/mo |
| TLS / Reverse proxy | Caddy + Let's Encrypt on the VM | €0 |
| DNS | Scaleway DNS (free with the domain) | €0 |

---

## Phase 0 — One-time Scaleway organization setup

### 0.1. Create Scaleway account

1. Sign up at https://console.scaleway.com
2. Create an Organization and a Project named `axiome` (or use Default).
3. Enable billing (credit card or invoice).
4. Set up billing alerts in Console → Billing.

### 0.2. Create a domain (or transfer one)

The Scaleway DNS provider expects a managed DNS zone. Two paths:

```bash
# Option A: register through Scaleway (~€7/year for .com)
#   Console → Domains and DNS → Buy a domain
#
# Option B: transfer DNS to Scaleway from another registrar
#   Console → Domains and DNS → Add an external domain
#   Update the registrar's nameservers to:
#     ns0.dom.scw.cloud  ns1.dom.scw.cloud  ns2.dom.scw.cloud  ns3.dom.scw.cloud
```

DNS propagation: 1–24h.

### 0.3. Generate IAM API keys for Terraform

```bash
# Console → IAM → API Keys → Generate API Key
# - Belonging to: an IAM application named "axiome-terraform"
# - Permissions: assign role "Editor" or fine-grained as policy stabilizes
# Save:
#   SCW_ACCESS_KEY  (looks like SCW...)
#   SCW_SECRET_KEY  (UUID)
#   SCW_DEFAULT_PROJECT_ID
#   SCW_DEFAULT_ORGANIZATION_ID
```

### 0.4. Install and configure Scaleway CLI

```bash
curl -s https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
scw init   # paste keys interactively, choose region fr-par
scw account project list   # verify
```

### 0.5. Create Neon and Atlas accounts (if not already done for AWS)

Same as [providers/aws/README.md §0.5](../aws/README.md#05-create-neon-and-atlas-accounts-one-time). Both services run on AWS infrastructure but are reachable from Scaleway VMs over the internet. EU regions: Frankfurt for both.

---

## Phase 1 — Per-environment bootstrap

Repeat for each of `dev`, `staging`, `production`.

### 1.1. Create state bucket

Scaleway Object Storage is S3-compatible. The state bucket is one-off per environment.

```bash
cd providers/scaleway
make bootstrap ENV=dev
make bootstrap ENV=staging
make bootstrap ENV=production
```

This creates `axiome-<env>-tfstate` with versioning enabled.

**Note**: Scaleway has no native equivalent to DynamoDB state locking. For solo work this is fine; for team work, enforce one-applier-at-a-time via CI (mutex job) or shared agreement. State corruption from concurrent applies is the failure mode.

### 1.2. Set environment variables

```bash
# Scaleway credentials for Terraform AND backend.tf (S3-style)
export SCW_ACCESS_KEY="<your-access-key>"
export SCW_SECRET_KEY="<your-secret-key>"
export SCW_DEFAULT_ORGANIZATION_ID="<your-org-id>"
export SCW_DEFAULT_PROJECT_ID="<your-project-id>"

# AWS-compatible env vars for the S3 backend (points at Scaleway endpoints)
export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"

# Neon and Atlas
export NEON_API_KEY="<your-neon-api-key>"
export MONGODB_ATLAS_PUBLIC_KEY="<atlas-public-key>"
export MONGODB_ATLAS_PRIVATE_KEY="<atlas-private-key>"
export TF_VAR_atlas_org_id="<atlas-org-id>"
```

Add these to a local `.env.tfshell` (gitignored) or your shell rc with appropriate sourcing.

### 1.3. Update tfvars

Edit `providers/scaleway/environments/<env>/terraform.tfvars`:

```hcl
domain    = "axiome.example.com"   # Your Scaleway-managed DNS zone
subdomain = "dev"                    # → dev.axiome.example.com
                                     # production: subdomain = ""
atlas_org_id = "<atlas-org-id>"
```

### 1.4. Initialize and plan

```bash
cd providers/scaleway

make init ENV=dev
make plan ENV=dev
```

Expected resources for dev (~25):
- 1 Scaleway Instance + 1 routed IPv4
- 3 Object Storage buckets (artifacts versioned)
- 1 Container Registry namespace
- 2 IAM applications (storage runtime + registry pull) + policies + API keys
- 1 Neon project + branch + role + database
- 1 Atlas project + cluster + DB user + IP allowlist
- 1 DNS A record

### 1.5. Apply

```bash
make apply ENV=dev
```

Estimated duration: **3–8 minutes**.
- Scaleway Instance: ~1–2 min
- Neon: ~30 sec
- Atlas M0: ~3 min; M10: ~7 min
- Cloud-init on the VM: another **~3–5 min** (Docker install + image pulls)

### 1.6. Push initial images to Scaleway Container Registry

```bash
REGISTRY=$(terraform output -raw registry_endpoint)

# Login (Scaleway uses any user with valid secret-key as password)
docker login "$REGISTRY" -u nologin -p "$SCW_SECRET_KEY"

# Build and push each service
cd ../axiome-back
docker build -t "$REGISTRY/backend:latest" .
docker push "$REGISTRY/backend:latest"

cd ../axiome-bio-compute
docker build -t "$REGISTRY/biocompute:latest" .
docker push "$REGISTRY/biocompute:latest"

cd ../axiome-front
docker build -t "$REGISTRY/frontend:latest" .
docker push "$REGISTRY/frontend:latest"
```

The cloud-init on the VM logged in to the registry at first boot using the registry pull token, so subsequent `docker compose pull` works.

### 1.7. Trigger the VM to pull the new images

```bash
# Get the public IP
PUBLIC_IP=$(terraform output -raw public_ip)

# SSH (Scaleway PLAY2/DEV1 default user is root; key from console)
ssh root@$PUBLIC_IP

# On the VM
cd /opt/axiome
docker compose pull
docker compose up -d
docker compose ps
```

### 1.8. Run migrations

```bash
DATABASE_URL=$(terraform output -raw neon_connection_string)
cd ../axiome-back
DATABASE_URL="$DATABASE_URL" npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

### 1.9. Verify

```bash
# DNS resolves
dig +short dev.axiome.example.com

# Health (Caddy needs ~60s for Let's Encrypt cert on first hit)
curl -fsS https://dev.axiome.example.com/health
curl -fsS https://dev.axiome.example.com/ready
curl -fsS https://dev.axiome.example.com/
```

### 1.10. Verify cost telemetry

- Scaleway Console → Billing → confirm running compute charges align with instance type
- Neon dashboard → free tier usage
- Atlas dashboard → cluster M0 (or expected tier)

---

## Per-environment summary

### Dev

```bash
cd providers/scaleway
make bootstrap ENV=dev
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
# Push images (§1.6)
# Run migrations (§1.8)
# Verify (§1.9)
```

Expected cost: **~€7–8/month** (PLAY2-PICO instance + Object Storage; Neon and Atlas free).

### Staging

```bash
make bootstrap ENV=staging
make init ENV=staging
make apply ENV=staging
```

Expected cost: **~€12/month** (DEV1-M) + **$0–$19** Neon + **$0** Atlas (M0).

### Production

```bash
make bootstrap ENV=production
make init ENV=production
make apply ENV=production
```

Expected cost: **~€12/month** (DEV1-M) + **~$19** Neon Launch + **~$60** Atlas M10 = **~€85/month** for production.

---

## Day-2 operations

### Update images

```bash
ssh root@<public-ip>
cd /opt/axiome
docker compose pull
docker compose up -d
```

### Rotate the runtime IAM API keys

```bash
# Replace keys (storage + registry pull)
terraform apply -replace='module.storage.scaleway_iam_api_key.vm_runtime' \
                -replace='module.registry.scaleway_iam_api_key.registry_pull' \
                -var-file=environments/dev/terraform.tfvars
```

Cloud-init only runs on first boot — for an existing VM, SSH in and update `/opt/axiome/.env` with the new keys (read from Terraform outputs), then restart docker-compose.

### Vertical scale

Update `instance_type` in tfvars (e.g., `DEV1-L` for 4 vCPU / 8 GB) and apply. Scaleway requires the instance to be powered off for type change. Terraform handles the stop/change/start sequence.

```bash
make apply ENV=production
```

Expect **~3 min downtime** during the resize.

### Rebuild from scratch (DR drill)

```bash
make destroy ENV=dev
make apply ENV=dev
# Push images, run migrations, verify
```

**Run this drill quarterly** per [graduation-criteria.md](../../docs/graduation-criteria.md) §5.5.

### Tear down

```bash
make destroy ENV=dev
```

⚠️ Deletes the VM, Object Storage buckets (with all artifacts), Neon project, Atlas cluster, registry namespace, DNS records.

---

## Differences from AWS provider

| Concern | AWS Lightsail | Scaleway Instance |
|---|---|---|
| Compute base price | $12/mo (small_arm_3_0) | €7/mo (PLAY2-PICO) or €12 (DEV1-M) |
| State locking | DynamoDB (native) | None — manual coordination required |
| Static IP | Free with Lightsail | Routed IPv4 ~€1/mo |
| Outbound transfer | 4 TB included | Unlimited (Scaleway) |
| TLS | Let's Encrypt via Caddy | Same |
| DNS | Route 53 | Scaleway DNS (free) |
| Billing alerts | CloudWatch Alarms | Scaleway native |
| EU residency | eu-west-3 (Paris) | fr-par (Paris) — single AZ |
| Neon/Atlas | Same — both run on AWS, reachable from Scaleway over public internet | Same |

The application stack is identical. Migration AWS↔Scaleway is a Terraform module swap with `pg_dump`/`pg_restore` (or change Neon project), `mongodump`/`mongorestore` (or just keep using Atlas), and S3 artifact copy.

---

## Legacy Scaleway code

The repo previously contained a Scaleway-managed-services version (RDB Postgres + Scaleway MongoDB + Serverless Containers) at the root level (`/main.tf`, `/modules/*`). This is **superseded** by the architecture in `providers/scaleway/` documented here.

The legacy code is preserved for reference but should not be used for new deployments — its DocumentDB-equivalent (Scaleway Managed MongoDB) introduces the same lock-in concerns described in [providers.md](../../docs/providers.md), and Serverless Containers couples compute orchestration to Scaleway specifically.

To migrate a legacy Scaleway deployment to this provider:

1. Take backups: `pg_dump` of Scaleway RDB → import to Neon; `mongodump` of Scaleway Mongo → restore to Atlas.
2. Copy Object Storage contents to the new buckets (`scw object copy ...` or `aws s3 sync`).
3. Apply this provider's Terraform with the same `domain` / `subdomain`.
4. Cut DNS over.
5. Tear down legacy resources.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init` fails on backend | State bucket missing | Run `make bootstrap ENV=<env>` |
| Cloud-init times out | First boot slow | Wait 5 min; check `/var/log/axiome-init.log` via SSH |
| Caddy fails TLS | DNS not propagated | `dig <fqdn>` — wait for TTL |
| Registry login fails | API key revoked / expired | `terraform apply -replace='module.registry.scaleway_iam_api_key.registry_pull'` |
| Neon connection refused | Free tier autosuspend | First request takes ~1–2s |
| Atlas IP whitelisted | 0.0.0.0/0 by default | Tighten for production |
| OOM on PLAY2-PICO | 2 GB too small for full stack | Move to DEV1-M (4 GB) |
| State drift across operators | No locking | Coordinate manually OR add CI mutex |

---

## What's next

1. Wire CI to build and push images, then trigger deploys (covered in [ci-cd.md](../../docs/ci-cd.md))
2. Quarterly DR drill (rebuild dev from scratch)
3. External uptime monitor on production
4. Track [graduation-criteria.md](../../docs/graduation-criteria.md) signals
