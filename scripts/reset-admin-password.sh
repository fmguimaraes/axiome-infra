#!/usr/bin/env bash
# reset-admin-password.sh — rotate the bootstrap admin password for a platform env.
#
# Why this exists (incident 2026-06-23): the admin password lives in the SSM
# parameter BOOTSTRAP_ADMIN_PASSWORD, and AdminBootstrapService re-upserts it from
# that value on every user-service start (the "G5 replay" gap). So a UI password
# change silently reverts on the next restart/stop-start, and the only reliable way
# to set the admin password is to change it in SSM + refresh the on-box .env +
# recreate user-service. This script does exactly that, atomically and verified.
#
# Usage:
#   scripts/reset-admin-password.sh                       # rotate prod, auto-generate pw
#   scripts/reset-admin-password.sh -e staging
#   scripts/reset-admin-password.sh -p 'My-Strong-Pass'   # set a specific value
#
# Options:
#   -e ENV       Environment (production|staging|dev). Default: production.
#   -r REGION    AWS region. Default: eu-west-3.
#   -p PASSWORD  Use this password instead of auto-generating one.
#
# After success it prints the new password ONCE. Save it in your password manager.
#
# The new password is fetched on the box from SSM during the refresh, so the value
# never travels through SSM Run Command history.

set -euo pipefail

ENVIRONMENT="production"
REGION="${AWS_REGION:-eu-west-3}"
PASSWORD=""

while getopts "e:r:p:h" opt; do
  case "${opt}" in
    e) ENVIRONMENT="${OPTARG}" ;;
    r) REGION="${OPTARG}" ;;
    p) PASSWORD="${OPTARG}" ;;
    h) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Run: $0 -h" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSM="${SCRIPT_DIR}/ssm-exec.sh"
PARAM="/${ENVIRONMENT}/axiome-${ENVIRONMENT}/BOOTSTRAP_ADMIN_PASSWORD"

# Generate a strong password if none was supplied (alnum + hyphens — safe in
# shell, JSON and .env without quoting; ~128 bits of entropy).
if [ -z "${PASSWORD}" ]; then
  PASSWORD="Axm-$(openssl rand -hex 16)-Hds$(date +%Y)"
fi

echo "==> Writing ${PARAM} (SecureString) ..."
aws ssm put-parameter --region "${REGION}" \
  --name "${PARAM}" --type SecureString --key-id alias/aws/ssm \
  --value "${PASSWORD}" --overwrite \
  --query 'Version' --output text | sed 's/^/    SSM version: /'

echo "==> Refreshing /opt/axiome/.env and recreating user-service ..."
# Runs on the box. Fetches the new value from SSM there, rewrites the .env line
# with a CLEAN write (printf '%s\n' — quoted format string, so no stray characters
# from backslash mangling), recreates user-service, and verifies login = 200.
"${SSM}" -e "${ENVIRONMENT}" -r "${REGION}" -t 90 "set -e
cd /opt/axiome
EMAIL=\$(aws ssm get-parameter --region ${REGION} --name /${ENVIRONMENT}/axiome-${ENVIRONMENT}/BOOTSTRAP_ADMIN_EMAIL --with-decryption --query Parameter.Value --output text)
NEW=\$(aws ssm get-parameter --region ${REGION} --name ${PARAM} --with-decryption --query Parameter.Value --output text)
grep -v '^BOOTSTRAP_ADMIN_PASSWORD=' .env > .env.new
printf '%s\n' \"BOOTSTRAP_ADMIN_PASSWORD=\$NEW\" >> .env.new
chmod 600 .env.new
mv .env.new .env
docker compose up -d --force-recreate user-service >/dev/null 2>&1
sleep 25
docker compose logs --tail=30 user-service 2>&1 | grep -i 'bootstrap admin ensured' | tail -1
BODY=\$(printf '{\"email\":\"%s\",\"password\":\"%s\"}' \"\$EMAIL\" \"\$NEW\")
echo -n 'login check: '
docker exec axiome-gateway wget -S -qO /dev/null --post-data=\"\$BODY\" --header=Content-Type:application/json http://localhost:3000/api/v1/auth/login 2>&1 | grep -i 'HTTP/' | head -1"

echo
echo "==> Done. New admin password (save it now, shown once):"
echo
echo "    ${PASSWORD}"
echo
echo "    A '200 OK' login check above means it works. Anything else: see"
echo "    docs/troubleshooting.md §'Admin login returns 401'."
