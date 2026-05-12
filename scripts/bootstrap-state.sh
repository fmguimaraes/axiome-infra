#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the terraform remote-state bucket and DynamoDB lock table on AWS
# for one environment. Idempotent — safe to re-run.
#
# Run this ONCE per environment, locally, before terraform-cd can apply that
# environment. After bootstrap, terraform-cd uses AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY env vars for both the S3 backend (state) and the AWS
# provider (resources) — no other credentials needed.
#
# Required env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (must have S3 +
# DynamoDB create permissions).

usage() {
  cat <<EOF
Usage: bootstrap-state.sh <environment> [--region REGION]

  environment   Target env: dev | staging | production
  --region      AWS region (default: eu-west-3)

Creates (if missing):
  - S3 bucket           axiome-<env>-tfstate           (versioned, encrypted,
                                                        all public access blocked)
  - DynamoDB lock table axiome-<env>-tflock
                                                       (PAY_PER_REQUEST,
                                                        LockID hash key)
EOF
  exit 1
}

ENVIRONMENT="${1:-}"
[ -z "${ENVIRONMENT}" ] && usage
case "${ENVIRONMENT}" in dev|staging|production) ;; *) usage ;; esac

REGION="eu-west-3"
if [ "${2:-}" = "--region" ]; then
  REGION="${3:?--region requires a value}"
fi

BUCKET="axiome-${ENVIRONMENT}-tfstate"
TABLE="axiome-${ENVIRONMENT}-tflock"

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

echo "==> Bootstrapping terraform state for '${ENVIRONMENT}' in ${REGION}"
echo "    Bucket:     ${BUCKET}"
echo "    Lock table: ${TABLE}"

if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "==> S3 bucket already exists."
else
  echo "==> Creating S3 bucket..."
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
fi

echo "==> Enforcing bucket versioning"
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

echo "==> Enforcing AES256 server-side encryption"
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "==> Blocking all public access"
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> DynamoDB lock table already exists."
else
  echo "==> Creating DynamoDB lock table..."
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" >/dev/null
  echo "    Waiting for ACTIVE status..."
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
fi

echo "==> Done."
echo ""
echo "environments/${ENVIRONMENT}/backend.hcl should match:"
echo "  bucket         = \"${BUCKET}\""
echo "  key            = \"infrastructure/terraform.tfstate\""
echo "  region         = \"${REGION}\""
echo "  dynamodb_table = \"${TABLE}\""
echo "  encrypt        = true"
