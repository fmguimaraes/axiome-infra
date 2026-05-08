#!/bin/bash
# Builds an air-gapped install bundle for delivery to a customer.
# Output: axiome-airgapped-<version>.tar.gz containing:
#   - All container images (docker save tarball)
#   - Compose file
#   - Caddyfile template
#   - install.sh
#   - .env.airgapped.example
#
# Usage:
#   ./build-airgapped-bundle.sh --version 1.2.3 --registry 123.dkr.ecr.eu-west-3.amazonaws.com

set -euo pipefail

VERSION=""
REGISTRY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)  VERSION="$2";  shift 2 ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" || -z "$REGISTRY" ]]; then
    echo "Usage: $0 --version <semver> --registry <ecr-url>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR=$(mktemp -d)
BUNDLE_NAME="axiome-airgapped-$VERSION"
BUNDLE_DIR="$WORK_DIR/$BUNDLE_NAME"

mkdir -p "$BUNDLE_DIR"

echo "Pulling images from $REGISTRY (tag: $VERSION)..."
for service in backend biocompute frontend; do
    docker pull "$REGISTRY/axiome/$service:$VERSION"
    # Re-tag without registry so loaded images use plain names
    docker tag "$REGISTRY/axiome/$service:$VERSION" "axiome/$service:stable"
done

# Also pull infrastructure images so the install is fully offline
for img in postgres:15-alpine mongo:7 minio/minio:latest minio/mc:latest caddy:2-alpine; do
    docker pull "$img"
done

echo "Saving images to tarball..."
docker save \
    axiome/backend:stable \
    axiome/biocompute:stable \
    axiome/frontend:stable \
    postgres:15-alpine \
    mongo:7 \
    minio/minio:latest \
    minio/mc:latest \
    caddy:2-alpine \
    -o "$BUNDLE_DIR/images.tar"

cp -r "$PROVIDER_DIR/compose"   "$BUNDLE_DIR/compose"
cp -r "$PROVIDER_DIR/scripts"   "$BUNDLE_DIR/scripts"
cp -r "$PROVIDER_DIR/env"       "$BUNDLE_DIR/env"
cp    "$PROVIDER_DIR/README.md" "$BUNDLE_DIR/README.md"

cd "$WORK_DIR"
tar czf "$BUNDLE_NAME.tar.gz" "$BUNDLE_NAME"

OUTPUT="$PROVIDER_DIR/dist/$BUNDLE_NAME.tar.gz"
mkdir -p "$(dirname "$OUTPUT")"
mv "$BUNDLE_NAME.tar.gz" "$OUTPUT"

echo
echo "Bundle created: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
echo "SHA256: $(sha256sum "$OUTPUT" | cut -d' ' -f1)"
echo
echo "Customer install:"
echo "  tar xzf $BUNDLE_NAME.tar.gz"
echo "  cd $BUNDLE_NAME"
echo "  cp env/.env.airgapped.example .env"
echo "  vi .env  # fill in values"
echo "  sudo ./scripts/install.sh --mode airgapped --images-tar images.tar"
