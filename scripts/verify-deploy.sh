#!/usr/bin/env bash
# Verify a deployed environment is reachable and healthy.
#
# Usage:
#   verify-deploy.sh dev
#   verify-deploy.sh staging
#   verify-deploy.sh production
#
# Checks:
#   1. DNS resolves to the provider's public IP
#   2. https://<fqdn>/health returns 2xx (TLS valid)
#   3. https://<fqdn>/ returns 2xx
#
# Exits non-zero if any check fails.
#
# Env vars (auto-discovered when missing):
#   PROVIDER          aws | scaleway | ovh. Default: aws. Selects the provider root
#                     and the IP output name (aws=lightsail_static_ip, else public_ip).
#   FQDN              Full domain. Default: terraform output -raw fqdn
#   EXPECTED_IP       IP it should resolve to. Default: terraform output -raw <IP_OUTPUT>
#   IP_OUTPUT         Terraform output key for the public IP. Default: per-provider.
#   HEALTH_PATH       Default: /health
#   ROOT_PATH         Default: /
#   TIMEOUT           Per-curl timeout in seconds. Default: 10

set -euo pipefail

ENVIRONMENT="${1:-}"
if [ -z "${ENVIRONMENT}" ]; then
  echo "Usage: $0 <dev|staging|production>   (PROVIDER=aws|scaleway|ovh)" >&2
  exit 1
fi

PROVIDER="${PROVIDER:-aws}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVIDER_DIR="${INFRA_ROOT}/providers/${PROVIDER}"

# Public-IP output name differs per provider (AWS Lightsail vs Scaleway instance IP).
if [ "${PROVIDER}" = "aws" ]; then
  IP_OUTPUT="${IP_OUTPUT:-lightsail_static_ip}"
else
  IP_OUTPUT="${IP_OUTPUT:-public_ip}"
fi

HEALTH_PATH="${HEALTH_PATH:-/health}"
ROOT_PATH="${ROOT_PATH:-/}"
TIMEOUT="${TIMEOUT:-10}"

if [ -z "${FQDN:-}" ]; then
  FQDN=$(cd "${PROVIDER_DIR}" && terraform output -raw fqdn)
fi
if [ -z "${EXPECTED_IP:-}" ]; then
  EXPECTED_IP=$(cd "${PROVIDER_DIR}" && terraform output -raw "${IP_OUTPUT}")
fi

PASS=0
FAIL=0

check() {
  local name="$1" cmd="$2"
  if eval "${cmd}"; then
    echo "  PASS  ${name}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  ${name}"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> Verifying ${ENVIRONMENT} at https://${FQDN}"
echo

echo "[DNS]"
RESOLVED=$(dig +short "${FQDN}" | tail -n1)
if [ "${RESOLVED}" = "${EXPECTED_IP}" ]; then
  echo "  PASS  ${FQDN} → ${RESOLVED}"
  PASS=$((PASS + 1))
else
  echo "  FAIL  ${FQDN} → ${RESOLVED:-<no answer>} (expected ${EXPECTED_IP})"
  FAIL=$((FAIL + 1))
fi

echo
echo "[HTTPS]"
check "GET ${HEALTH_PATH}" "curl -fsS --max-time ${TIMEOUT} https://${FQDN}${HEALTH_PATH} > /dev/null"
check "GET ${ROOT_PATH}"   "curl -fsS --max-time ${TIMEOUT} https://${FQDN}${ROOT_PATH}   > /dev/null"

echo
if [ ${FAIL} -eq 0 ]; then
  echo "==> ${PASS} check(s) passed."
  exit 0
else
  echo "==> ${PASS} passed, ${FAIL} failed."
  exit 1
fi
