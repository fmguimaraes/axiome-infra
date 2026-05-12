#!/usr/bin/env bash
set -euo pipefail

# Update images.tfvars for a single service in a target environment.
#
# Usage: ./update-manifest.sh <service> <environment> <image_tag>
# Required env: PROVIDER (aws | scaleway | onprem)
#
# Writes to providers/${PROVIDER}/environments/${ENVIRONMENT}/images.tfvars.

SERVICE="${1:?Usage: $0 <service> <environment> <image_tag>}"
ENVIRONMENT="${2:?Missing environment}"
IMAGE_TAG="${3:?Missing image_tag}"
: "${PROVIDER:?PROVIDER env var required (aws | scaleway | onprem)}"

case "${PROVIDER}" in
  aws|scaleway|onprem) ;;
  *) echo "ERROR: PROVIDER must be aws, scaleway, or onprem (got '${PROVIDER}')"; exit 1 ;;
esac

declare -A SERVICE_KEYS=(
    [backend]="backend_image_tag"
    [biocompute]="biocompute_image_tag"
    [frontend]="frontend_image_tag"
)

TF_KEY="${SERVICE_KEYS[$SERVICE]:-}"
if [[ -z "$TF_KEY" ]]; then
    echo "ERROR: Unknown service '${SERVICE}'. Must be one of: backend, biocompute, frontend"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS_REL="providers/${PROVIDER}/environments/${ENVIRONMENT}/images.tfvars"
TFVARS_FILE="${REPO_ROOT}/${TFVARS_REL}"

if [[ ! -f "$TFVARS_FILE" ]]; then
    echo "ERROR: images.tfvars not found: ${TFVARS_FILE}"
    exit 1
fi

echo "=== Updating ${SERVICE} in ${ENVIRONMENT} (PROVIDER=${PROVIDER}): ${TF_KEY} -> ${IMAGE_TAG} ==="

sed -i "s|^${TF_KEY}.*|${TF_KEY} = \"${IMAGE_TAG}\"|" "$TFVARS_FILE"

cd "$REPO_ROOT"

git config user.name "ci-bot"
git config user.email "ci-bot@axiome.dev"

git add "${TFVARS_REL}"

if git diff --cached --quiet; then
    echo "No changes to commit (${SERVICE} already at ${IMAGE_TAG})."
    exit 0
fi

git commit -m "ci(${ENVIRONMENT}): update ${SERVICE} to ${IMAGE_TAG}"
git push origin HEAD

echo "=== ${SERVICE} manifest updated in ${ENVIRONMENT} ==="
