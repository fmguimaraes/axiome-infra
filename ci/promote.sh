#!/usr/bin/env bash
#
# promote.sh — Update image tags in the infra repo for a target environment
#
# Usage:
#   ./ci/promote.sh <environment> <image_tag>
#
# This writes the new tag into environments/<env>/images.tfvars, then
# commits and pushes the change to the infra repo. The git commit acts
# as the GitOps trigger — deploy.sh reads these values via terraform.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(dirname "$SCRIPT_DIR")"

ENV="${1:-}"
TAG="${2:-}"

if [[ -z "$ENV" || -z "$TAG" ]]; then
  echo "Usage: $0 <environment> <image_tag>" >&2
  echo "  environment: dev | staging | production" >&2
  echo "  image_tag:   e.g. a1b2c3d4" >&2
  exit 1
fi

if [[ "$ENV" != "dev" && "$ENV" != "staging" && "$ENV" != "production" ]]; then
  echo "ERROR: Invalid environment '$ENV'. Must be: dev, staging, production" >&2
  exit 1
fi

IMAGES_FILE="$INFRA_ROOT/environments/$ENV/images.tfvars"

if [[ ! -f "$IMAGES_FILE" ]]; then
  echo "ERROR: $IMAGES_FILE not found" >&2
  exit 1
fi

echo "==> Promoting tag '$TAG' to environment '$ENV'"

# Update all image tags in the tfvars file
sed -i "s/backend_image_tag.*/backend_image_tag    = \"$TAG\"/" "$IMAGES_FILE"
sed -i "s/biocompute_image_tag.*/biocompute_image_tag = \"$TAG\"/" "$IMAGES_FILE"
sed -i "s/frontend_image_tag.*/frontend_image_tag   = \"$TAG\"/" "$IMAGES_FILE"

echo "==> Updated $IMAGES_FILE:"
cat "$IMAGES_FILE"
echo ""

# Commit and push the change
cd "$INFRA_ROOT"
git add "$IMAGES_FILE"

if git diff --cached --quiet; then
  echo "==> No changes to commit (tag already set)"
  exit 0
fi

git commit -m "deploy($ENV): promote images to $TAG"
git push

echo "==> Promoted $TAG to $ENV and pushed to infra repo"
