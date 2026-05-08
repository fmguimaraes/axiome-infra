#!/usr/bin/env bash
#
# deploy.sh — Run terraform apply for a target environment
#
# Usage:
#   ./ci/deploy.sh <environment> [--plan-only] [--auto-approve]
#
# Reads image tags from environments/<env>/images.tfvars and infra config
# from environments/<env>/terraform.tfvars, then applies via terraform.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(dirname "$SCRIPT_DIR")"

ENV="${1:-}"
PLAN_ONLY=false
AUTO_APPROVE=false

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-only)     PLAN_ONLY=true; shift ;;
    --auto-approve)  AUTO_APPROVE=true; shift ;;
    *)               echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment> [--plan-only] [--auto-approve]" >&2
  echo "  environment: dev | staging | production" >&2
  exit 1
fi

if [[ "$ENV" != "dev" && "$ENV" != "staging" && "$ENV" != "production" ]]; then
  echo "ERROR: Invalid environment '$ENV'. Must be: dev, staging, production" >&2
  exit 1
fi

ENV_DIR="$INFRA_ROOT/environments/$ENV"
TFVARS_FILE="$ENV_DIR/terraform.tfvars"
IMAGES_FILE="$ENV_DIR/images.tfvars"
BACKEND_FILE="$ENV_DIR/backend.hcl"

for f in "$TFVARS_FILE" "$IMAGES_FILE" "$BACKEND_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

echo "==> Deploying environment: $ENV"
echo "==> Image tags:"
grep '_image_tag' "$IMAGES_FILE"
echo ""

cd "$INFRA_ROOT"

echo "--- terraform init ---"
terraform init -backend-config="$BACKEND_FILE"

echo ""
echo "--- terraform plan ---"
terraform plan \
  -var-file="$TFVARS_FILE" \
  -var-file="$IMAGES_FILE" \
  -out=tfplan

if [[ "$PLAN_ONLY" == true ]]; then
  echo "==> Plan complete (--plan-only). Review above and re-run without --plan-only to apply."
  exit 0
fi

echo ""
if [[ "$AUTO_APPROVE" == true ]]; then
  echo "--- terraform apply (auto-approved) ---"
  terraform apply tfplan
else
  echo "--- terraform apply ---"
  terraform apply tfplan
fi

rm -f tfplan

echo ""
echo "==> Deployment to $ENV complete"
