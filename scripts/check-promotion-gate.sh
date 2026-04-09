#!/usr/bin/env bash
set -euo pipefail

# Verify that a service's image tag has been deployed to the previous environment
# before allowing promotion. Enforces dev -> staging -> production sequence per service.
# Usage: ./check-promotion-gate.sh <service> <target_environment> <image_tag>
#
# Services: backend | biocompute | frontend

SERVICE="${1:?Usage: $0 <service> <target_environment> <image_tag>}"
TARGET="${2:?Missing target_environment}"
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

get_tag_from_tfvars() {
    local env="$1"
    local file="${INFRA_ROOT}/environments/${env}/images.tfvars"
    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi
    grep "^${TF_KEY}" "$file" | sed 's/.*=\s*"\(.*\)"/\1/'
}

case "$TARGET" in
    dev)
        echo "No gate for dev — any ${SERVICE} image can be deployed."
        exit 0
        ;;
    staging)
        REQUIRED_ENV="dev"
        ;;
    production)
        REQUIRED_ENV="staging"
        ;;
    *)
        echo "ERROR: Unknown environment: ${TARGET}"
        exit 1
        ;;
esac

DEPLOYED_TAG=$(get_tag_from_tfvars "$REQUIRED_ENV")

if [[ "$DEPLOYED_TAG" != "$IMAGE_TAG" ]]; then
    echo "GATE FAILED: ${SERVICE} tag '${IMAGE_TAG}' is not in '${REQUIRED_ENV}'."
    echo "  ${REQUIRED_ENV} ${TF_KEY} = ${DEPLOYED_TAG}"
    echo "  Deploy ${SERVICE} to ${REQUIRED_ENV} first, then promote to ${TARGET}."
    exit 1
fi

echo "GATE PASSED: ${SERVICE} '${IMAGE_TAG}' is in '${REQUIRED_ENV}'. Promotion to '${TARGET}' allowed."
