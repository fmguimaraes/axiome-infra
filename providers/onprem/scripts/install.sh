#!/bin/bash
# Axiome on-prem installer.
# Provisions a single Linux host (Ubuntu 22.04 / Debian 12) with Docker and starts
# the Axiome stack via docker-compose. Run as root or via sudo.
#
# Usage:
#   sudo ./install.sh --mode connected
#   sudo ./install.sh --mode airgapped --images-tar /path/to/images.tar
#
# Idempotent: re-runs are safe.

set -euo pipefail

MODE=""
IMAGES_TAR=""
INSTALL_DIR="/opt/axiome"

while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)        MODE="$2";        shift 2 ;;
        --images-tar)  IMAGES_TAR="$2";  shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$MODE" != "connected" && "$MODE" != "airgapped" ]]; then
    echo "Error: --mode must be 'connected' or 'airgapped'" >&2
    exit 1
fi

if [[ "$MODE" == "airgapped" && -z "$IMAGES_TAR" ]]; then
    echo "Error: --images-tar required in airgapped mode" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (use sudo)" >&2
    exit 1
fi

LOG=/var/log/axiome-install.log
exec > >(tee -a "$LOG") 2>&1
echo "=== axiome installer started at $(date) (mode=$MODE) ==="

# 1. Detect OS
. /etc/os-release
case "$ID" in
    ubuntu|debian) ;;
    *) echo "Unsupported OS: $ID. Ubuntu 22.04 or Debian 12 required." >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive

# 2. Install Docker (if not already installed)
if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$ID/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$ID $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
fi

# 3. Install supporting tools
apt-get install -y unzip jq cron logrotate openssl

# 4. Create install directory
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 5. Verify .env exists
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    echo "Error: $INSTALL_DIR/.env not found." >&2
    echo "Copy from env/.env.${MODE}.example, fill in values, place at $INSTALL_DIR/.env" >&2
    exit 1
fi
chmod 600 "$INSTALL_DIR/.env"

# 6. Copy compose file + Caddyfile
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_DIR="$(dirname "$SCRIPT_DIR")"

cp "$PROVIDER_DIR/compose/docker-compose.${MODE}.yml" "$INSTALL_DIR/docker-compose.yml"
cp "$PROVIDER_DIR/compose/Caddyfile" "$INSTALL_DIR/Caddyfile"

# 7. Mode-specific setup
case "$MODE" in
    connected)
        echo "Connected mode: pulling images from registry..."
        # If using ECR, log in
        if grep -q '^AWS_ACCESS_KEY_ID=.\+' "$INSTALL_DIR/.env"; then
            source "$INSTALL_DIR/.env"
            aws ecr get-login-password --region "${AWS_REGION:-eu-west-3}" \
                | docker login --username AWS --password-stdin "$REGISTRY_URL"
        fi
        docker compose -f "$INSTALL_DIR/docker-compose.yml" pull
        ;;
    airgapped)
        echo "Airgapped mode: loading images from $IMAGES_TAR..."
        if [[ ! -f "$IMAGES_TAR" ]]; then
            echo "Image tarball not found: $IMAGES_TAR" >&2; exit 1
        fi
        docker load -i "$IMAGES_TAR"
        ;;
esac

# 8. Start the stack
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

# 9. Install systemd unit for restart on reboot
cat > /etc/systemd/system/axiome.service <<SVC
[Unit]
Description=Axiome stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable axiome.service

# 10. Backup cron (airgapped only — connected mode relies on managed backups)
if [[ "$MODE" == "airgapped" ]]; then
    cat > /etc/cron.daily/axiome-backup <<'CRON'
#!/bin/bash
set -e
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/axiome"
mkdir -p "$BACKUP_DIR"

# Postgres
docker exec axiome-postgres pg_dump -U "${POSTGRES_USER:-axiome}" "${POSTGRES_DB:-axiome}" \
    | gzip > "$BACKUP_DIR/postgres-$DATE.sql.gz"

# Mongo
docker exec axiome-mongodb mongodump \
    --username "${MONGODB_USER:-axiome}" \
    --password "${MONGODB_PASSWORD}" \
    --authenticationDatabase admin \
    --archive --gzip \
    > "$BACKUP_DIR/mongo-$DATE.archive.gz"

# MinIO via mc mirror to system bucket
docker exec axiome-minio-init \
    mc mirror local/axiome-artifacts "/data-backups/$DATE/" 2>/dev/null || true

# Retain 14 days
find "$BACKUP_DIR" -mtime +14 -delete
CRON
    chmod +x /etc/cron.daily/axiome-backup
    echo "Daily backup cron installed at /etc/cron.daily/axiome-backup"
    echo "  Backups land in /var/backups/axiome (14-day retention)"
fi

# 11. Hourly ECR re-auth for connected mode using ECR
if [[ "$MODE" == "connected" ]] && grep -q '^AWS_ACCESS_KEY_ID=.\+' "$INSTALL_DIR/.env"; then
    cat > /etc/cron.hourly/ecr-relogin <<CRON
#!/bin/sh
set -a; . $INSTALL_DIR/.env; set +a
aws ecr get-login-password --region "\${AWS_REGION:-eu-west-3}" \\
    | docker login --username AWS --password-stdin "\$REGISTRY_URL" 2>&1
CRON
    chmod +x /etc/cron.hourly/ecr-relogin
fi

# 12. Logrotate for docker stdout
cat > /etc/logrotate.d/docker-containers <<'ROT'
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    missingok
    delaycompress
    copytruncate
}
ROT

echo "=== axiome installer finished at $(date) ==="
echo
echo "Next steps:"
echo "  1. Verify the stack: docker compose -f $INSTALL_DIR/docker-compose.yml ps"
echo "  2. Tail logs:        docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
echo "  3. Run migrations:   see README.md §3.6"
echo "  4. Check health:     curl https://<your-fqdn>/health"
