#!/usr/bin/env bash
# deploy-latest.sh — resolve each service's latest green `main` build (the
# most recently pushed ECR image tag, which is only ever written by a
# successful CI build on main — reusable-build.yml) and, by default, promote
# it to an environment through the one authoritative deploy path,
# scripts/deploy-prod.sh. This script never decides anything deploy-prod.sh
# doesn't already decide (locking, migration gate, health poll, :stable
# advance, auto-rollback) — it only answers "what tag is latest" and loops
# over services.
#
# "Latest" is read from ECR itself (ground truth: what CI actually built and
# pushed), never from a git branch tip directly — a `main` commit with no
# successful image build is not deployable, and this script must never
# resolve to one.
#
# Usage:
#   scripts/deploy-latest.sh                                  # resolve + deploy all 3 services to production
#   scripts/deploy-latest.sh --service backend                # resolve + deploy backend only
#   scripts/deploy-latest.sh --resolve-only                    # print latest tags, deploy nothing
#   scripts/deploy-latest.sh --service backend --resolve-only  # print backend's latest tag only
#   scripts/deploy-latest.sh --dry-run                         # resolve + deploy-prod.sh --dry-run for each service
#   scripts/deploy-latest.sh --env staging                     # target a non-production environment
#
# Options:
#   --service   backend|frontend|biocompute|all   Default: all.
#   --env       dev|staging|production             Default: production.
#   --resolve-only                                  Print the resolved tag(s) and exit; deploy nothing.
#   --dry-run                                       Pass --dry-run through to deploy-prod.sh.
#
# Env vars (same defaults/names as deploy-prod.sh):
#   AWS_REGION           Default: eu-west-3.
#   REGISTRY_NAMESPACE   ECR namespace. Default: axiome.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

AWS_REGION="${AWS_REGION:-eu-west-3}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-axiome}"
ENV="production"
SERVICE="all"
RESOLVE_ONLY=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --service)      SERVICE="$2"; shift 2 ;;
    --env)          ENV="$2"; shift 2 ;;
    --resolve-only) RESOLVE_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "${SERVICE}" in
  backend|frontend|biocompute) SERVICES=("${SERVICE}") ;;
  all)                         SERVICES=(backend frontend biocompute) ;;
  *) echo "ERROR: unknown --service '${SERVICE}'. Valid: backend|frontend|biocompute|all" >&2; exit 2 ;;
esac

# service -> ECR repo suffix (mirrors deploy-prod.sh's own mapping).
ecr_suffix_for() {
  case "$1" in
    backend)    echo "backend" ;;
    frontend)   echo "frontend" ;;
    biocompute) echo "biocompute" ;;
  esac
}

# Prints the 8-char git SHA tag of the most recently pushed image for a
# service, or fails loudly if none is found. An image tag always carries
# BOTH the SHA and (redundantly) `latest`; this filters to the SHA-shaped
# one so callers get a tag deploy-prod.sh's own commit-resolution step
# (deploy-production.yml) can resolve back to a real commit — `latest`
# itself is not a git ref and would fail that resolution.
resolve_tag() {
  local service="$1" suffix repo tags sha_tag
  suffix="$(ecr_suffix_for "${service}")"
  repo="${REGISTRY_NAMESPACE}/${suffix}"

  tags="$(aws ecr describe-images \
    --repository-name "${repo}" --region "${AWS_REGION}" \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags' \
    --output text 2>/dev/null)" || {
    echo "ERROR: could not list images for ${repo} in ${AWS_REGION} — check the repo name/region/credentials." >&2
    return 1
  }

  if [ -z "${tags}" ] || [ "${tags}" = "None" ]; then
    echo "ERROR: ${repo} has no pushed images." >&2
    return 1
  fi

  sha_tag="$(tr '\t' '\n' <<<"${tags}" | grep -E '^[0-9a-f]{8}$' | head -1)" || true
  if [ -z "${sha_tag}" ]; then
    echo "ERROR: most recently pushed image in ${repo} carries no 8-char-SHA tag (tags: ${tags}) — refusing to guess." >&2
    return 1
  fi

  echo "${sha_tag}"
}

declare -A RESOLVED
for service in "${SERVICES[@]}"; do
  echo "==> Resolving latest ${service} build..." >&2
  tag="$(resolve_tag "${service}")"
  RESOLVED["${service}"]="${tag}"
  echo "    ${service} -> ${tag}" >&2
done

if [ "${RESOLVE_ONLY}" = "1" ]; then
  for service in "${SERVICES[@]}"; do
    echo "${service}=${RESOLVED[${service}]}"
  done
  exit 0
fi

DEPLOY_ARGS=()
[ "${DRY_RUN}" = "1" ] && DEPLOY_ARGS+=(--dry-run)

for service in "${SERVICES[@]}"; do
  tag="${RESOLVED[${service}]}"
  echo ""
  echo "==> Deploying ${service} -> ${tag} (${ENV})"
  "${SCRIPT_DIR}/deploy-prod.sh" --env "${ENV}" --service "${service}" --tag "${tag}" "${DEPLOY_ARGS[@]}"
done
