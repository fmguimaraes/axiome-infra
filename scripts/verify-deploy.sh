#!/usr/bin/env bash
# Verify a deployed environment is reachable and healthy.
#
# Usage:
#   verify-deploy.sh dev
#   verify-deploy.sh staging
#   verify-deploy.sh production
#
# Checks:
#   1. DNS resolves to the Lightsail static IP
#   2. https://<fqdn>/health returns 2xx (TLS valid)
#   3. https://<fqdn>/ returns 2xx
#
# Exits non-zero if any check fails.
#
# Env vars (auto-discovered when missing):
#   FQDN              Full domain. Default: terraform output -raw fqdn
#   EXPECTED_IP       IP it should resolve to. Default: terraform output -raw lightsail_static_ip
#   HEALTH_PATH       Default: /health
#   ROOT_PATH         Default: /
#   TIMEOUT           Per-curl timeout in seconds. Default: 10

set -euo pipefail

ENVIRONMENT="${1:-}"
if [ -z "${ENVIRONMENT}" ]; then
  echo "Usage: $0 <dev|staging|production>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVIDER_DIR="${INFRA_ROOT}/providers/aws"

HEALTH_PATH="${HEALTH_PATH:-/health}"
ROOT_PATH="${ROOT_PATH:-/}"
TIMEOUT="${TIMEOUT:-10}"

if [ -z "${FQDN:-}" ]; then
  FQDN=$(cd "${PROVIDER_DIR}" && terraform output -raw fqdn)
fi
if [ -z "${EXPECTED_IP:-}" ]; then
  EXPECTED_IP=$(cd "${PROVIDER_DIR}" && terraform output -raw lightsail_static_ip)
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
