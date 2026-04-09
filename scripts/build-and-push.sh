#!/usr/bin/env bash
set -euo pipefail

# Build and push a Docker image for a single service.
# Usage: ./build-and-push.sh <service> <registry_endpoint> <image_tag> <gh_pat> <repo_owner>
#
# Services: backend | biocompute | frontend

SERVICE="${1:?Usage: $0 <service> <registry_endpoint> <image_tag> <gh_pat> <repo_owner>}"
REGISTRY_ENDPOINT="${2:?Missing registry_endpoint}"
IMAGE_TAG="${3:?Missing image_tag}"
GH_PAT="${4:?Missing gh_pat}"
REPO_OWNER="${5:?Missing repo_owner}"

# Map service name to git repo name
declare -A SERVICE_REPOS=(
    [backend]="axiome-back"
    [biocompute]="axiome-bio-compute"
    [frontend]="axiome-front"
)

REPO_NAME="${SERVICE_REPOS[$SERVICE]:-}"
if [[ -z "$REPO_NAME" ]]; then
    echo "ERROR: Unknown service '${SERVICE}'. Must be one of: backend, biocompute, frontend"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Logging in to registry ==="
echo "${SCW_SECRET_KEY}" | docker login "${REGISTRY_ENDPOINT}" -u nologin --password-stdin

echo "=== Cloning ${REPO_NAME} ==="
git clone --depth 1 "https://x-access-token:${GH_PAT}@github.com/${REPO_OWNER}/${REPO_NAME}.git" "${WORK_DIR}/${REPO_NAME}"

IMAGE="${REGISTRY_ENDPOINT}/${SERVICE}:${IMAGE_TAG}"
LATEST="${REGISTRY_ENDPOINT}/${SERVICE}:latest"

echo "=== Building ${SERVICE} (tag: ${IMAGE_TAG}) ==="
docker build -t "$IMAGE" -t "$LATEST" "${WORK_DIR}/${REPO_NAME}"

echo "=== Pushing ${SERVICE} ==="
docker push "$IMAGE"
docker push "$LATEST"

echo "=== ${SERVICE} image pushed: ${IMAGE} ==="
