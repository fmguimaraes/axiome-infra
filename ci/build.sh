#!/usr/bin/env bash
#
# build.sh — Build and push Docker images for all services
#
# Usage:
#   ./ci/build.sh [--registry REGISTRY_ENDPOINT] [--tag TAG]
#
# If --tag is omitted, uses the short git SHA from axiome-back (or HEAD).
# Outputs the image tag to stdout (last line) for piping into promote.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(dirname "$SCRIPT_DIR")"
GLOBAL_ROOT="$(dirname "$INFRA_ROOT")"

REGISTRY="${REGISTRY:-${SCW_REGISTRY_ENDPOINT:-}}"
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    *)          echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REGISTRY" ]]; then
  echo "ERROR: Registry endpoint required. Set REGISTRY or SCW_REGISTRY_ENDPOINT, or pass --registry." >&2
  exit 1
fi

# Resolve tag from git SHA if not provided
if [[ -z "$TAG" ]]; then
  TAG="$(git -C "$GLOBAL_ROOT/axiome-back" rev-parse --short=8 HEAD 2>/dev/null || git rev-parse --short=8 HEAD)"
fi

echo "==> Building images with tag: $TAG"
echo "==> Registry: $REGISTRY"
echo ""

build_and_push() {
  local service="$1"
  local context="$2"

  echo "--- Building $service ---"
  docker build -t "${REGISTRY}/${service}:${TAG}" \
               -t "${REGISTRY}/${service}:latest" \
               "$context"

  echo "--- Pushing $service:$TAG ---"
  docker push "${REGISTRY}/${service}:${TAG}"
  docker push "${REGISTRY}/${service}:latest"
  echo ""
}

# Login to registry
if [[ -n "${SCW_SECRET_KEY:-}" ]]; then
  echo "$SCW_SECRET_KEY" | docker login "$REGISTRY" -u nologin --password-stdin
fi

build_and_push "backend"    "$GLOBAL_ROOT/axiome-back"
build_and_push "biocompute" "$GLOBAL_ROOT/axiome-bio-compute"
build_and_push "frontend"   "$GLOBAL_ROOT/axiome-front"

echo "==> All images built and pushed successfully"
echo ""

# Output tag as last line for piping
echo "$TAG"
