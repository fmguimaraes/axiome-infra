#!/usr/bin/env bash
# Trigger the Lightsail VM to pull the latest images and restart the stack.
#
# Usage:
#   pull-on-vm.sh dev
#   pull-on-vm.sh staging
#   pull-on-vm.sh production
#
# Env vars (auto-discovered when missing):
#   INSTANCE_IP          VM IP. Default: terraform output -raw lightsail_static_ip
#   LIGHTSAIL_SSH_KEY    Path to the Lightsail PEM. Default: ~/.ssh/lightsail-<region>.pem
#   AWS_REGION           Default: eu-west-3
#   SSH_USER             Default: ubuntu

set -euo pipefail

ENVIRONMENT="${1:-}"
if [ -z "${ENVIRONMENT}" ]; then
  echo "Usage: $0 <dev|staging|production>" >&2
  exit 1
fi

case "${ENVIRONMENT}" in
  dev|staging|production) ;;
  *) echo "ERROR: environment must be dev, staging, or production" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVIDER_DIR="${INFRA_ROOT}/providers/aws"

AWS_REGION="${AWS_REGION:-eu-west-3}"
SSH_USER="${SSH_USER:-ubuntu}"
LIGHTSAIL_SSH_KEY="${LIGHTSAIL_SSH_KEY:-${HOME}/.ssh/lightsail-${AWS_REGION}.pem}"

if [ -z "${INSTANCE_IP:-}" ]; then
  echo "==> Resolving instance IP from terraform output"
  INSTANCE_IP=$(cd "${PROVIDER_DIR}" && terraform output -raw lightsail_static_ip)
fi

if [ ! -f "${LIGHTSAIL_SSH_KEY}" ]; then
  echo "ERROR: SSH key not found at ${LIGHTSAIL_SSH_KEY}" >&2
  echo "Download from: AWS Console → Lightsail → Account → SSH keys → ${AWS_REGION} default key" >&2
  exit 1
fi

if [ "$(stat -c %a "${LIGHTSAIL_SSH_KEY}")" != "600" ]; then
  chmod 600 "${LIGHTSAIL_SSH_KEY}"
fi

echo "==> Connecting to ${SSH_USER}@${INSTANCE_IP}"

ssh -i "${LIGHTSAIL_SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${SSH_USER}@${INSTANCE_IP}" \
    'set -e
     cd /opt/axiome
     echo "==> docker compose pull"
     sudo docker compose pull
     echo "==> docker compose up -d"
     sudo docker compose up -d
     echo "==> docker compose ps"
     sudo docker compose ps'

echo "==> Deploy triggered on ${ENVIRONMENT} (${INSTANCE_IP})"
