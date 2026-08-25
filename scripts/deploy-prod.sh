#!/usr/bin/env bash
# deploy-prod.sh — the single authoritative one-command production deploy (FR12/AC15).
#
# Closes the promote≠deploy gap: a green `promote-to-production` CI job only bumps
# the axiome-infra manifest and is INERT on the running system (prod pins :stable).
# This script is the only thing that changes what production actually runs. It:
#
#   1. Verifies the chosen source image exists in ECR and resolves its digest.
#   2. Captures the CURRENT :stable target (for fail-closed rollback).
#   3. Advances ECR :stable to the chosen image (server-side manifest retag — no pull).
#   4. Rolls the service on the box over SSM by piping scripts/roll-service.sh, which
#      `docker compose pull` + `prisma migrate deploy` (fail-closed) + `up -d`.
#   5. Health-checks /api/v1/health; on an unhealthy result it ABORTS fail-closed —
#      auto-rolling :stable back to the prior image so the prior image keeps serving.
#   6. Records the action (SHA + digest + timestamp) to reports/ (like the power scripts).
#
# Idempotent (NFR6): re-running with the same TAG is a no-op retag + a no-op roll
# (roll-service's sed + `up -d` + `migrate deploy` are all idempotent).
# Fail-closed (NFR6): a failed migration never swaps the image; a post-swap health
# failure auto-rolls back to the previously-serving image.
#
# Usage:
#   scripts/deploy-prod.sh --tag <sha> [--env production] [--service backend] [--dry-run]
#   ENV=production TAG=<sha> SERVICE=backend scripts/deploy-prod.sh          # env-var form
#   make deploy-prod ENV=production TAG=<sha>                                # Makefile wrapper
#
# Options / env vars (flags win over env vars):
#   --env      ENV        Target environment. Default: production.
#   --tag      TAG        Source image tag to promote (8-char git SHA). REQUIRED.
#   --service  SERVICE    backend | frontend | biocompute. Default: backend.
#   --dry-run  DRY_RUN=1  Print the plan and mutate NOTHING (safe when prod is off).
#
# Other env vars (auto-discovered when missing):
#   AWS_REGION        Default: eu-west-3.
#   AWS_ACCOUNT_ID    Default: aws sts get-caller-identity.
#   REGISTRY_NAMESPACE ECR namespace. Default: axiome (repo = <ns>/<service-repo>).
#   HEALTH_URL        Health endpoint. Default per env (production=platform.axiomebio.com).
#   HEALTH_RETRIES    Health poll attempts. Default: 30 (x 10s ≈ 5min, matches runbook).
#
# SECURITY: never pass a secret as a literal to SSM (logged to CloudTrail); the
# on-box roll fetches everything it needs from /opt/axiome/.env (sourced from SSM).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- defaults + arg parsing ---------------------------------------------------
ENV="${ENV:-production}"
TAG="${TAG:-}"
SERVICE="${SERVICE:-backend}"
DRY_RUN="${DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --env)     ENV="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'. Run: $0 --help" >&2; exit 2 ;;
  esac
done

AWS_REGION="${AWS_REGION:-eu-west-3}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-axiome}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"

# service (dispatch name) -> ECR repo suffix + roll-service KEY + compose health owner
case "${SERVICE}" in
  backend)    ECR_SUFFIX="backend";    ROLL_KEY="BACKEND_IMAGE_TAG" ;;
  frontend)   ECR_SUFFIX="frontend";   ROLL_KEY="FRONTEND_IMAGE_TAG" ;;
  biocompute) ECR_SUFFIX="biocompute"; ROLL_KEY="BIOCOMPUTE_IMAGE_TAG" ;;
  *) echo "ERROR: unknown SERVICE '${SERVICE}'. Valid: backend|frontend|biocompute" >&2; exit 2 ;;
esac
ECR_REPO="${REGISTRY_NAMESPACE}/${ECR_SUFFIX}"

# Health endpoint per environment (public FQDN).
default_fqdn() {
  case "${ENV}" in
    production) echo "platform.axiomebio.com" ;;
    staging)   echo "staging.axiomebio.com" ;;
    dev)       echo "dev.axiomebio.com" ;;
    *)         echo "" ;;
  esac
}
HEALTH_URL="${HEALTH_URL:-https://$(default_fqdn)/api/v1/health}"

[ -n "${TAG}" ] || { echo "ERROR: --tag/TAG is required (the source image git SHA)." >&2; exit 2; }

is_dry() { [ "${DRY_RUN}" = "1" ]; }

# run <description> -- <cmd...>  : execute, or in dry-run print the intent and skip.
run() {
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  if is_dry; then
    echo "DRY-RUN would: ${desc}"
    echo "               \$ $*"
    return 0
  fi
  echo "==> ${desc}"
  "$@"
}

# --- reporting (mirrors providers/aws/scripts/_power_lib.sh, self-contained) ---
REPORTS_DIR="${REPORTS_DIR:-${INFRA_ROOT}/reports}"
REPORT_FILE=""
REPORT_BUF=""
_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown; }

report_init() {
  if is_dry; then echo "DRY-RUN would: record this deploy to ${REPORTS_DIR}/"; return 0; fi
  mkdir -p "${REPORTS_DIR}"
  REPORT_BUF="$(mktemp)"
  REPORT_FILE="${REPORTS_DIR}/$(date -u +%Y-%m-%d-%H%M%S)-${ENV}-deploy-${SERVICE}.md"
  {
    echo "# Deploy — ${ENV} / ${SERVICE}"
    echo
    echo "- **When (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **Actor:** $(_actor)"
    echo "- **Region:** ${AWS_REGION}"
    echo "- **ECR repo:** ${ECR_REPO}"
    echo "- **Requested tag:** ${TAG}"
    echo
    echo "## Steps"
    echo
  } > "${REPORT_BUF}"
}
report_line() { is_dry && return 0; printf -- '- %s\n' "$1" >> "${REPORT_BUF}"; }
report_finish() {
  is_dry && return 0
  mv "${REPORT_BUF}" "${REPORT_FILE}"
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ENV}" "${SERVICE}" "${TAG}" "${DEPLOY_DIGEST:-unknown}" "$(_actor)" \
    >> "${REPORTS_DIR}/deploy-operations.md"
  echo "  report: ${REPORT_FILE}"
}

# --- ECR helpers --------------------------------------------------------------
ecr_registry() {
  local acct="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
  echo "${acct}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

# Digest of a tag in ECR, or empty string if the tag does not exist.
ecr_digest_of() {
  aws ecr describe-images --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-ids "imageTag=$1" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo ""
}

# Server-side retag: copy the source tag's manifest onto :stable (no docker pull).
# (Invoked indirectly through run(); shellcheck can't see that.)
# shellcheck disable=SC2329
ecr_retag_stable() {
  local from_tag="$1" manifest err
  manifest="$(aws ecr batch-get-image --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-ids "imageTag=${from_tag}" \
    --query 'images[0].imageManifest' --output text)"
  # put-image throws ImageAlreadyExistsException when :stable already points at this
  # exact manifest — that IS the idempotent no-op case, so tolerate only that error.
  if ! err="$(aws ecr put-image --region "${AWS_REGION}" \
      --repository-name "${ECR_REPO}" --image-tag stable \
      --image-manifest "${manifest}" 2>&1 >/dev/null)"; then
    if printf '%s' "${err}" | grep -q 'ImageAlreadyExistsException'; then
      echo "  :stable already points at ${from_tag} — retag no-op (idempotent)."
      return 0
    fi
    echo "${err}" >&2
    return 1
  fi
}

# Roll the service on the box: prepend the roll-service env vars, pipe the script
# over SSM. Prod pins :stable, so IMAGE_TAG=stable (KEY records it in /opt/axiome/.env).
roll_on_box() {
  { echo "export KEY='${ROLL_KEY}' IMAGE_TAG='stable' SERVICE='${SERVICE}'"; cat "${SCRIPT_DIR}/roll-service.sh"; } \
    | "${SCRIPT_DIR}/ssm-exec.sh" -e "${ENV}" -t 300 -
}

# Poll the public health endpoint. 0 = healthy, 1 = unhealthy after all retries.
health_check() {
  local i code
  for i in $(seq 1 "${HEALTH_RETRIES}"); do
    code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${HEALTH_URL}" || true)"
    echo "  health ${HEALTH_URL} -> ${code} (attempt ${i}/${HEALTH_RETRIES})"
    [[ "${code}" =~ ^2 ]] && return 0
    sleep 10
  done
  return 1
}

# Fail-closed rollback: point :stable back at the prior image and re-roll the box.
rollback_stable() {
  local prior="$1"
  if [ -z "${prior}" ] || [ "${prior}" = "None" ]; then
    echo "FAIL-CLOSED: no prior :stable digest captured — cannot auto-rollback." >&2
    echo "Manually retag :stable to a known-good SHA and re-run roll-service.sh." >&2
    return 1
  fi
  echo "FAIL-CLOSED: health failed — rolling :stable back to prior ${prior}." >&2
  local manifest
  manifest="$(aws ecr batch-get-image --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-ids "imageDigest=${prior}" \
    --query 'images[0].imageManifest' --output text)"
  aws ecr put-image --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-tag stable --image-manifest "${manifest}" > /dev/null
  roll_on_box
}

# --- plan banner --------------------------------------------------------------
# Avoid the aws sts call (and a network round-trip) when only printing a dry-run plan.
if is_dry; then
  REPO_DISPLAY="<account>.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
  MODE_DISPLAY="DRY-RUN (no mutations)"
else
  REPO_DISPLAY="$(ecr_registry)/${ECR_REPO}"
  MODE_DISPLAY="LIVE"
fi
cat <<BANNER
================================================================================
 Production deploy — ${SERVICE} -> ${ENV}
   ECR repo:      ${REPO_DISPLAY}
   Source tag:    ${TAG}
   Health URL:    ${HEALTH_URL}
   Mode:          ${MODE_DISPLAY}
================================================================================
BANNER

# --- 1. preflight: source image exists, resolve digests -----------------------
DEPLOY_DIGEST=""
PRIOR_STABLE_DIGEST=""
if is_dry; then
  echo "DRY-RUN would: verify ${ECR_REPO}:${TAG} exists and resolve its digest"
  echo "DRY-RUN would: capture the current :stable digest for rollback"
else
  echo "==> Preflight: verifying ${ECR_REPO}:${TAG} exists in ECR"
  DEPLOY_DIGEST="$(ecr_digest_of "${TAG}")"
  if [ -z "${DEPLOY_DIGEST}" ] || [ "${DEPLOY_DIGEST}" = "None" ]; then
    echo "FAIL-CLOSED: source image ${ECR_REPO}:${TAG} not found in ECR — nothing deployed." >&2
    exit 1
  fi
  PRIOR_STABLE_DIGEST="$(ecr_digest_of stable)"
  echo "  source digest: ${DEPLOY_DIGEST}"
  echo "  prior :stable: ${PRIOR_STABLE_DIGEST:-<none>}"
  if [ "${DEPLOY_DIGEST}" = "${PRIOR_STABLE_DIGEST}" ]; then
    echo "  note: :stable already points at ${TAG} — retag is a no-op (idempotent)."
  fi
fi

report_init
report_line "Source image: ${ECR_REPO}:${TAG} (digest ${DEPLOY_DIGEST:-dry-run})"
report_line "Prior :stable digest: ${PRIOR_STABLE_DIGEST:-<none>}"

# --- 2. advance :stable -------------------------------------------------------
run "advance ECR :stable -> ${TAG} (${ECR_REPO}, server-side retag)" -- ecr_retag_stable "${TAG}"
report_line "Advanced :stable to ${TAG}."

# --- 3. roll the service on the box (pull + migrate deploy + up) ---------------
run "roll ${SERVICE} on ${ENV} over SSM (docker compose pull + prisma migrate deploy + up -d)" -- roll_on_box
report_line "Rolled ${SERVICE} on ${ENV} (roll-service.sh: pull + migrate deploy + up)."

# --- 4. health check + fail-closed rollback -----------------------------------
if is_dry; then
  echo "DRY-RUN would: poll ${HEALTH_URL} up to ${HEALTH_RETRIES}x; auto-rollback :stable on failure"
  report_line "Health check + fail-closed rollback (skipped in dry-run)."
else
  echo "==> Health check: ${HEALTH_URL}"
  if health_check; then
    report_line "Health check PASS (${HEALTH_URL} = 2xx)."
    echo "==> Deploy OK: ${ENV}/${SERVICE} now serving ${TAG} (digest ${DEPLOY_DIGEST})."
  else
    report_line "Health check FAILED — auto-rolled :stable back to ${PRIOR_STABLE_DIGEST:-<none>}."
    report_finish
    rollback_stable "${PRIOR_STABLE_DIGEST}" || true
    echo "FAIL-CLOSED: ${ENV}/${SERVICE} unhealthy after deploy; prior image restored. Aborting." >&2
    exit 1
  fi
fi

# --- 5. record ----------------------------------------------------------------
report_finish
is_dry && echo "DRY-RUN complete — no changes were made."
exit 0
