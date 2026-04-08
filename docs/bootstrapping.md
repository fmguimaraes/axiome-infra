# Bootstrapping Guide

Step-by-step instructions to bootstrap the Axiome platform from scratch on each target: local development, Scaleway (primary cloud), and AWS (portable).

---

## Prerequisites (All Targets)

| Tool | Version | Purpose |
|------|---------|---------|
| Git | >= 2.30 | Source control |
| Terraform | >= 1.5 | Infrastructure provisioning |
| Docker | >= 24.0 | Container runtime |
| Docker Compose | >= 2.20 | Local development stack |
| Node.js | 20 LTS | Backend and frontend |
| Python | 3.12 | Biocompute service |
| Make | any | Operational shortcuts |

### Install tools

```bash
# Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip -o tf.zip \
  && unzip tf.zip -d /usr/local/bin && rm tf.zip

# Docker (Ubuntu/Debian)
curl -fsSL https://get.docker.com | sh

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs

# Python 3.12
sudo apt-get install -y python3.12 python3.12-venv
```

---

## 1. Local Development Bootstrap

Time estimate: ~15 minutes from clone to running stack.

### 1.1. Clone repositories

All repositories must be siblings in the same parent directory:

```bash
mkdir -p ~/dev/axiome && cd ~/dev/axiome

git clone git@github.com:<org>/axiome-infra.git
git clone git@github.com:<org>/axiome-back.git
git clone git@github.com:<org>/axiome-front.git
git clone git@github.com:<org>/axiome-biocompute.git
```

Expected directory layout:

```
~/dev/axiome/
├── axiome-infra/          # Infrastructure (you are here)
├── axiome-back/           # Backend (NestJS)
├── axiome-front/          # Frontend (React/Vite)
└── axiome-biocompute/     # Biocompute (Python/FastAPI)
```

### 1.2. Configure local environment

```bash
cd axiome-infra
cp .env.example .env.local
```

The defaults in `.env.example` work out of the box. Edit `.env.local` only if you need to change ports or credentials.

### 1.3. Start the stack

```bash
make local-up
```

This starts all services via docker-compose:

| Service | URL | Notes |
|---------|-----|-------|
| Frontend | http://localhost:5173 | Vite dev server with hot reload |
| Backend API | http://localhost:3000 | NestJS with hot reload |
| Backend health | http://localhost:3000/health | Health check endpoint |
| Biocompute API | http://localhost:8000 | FastAPI with hot reload |
| Biocompute health | http://localhost:8000/health | Health check endpoint |
| MinIO Console | http://localhost:9001 | S3 admin UI (minioadmin/minioadmin) |
| Postgres | localhost:5432 | axiome/axiome_local_dev |
| MongoDB | localhost:27017 | axiome/axiome_local_dev |

### 1.4. Verify

```bash
# Check all containers are running
docker compose ps

# Check health endpoints
curl http://localhost:3000/health
curl http://localhost:8000/health

# Check MinIO buckets were created
curl http://localhost:9000/minio/health/live
```

### 1.5. Run database migrations

```bash
cd ../axiome-back
npm run migration:run
```

### 1.6. Daily operations

```bash
cd axiome-infra

make local-up        # Start all services
make local-down      # Stop all services
make local-restart   # Restart all services
make local-logs      # Tail logs from all services
```

### 1.7. Resetting local data

```bash
# Stop and remove all data volumes
docker compose down -v

# Restart fresh
make local-up
```

---

## 2. Scaleway Cloud Bootstrap

Scaleway is the primary cloud provider. All shared environments (dev, staging, production) follow this procedure.

### 2.1. Account setup

1. Create a Scaleway account at https://console.scaleway.com
2. Create a Project named `axiome`
3. Generate an API key:
   - Console → IAM → API Keys → Generate API Key
   - Save the **Access Key** and **Secret Key**
4. Select region: **fr-par** (Paris, EU)

### 2.2. Install Scaleway CLI

```bash
curl -s https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
scw init
```

Enter your Access Key, Secret Key, default organization, and default project when prompted.

### 2.3. Create Terraform state bucket

Terraform needs a remote state bucket before the first `init`. Create it manually (one-time per environment):

```bash
# For dev
scw object bucket create name=axiome-dev-terraform-state region=fr-par

# For staging
scw object bucket create name=axiome-staging-terraform-state region=fr-par

# For production
scw object bucket create name=axiome-production-terraform-state region=fr-par
```

### 2.4. Configure provider credentials

Export Scaleway credentials for Terraform:

```bash
export SCW_ACCESS_KEY="<your-access-key>"
export SCW_SECRET_KEY="<your-secret-key>"

# Terraform S3 backend also needs these as AWS-compatible vars
export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
```

Add these to your shell profile (`~/.bashrc` or `~/.zshrc`) or use a secrets manager.

### 2.5. Initialize Terraform

```bash
cd axiome-infra

# Initialize for the target environment
make init ENV=dev        # or staging, production
```

### 2.6. Review and apply infrastructure

```bash
# Preview what will be created
make plan ENV=dev

# Apply (creates all resources)
make apply ENV=dev
```

Terraform will provision:
- Private network
- Container registry
- Postgres managed database
- MongoDB managed instance
- Object storage buckets (artifacts, uploads, system, frontend)
- Serverless container namespaces (backend, biocompute)
- Scaleway Secret Manager entries

### 2.7. Note output values

After `apply`, Terraform outputs important values:

```bash
terraform output
```

Record these values — they are needed for GitHub Actions secrets:
- `backend_endpoint` — Backend public URL
- `biocompute_private_endpoint` — Biocompute internal URL
- `frontend_url` — Frontend static hosting URL
- `registry_endpoint` — Container registry URL
- `postgres_host` — Database host (sensitive)

### 2.8. Configure GitHub Actions secrets

Go to the axiome-infra GitHub repository → Settings → Secrets and variables → Actions.

Create an environment (dev, staging, or production) and add these secrets:

| Secret | Value | Source |
|--------|-------|--------|
| `SCW_ACCESS_KEY` | Scaleway API access key | Step 2.1 |
| `SCW_SECRET_KEY` | Scaleway API secret key | Step 2.1 |
| `SCW_REGISTRY_ENDPOINT` | `terraform output registry_endpoint` | Step 2.7 |
| `SCW_BACKEND_CONTAINER_ID` | `terraform output backend_container_id` | Step 2.7 |
| `SCW_BIOCOMPUTE_CONTAINER_ID` | `terraform output biocompute_container_id` | Step 2.7 |
| `BACKEND_URL` | `terraform output backend_endpoint` | Step 2.7 |
| `BIOCOMPUTE_URL` | `terraform output biocompute_private_endpoint` | Step 2.7 |
| `DATABASE_URL` | Postgres connection string | Scaleway console |
| `GH_PAT` | GitHub personal access token | GitHub settings |

### 2.9. Build and push initial images

For the first deployment, manually build and push images:

```bash
# Login to Scaleway registry
echo "$SCW_SECRET_KEY" | docker login "$(terraform output -raw registry_endpoint)" -u nologin --password-stdin

REGISTRY=$(terraform output -raw registry_endpoint)

# Build and push backend
cd ../axiome-back
docker build -t "$REGISTRY/backend:initial" .
docker push "$REGISTRY/backend:initial"

# Build and push biocompute
cd ../axiome-biocompute
docker build -t "$REGISTRY/biocompute:initial" .
docker push "$REGISTRY/biocompute:initial"

# Build and deploy frontend
cd ../axiome-front
npm ci && npm run build
pip install awscli
aws s3 sync dist/ s3://axiome-dev-frontend/ \
  --endpoint-url https://s3.fr-par.scw.cloud --delete
```

### 2.10. Deploy initial containers

```bash
cd ../axiome-infra
REGISTRY=$(terraform output -raw registry_endpoint)

scw container container update \
  $(terraform output -raw backend_container_id) \
  registry-image="$REGISTRY/backend:initial" \
  redeploy=true

scw container container update \
  $(terraform output -raw biocompute_container_id) \
  registry-image="$REGISTRY/biocompute:initial" \
  redeploy=true
```

### 2.11. Run database migrations

```bash
cd ../axiome-back
DATABASE_URL="<postgres-connection-string-from-scaleway>" npm run migration:run
```

### 2.12. Verify deployment

```bash
curl https://<backend-endpoint>/health
# Expected: 200 OK
```

### 2.13. Repeat for other environments

Repeat steps 2.5 through 2.12 for staging and production, using the appropriate `ENV` value and separate GitHub Actions environments.

---

## 3. AWS Cloud Bootstrap

AWS is the secondary provider for portability. The module interface is the same, but the underlying resources differ.

### 3.1. Account setup

1. Create an AWS account or use an existing one
2. Create an IAM user with programmatic access:
   - Permissions: `AdministratorAccess` (scope down later)
   - Save the **Access Key ID** and **Secret Access Key**
3. Select region: **eu-west-3** (Paris, EU)

### 3.2. Install AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

aws configure
# Enter: Access Key ID, Secret Access Key, region: eu-west-3, output: json
```

### 3.3. Create Terraform state bucket

```bash
aws s3 mb s3://axiome-dev-terraform-state --region eu-west-3
aws s3api put-bucket-versioning \
  --bucket axiome-dev-terraform-state \
  --versioning-configuration Status=Enabled
```

### 3.4. Create AWS provider modules

AWS modules must implement the same interface as the Scaleway modules. Create them in `providers/aws/`:

```
providers/aws/
├── network/       # AWS VPC + subnets + security groups
├── compute/       # ECS Fargate tasks + services
├── database/      # RDS PostgreSQL + DocumentDB
├── storage/       # S3 buckets
├── registry/      # ECR repositories
└── secrets/       # AWS Secrets Manager
```

Each module must expose the same variables and outputs as its Scaleway counterpart. See [providers.md](providers.md) for the service mapping table.

### 3.5. Update Terraform configuration

```bash
# 1. Update versions.tf — add AWS provider
cat > versions.tf <<'EOF'
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
EOF

# 2. Update main.tf — change module sources
# Replace: source = "./modules/<module>"
# With:    source = "./providers/aws/<module>"

# 3. Create AWS-specific tfvars
cp environments/dev/terraform.tfvars environments/dev/terraform.tfvars.aws
```

### 3.6. Update environment variables for AWS

Edit `environments/dev/terraform.tfvars.aws`:

```hcl
environment   = "dev"
provider_name = "aws"
region        = "eu-west-3"
zone          = "eu-west-3a"
project_name  = "axiome"

# AWS-specific node types
postgres_node_type = "db.t3.micro"
mongodb_node_type  = "db.t3.medium"

# Compute (ECS Fargate)
backend_cpu_limit      = 256    # vCPU units (256 = 0.25 vCPU)
backend_memory_limit   = 512    # MB
biocompute_cpu_limit   = 1024   # vCPU units (1024 = 1 vCPU)
biocompute_memory_limit = 2048  # MB
```

### 3.7. Update backend configuration

Create `environments/dev/backend.hcl.aws`:

```hcl
bucket         = "axiome-dev-terraform-state"
key            = "infrastructure/terraform.tfstate"
region         = "eu-west-3"
encrypt        = true
dynamodb_table = "axiome-dev-terraform-lock"
```

Create a DynamoDB table for state locking:

```bash
aws dynamodb create-table \
  --table-name axiome-dev-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-3
```

### 3.8. Initialize and apply

```bash
export AWS_ACCESS_KEY_ID="<your-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret>"

terraform init -backend-config=environments/dev/backend.hcl.aws
terraform plan -var-file=environments/dev/terraform.tfvars.aws
terraform apply -var-file=environments/dev/terraform.tfvars.aws
```

### 3.9. Known differences from Scaleway

| Concern | Scaleway | AWS |
|---------|----------|-----|
| Container deployment | Serverless Containers (simple, built-in) | ECS Fargate (requires task definitions, services, ALB) |
| MongoDB | Managed MongoDB (native) | DocumentDB (partial compatibility) or self-hosted on ECS |
| Networking | Private Network (flat, simple) | VPC + subnets + route tables + NAT gateway |
| Object storage | Object Storage (S3-compatible, same API) | S3 (native) |
| Registry | Container Registry | ECR |
| Secrets | Secret Manager | Secrets Manager |
| Cold start | ~1-3s for serverless containers | ~5-30s for Fargate tasks |
| Region | fr-par | eu-west-3 |

### 3.10. CI/CD for AWS

Update GitHub Actions workflows:
- Replace `scw` CLI commands with `aws` CLI equivalents
- Use `aws ecs update-service --force-new-deployment` instead of `scw container container update`
- Push images to ECR instead of Scaleway Registry
- Update S3 sync endpoint (no `--endpoint-url` needed for native AWS S3)

---

## 4. Post-Bootstrap Checklist

After bootstrapping any environment, verify:

- [ ] All services are running and healthy
- [ ] Backend `/health` returns 200
- [ ] Biocompute `/health` returns 200
- [ ] Frontend loads in browser
- [ ] Database migrations have been applied
- [ ] Object storage buckets exist with correct naming
- [ ] Secrets are injected (not hardcoded)
- [ ] No plaintext secrets in the repository
- [ ] GitHub Actions secrets are configured (cloud only)
- [ ] Terraform state is stored remotely (cloud only)
- [ ] Environment is isolated from other environments (cloud only)

## 5. Teardown

### Local

```bash
make local-down       # Stop services, keep data
docker compose down -v  # Stop services and delete all data
```

### Scaleway / AWS

```bash
# Preview what will be destroyed
make plan ENV=dev

# Destroy all resources (irreversible)
make destroy ENV=dev
```

**Warning**: `destroy` deletes all databases, storage, and services in the target environment. Data is not recoverable unless backups were taken. Never run against production without explicit authorization.
