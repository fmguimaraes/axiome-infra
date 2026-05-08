# AWS Provider — Bootstrap Guide

Complete Day-0 bootstrap for the AWS provider variant: Lightsail compute + Neon Postgres + Atlas MongoDB + S3 + ECR + Route 53.

This guide is run **once per AWS account, then once per environment**. Subsequent operations use the Makefile targets.

---

## Architecture summary

| Layer | Service | Per-env cost (Phase 1) |
|---|---|---|
| Compute | AWS Lightsail (single VM, 4 GB ARM, $12) running docker-compose | ~$12/mo |
| Postgres | Neon (free for dev, Launch+ for staging/prod) | $0–$19/mo |
| MongoDB | Atlas (M0 free for dev, M10+ for prod) | $0–$60/mo |
| Object storage | S3 (3 buckets per env: artifacts, uploads, system) | <$1/mo |
| Container registry | ECR (account-shared across envs) | <$1/mo |
| TLS / Reverse proxy | Caddy + Let's Encrypt (on the VM) | $0 |
| DNS | Route 53 hosted zone (account-shared) | ~$0.50/mo |
| Secrets / config | SSM Parameter Store | $0 |

**Three environments**: `dev`, `staging`, `production` — each is one Lightsail VM, one Neon project, one Atlas cluster, three S3 buckets. They share one ECR registry and one Route 53 hosted zone at the AWS-account level.

---

## Phase 0 — One-time AWS account setup (run once, ever)

### 0.1. Create or use an existing AWS account

1. Sign up at https://aws.amazon.com — or use an existing account
2. Enable billing alerts:
   - AWS Console → Billing → Billing preferences → "Receive Billing Alerts"
   - CloudWatch → Alarms → create alarms at €50, €100, €200 monthly thresholds

### 0.2. Create an IAM user for Terraform

Do **not** use the root user for day-to-day operations.

```bash
# In AWS Console:
# IAM → Users → Add user → "axiome-terraform"
# - Access type: Programmatic access only
# - Permissions: AdministratorAccess (scope down later — see §0.6)
# - Save the Access Key ID and Secret Access Key
```

### 0.3. Configure local AWS CLI

```bash
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
rm -rf awscliv2.zip aws/

# Configure
aws configure
# AWS Access Key ID:     <from 0.2>
# AWS Secret Access Key: <from 0.2>
# Default region:        eu-west-3
# Default output:        json

# Verify
aws sts get-caller-identity
```

For this project, AWS credentials may already exist at `/home/felipe/dev/quietstage/tarot/back/.env.dev`. Source them or copy into `~/.aws/credentials` — do not commit them.

### 0.4. Register or transfer a domain

The Terraform stack expects a Route 53 hosted zone for your base domain (e.g., `axiome.example.com`). Set this up once.

```bash
# Option A: Register through Route 53 (~$12/year for .com)
#   Console → Route 53 → Registered domains → Register domain
#
# Option B: External registrar (Gandi/Namecheap) — create a Route 53 hosted zone
#   and update the registrar's nameservers to Route 53's NS records.

aws route53 create-hosted-zone \
    --name axiome.example.com \
    --caller-reference "$(date +%s)"

# Note the four NS records returned and update them at the registrar.
# Verification with `dig` may take 1–24h to propagate.
```

### 0.5. Create Neon and Atlas accounts (one-time)

#### Neon

1. Sign up at https://console.neon.tech
2. Generate an API key: **Account settings → API keys → Generate**
3. Save the key.

```bash
export NEON_API_KEY="<your-neon-api-key>"
```

#### MongoDB Atlas

1. Sign up at https://cloud.mongodb.com
2. Create an organization (one Atlas org spans all environments).
3. Generate API keys at **Organization → Access Manager → API keys**.
4. Required role: **Organization Project Creator**.
5. Save **Public Key** (acts as username) and **Private Key**.
6. Note the **Organization ID** (Settings → General → Organization ID).

```bash
export MONGODB_ATLAS_PUBLIC_KEY="<public-key>"
export MONGODB_ATLAS_PRIVATE_KEY="<private-key>"
export TF_VAR_atlas_org_id="<organization-id>"
```

### 0.6. Scope down Terraform IAM (recommended after first apply)

After the first successful `terraform apply`, replace the AdministratorAccess policy on `axiome-terraform` with the least-privilege set covering only the resources Terraform manages (Lightsail, S3, IAM, ECR, SSM, Route 53, DynamoDB). This is the standard production-hygiene step. A policy template is at [docs/iam-terraform-policy.json](../../docs/iam-terraform-policy.json) (create separately as the policy stabilizes).

---

## Phase 1 — Per-environment bootstrap

Repeat for each of `dev`, `staging`, `production`.

### 1.1. Create the Terraform state bucket and lock table

The bootstrap module runs with **local state** to create the S3 + DynamoDB infrastructure that the main stack depends on.

```bash
cd providers/aws/bootstrap

terraform init

# For dev
terraform apply -var=environment=dev

# For staging
terraform apply -var=environment=staging

# For production
terraform apply -var=environment=production
```

After each apply, the output `backend_hcl` shows the contents of the corresponding `environments/<env>/backend.hcl` file. These files are pre-populated in this repo, but verify they match your bootstrap output.

The bootstrap state is local (`bootstrap/terraform.tfstate`). Back it up to your password manager or a private S3 bucket. Losing it is recoverable (resources can be re-imported), but inconvenient.

### 1.2. Set environment-specific variables

Edit `providers/aws/environments/<env>/terraform.tfvars`:

```hcl
domain    = "axiome.example.com"   # Your Route 53 hosted zone
subdomain = "dev"                   # dev → dev.axiome.example.com
                                    # staging → staging.axiome.example.com
                                    # production → "" (apex)
atlas_org_id = "<your-atlas-org-id>"  # From 0.5
```

Sensitive values (`atlas_org_id` is benign; the API keys are sensitive) flow through environment variables — never commit them.

### 1.3. Initialize Terraform with the remote backend

```bash
cd providers/aws

# For dev
make init ENV=dev

# Confirms: "Successfully configured the backend 's3'!"
```

### 1.4. Plan — review before apply

```bash
make plan ENV=dev
```

Expected resources for dev (~30):
- 1 Lightsail instance + 1 static IP
- 3 S3 buckets (versioning, encryption, public access block)
- 3 ECR repositories (production env only — dev/staging skip)
- 1 IAM user (Lightsail runtime) + access key + policy
- 1 IAM role (SSM) + policy
- 1 IAM role (ECR pull) + policy
- ~8 SSM parameters
- 1 Neon project + branch + role + database
- 1 Atlas project + cluster + DB user + IP allowlist
- 1 Route 53 record

### 1.5. Apply

```bash
make apply ENV=dev
```

Estimated duration: **3–8 minutes**.
- Lightsail instance: ~2 min
- Neon project: ~30 sec
- Atlas cluster: ~3 min (M0); ~7 min (M10)
- S3 / ECR / IAM / SSM: <30 sec total

The Lightsail VM begins running cloud-init when it boots. Cloud-init takes another **~3–5 minutes** to install Docker, fetch images from ECR, and start the stack.

### 1.6. Push initial images to ECR (first deployment only)

The first deployment requires images in ECR before Lightsail can pull them. Subsequent deployments are CI-driven.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-west-3
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Authenticate docker to ECR
aws ecr get-login-password --region $REGION \
    | docker login --username AWS --password-stdin $REGISTRY

# Build and push each service
cd ../axiome-back
docker build -t $REGISTRY/axiome/backend:latest .
docker push $REGISTRY/axiome/backend:latest

cd ../axiome-bio-compute
docker build -t $REGISTRY/axiome/biocompute:latest .
docker push $REGISTRY/axiome/biocompute:latest

cd ../axiome-front
docker build -t $REGISTRY/axiome/frontend:latest .
docker push $REGISTRY/axiome/frontend:latest
```

**Note:** ECR repositories are only created by the `production` environment apply. If you bootstrap `dev` first, run `make apply ENV=production` (or temporarily flip `create_repositories = true` for the first env) — the bootstrap order is documented separately.

### 1.7. Trigger the VM to pull updated images

After the first push, SSH into the Lightsail VM and re-run docker-compose:

```bash
# Get instance details
make ssh ENV=dev   # prints IP and username

# SSH (Lightsail uses key-based access; download the default key from console)
ssh ubuntu@<static_ip>

# On the VM
cd /opt/axiome
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
```

### 1.8. Run database migrations

```bash
# Pull the Neon connection string
DATABASE_URL=$(terraform output -raw neon_connection_string)

cd ../axiome-back
DATABASE_URL="$DATABASE_URL" npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

For Atlas, MongoDB collections are created lazily on first write; no migration step required initially. Indexes should be created idempotently in app startup or a one-shot script.

### 1.9. Verify

```bash
# DNS resolves
dig +short dev.axiome.example.com

# Health checks (allow ~60s for Caddy to issue cert)
curl -fsS https://dev.axiome.example.com/health
curl -fsS https://dev.axiome.example.com/ready

# Frontend loads
curl -fsS https://dev.axiome.example.com/
```

If TLS issuance fails, check Caddy logs: `ssh ubuntu@<ip> 'sudo docker compose -f /opt/axiome/docker-compose.yml logs caddy'`.

### 1.10. Verify cost telemetry

- AWS Cost Explorer → confirm tags `Project=axiome`, `Environment=dev` are applied
- Neon dashboard → confirm project usage shows free tier
- Atlas dashboard → confirm cluster is M0 (or expected tier)

---

## Per-environment summary

### Dev

```bash
cd providers/aws
make bootstrap ENV=dev          # one-time
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
# Push images to ECR (§1.6)
# Run migrations (§1.8)
# Verify (§1.9)
```

Expected cost: **~$12–13/month** (Lightsail + S3/SSM/ECR overhead; Neon and Atlas free).

### Staging

```bash
make bootstrap ENV=staging
make init ENV=staging
make plan ENV=staging
make apply ENV=staging
# Same image push + migrations
```

Expected cost: **~$12/month** if Neon/Atlas stay free; **~$30–40/month** with Neon Launch tier for production-shape testing.

### Production

```bash
make bootstrap ENV=production
make init ENV=production
make plan ENV=production
make apply ENV=production
# Image push uses :stable tag — promote from staging :latest after validation
```

Expected cost: **~$12/month** (Lightsail) + **~$60/month** (Atlas M10) + **~$19/month** (Neon Launch) = **~$91/month** for the production data path with managed-DB SLAs.

---

## Day-2 operations

### Update image tags (CI-driven)

CI updates `environments/<env>/images.tfvars` and runs `make apply ENV=<env>`. The Lightsail VM does not auto-pick-up new tags — a deploy script SSHes in and runs `docker compose pull && up -d`.

For now (until CI is wired):

```bash
# After pushing new images to ECR
ssh ubuntu@<lightsail-ip>
cd /opt/axiome
sudo docker compose pull
sudo docker compose up -d
```

### Rotate the Lightsail runtime IAM access key

```bash
cd providers/aws
terraform apply -replace='module.compute.aws_iam_access_key.lightsail_runtime' \
    -var-file=environments/dev/terraform.tfvars \
    -var-file=environments/dev/images.tfvars
```

The replace causes a new key to be generated and re-injected via cloud-init. **Cloud-init only runs on first boot**, so for an existing instance you must SSH in and update `/root/.aws/credentials` manually (or recreate the instance with `-replace=module.compute.aws_lightsail_instance.main`).

### Rebuild the VM from scratch (DR drill)

```bash
make destroy ENV=dev
make apply ENV=dev
# Push images, run migrations, verify
```

State (Postgres data, Mongo data, S3 objects) is unaffected because it lives in Neon/Atlas/S3, not on the VM. Total elapsed: **~10–15 min** including image push.

**Run this drill quarterly per [graduation-criteria.md](../../docs/graduation-criteria.md) §5.5.**

### Change Lightsail bundle (vertical scale)

Update `lightsail_bundle_id` in tfvars (e.g., `large_arm_3_0` for 8 GB / 2 vCPU at $24/mo) and run `make apply`. Lightsail rebuilds the instance — **expect ~2 min downtime** and re-run cloud-init from scratch.

### Tear down

```bash
make destroy ENV=dev
```

⚠️ This deletes the Lightsail VM, S3 buckets (with versioned data), Neon project, Atlas cluster, and all SSM parameters. Backups should be taken first if any data matters.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init` fails on backend | State bucket not created | Run `make bootstrap ENV=<env>` first |
| Cloud-init hangs / VM not responding | First boot is slow | Wait 5 min; check `/var/log/axiome-init.log` via SSH |
| Caddy fails to fetch cert | DNS not propagated to Lightsail IP | Wait for DNS TTL; check `dig <fqdn>` |
| `docker pull` fails on VM | ECR token expired (12h) | `/etc/cron.hourly/ecr-relogin` runs hourly; re-run manually if needed |
| Neon connection refused | Neon free tier autosuspend | First request takes ~1–2s to wake; subsequent requests fast |
| Atlas connection timeout | IP allowlist | Atlas allows `0.0.0.0/0` in this stack; tighten for production via `mongodbatlas_project_ip_access_list` |
| OOM kills | 4 GB Lightsail too small | Either upgrade bundle (`large_arm_3_0`) or tighten container `mem_limit` in docker-compose |
| Apply fails on `aws_iam_access_key` | Race condition (rare) | Re-run `terraform apply` |

---

## What's next

After all three environments are running:

1. **Wire CI/CD** to build and push images, then trigger deploys (covered in [ci-cd.md](../../docs/ci-cd.md))
2. **Configure quarterly DR drill** (cron or calendar) to rebuild dev from scratch
3. **Install external uptime monitor** (UptimeRobot, BetterStack) on production endpoint
4. **Track signals** in [graduation-criteria.md](../../docs/graduation-criteria.md) for production graduation to Phase 2 (Fargate)
