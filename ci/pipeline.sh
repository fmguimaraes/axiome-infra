#!/usr/bin/env bash
#
# pipeline.sh — Full trunk-based CI/CD pipeline with manual gates
#
# Flow:
#   1. Build & push images from main (automatic)
#   2. Promote + deploy to dev (automatic)
#   3. Promote + deploy to staging (manual confirmation)
#   4. Promote + deploy to production (manual confirmation)
#
# Usage:
#   ./ci/pipeline.sh [--registry REGISTRY] [--tag TAG] [--skip-build] [--from ENV]
#
# Options:
#   --registry    Container registry endpoint (or set REGISTRY / SCW_REGISTRY_ENDPOINT)
#   --tag         Use a specific tag instead of building (implies --skip-build)
#   --skip-build  Skip the build step, reuse existing images
#   --from        Start from a specific environment (dev, staging, production)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGISTRY="${REGISTRY:-${SCW_REGISTRY_ENDPOINT:-}}"
TAG=""
SKIP_BUILD=false
FROM_ENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)   REGISTRY="$2"; shift 2 ;;
    --tag)        TAG="$2"; SKIP_BUILD=true; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --from)       FROM_ENV="$2"; SKIP_BUILD=true; shift 2 ;;
    *)            echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

confirm() {
  local env="$1"
  echo ""
  echo "============================================"
  echo "  Ready to promote and deploy to: $env"
  echo "  Image tag: $TAG"
  echo "============================================"
  echo ""
  read -rp "Proceed with $env deployment? [y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "==> Skipped $env deployment"
    return 1
  fi
  return 0
}

deploy_env() {
  local env="$1"
  echo ""
  echo "========== PROMOTE: $env =========="
  "$SCRIPT_DIR/promote.sh" "$env" "$TAG"

  echo ""
  echo "========== DEPLOY: $env =========="
  "$SCRIPT_DIR/deploy.sh" "$env" --auto-approve
}

# Determine starting point
should_run() {
  local env="$1"
  if [[ -z "$FROM_ENV" ]]; then
    return 0
  fi
  case "$FROM_ENV" in
    dev)        return 0 ;;
    staging)    [[ "$env" == "staging" || "$env" == "production" ]] && return 0 || return 1 ;;
    production) [[ "$env" == "production" ]] && return 0 || return 1 ;;
  esac
}

# --- Step 1: Build ---
if [[ "$SKIP_BUILD" == false ]]; then
  echo "========== BUILD =========="
  BUILD_ARGS=()
  [[ -n "$REGISTRY" ]] && BUILD_ARGS+=(--registry "$REGISTRY")
  [[ -n "$TAG" ]] && BUILD_ARGS+=(--tag "$TAG")

  BUILD_OUTPUT=$("$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}" | tee /dev/stderr)
  TAG=$(echo "$BUILD_OUTPUT" | tail -1)
fi

if [[ -z "$TAG" ]]; then
  echo "ERROR: No image tag. Provide --tag or let build.sh generate one." >&2
  exit 1
fi

echo ""
echo "==> Pipeline image tag: $TAG"

# --- Step 2: Dev (automatic) ---
if should_run "dev"; then
  echo ""
  echo "=========================================="
  echo "  STAGE 1/3: DEV (automatic)"
  echo "=========================================="
  deploy_env "dev"
fi

# --- Step 3: Staging (manual gate) ---
if should_run "staging"; then
  if confirm "staging"; then
    echo ""
    echo "=========================================="
    echo "  STAGE 2/3: STAGING"
    echo "=========================================="
    deploy_env "staging"
  fi
fi

# --- Step 4: Production (manual gate) ---
if should_run "production"; then
  if confirm "production"; then
    echo ""
    echo "=========================================="
    echo "  STAGE 3/3: PRODUCTION"
    echo "=========================================="
    deploy_env "production"
  fi
fi

echo ""
echo "==> Pipeline complete. Tag: $TAG"
