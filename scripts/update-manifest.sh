#!/usr/bin/env bash
set -euo pipefail

# Update images.tfvars for a single service in a target environment.
#
# Usage: ./update-manifest.sh <service> <environment> <image_tag>
# Required env: PROVIDER (aws | scaleway | onprem)
# Optional env: SOURCE_REPO, SOURCE_MESSAGE — when both are set, the commit
#   message becomes "<repo>-<original commit subject>" instead of the opaque
#   "ci(<env>): update <service> to <sha>" form, so infra history is readable.
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

# Pad the key so the `=` aligns the way `terraform fmt` expects; otherwise the
# infra CI `terraform fmt -check` fails on every promote. Width = length of the
# longest key (biocompute_image_tag, 20 chars); all keys are always present, so
# this column is stable.
NEW_LINE="$(printf '%-20s = "%s"' "${TF_KEY}" "${IMAGE_TAG}")"
sed -i "s|^${TF_KEY}[[:space:]].*|${NEW_LINE}|" "$TFVARS_FILE"

cd "$REPO_ROOT"

git config user.name "ci-bot"
git config user.email "ci-bot@axiome.dev"

git add "${TFVARS_REL}"

if git diff --cached --quiet; then
    echo "No changes to commit (${SERVICE} already at ${IMAGE_TAG})."
    exit 0
fi

# Prefer a human-readable "<repo>-<original commit subject>" message when the
# triggering service passes its repo + commit message; fall back otherwise.
COMMIT_MSG="ci(${ENVIRONMENT}): update ${SERVICE} to ${IMAGE_TAG}"
if [[ -n "${SOURCE_REPO:-}" && -n "${SOURCE_MESSAGE:-}" ]]; then
    SOURCE_SUBJECT="${SOURCE_MESSAGE%%$'\n'*}"
    COMMIT_MSG="${SOURCE_REPO}-${SOURCE_SUBJECT}"
fi

git commit -m "${COMMIT_MSG}"
git push origin HEAD

echo "=== ${SERVICE} manifest updated in ${ENVIRONMENT} ==="
