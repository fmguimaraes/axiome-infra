#!/usr/bin/env bash
# Build and push service images to ECR.
#
# Usage:
#   push-images.sh                       # push all 3 services
#   push-images.sh backend               # push only backend
#   push-images.sh backend frontend      # push backend + frontend
#
# Tag strategy:
#   - Always pushes <service>:latest
#   - Also pushes <service>:<TAG> if TAG env var is set (e.g. git SHA)
#
# Env vars (auto-discovered when missing):
#   AWS_ACCOUNT_ID    AWS account (default: aws sts get-caller-identity)
#   AWS_REGION        Region (default: eu-west-3)
#   TAG               Extra tag (e.g. ${GITHUB_SHA::8}); optional
#   REPOS_ROOT        Parent dir holding axiome-back/, axiome-front/, axiome-bio-compute/
#                     Default: parent of axiome-infra (i.e. ~/dev/axiome/axiome-global)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$(cd "${INFRA_ROOT}/.." && pwd)}"

AWS_REGION="${AWS_REGION:-eu-west-3}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# service-name → repo-dir
declare -A REPO_DIR=(
  [backend]="axiome-back"
  [biocompute]="axiome-bio-compute"
  [frontend]="axiome-front"
)

ALL_SERVICES=(backend biocompute frontend)
SERVICES=("$@")
if [ ${#SERVICES[@]} -eq 0 ]; then
  SERVICES=("${ALL_SERVICES[@]}")
fi

for svc in "${SERVICES[@]}"; do
  if [ -z "${REPO_DIR[$svc]:-}" ]; then
    echo "ERROR: unknown service '${svc}'. Valid: ${ALL_SERVICES[*]}" >&2
    exit 1
  fi
done

echo "==> Logging in to ECR (${REGISTRY})"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

for svc in "${SERVICES[@]}"; do
  dir="${REPOS_ROOT}/${REPO_DIR[$svc]}"
  if [ ! -d "${dir}" ]; then
    echo "ERROR: repo dir not found: ${dir}" >&2
    exit 1
  fi

  image="${REGISTRY}/axiome/${svc}"
  tags=("-t" "${image}:latest")
  [ -n "${TAG:-}" ] && tags+=("-t" "${image}:${TAG}")

  echo "==> Building ${svc} (${dir})"
  docker build "${tags[@]}" "${dir}"

  echo "==> Pushing ${image}:latest"
  docker push "${image}:latest"
  if [ -n "${TAG:-}" ]; then
    echo "==> Pushing ${image}:${TAG}"
    docker push "${image}:${TAG}"
  fi
done

echo "==> Done. ${#SERVICES[@]} service(s) pushed to ${REGISTRY}/axiome/*"
