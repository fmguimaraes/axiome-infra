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
| Python | 3.11 | Biocompute service |
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

# Python 3.11
sudo apt-get install -y python3.11 python3.11-venv
```

---

## 1. Local Development Bootstrap

### 1.1. Clone repositories

All repositories must be siblings in the same parent directory:

```bash
mkdir -p ~/dev/axiome && cd ~/dev/axiome

git clone git@github.com:<org>/axiome-infra.git
git clone git@github.com:<org>/axiome-back.git
git clone git@github.com:<org>/axiome-front.git
git clone git@github.com:<org>/axiome-bio-compute.git
```

Expected directory layout:

```
~/dev/axiome/
├── axiome-infra/          # Infrastructure (you are here)
├── axiome-back/           # Backend (NestJS)
├── axiome-front/          # Frontend (React/Vite)
└── axiome-bio-compute/    # Biocompute (Python/FastAPI)
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
npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
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

## 2. Cloud Bootstrap (Scaleway or AWS)

The infrastructure and CI/CD pipeline are provider-agnostic. The same Terraform modules, bash scripts, and GitHub Actions workflows work on both Scaleway and AWS. Provider-specific logic is isolated behind a `REGISTRY_PROVIDER` secret and `case` branching in the reusable workflow and deploy scripts.

### 2.1. Provider-specific account setup

<details>
<summary><strong>Scaleway</strong></summary>

1. Create a Scaleway account at https://console.scaleway.com
2. Create a Project named `axiome`
3. Generate an API key: Console → IAM → API Keys → Generate API Key
4. Save the **Access Key** and **Secret Key**
5. Region: **fr-par** (Paris, EU)

```bash
# Install CLI
curl -s https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
scw init
```

```bash
# Create Terraform state buckets (one-time per environment)
scw object bucket create name=axiome-dev-terraform-state region=fr-par
scw object bucket create name=axiome-staging-terraform-state region=fr-par
scw object bucket create name=axiome-production-terraform-state region=fr-par
```

Export credentials:

```bash
export SCW_ACCESS_KEY="<your-access-key>"
export SCW_SECRET_KEY="<your-secret-key>"
export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
```

</details>

<details>
<summary><strong>AWS</strong></summary>

1. Create an AWS account or use an existing one
2. Create an IAM user with programmatic access (scope down from AdministratorAccess later)
3. Save the **Access Key ID** and **Secret Access Key**
4. Region: **eu-west-3** (Paris, EU)

```bash
# Install CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws configure  # Enter key, secret, region: eu-west-3, output: json
```

```bash
# Create Terraform state bucket + DynamoDB lock table
aws s3 mb s3://axiome-dev-terraform-state --region eu-west-3
aws s3api put-bucket-versioning \
  --bucket axiome-dev-terraform-state \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name axiome-dev-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-3
```

Export credentials:

```bash
export AWS_ACCESS_KEY_ID="<your-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret>"
```

</details>

### 2.2. Initialize and apply Terraform

```bash
cd axiome-infra

# Initialize for the target environment
terraform init -backend-config=environments/dev/backend.hcl -reconfigure

# Preview
terraform plan -var-file=environments/dev/terraform.tfvars

# Apply
terraform apply -var-file=environments/dev/terraform.tfvars
```

Or use the deploy script:

```bash
bash scripts/deploy.sh dev --plan-only   # Preview
bash scripts/deploy.sh dev               # Apply
```

Terraform provisions: private network, container registry, Postgres, MongoDB, object storage, serverless containers, and secrets management.

### 2.3. Note output values

```bash
terraform output
```

Record: `registry_endpoint`, `backend_endpoint`, `biocompute_private_endpoint`, `frontend_url`, `postgres_host`.

### 2.4. Configure GitHub secrets

Secrets must be configured at **two levels**:

#### Repository-level secrets (on each service repo AND axiome-infra)

| Secret | Scaleway | AWS |
|--------|----------|-----|
| `REGISTRY_PROVIDER` | `scaleway` | `aws` |
| `GH_PAT` | GitHub PAT with `repo` scope | same |
| `SCW_REGISTRY_ENDPOINT` | Registry URL from terraform output | — |
| `SCW_SECRET_KEY` | Scaleway secret key | — |
| `SCW_ACCESS_KEY` | Scaleway access key | — |
| `AWS_ACCOUNT_ID` | — | AWS account ID |
| `AWS_REGION` | — | e.g. `eu-west-3` |
| `AWS_ACCESS_KEY_ID` | — | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | — | IAM secret key |

#### Per-environment secrets (on axiome-infra, per GitHub environment: dev/staging/production)

| Secret | Description |
|--------|-------------|
| `DATABASE_URL` | Postgres connection string |
| `BACKEND_URL` | Backend base URL (for health checks) |
| `BIOCOMPUTE_URL` | Biocompute base URL (for health checks) |
| `FRONTEND_URL` | Frontend URL (for health checks) |

### 2.5. Enable reusable workflow access

For the service repos to call the reusable build workflow in axiome-infra:

**axiome-infra → Settings → Actions → General → Access → "Accessible from repositories owned by the user"**

### 2.6. Build and push initial images

For the first deployment, manually build and push images before CI takes over:

```bash
REGISTRY=$(terraform output -raw registry_endpoint)

# Login (Scaleway example — for AWS use: aws ecr get-login-password | docker login ...)
echo "$SCW_SECRET_KEY" | docker login "$REGISTRY" -u nologin --password-stdin

# Build and push each service
cd ../axiome-back
docker build -t "$REGISTRY/backend:initial" .
docker push "$REGISTRY/backend:initial"

cd ../axiome-bio-compute
docker build -t "$REGISTRY/biocompute:initial" .
docker push "$REGISTRY/biocompute:initial"

cd ../axiome-front
docker build -t "$REGISTRY/frontend:initial" .
docker push "$REGISTRY/frontend:initial"
```

### 2.7. Set initial image tags and deploy

```bash
cd ../axiome-infra

# Update all services to the initial tag
bash scripts/update-manifest.sh backend dev initial
bash scripts/update-manifest.sh biocompute dev initial
bash scripts/update-manifest.sh frontend dev initial

# Deploy
bash scripts/deploy.sh dev
```

### 2.8. Run database migrations

```bash
cd ../axiome-back
DATABASE_URL="<postgres-connection-string>" npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

### 2.9. Verify deployment

```bash
curl https://<backend-endpoint>/health    # Expected: 200
curl https://<biocompute-endpoint>/health # Expected: 200
curl https://<frontend-url>              # Expected: 200
```

### 2.10. Bootstrap staging and production

Repeat steps 2.2 through 2.9 for each environment, substituting `dev` with `staging` or `production` in all commands.

---

## 3. CI/CD Pipeline — Post-Bootstrap

After the initial bootstrap, all subsequent deployments flow through the CI/CD pipeline:

```
Service push to main → CI: test → build → push → notify infra
                                                      ↓
                                          Update dev/images.tfvars (automatic)
                                                      ↓
                                          Manual: promote.yml per service per env
                                             ↓            ↓             ↓
                                            dev  →   staging   →   production
```

Each service (backend, biocompute, frontend) is independent:
- **Own CI**: test job defined locally, build/push/notify via shared reusable workflow
- **Own image tag**: tracked independently in `environments/<env>/images.tfvars`
- **Own promotion path**: promote one service without touching others

The reusable build workflow and deploy workflow handle both Scaleway and AWS via the `REGISTRY_PROVIDER` secret — no code changes needed to switch providers.

See [ci-cd.md](ci-cd.md) for the complete pipeline architecture, provider polymorphism details, and deployment walkthrough.

---

## 4. Known Provider Differences

| Concern | Scaleway | AWS |
|---------|----------|-----|
| Container deployment | Serverless Containers | ECS Fargate (task defs, services, ALB) |
| MongoDB | Managed MongoDB (native) | DocumentDB (partial compatibility) |
| Networking | Private Network (flat) | VPC + subnets + route tables + NAT |
| Object storage | Object Storage (S3-compatible) | S3 (native) |
| Registry | Container Registry | ECR |
| Secrets | Secret Manager | Secrets Manager |
| Cold start | ~1-3s | ~5-30s |
| Region | fr-par | eu-west-3 |

---

## 5. Post-Bootstrap Checklist

- [ ] All services are running and healthy
- [ ] Backend `/health` returns 200
- [ ] Biocompute `/health` returns 200
- [ ] Frontend loads in browser
- [ ] Database migrations have been applied
- [ ] Object storage buckets exist with correct naming
- [ ] Secrets are injected (not hardcoded)
- [ ] No plaintext secrets in the repository
- [ ] GitHub Actions secrets are configured
- [ ] `REGISTRY_PROVIDER` secret is set on all service repos and infra
- [ ] Reusable workflow access is enabled on axiome-infra
- [ ] Terraform state is stored remotely
- [ ] Environment is isolated from other environments
- [ ] CI triggers on push to main and successfully runs test + build + push
- [ ] `repository_dispatch` arrives at infra and updates `dev/images.tfvars`

## 6. Teardown

### Local

```bash
make local-down         # Stop services, keep data
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
