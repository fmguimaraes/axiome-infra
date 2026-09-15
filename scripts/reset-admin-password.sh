#!/usr/bin/env bash
# reset-admin-password.sh — seed/rotate the bootstrap admin password for a platform env.
#
# Why this exists (incident 2026-06-23): the admin password used to live in the SSM
# parameter BOOTSTRAP_ADMIN_PASSWORD, and AdminBootstrapService re-upserted it from
# that value on every user-service start (the "G5 replay" gap). A UI password
# change silently reverted on the next restart/stop-start.
#
# FR9/AXI-983 fix: AdminBootstrapService is now create-only (it skips seeding when
# the admin already exists), so this script only affects an environment that has
# NO admin user yet. Once the admin exists, rotate its password through the normal
# product flow (forgot-password / reset-password), NOT this script — writing SSM
# and recreating user-service will no longer change an existing admin's password.
#
# After a successful run (login verified) the script BLANKS the SSM parameter
# (deletes it) so no replayable bootstrap secret is left lying around per FR9/FR10 —
# pass -k/--keep-param to skip that (e.g. re-seeding a throwaway dev/CI env
# repeatedly). SSM SecureString rejects empty values, so "blank" means delete.
#
# Usage:
#   scripts/reset-admin-password.sh                       # seed prod, auto-generate pw
#   scripts/reset-admin-password.sh -e staging
#   scripts/reset-admin-password.sh -p 'My-Strong-Pass'   # set a specific value
#   scripts/reset-admin-password.sh -k                    # keep the SSM param afterwards
#
# Options:
#   -e ENV       Environment (production|staging|dev). Default: production.
#   -r REGION    AWS region. Default: eu-west-3.
#   -p PASSWORD  Use this password instead of auto-generating one.
#   -k           Keep the BOOTSTRAP_ADMIN_PASSWORD SSM param after success (default: delete it).
#
# After success it prints the new password ONCE. Save it in your password manager.
#
# The new password is fetched on the box from SSM during the refresh, so the value
# never travels through SSM Run Command history.

set -euo pipefail

ENVIRONMENT="production"
REGION="${AWS_REGION:-eu-west-3}"
PASSWORD=""
KEEP_PARAM=0

while getopts "e:r:p:kh" opt; do
  case "${opt}" in
    e) ENVIRONMENT="${OPTARG}" ;;
    r) REGION="${OPTARG}" ;;
    p) PASSWORD="${OPTARG}" ;;
    k) KEEP_PARAM=1 ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
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
# Bootstrap is create-only (FR9): this only sets the password when no admin
# exists yet. Against an environment that already has an admin, the recreate is
# a no-op for the password and the login check below correctly reports failure.
RESULT="$("${SSM}" -e "${ENVIRONMENT}" -r "${REGION}" -t 90 "set -e
cd /opt/axiome
EMAIL=\$(aws ssm get-parameter --region ${REGION} --name /${ENVIRONMENT}/axiome-${ENVIRONMENT}/BOOTSTRAP_ADMIN_EMAIL --with-decryption --query Parameter.Value --output text)
NEW=\$(aws ssm get-parameter --region ${REGION} --name ${PARAM} --with-decryption --query Parameter.Value --output text)
grep -v '^BOOTSTRAP_ADMIN_PASSWORD=' .env > .env.new
printf '%s\n' \"BOOTSTRAP_ADMIN_PASSWORD=\$NEW\" >> .env.new
chmod 600 .env.new
mv .env.new .env
docker compose up -d --force-recreate user-service >/dev/null 2>&1
sleep 25
docker compose logs --tail=30 user-service 2>&1 | grep -iE 'bootstrap admin (seeded|already seeded)' | tail -1
BODY=\$(printf '{\"email\":\"%s\",\"password\":\"%s\"}' \"\$EMAIL\" \"\$NEW\")
echo -n 'login check: '
docker exec axiome-gateway wget -S -qO /dev/null --post-data=\"\$BODY\" --header=Content-Type:application/json http://localhost:3000/api/v1/auth/login 2>&1 | grep -i 'HTTP/' | head -1")"
echo "${RESULT}"

echo
if echo "${RESULT}" | grep -q 'login check: HTTP/1.1 200'; then
  echo "==> Login verified. New admin password (save it now, shown once):"
  echo
  echo "    ${PASSWORD}"
  echo
  if [ "${KEEP_PARAM}" -eq 0 ]; then
    echo "==> Blanking ${PARAM} (FR9/FR10: no replayable bootstrap secret left in SSM) ..."
    aws ssm delete-parameter --region "${REGION}" --name "${PARAM}"
    echo "    Deleted. Re-run without -k any time you need to seed a brand-new environment."
  else
    echo "    -k passed: leaving ${PARAM} in SSM as requested."
  fi
else
  echo "==> Login check did NOT return 200 — the SSM param was written but the"
  echo "    running admin was not affected. If an admin already exists here,"
  echo "    that's expected: bootstrap is create-only (FR9). Rotate an existing"
  echo "    admin's password via the product's forgot-password / reset-password"
  echo "    flow instead. Leaving ${PARAM} untouched (not deleting on failure)."
  echo "    See docs/troubleshooting.md §'Admin login returns 401'."
  exit 1
fi
