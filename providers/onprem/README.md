# On-Prem Provider — Bootstrap Guide

Deployment of the Axiome platform to a customer-managed Linux host. Two modes are supported, **chosen per customer** based on connectivity and compliance requirements.

| Mode | Use when | State services | Backups |
|---|---|---|---|
| **Connected** | Customer datacenter has internet egress; Atlas/Neon/cloud S3 acceptable | Neon (Postgres) + Atlas (MongoDB) + AWS S3 (or Scaleway, or MinIO) | Managed by Neon/Atlas + S3 versioning |
| **Air-gapped** | No internet egress; data sovereignty / regulated workload | Self-hosted Postgres + MongoDB + MinIO containers on the same host | Customer's responsibility — daily cron included |

Both modes use the same Axiome application images. **Connection strings differ; code does not.**

---

## Prerequisites

Customer-supplied:

- One Linux host (Ubuntu 22.04 LTS or Debian 12; arm64 or amd64)
- 4 GB RAM minimum (8 GB recommended for air-gapped — must run Postgres + Mongo + MinIO on the same box)
- 80 GB SSD minimum (200 GB+ for air-gapped with persistent data)
- Root or `sudo` access
- Open ports: 22 (SSH inbound from operator), 80/443 (HTTPS public)
- Domain name pointing to the host's public IP, OR an internal DNS entry for air-gapped
- (Connected mode) Internet egress to ECR (or alternate registry), Neon, Atlas, S3 endpoints
- (Air-gapped mode) Image bundle delivered out-of-band (USB, tarball over secure transfer)

Operator-side:

- Axiome operator workstation with `bash` (for shell installer) or `ansible` (for fleet management)
- (Connected mode, ECR) AWS credentials with `ecr:GetAuthorizationToken` and pull permissions on the axiome repos

---

## Mode 1 — Connected install

Same architectural footprint as the AWS Lightsail deployment, just on a customer-owned VM. Choose this when the customer accepts third-party managed services.

### 1.1. Set up external services

These steps mirror [providers/aws/README.md §0.5](../aws/README.md#05-create-neon-and-atlas-accounts-one-time):

1. **Neon** — create a project for this customer (`axiome-customer-prod`). Note the connection string.
2. **Atlas** — create a project + cluster (M0 for low-traffic; M10+ for production scale). Note the SRV connection string. Whitelist the customer's egress IP on the Atlas project.
3. **S3** — create three buckets in your AWS account (or Scaleway):
    - `axiome-onprem-<customer>-artifacts` (versioning enabled)
    - `axiome-onprem-<customer>-uploads`
    - `axiome-onprem-<customer>-system`

   Issue an IAM user scoped to these three buckets only.
4. **ECR access** — issue an IAM user with read-only on `axiome/*` repositories.

### 1.2. Customer-side preparation

```bash
# Customer prepares the host
sudo apt-get update
# Pre-install nothing else — install.sh handles Docker
```

Open firewall: 22 (operator SSH), 80, 443 (public). Ensure the host's public IP has DNS pointing at the customer-chosen FQDN.

### 1.3. Operator delivers the install package

```bash
# On operator workstation
cd providers/onprem
scp -r compose env scripts customer-host:/tmp/axiome-install/
```

Or use the Ansible path (§1.6).

### 1.4. Configure environment file

```bash
# On the customer host, as root
sudo mkdir -p /opt/axiome
cd /opt/axiome
sudo cp /tmp/axiome-install/env/.env.connected.example .env
sudo vi .env   # Fill in all values (see env file comments)
sudo chmod 600 .env
```

Required values (from §1.1):
- `FQDN` — customer-facing hostname
- `REGISTRY_URL` + AWS credentials for ECR
- `DATABASE_URL` from Neon
- `MONGODB_URL` from Atlas
- `S3_*` variables for artifact storage
- `JWT_SECRET` (generate with `openssl rand -base64 64`)

### 1.5. Run the installer

```bash
sudo bash /tmp/axiome-install/scripts/install.sh --mode connected
```

The installer:
- Installs Docker engine + compose plugin
- Logs into ECR using the AWS credentials from `.env`
- Pulls the three Axiome images
- Writes `docker-compose.yml` + `Caddyfile` to `/opt/axiome/`
- Starts the stack via `docker compose up -d`
- Installs `axiome.service` systemd unit (auto-restart on reboot)
- Installs hourly cron for ECR re-auth

Estimated time: **~5–10 min** (depends on customer's internet bandwidth).

### 1.6. (Optional) Use Ansible instead of install.sh

For multiple customer hosts or environments where customer ops prefers Ansible:

```bash
cd providers/onprem/ansible
cp inventory.ini.example inventory.ini
vi inventory.ini   # set the customer host IP and SSH key

ansible-playbook -i inventory.ini site.yml \
    -e "axiome_mode=connected" \
    -e "axiome_env_file=/path/to/customer-prod.env" \
    -e "axiome_install_dir=/opt/axiome"
```

### 1.7. Run database migrations

```bash
# On operator workstation, with DATABASE_URL pointing at customer's Neon project
cd ../axiome-back
DATABASE_URL="<neon-url>" npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

### 1.8. Verify

```bash
# DNS
dig +short <customer-fqdn>

# Health (allow ~60s for Caddy to fetch Let's Encrypt cert on first request)
curl -fsS https://<customer-fqdn>/health
curl -fsS https://<customer-fqdn>/ready
```

### 1.9. Hand off operations

Document for the customer's ops team:
- Where logs are: `docker compose -f /opt/axiome/docker-compose.yml logs`
- How to update images: `docker compose pull && docker compose up -d`
- How to view env vars: `cat /opt/axiome/.env` (root only)
- Where to find their backups: managed by Neon/Atlas dashboards + S3 versioning

---

## Mode 2 — Air-gapped install

Choose this for regulated workloads (life sciences, healthcare, public sector) where data must remain inside the customer's network and external dependencies are forbidden.

### 2.1. Operator builds the install bundle

```bash
# On operator workstation, with AWS CLI authenticated
cd providers/onprem
./scripts/build-airgapped-bundle.sh \
    --version 1.2.3 \
    --registry 123456789012.dkr.ecr.eu-west-3.amazonaws.com
```

Output: `dist/axiome-airgapped-1.2.3.tar.gz` (~1–2 GB depending on image sizes).

The bundle contains:
- All container images (axiome services + Postgres + Mongo + MinIO + Caddy) saved as a tarball
- `docker-compose.airgapped.yml`
- `Caddyfile`
- `install.sh`
- `.env.airgapped.example`
- `README.md` (this file)

### 2.2. Deliver the bundle to the customer

Transfer via the customer's approved out-of-band mechanism: encrypted USB, customer-managed file share, secure shipping. Provide the SHA-256 checksum separately for integrity verification.

### 2.3. Customer-side install

```bash
# On the customer host, as root
mkdir -p /tmp/axiome-install
tar xzf axiome-airgapped-1.2.3.tar.gz -C /tmp/axiome-install --strip-components=1
cd /tmp/axiome-install

# Configure
sudo mkdir -p /opt/axiome
sudo cp env/.env.airgapped.example /opt/axiome/.env
sudo vi /opt/axiome/.env   # Fill in passwords, FQDN
sudo chmod 600 /opt/axiome/.env

# Install (loads images from bundle, starts stack)
sudo bash scripts/install.sh --mode airgapped --images-tar images.tar
```

The installer:
- Installs Docker engine (from system apt — assumes mirror or pre-cached)
- `docker load` images from the bundle
- Writes compose + Caddyfile
- Starts the stack
- Installs systemd service
- Installs **daily backup cron** (Postgres + Mongo + MinIO mirror) → `/var/backups/axiome` (14-day retention)

### 2.4. TLS certificate (air-gapped)

Caddy's default config uses Let's Encrypt — which requires internet egress. For air-gapped:

**Option A — internal CA**: ask the customer's PKI team to issue a cert for the FQDN. Mount it into the Caddy container:

```yaml
# In docker-compose.airgapped.yml under caddy.volumes:
- /etc/ssl/customer-axiome.pem:/etc/caddy/cert.pem:ro
- /etc/ssl/customer-axiome.key:/etc/caddy/key.pem:ro
```

And replace the implicit `tls` directive in the Caddyfile with:

```
tls /etc/caddy/cert.pem /etc/caddy/key.pem
```

**Option B — self-signed for testing**: generate with `openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=<fqdn>"`. Customer browsers will warn until they trust the cert.

### 2.5. Run database migrations

```bash
# On the customer host
cd /tmp/axiome-install   # or wherever you have the migrate scripts
docker run --rm \
    --network axiome-onprem-airgapped \
    -e DATABASE_URL="postgresql://axiome:<password>@postgres:5432/axiome" \
    axiome/backend:stable \
    npx prisma db push --schema apps/organization-service/src/prisma/schema.prisma
```

### 2.6. Verify

```bash
docker compose -f /opt/axiome/docker-compose.yml ps
curl -fsS -k https://<fqdn>/health
```

### 2.7. Hand off operations

Document for the customer:
- **Backups**: located in `/var/backups/axiome`. 14-day retention. Customer should ship these to a separate location (NFS, tape, encrypted external drive).
- **Restore procedure**: see [docs/runbooks.md](../../docs/runbooks.md) §"On-prem Postgres restore"
- **Image updates**: receive new bundle, run `scripts/install.sh` again (idempotent)
- **Disk usage**: Postgres + Mongo + MinIO grow without managed-service quota signals; monitor via `df -h` and configure alerts

---

## Day-2 operations

### Update images (connected mode)

```bash
ssh operator@customer-host
cd /opt/axiome
sudo docker compose pull
sudo docker compose up -d
```

### Update images (air-gapped mode)

Operator builds a new bundle (§2.1), delivers it, customer re-runs `install.sh --mode airgapped --images-tar images.tar`.

### Rotate secrets

Edit `/opt/axiome/.env`, then:

```bash
sudo docker compose -f /opt/axiome/docker-compose.yml down
sudo docker compose -f /opt/axiome/docker-compose.yml up -d
```

### Tear down

```bash
sudo docker compose -f /opt/axiome/docker-compose.yml down -v   # -v removes volumes
sudo systemctl disable axiome.service
sudo rm -rf /opt/axiome /etc/systemd/system/axiome.service
sudo systemctl daemon-reload
```

⚠️ Air-gapped mode `-v` deletes Postgres/Mongo/MinIO data permanently. Take backups first.

---

## Architectural notes

### Why one VM, not Kubernetes?

For Phase 1 on-prem, single-VM matches the AWS architecture and minimizes the customer's operational surface. K8s deployment is a deliberate Phase 2/3 graduation; do not lead with it.

### Connected vs. air-gapped — when to choose which

| Question | Connected | Air-gapped |
|---|---|---|
| Customer accepts US-managed cloud services (Atlas, Neon)? | Yes | No |
| Customer accepts EU-managed cloud (S3 in eu-west-3)? | Yes | No |
| Customer has compliance requiring data on-prem? | No | Yes |
| Customer has internet egress from the host? | Required | Forbidden |
| Customer's ops team capable of managing Postgres/Mongo/MinIO? | Not required | Required |
| Backup strategy preference | Managed (Neon/Atlas) | Customer-managed cron |

Most customers will fit one mode unambiguously. For ambiguous cases, default to **connected** unless explicit constraint forbids it — managed databases reduce customer ops load and your support burden.

### What carries forward to Phase 2/3

If a customer's deployment grows (more tenants, SLA, compliance audit), the architecture supports the same evolution as cloud:

- Compute: single VM → multiple VMs behind a load balancer → Kubernetes (customer-managed or rancher/k3s)
- State: stays on Neon/Atlas (connected) or grows to a Postgres/MongoDB cluster (air-gapped)
- Object storage: stays on cloud S3 (connected) or grows to MinIO cluster (air-gapped)

The application code does not change. Connection strings change to point at the new endpoints.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `install.sh: command not found: docker` after install | apt mirror lacks docker repo | Use a different apt source or pre-install docker via customer's package manager |
| Caddy fails TLS issuance (connected mode) | DNS not pointing at host yet | Wait for DNS propagation; check `dig <fqdn>` |
| Caddy fails TLS issuance (air-gapped mode) | Internet ACME unreachable | Use customer's internal CA cert (§2.4) |
| `docker pull` 403 (connected mode, ECR) | IAM user lacks `ecr:BatchGetImage` | Re-issue customer IAM with correct policy |
| Postgres container CrashLoopBackOff (air-gapped) | `POSTGRES_PASSWORD` empty in `.env` | Generate and set; restart |
| `mongosh` healthcheck failing | Mongo init still running on first boot | Wait 30–60s; if persistent, check `docker logs axiome-mongodb` |
| 502 from Caddy | Backend not yet healthy | Check `docker compose ps`; backend takes ~20s to start |
| Disk fill (air-gapped) | Mongo / Postgres data growth | Run `docker system df`; expand disk; document customer-side log rotation |

---

## What's next

After install:

1. **Smoke test the application end-to-end** with a sample workflow.
2. **Confirm backups land** (air-gapped: `ls /var/backups/axiome`; connected: check Neon/Atlas dashboards).
3. **Document the customer's ops contact** for incident response.
4. **Schedule a quarterly DR drill** with the customer (restore from backup into a sandbox).
5. **Track the customer's signals** for Phase 2/3 graduation per [graduation-criteria.md](../../docs/graduation-criteria.md).
