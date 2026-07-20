# AWS Provider — Bootstrap Guide

Complete Day-0 bootstrap for the AWS provider variant: Lightsail compute + Neon Postgres + in-region MongoDB + S3 + ECR. DNS is managed manually in Microsoft 365 (see §0.4); Route 53 is **not** used in the default setup.

This guide is run **once per AWS account, then once per environment**. Subsequent operations use the Makefile targets.

---

## Architecture summary

| Layer | Service | Per-env cost (Phase 1) |
|---|---|---|
| Compute | AWS Lightsail (single VM, x86; 2 GB `small_3_0` for dev/staging, 4 GB `medium_3_0` for prod — eu-west-3 has no ARM bundles) running docker-compose | ~$12–24/mo |
| Postgres | Neon (free for dev, Launch+ for staging/prod) | $0–$19/mo |
| MongoDB | Self-hosted container on the same VM (in-region, daily `mongodump` → S3 — see [restore-procedures.md](docs/restore-procedures.md)) | included in compute |
| Object storage | S3 (3 buckets per env: artifacts, uploads, system) | <$1/mo |
| Container registry | ECR (account-shared across envs) | <$1/mo |
| TLS / Reverse proxy | Caddy + Let's Encrypt (on the VM) | $0 |
| DNS | Microsoft 365 (manual A records pointing at Lightsail static IPs — see §0.4) | included with domain |
| Secrets / config | SSM Parameter Store | $0 |
| Logs (FR9) | CloudWatch Logs — group `/axiome/<env>/ec2`, CMK-encrypted, `eu-west-3` only (EC2/HDS path) | ~$0.50/GB ingested |

**Logs:** on the EC2/HDS compute path the `amazon-cloudwatch-agent` ships container
stdout/stderr (json-file — `docker compose logs` still works) plus
`/var/log/axiome-init.log` and `docker-prune.log` to CloudWatch Logs group
`/axiome/<env>/ec2`. The group is encrypted with a dedicated CMK and stays in-region.
Retention defaults to 30 days (`compute-ec2` `log_retention_days`). Streams:
`<instance-id>/containers`, `<instance-id>/axiome-init`, `<instance-id>/docker-prune`.
Query in **CloudWatch → Logs Insights**. The legacy Lightsail path has no CloudWatch sink.

**Three environments**: `dev`, `staging`, `production` — each is one Lightsail VM (running its own in-region Mongo container), one Neon project, three S3 buckets, one A record at Microsoft 365. They share one ECR registry at the AWS-account level. DNS is managed manually in Microsoft 365 (see §0.4); no shared Route 53 zone.

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

### 0.4. DNS — Microsoft 365 (current setup)

The domain is registered and managed at **Microsoft 365**. DNS records are created **manually in the Microsoft 365 control panel** pointing at the Lightsail static IPs that Terraform provisions. We do **not** use Route 53 in this setup.

> **Terraform note:** the `providers/aws/modules/dns` module is gated on `var.use_route53` (default **false**). With the default, Terraform does **not** touch Route 53 and `make apply` will not look up a hosted zone — it only provisions the Lightsail static IP, which you then point to manually in Microsoft 365. To switch back to Route 53 management later, pre-create a hosted zone for `var.domain` and set `use_route53 = true` in the env's `terraform.tfvars`.

#### 0.4.1. Required DNS records (recovery reference)

After `make apply` completes for an environment, retrieve the static IP and add the corresponding A record(s) in Microsoft 365.

| Environment | FQDN | Record type | Value | TTL |
|---|---|---|---|---|
| dev | `dev.axiomebio.com` | A | `<lightsail-static-ip-dev>` | 300 |
| staging | `staging.axiomebio.com` | A | `<lightsail-static-ip-staging>` | 300 |
| production | `platform.axiomebio.com` | A | `<lightsail-static-ip-prod>` | 300 |

The apex `axiomebio.com` is the marketing landing page and is **not** managed by this Terraform stack — leave its existing A/CNAME records in Microsoft 365 untouched.

#### 0.4.2. How to retrieve the static IP from Terraform

```bash
cd providers/aws
terraform output -raw lightsail_static_ip   # for the currently-init'd env
# or, per-env without switching backends:
make output ENV=dev   | grep static_ip
make output ENV=staging | grep static_ip
make output ENV=prod  | grep static_ip
```

#### 0.4.3. How to configure in Microsoft 365

1. Log in to Microsoft 365 → **Domains** → select the base domain → **DNS / Nameservers**.
2. Confirm Microsoft 365's default nameservers are active (NOT delegated to Route 53). If they were ever pointed elsewhere, restore them from Microsoft 365's panel.
3. Add or update the A records from the table above. For the production apex, edit the existing `@` record; for subdomains, create a new A record with the env name as the host.
4. Save. Propagation: typically ~5 min on Microsoft 365, but TLS issuance via Caddy may need up to ~10 min after DNS resolves.
5. Verify:
   ```bash
   dig +short dev.axiomebio.com   # should return the Lightsail IP
   curl -fsS https://dev.axiomebio.com/health
   ```

#### 0.4.4. Recovery procedure (if DNS records are lost or domain is migrated)

If the Microsoft 365 DNS configuration is wiped or the domain is moved between Microsoft 365 accounts:

1. Confirm the Lightsail VMs are still running and have their static IPs:
   ```bash
   aws lightsail get-static-ips --region eu-west-3 \
     --query 'staticIps[].{Name:name,IP:ipAddress,AttachedTo:attachedTo}' --output table
   ```
2. For each env, recreate the A record per the table in §0.4.1 using the IPs from step 1.
3. If the domain itself was moved, also re-verify ownership / re-enable email forwarding / etc. from Microsoft 365's domain page.
4. Wait for propagation, then re-run the verification curls in [§1.9](#19-verify).

**No data is at risk during DNS recovery** — Postgres lives in Neon, blobs in S3, and MongoDB's docker volume survives on the running VM (backed up nightly to S3 regardless — see [restore-procedures.md](docs/restore-procedures.md)). Only the public name → IP mapping is being restored.

### 0.5. Create a Neon account (one-time)

#### Neon

1. Sign up at https://console.neon.tech
2. Generate an API key: **Account settings → API keys → Generate**
3. Save the key.

```bash
export NEON_API_KEY="<your-neon-api-key>"
```

MongoDB needs no account setup — it runs as an in-region container on the same
VM (`modules/secrets` generates its root password; no external service).

#### Mailjet (transactional email)

Powers the user-service `EmailService` (welcome, password reset, export, and
sponsor-publish emails). Optional — if the keys are absent, Terraform skips the
SSM parameters and the service logs links instead of sending.

1. Sign up at https://app.mailjet.com and open **Account → API Key Management**.
2. Save the **API Key** and **Secret Key**.
3. Verify the sender address you intend to send from (**Account → Senders & Domains**).
   It must match `mailjet_from_email` (default `contact@axiomebio.com`), or Mailjet
   rejects the send.

```bash
export TF_VAR_mailjet_api_key="<api-key>"
export TF_VAR_mailjet_secret_key="<secret-key>"
```

In CI these come from the `MAILJET_API_KEY` / `MAILJET_SECRET_KEY` GitHub secrets
(see [docs/secrets.md](../../docs/secrets.md)); the `export-deploy-credentials`
action re-exports them as the `TF_VAR_*` above. The secrets module then writes
them to SSM (`MAILJET_API_KEY`, `MAILJET_SECRET_KEY`) along with `MAILJET_FROM_EMAIL`,
`MAILJET_FROM_NAME`, and `FRONTEND_URL` (derived from the env's `fqdn`), all of
which land in `/opt/axiome/.env` at boot. Override the From identity per env with
`-var mailjet_from_email=...` / `-var mailjet_from_name=...` if needed.

### 0.6. Scope down Terraform IAM (recommended after first apply)

After the first successful `terraform apply`, replace the AdministratorAccess policy on `axiome-terraform` with the least-privilege set covering only the resources Terraform manages (Lightsail, S3, IAM, ECR, SSM, DynamoDB — plus Route 53 only if you flip `use_route53 = true`; the default Microsoft 365 setup does not need it). This is the standard production-hygiene step. A policy template is at [docs/iam-terraform-policy.json](../../docs/iam-terraform-policy.json) (create separately as the policy stabilizes).

---

## Phase 1 — Per-environment bootstrap

Repeat for each of `dev`, `staging`, `production`.

### 1.1. Create the Terraform state bucket and lock table

The bootstrap module runs with **local state** to create the S3 + DynamoDB infrastructure that the main stack depends on. It provisions one bucket + lock table per entry in `var.environments` (default: `dev`, `staging`, `production`, `shared`) in a single `for_each`-keyed apply — re-applying is idempotent and never touches another environment's bucket.

```bash
cd providers/aws/bootstrap

terraform init

# Creates/reconciles all of var.environments (idempotent — safe to re-run)
terraform apply

# To bootstrap just one new entry without touching the others already applied
# (e.g. adding "shared" to an account that already has dev/staging/production):
terraform apply -var='environments=["shared"]'
```

After apply, the outputs `state_buckets` / `lock_tables` show the bucket/table per environment — they should match the corresponding `environments/<env>/backend.hcl` file. These files are pre-populated in this repo, but verify they match your bootstrap output.

`shared` holds account-shared resources (today: ECR — see §1.4a) owned by no single per-environment state, so a stray dev/staging apply or destroy can never touch them (FR8/AC8).

The bootstrap state is local (`bootstrap/terraform.tfstate`). Back it up to your password manager or a private S3 bucket. Losing it is recoverable (resources can be re-imported), but inconvenient.

### 1.2. Set environment-specific variables

Edit `providers/aws/environments/<env>/terraform.tfvars`:

```hcl
domain    = "axiomebio.com"   # Your base domain registered at Microsoft 365
subdomain = "dev"                   # dev → dev.axiomebio.com
                                    # staging → staging.axiomebio.com
                                    # production → "" (apex)
# use_route53 = false               # default; leave unset for Microsoft 365 DNS
```

Sensitive values (the Neon API key) flow through environment variables — never commit them.

After `make apply` completes, retrieve the Lightsail static IP and add the matching A record(s) in the Microsoft 365 DNS panel — see [§0.4.1](#041-required-dns-records-recovery-reference) for the table and [§0.4.3](#043-how-to-configure-in-hostinger) for the click-path.

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

Expected resources for dev (~26):
- 1 Lightsail instance + 1 static IP
- 3 S3 buckets (versioning, encryption, public access block)
- 1 IAM user (Lightsail runtime) + access key + policy
- 1 IAM role (SSM) + policy
- ~8 SSM parameters
- 1 Neon project + branch + role + database
- *(MongoDB: no separate resource — runs as a container on the Lightsail VM, provisioned by cloud-init)*
- *(DNS: configured manually in Microsoft 365 after apply — see §0.4)*

### 1.4a. One-time: apply the shared registry state

ECR repositories are account-shared across dev/staging/production and live in
their own `../shared` root/state (FR8/AC8), not in any per-environment apply.
Run this **once per AWS account**, before the first `make apply` for any
environment (every environment's plan reads the registry URL / pull role from
this state via `terraform_remote_state`):

```bash
cd providers/aws/shared
terraform init -backend-config=../environments/shared/backend.hcl
terraform apply -var-file=../environments/shared/terraform.tfvars
```

### 1.5. Apply

```bash
make apply ENV=dev
```

Estimated duration: **3–8 minutes**.
- Lightsail instance: ~2 min
- Neon project: ~30 sec
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

**Note:** ECR repositories are created once by `../shared` (§1.4a), not by any per-environment apply — every environment just reads the registry URL via remote state.

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

For the in-region Mongo container, collections are created lazily on first write; no migration step required initially. Indexes should be created idempotently in app startup or a one-shot script.

### 1.9. Verify

```bash
# DNS resolves
dig +short dev.axiomebio.com

# Health checks (allow ~60s for Caddy to issue cert)
curl -fsS https://dev.axiomebio.com/health
curl -fsS https://dev.axiomebio.com/ready

# Frontend loads
curl -fsS https://dev.axiomebio.com/
```

If TLS issuance fails, check Caddy logs: `ssh ubuntu@<ip> 'sudo docker compose -f /opt/axiome/docker-compose.yml logs caddy'`.

### 1.10. Verify cost telemetry

- AWS Cost Explorer → confirm tags `Project=axiome`, `Environment=dev` are applied
- Neon dashboard → confirm project usage shows free tier
- `ssh ubuntu@<ip> 'sudo docker compose -f /opt/axiome/docker-compose.yml ps mongo'` → confirm the Mongo container is healthy

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

Expected cost: **~$12–13/month** (Lightsail, which also hosts Mongo, + S3/SSM/ECR overhead; Neon free).

### Staging

```bash
make bootstrap ENV=staging
make init ENV=staging
make plan ENV=staging
make apply ENV=staging
# Same image push + migrations
```

Expected cost: **~$12/month** if Neon stays free; **~$30–40/month** with Neon Launch tier for production-shape testing.

### Production

```bash
make bootstrap ENV=production
make init ENV=production
make plan ENV=production
make apply ENV=production
# Image push uses :stable tag — promote from staging :latest after validation
```

Expected cost: **~$12/month** (Lightsail, hosting Mongo) + **~$19/month** (Neon Launch) = **~$31/month** for the production data path.

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
# Restore Mongo from the latest S3 backup (see docs/restore-procedures.md) —
# destroying the VM destroys its docker volume, and Mongo data lives there.
# Push images, run migrations, verify
```

Postgres data and S3 objects are unaffected because they live in Neon/S3, not on the VM. **Mongo data does NOT survive this** — it lives on the VM's docker volume and must be restored from the latest `mongodump` backup in the `system` S3 bucket (`backups/mongo/`, see [restore-procedures.md](docs/restore-procedures.md)) after the new VM boots. Total elapsed: **~10–15 min** including image push, plus Mongo restore time.

**Run this drill quarterly per [graduation-criteria.md](../../docs/graduation-criteria.md) §5.5.**

### Change Lightsail bundle (vertical scale)

Update `lightsail_bundle_id` in tfvars (e.g., `medium_3_0` for 4 GB / 2 vCPU at $24/mo, or `large_3_0` for 8 GB / 2 vCPU at $44/mo in eu-west-3) and run `make apply`. Lightsail rebuilds the instance — **expect ~2 min downtime** and re-run cloud-init from scratch. Run `aws lightsail get-bundles --region <region>` to see what's available before changing.

### Tear down

```bash
make destroy ENV=dev
```

⚠️ This deletes the Lightsail VM (and its Mongo docker volume — take a fresh `mongodump` first if the automatic nightly backup isn't recent enough), S3 buckets (with versioned data), Neon project, and all SSM parameters. Backups should be taken first if any data matters.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init` fails on backend | State bucket not created | Run `make bootstrap ENV=<env>` first |
| Cloud-init hangs / VM not responding | First boot is slow | Wait 5 min; check `/var/log/axiome-init.log` via SSH |
| Caddy fails to fetch cert | DNS not propagated to Lightsail IP | Wait for DNS TTL; check `dig <fqdn>` |
| `docker pull` fails on VM | ECR token expired (12h) | `/etc/cron.hourly/ecr-relogin` runs hourly; re-run manually if needed |
| Neon connection refused | Neon free tier autosuspend | First request takes ~1–2s to wake; subsequent requests fast |
| Mongo connection refused | Container not up yet / crashed | `ssh ubuntu@<ip> 'sudo docker compose -f /opt/axiome/docker-compose.yml logs mongo'` |
| OOM kills | Lightsail bundle too small (2 GB on small_3_0 is tight for 4 services) | Upgrade bundle (`medium_3_0` → 4 GB, `large_3_0` → 8 GB) or tighten container `mem_limit` in docker-compose |
| Apply fails on `aws_iam_access_key` | Race condition (rare) | Re-run `terraform apply` |

---

## What's next

After all three environments are running:

1. **Wire CI/CD** to build and push images, then trigger deploys (covered in [ci-cd.md](../../docs/ci-cd.md))
2. **Configure quarterly DR drill** (cron or calendar) to rebuild dev from scratch
3. **Install external uptime monitor** (UptimeRobot, BetterStack) on production endpoint
4. **Track signals** in [graduation-criteria.md](../../docs/graduation-criteria.md) for production graduation to Phase 2 (Fargate)
