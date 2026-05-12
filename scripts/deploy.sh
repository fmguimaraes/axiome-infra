#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: deploy.sh <environment> [--plan-only]

Deploy to the target environment using Terraform.

The infra root is selected by the PROVIDER env var: terraform runs against
providers/\${PROVIDER}/, and env files come from
providers/\${PROVIDER}/environments/<environment>/.

Arguments:
  environment   Target: dev | staging | production
  --plan-only   Only run terraform plan, do not apply

Environment variables:
  PROVIDER              Required. Selects the infra codepath:
                        aws | scaleway | onprem
                        (corresponds to a providers/\${PROVIDER}/ subtree)
  AWS_ACCESS_KEY_ID     AWS access key (required when PROVIDER=aws —
                        used by both the S3 state backend and the AWS
                        resource provider)
  AWS_SECRET_ACCESS_KEY AWS secret key (required when PROVIDER=aws)
EOF
  exit 1
}

ENVIRONMENT="${1:-}"
[ -z "${ENVIRONMENT}" ] && usage

PLAN_ONLY=false
[ "${2:-}" = "--plan-only" ] && PLAN_ONLY=true

case "${ENVIRONMENT}" in
  dev|staging|production) ;;
  *) echo "Error: environment must be dev, staging, or production"; exit 1 ;;
esac

: "${PROVIDER:?PROVIDER is required (aws | scaleway | onprem)}"
case "${PROVIDER}" in
  aws|scaleway|onprem) ;;
  *) echo "Error: PROVIDER must be aws, scaleway, or onprem (got '${PROVIDER}')"; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVIDER_ROOT="${REPO_ROOT}/providers/${PROVIDER}"

if [ ! -d "${PROVIDER_ROOT}" ]; then
  echo "Error: ${PROVIDER_ROOT} does not exist."
  exit 1
fi

cd "${PROVIDER_ROOT}"

ENV_DIR="environments/${ENVIRONMENT}"
if [ ! -d "${ENV_DIR}" ]; then
  echo "Error: ${PROVIDER_ROOT}/${ENV_DIR} does not exist."
  exit 1
fi

# Build -var-file flags
VAR_FILES=("-var-file=${ENV_DIR}/terraform.tfvars")
if [ -f "${ENV_DIR}/images.tfvars" ]; then
  VAR_FILES+=("-var-file=${ENV_DIR}/images.tfvars")
  echo "==> Image tags from ${ENV_DIR}/images.tfvars:"
  grep '_image_tag' "${ENV_DIR}/images.tfvars" | sed 's/^/    /'
else
  echo "Warning: ${ENV_DIR}/images.tfvars not found, using defaults."
fi

if [ "${PROVIDER}" = "aws" ]; then
  : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required when PROVIDER=aws}"
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required when PROVIDER=aws}"
fi

echo "==> Initializing terraform for ${ENVIRONMENT} (PROVIDER=${PROVIDER})..."
terraform init -backend-config="${ENV_DIR}/backend.hcl" -reconfigure -input=false

echo "==> Planning..."
terraform plan "${VAR_FILES[@]}" -out=tfplan -input=false

if [ "${PLAN_ONLY}" = true ]; then
  echo "==> Plan-only mode. Review the plan above."
  rm -f tfplan
  exit 0
fi

echo "==> Applying..."
terraform apply -input=false tfplan
rm -f tfplan

echo "==> ${ENVIRONMENT} deployment complete."
