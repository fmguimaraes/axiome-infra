#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: deploy.sh <environment> [--plan-only]

Deploy to the target environment using Terraform.
Image tags are read from environments/<environment>/images.tfvars.

Arguments:
  environment   Target: dev | staging | production
  --plan-only   Only run terraform plan, do not apply

Environment variables:
  SCW_ACCESS_KEY   Scaleway access key (required)
  SCW_SECRET_KEY   Scaleway secret key (required)
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${INFRA_ROOT}"

ENV_DIR="environments/${ENVIRONMENT}"

# Build -var-file flags
VAR_FILES=("-var-file=${ENV_DIR}/terraform.tfvars")
if [ -f "${ENV_DIR}/images.tfvars" ]; then
  VAR_FILES+=("-var-file=${ENV_DIR}/images.tfvars")
  echo "==> Image tags from ${ENV_DIR}/images.tfvars:"
  grep '_image_tag' "${ENV_DIR}/images.tfvars" | sed 's/^/    /'
else
  echo "Warning: ${ENV_DIR}/images.tfvars not found, using defaults."
fi

echo "==> Initializing terraform for ${ENVIRONMENT}..."
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
