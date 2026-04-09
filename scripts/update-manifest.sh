#!/usr/bin/env bash
set -euo pipefail

# Update images.tfvars for a single service in a target environment.
# Usage: ./update-manifest.sh <service> <environment> <image_tag>
#
# Services: backend | biocompute | frontend

SERVICE="${1:?Usage: $0 <service> <environment> <image_tag>}"
ENVIRONMENT="${2:?Missing environment}"
IMAGE_TAG="${3:?Missing image_tag}"

# Map service to tfvars key
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
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS_FILE="${INFRA_ROOT}/environments/${ENVIRONMENT}/images.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
    echo "ERROR: images.tfvars not found: ${TFVARS_FILE}"
    exit 1
fi

echo "=== Updating ${SERVICE} in ${ENVIRONMENT}: ${TF_KEY} -> ${IMAGE_TAG} ==="

sed -i "s|^${TF_KEY}.*|${TF_KEY} = \"${IMAGE_TAG}\"|" "$TFVARS_FILE"

cd "$INFRA_ROOT"

git config user.name "ci-bot"
git config user.email "ci-bot@axiome.dev"

git add "environments/${ENVIRONMENT}/images.tfvars"

if git diff --cached --quiet; then
    echo "No changes to commit (${SERVICE} already at ${IMAGE_TAG})."
    exit 0
fi

git commit -m "ci(${ENVIRONMENT}): update ${SERVICE} to ${IMAGE_TAG}"
git push origin HEAD

echo "=== ${SERVICE} manifest updated in ${ENVIRONMENT} ==="
