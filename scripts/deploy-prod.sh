#!/usr/bin/env bash
# deploy-prod.sh — the single authoritative production deploy (AXI-1954, epic
# AXI-1944, FR14-FR21/EC1/EC13, AC11-14/18/19/28).
#
# Re-ordered deploy (closes H2/H6/H7 from the feature doc): take the deploy
# lock -> preflight (box reachable, migration gate state) -> snapshot (only
# if migrations are pending, production only) -> roll the box to the
# IMMUTABLE SOURCE TAG (the gate runs on the NEW image while the OLD
# containers still serve, via roll-service.sh + the compose `migrate`
# dependency, AXI-1950/1953) -> poll `/health/ready` -> only on PASS advance
# ECR `:stable` (the LAST mutation) -> read-only baseline verification
# (warning only, never rolls back) -> release the lock.
#
# A failure at ANY step before `:stable` advances leaves `:stable` pointing
# at whatever it pointed to before this run. A failure after the roll wrote
# the new tag into the box's /opt/axiome/.env (gate failure, readiness
# failure, SSM indeterminate) re-rolls the box back to the tag it reads at
# the start of this run (FR15) — using roll-service.sh unmodified, never a
# second gate implementation.
#
# Usage:
#   scripts/deploy-prod.sh --tag <sha> [--env production] [--service backend] [--dry-run]
#   ENV=production TAG=<sha> SERVICE=backend scripts/deploy-prod.sh
#   make deploy-prod ENV=production TAG=<sha>
#
# Options / env vars (flags win over env vars):
#   --env      ENV        Target environment (dev|staging|production). Default: production.
#   --tag      TAG        Source image tag to promote (8-char git SHA). REQUIRED.
#   --service  SERVICE    backend | frontend | biocompute. Default: backend.
#   --dry-run  DRY_RUN=1  Print the plan; take no lock, make no AWS/SSM mutation.
#                         Still performs ONE read-only SSM query to report
#                         pending migrations when the box is reachable (FR19).
#
# Other env vars:
#   AWS_REGION           Default: eu-west-3.
#   AXIOME_PROJECT       Default: axiome. Used for ECR repo, RDS id, lock bucket.
#   REGISTRY_NAMESPACE   ECR namespace. Default: axiome.
#   HEALTH_URL           Health endpoint. Default per-service/env.
#   HEALTH_RETRIES       Health poll attempts. Default: 30.
#   HEALTH_POLL_INTERVAL Seconds between polls. Default: 10.
#   SNAPSHOT_RETENTION   Pre-deploy RDS snapshots kept per environment. Default: 5.
#   SSM_PREFLIGHT_WAIT   Seconds for the read-only preflight SSM call. Default: 120.
#   SSM_ROLL_WAIT        Seconds for the roll SSM call. Default: 900 (ssm-exec.sh default).
#
# SECURITY (NFR3): no secret is ever placed in an SSM command line or in a
# report line — the on-box scripts this calls read everything they need
# from /opt/axiome/.env, which is itself never printed. Reports go through
# scripts/lib/report.sh, which refuses a secret-shaped line outright.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/report.sh
. "${SCRIPT_DIR}/lib/report.sh"
# shellcheck source=lock.sh
. "${SCRIPT_DIR}/lock.sh"

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

case "${ENV}" in dev|staging|production) ;; *) echo "ERROR: --env/ENV must be dev|staging|production" >&2; exit 2 ;; esac

AWS_REGION="${AWS_REGION:-eu-west-3}"
AXIOME_PROJECT="${AXIOME_PROJECT:-axiome}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-axiome}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_POLL_INTERVAL="${HEALTH_POLL_INTERVAL:-10}"
SNAPSHOT_RETENTION="${SNAPSHOT_RETENTION:-5}"
SSM_PREFLIGHT_WAIT="${SSM_PREFLIGHT_WAIT:-120}"
SSM_ROLL_WAIT="${SSM_ROLL_WAIT:-900}"
RDS_ID="${AXIOME_PROJECT}-${ENV}-pg"
PREDEPLOY_PREFIX="${AXIOME_PROJECT}-${ENV}-predeploy-"
# Overridable for tests only; a real caller never sets this.
SEED_ENVIRONMENT_SCRIPT="${SEED_ENVIRONMENT_SCRIPT:-${SCRIPT_DIR}/seed-environment.sh}"

# service (dispatch name) -> ECR repo suffix + roll-service KEY.
case "${SERVICE}" in
  backend)    ECR_SUFFIX="backend";    ROLL_KEY="BACKEND_IMAGE_TAG" ;;
  frontend)   ECR_SUFFIX="frontend";   ROLL_KEY="FRONTEND_IMAGE_TAG" ;;
  biocompute) ECR_SUFFIX="biocompute"; ROLL_KEY="BIOCOMPUTE_IMAGE_TAG" ;;
  *) echo "ERROR: unknown SERVICE '${SERVICE}'. Valid: backend|frontend|biocompute" >&2; exit 2 ;;
esac
ECR_REPO="${REGISTRY_NAMESPACE}/${ECR_SUFFIX}"
IS_BACKEND=0; [ "${SERVICE}" = "backend" ] && IS_BACKEND=1

default_fqdn() {
  case "${ENV}" in
    production) echo "platform.axiomebio.com" ;;
    staging)   echo "staging.axiomebio.com" ;;
    dev)       echo "dev.axiomebio.com" ;;
    *)         echo "" ;;
  esac
}
# FR24/FR26/AC18: the backend deploy gate polls the JSON readiness endpoint.
# Non-backend services keep the plain 2xx check (they have no /health/ready).
default_health_path() { [ "${IS_BACKEND}" -eq 1 ] && echo "/api/v1/health/ready" || echo "/api/v1/health"; }
HEALTH_URL="${HEALTH_URL:-https://$(default_fqdn)$(default_health_path)}"

[ -n "${TAG}" ] || { echo "ERROR: --tag/TAG is required (the source image git SHA)." >&2; exit 2; }

is_dry() { [ "${DRY_RUN}" = "1" ]; }
is_production_class() { [ "${ENV}" = "production" ]; }

# --- ECR helpers --------------------------------------------------------------
ecr_registry() {
  local acct="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
  echo "${acct}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

ecr_digest_of() {
  aws ecr describe-images --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-ids "imageTag=$1" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo ""
}

ecr_retag_stable() {
  # $1=from_tag $2=expected_digest (DEPLOY_DIGEST resolved at preflight time,
  # review bounce #1 item 5): TAG is a mutable ECR tag. Something could
  # re-push it between preflight and this point in the deploy (minutes
  # later, after the roll + readiness poll). Re-resolve the digest TAG
  # points at NOW and refuse to advance :stable if it no longer matches
  # what was actually rolled out and verified ready — advancing :stable
  # to a digest the deploy never proved healthy would be worse than not
  # advancing it at all. Note: the roll has ALREADY succeeded at this
  # point (the box is healthy and serving); this is purely about which
  # digest :stable ends up naming, so no restore is attempted here.
  local from_tag="$1" expected_digest="${2:-}" manifest err now_digest
  if [ -n "${expected_digest}" ]; then
    now_digest="$(ecr_digest_of "${from_tag}")"
    if [ -n "${now_digest}" ] && [ "${now_digest}" != "None" ] && [ "${now_digest}" != "${expected_digest}" ]; then
      echo "ERROR: ${ECR_REPO}:${from_tag} moved during this deploy — it now points at ${now_digest}, not the ${expected_digest} this deploy rolled out and verified ready. Refusing to advance :stable to a digest this deploy never proved healthy. The roll itself already succeeded and production is healthy on ${expected_digest}; this only blocks the :stable retag." >&2
      return 1
    fi
  fi
  manifest="$(aws ecr batch-get-image --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO}" --image-ids "imageTag=${from_tag}" \
    --query 'images[0].imageManifest' --output text)"
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

# --- on-box remote calls -------------------------------------------------------
# roll_on_box <tag>: writes KEY=<tag> into /opt/axiome/.env on the box, pulls
# that tag's image and runs `docker compose up -d` for this service's
# targets — on a backend roll this is exactly what proves the migration gate
# against the NEW image while the OLD containers still serve (the compose
# dependency graph, AXI-1950/1953); it never re-implements the gate here.
# Exit codes mirror ssm-exec.sh: 0 success, 1 definite failure (gate/roll
# failed), 2 indeterminate (wait expired; remote state unknown).
roll_on_box() {
  local tag="$1" wait="${SSM_ROLL_WAIT}"
  { echo "export KEY='${ROLL_KEY}' IMAGE_TAG='${tag}' SERVICE='${SERVICE}'"; cat "${SCRIPT_DIR}/roll-service.sh"; } \
    | "${SCRIPT_DIR}/ssm-exec.sh" -e "${ENV}" -t "${wait}" -
}

# preflight_on_box: read-only remote check (FR19, NFR7/AC8, EC1). Prints:
#   PRIOR_TAG=<tag>            the tag currently recorded in .env for this service
#   ENV_FILE_MISSING           (backend+non-backend) .env absent — box never booted
#   COMPOSE_MISSING            (backend only) compose file absent
#   COMPOSE_GATE=present|absent  (backend only) whether `migrate:` is declared
#   MIGRATE_STATUS_RC=<n>      (backend only, when COMPOSE_GATE=present) exit
#                              code of the read-only `migrate-gate status`
#   followed by migrate-gate's own stdout/stderr verbatim.
# Never mutates anything on the box; always exits 0 itself (findings are
# encoded in the printed text) so the ONLY non-zero ssm-exec.sh exit here
# means the box could not be reached at all (EC1).
preflight_on_box() {
  local wait="${SSM_PREFLIGHT_WAIT}"
  {
    printf 'export KEY=%q BACKEND_PREFLIGHT=%q\n' "${ROLL_KEY}" "${IS_BACKEND}"
    cat <<'REMOTE'
set +e
ENV_FILE=/opt/axiome/.env
COMPOSE_FILE=/opt/axiome/docker-compose.yml
if [ ! -f "${ENV_FILE}" ]; then
  echo "ENV_FILE_MISSING"
  exit 0
fi
PRIOR="$(grep "^${KEY}=" "${ENV_FILE}" | head -1 | cut -d= -f2-)"
echo "PRIOR_TAG=${PRIOR}"
if [ "${BACKEND_PREFLIGHT}" != "1" ]; then
  exit 0
fi
if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "COMPOSE_MISSING"
  exit 0
fi
# Same services:/migrate: scoping as roll-service.sh's require_migrate_service
# (duplicated here deliberately — this story does not edit roll-service.sh).
if awk '
  /^services:[[:space:]]*$/ { in_services=1; next }
  in_services && /^[^[:space:]]/ { in_services=0 }
  in_services && /^  migrate:[[:space:]]*$/ { found=1 }
  END { exit !found }
' "${COMPOSE_FILE}"; then
  echo "COMPOSE_GATE=present"
else
  echo "COMPOSE_GATE=absent"
  exit 0
fi
STATUS_OUT="$(docker compose -f "${COMPOSE_FILE}" run --rm -T migrate migrate-gate status 2>&1)"
STATUS_RC=$?
echo "MIGRATE_STATUS_RC=${STATUS_RC}"
printf '%s\n' "${STATUS_OUT}"
exit 0
REMOTE
  } | "${SCRIPT_DIR}/ssm-exec.sh" -e "${ENV}" -t "${wait}" -
}

preflight_field() { printf '%s\n' "${PREFLIGHT_OUT}" | sed -n "s/^$1=//p" | head -1; }
preflight_has()   { printf '%s\n' "${PREFLIGHT_OUT}" | grep -qx "$1"; }

# A non-zero `migrate-gate status` does NOT mean "tables exist with no
# ledger" (review bounce #1) — confirmed by reading axiome-back's actual
# docker/migrate-gate/lib/status.js (origin/main 5516e5be): `status` folds
# a missing ledger into "every shipped migration is pending" and exits 0;
# it only exits non-zero for `not_configured` (a service's DB URL env var
# unset), `missing_migration_files`, or `status_undetermined` (its sqlQuery
# threw — e.g. the database is unreachable). The literal
#   REFUSE <service>: tables exist with no migration ledger. Run: migrate-gate baseline <service>
# line only exists in `apply.js`'s classify step (`needs_baseline`), which
# this read-only preflight never runs (apply would migrate any OTHER
# already-ready service — a mutation). So today this function's "named
# service" branch below is realistically unreachable from `status`'s own
# output; it is kept (and tested) in case a future status.js surfaces the
# same classification, and so the parsing logic itself is provably correct
# rather than asserted by inspection. Every other non-zero status is a
# configuration/connectivity problem and must NEVER be answered with a
# baseline instruction — doing so would send an operator to record
# migrations as applied, on a service that may simply be unreachable right
# now, silently diverging the production ledger from reality.
preflight_refuse_status_nonzero() {
  local status_rc="$1" named_service
  named_service="$(printf '%s\n' "${PREFLIGHT_OUT}" | sed -n 's/^REFUSE \([^:]*\): tables exist with no migration ledger\..*/\1/p' | head -1)"
  if [ -n "${named_service}" ]; then
    echo "REFUSE: migrate-gate reports ${named_service} has tables but no migration ledger on the ${ENV} box. Run: migrate-gate baseline ${named_service}, then retry this deploy." >&2
    return 0
  fi
  echo "REFUSE: migrate-gate status could not be determined on the ${ENV} box (exit ${status_rc:-unknown}) — this is a configuration or connectivity problem (e.g. a service's database URL not set, or the database unreachable from inside the migrate container), NOT evidence that any service needs baselining. Do NOT run migrate-gate baseline unless the raw output below explicitly names a service with tables and no ledger. Check both database URLs are present and reachable from the migrate container, then retry. Raw output:" >&2
  printf '%s\n' "${PREFLIGHT_OUT}" >&2
}

# Runs the preflight and classifies the result. Sets PREFLIGHT_OUT,
# PRIOR_TAG, PENDING_COUNT, PREFLIGHT_UNREACHABLE and, on a REFUSE
# condition, prints the exact message and returns non-zero. A box that
# cannot be reached at all (SSM exit 1 or 2) is ALSO a refusal (EC1):
# nothing has mutated yet. PREFLIGHT_UNREACHABLE distinguishes THAT case
# (the box truly never answered) from every other refusal below (the box
# DID answer and refused for a real reason) — a dry-run caller must not
# claim "box was not reachable" when it was reached and refused (review
# bounce #1, item 2).
PREFLIGHT_UNREACHABLE=0
run_preflight() {
  local rc out
  PREFLIGHT_UNREACHABLE=0
  if out="$(preflight_on_box)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${rc}" -ne 0 ]; then
    PREFLIGHT_OUT=""
    PREFLIGHT_UNREACHABLE=1
    if [ "${rc}" -eq 2 ]; then
      echo "FAIL-CLOSED: could not reach ${ENV} over SSM to preflight-check (INDETERMINATE) — the box may be stopped. Nothing has been changed." >&2
    else
      echo "FAIL-CLOSED: could not reach ${ENV} over SSM to preflight-check — the box may be stopped. Nothing has been changed." >&2
    fi
    return 1
  fi
  PREFLIGHT_OUT="${out}"
  if preflight_has "ENV_FILE_MISSING"; then
    echo "FAIL-CLOSED: /opt/axiome/.env does not exist on the ${ENV} box — has cloud-init finished?" >&2
    return 1
  fi
  PRIOR_TAG="$(preflight_field PRIOR_TAG)"
  PENDING_COUNT=0
  [ "${IS_BACKEND}" -eq 1 ] || return 0
  if preflight_has "COMPOSE_MISSING" || preflight_has "COMPOSE_GATE=absent"; then
    echo "REFUSE: ${ENV} box has no 'migrate' service in its compose definition — it predates the AXI-1950 asset-sync conversion. Run the one-time conversion: scripts/asset-sync.sh pull s3://${AXIOME_PROJECT}-${ENV}-system/onbox /opt/axiome on the box, point axiome.service at scripts/boot.sh, systemctl daemon-reload, then retry this deploy." >&2
    return 1
  fi
  local status_rc
  status_rc="$(preflight_field MIGRATE_STATUS_RC)"
  if [ -z "${status_rc}" ] || [ "${status_rc}" != "0" ]; then
    preflight_refuse_status_nonzero "${status_rc}"
    return 1
  fi
  PENDING_COUNT="$(printf '%s\n' "${PREFLIGHT_OUT}" | sed -n 's/^PENDING_COUNT=//p' | head -1)"
  PENDING_COUNT="${PENDING_COUNT:-0}"
  return 0
}

# --- RDS pre-deploy snapshot (FR16/FR17) --------------------------------------
take_predeploy_snapshot() {
  local snap_id
  snap_id="${PREDEPLOY_PREFIX}$(date -u +%Y%m%d%H%M%S)"
  echo "==> Creating pre-deploy RDS snapshot ${snap_id} (${RDS_ID})"
  if ! aws rds create-db-snapshot --region "${AWS_REGION}" \
      --db-instance-identifier "${RDS_ID}" --db-snapshot-identifier "${snap_id}" >/dev/null; then
    echo "FAIL-CLOSED: could not create pre-deploy snapshot ${snap_id} — stopping before any migration." >&2
    return 1
  fi
  echo "  waiting for ${snap_id} to become available..."
  if ! aws rds wait db-snapshot-available --region "${AWS_REGION}" --db-snapshot-identifier "${snap_id}"; then
    echo "FAIL-CLOSED: pre-deploy snapshot ${snap_id} did not become available — stopping before any migration." >&2
    return 1
  fi
  SNAPSHOT_ID="${snap_id}"
  echo "  snapshot available: ${snap_id}"
}

prune_old_snapshots() {
  local lines sorted old id
  lines="$(aws rds describe-db-snapshots --region "${AWS_REGION}" \
    --db-instance-identifier "${RDS_ID}" --snapshot-type manual \
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'${PREDEPLOY_PREFIX}')].[DBSnapshotIdentifier,SnapshotCreateTime]" \
    --output text 2>/dev/null)" || { echo "WARN: could not list pre-deploy snapshots for pruning." >&2; return 0; }
  [ -z "${lines}" ] && return 0
  sorted="$(printf '%s\n' "${lines}" | sort -k2 -r)"
  old="$(printf '%s\n' "${sorted}" | tail -n +"$((SNAPSHOT_RETENTION + 1))" | awk 'NF{print $1}')"
  [ -z "${old}" ] && return 0
  while IFS= read -r id; do
    [ -z "${id}" ] && continue
    echo "  pruning old pre-deploy snapshot ${id} (retention ${SNAPSHOT_RETENTION})"
    aws rds delete-db-snapshot --region "${AWS_REGION}" --db-snapshot-identifier "${id}" >/dev/null 2>&1 \
      || echo "WARN: could not delete old snapshot ${id}." >&2
  done <<< "${old}"
}

# --- readiness polling (FR24/FR26, EC12) --------------------------------------
READY_LAST_BODY=""
poll_ready() {
  local i raw code
  for i in $(seq 1 "${HEALTH_RETRIES}"); do
    raw="$(curl -s -m 10 -w '\nHTTP_STATUS:%{http_code}' "${HEALTH_URL}" 2>/dev/null || true)"
    code="$(printf '%s' "${raw}" | sed -n 's/^HTTP_STATUS:\(.*\)$/\1/p' | tail -1)"
    READY_LAST_BODY="$(printf '%s' "${raw}" | sed '$d')"
    echo "  readiness ${HEALTH_URL} -> ${code:-<none>} (attempt ${i}/${HEALTH_RETRIES})"
    [ "${code}" = "200" ] && return 0
    sleep "${HEALTH_POLL_INTERVAL}"
  done
  return 1
}

# Non-backend services have no JSON readiness body — plain 2xx check. Uses
# the SAME wrapped-footer curl shape as poll_ready() (body + trailing
# `HTTP_STATUS:<code>` line, code extracted via sed) rather than `-o
# /dev/null`, so there is exactly one curl invocation shape in this whole
# script to stub/reason about — a `-o /dev/null` variant would discard the
# body in real curl but a test double has no way to know that from argv
# alone, which once made this function misread a stubbed body as its code.
poll_simple_health() {
  local i raw code
  for i in $(seq 1 "${HEALTH_RETRIES}"); do
    raw="$(curl -s -m 10 -w '\nHTTP_STATUS:%{http_code}' "${HEALTH_URL}" 2>/dev/null || true)"
    code="$(printf '%s' "${raw}" | sed -n 's/^HTTP_STATUS:\(.*\)$/\1/p' | tail -1)"
    echo "  health ${HEALTH_URL} -> ${code:-<none>} (attempt ${i}/${HEALTH_RETRIES})"
    [[ "${code}" =~ ^2 ]] && return 0
    sleep "${HEALTH_POLL_INTERVAL}"
  done
  return 1
}

# A restore-to-PRIOR_TAG re-points the BOX at the previous image, but never
# touches the DATABASE SCHEMA migrate-gate already wrote (review bounce #1,
# item 3). Depending on where the failure happened, the schema is either
# DEFINITELY ahead of the restored image (the gate completed before a LATER
# failure, e.g. readiness) or its true state is UNKNOWN (the gate itself
# failed partway through a multi-migration run within a service, or the
# roll result is INDETERMINATE). Either way a restored OLDER image may now
# run against a NEWER schema than it expects. This function never auto-
# restores the pre-deploy snapshot — that is a human decision — it only
# names it (when one was taken) as the point-in-time rollback path.
report_rollback_caveat() {
  local certainty="$1" msg # "confirmed" | "unknown"
  if [ "${certainty}" = "confirmed" ]; then
    msg="The migration gate completed successfully before this failure — the schema is now fully migrated, and the restored (older) image's own schema expectations predate this migration; restoring the box does NOT undo the schema change."
  else
    msg="Migrations may have PARTIALLY applied before this failure (the gate stops at the first failing migration within a service, not before it) — the schema's true state relative to the restored (older) image is UNKNOWN."
  fi
  if [ -n "${SNAPSHOT_ID}" ]; then
    msg="${msg} The pre-deploy snapshot ${SNAPSHOT_ID} is the point-in-time rollback path if the schema needs to be reverted — this script does NOT restore it automatically."
  else
    msg="${msg} No pre-deploy snapshot was taken this run — there is no automatic point-in-time rollback path available."
  fi
  report_line "${msg}"
  echo "${msg}" >&2
}

ready_failure_reasons() {
  command -v jq >/dev/null 2>&1 || { echo "${READY_LAST_BODY}"; return 0; }
  printf '%s' "${READY_LAST_BODY}" | jq -r '.services[]? | "\(.service): \(.reason // "unknown")"' 2>/dev/null \
    || echo "${READY_LAST_BODY}"
}

# --- previous-tag restore (closes the AXI-1953 known gap) --------------------
# roll-service.sh writes KEY=<tag> into .env BEFORE the gate runs. On any
# failure from here on, .env may name a tag that is not actually serving
# (gate failure) or whose state is unknown (readiness failure / SSM
# indeterminate). Re-roll to PRIOR_TAG to put the box back and prove it —
# never a second gate implementation, always through roll-service.sh.
restore_previous_tag() {
  if [ -z "${PRIOR_TAG}" ]; then
    echo "FAIL-CLOSED: no previous tag was captured for ${SERVICE}/${ENV} — cannot auto-restore. Inspect /opt/axiome/.env on the box by hand." >&2
    return 1
  fi
  echo "==> Restoring ${SERVICE}/${ENV} to the previous tag ${PRIOR_TAG}"
  local rc
  if roll_on_box "${PRIOR_TAG}"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL-CLOSED: restoring ${SERVICE}/${ENV} to ${PRIOR_TAG} ALSO FAILED (roll exit ${rc}) — /opt/axiome/.env may still name the failed tag ${TAG}. Manual intervention required: SSH/SSM onto the box, check 'docker compose ps' and 'docker compose logs migrate', and re-run roll-service.sh with KEY=${ROLL_KEY} IMAGE_TAG=${PRIOR_TAG} SERVICE=${SERVICE} by hand." >&2
    return 1
  fi
  if [ "${IS_BACKEND}" -eq 1 ]; then
    if poll_ready; then
      echo "  confirmed: ${ENV} is serving the restored tag ${PRIOR_TAG} (readiness OK)."
      return 0
    fi
  else
    if poll_simple_health; then
      echo "  confirmed: ${ENV} is serving the restored tag ${PRIOR_TAG}."
      return 0
    fi
  fi
  echo "FAIL-CLOSED: restored the tag in /opt/axiome/.env to ${PRIOR_TAG} but could NOT confirm the box is healthy afterwards. Check the box by hand before retrying." >&2
  return 1
}

# --- plan banner --------------------------------------------------------------
if is_dry; then
  REPO_DISPLAY="<account>.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
  MODE_DISPLAY="DRY-RUN (no lock, no AWS/SSM mutation — one read-only SSM query)"
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

PRIOR_TAG=""
PENDING_COUNT=0
SNAPSHOT_ID=""
MIGRATION_FACTS_TEXT=""
DEPLOY_TOKEN=""

if is_dry; then
  # FR19: still perform the ONE read-only preflight so the pending-migration
  # list is real, but never touch the lock or AWS; the box may simply not be
  # up (DRY_RUN is explicitly allowed while prod is powered off).
  DEPLOY_DIGEST=""
  echo "DRY-RUN would: verify ${ECR_REPO}:${TAG} exists and resolve its digest"
  echo "DRY-RUN would: take the deploy lock for ${ENV}"
  if run_preflight; then
    if [ "${IS_BACKEND}" -eq 1 ]; then
      echo "DRY-RUN: pending migrations per service (read-only check against ${ENV}):"
      printf '%s\n' "${PREFLIGHT_OUT}" | grep '^PENDING ' || echo "  (none pending)"
      echo "DRY-RUN: PENDING_COUNT=${PENDING_COUNT}"
      if [ "${PENDING_COUNT}" != "0" ] && is_production_class; then
        echo "DRY-RUN would: take a pre-deploy RDS snapshot of ${RDS_ID} before migrating."
      fi
    else
      echo "DRY-RUN: ${SERVICE} carries no schema — no migration/snapshot/baseline step applies (EC13)."
    fi
    echo "DRY-RUN: box currently serving tag ${PRIOR_TAG:-<unknown>} for ${ROLL_KEY}."
  elif [ "${PREFLIGHT_UNREACHABLE}" -eq 1 ]; then
    echo "DRY-RUN: could not determine pending migrations — ${ENV} box was not reachable over SSM."
  else
    echo "DRY-RUN: could not determine pending migrations — the ${ENV} box WAS reachable but the preflight check refused (see the REFUSE/FAIL-CLOSED message above for the exact reason)."
  fi
  echo "DRY-RUN would: roll ${SERVICE} on ${ENV} to ${TAG}, poll readiness, then advance ECR :stable only on PASS."
  echo "DRY-RUN complete — no changes were made."
  exit 0
fi

# --- 0. locks (FR28/FR29/FR42/FR43) -------------------------------------------
# Acquire-then-check (AXI-1967): take the deploy lock FIRST, then verify
# data-tier and apply are both free. If either is held, lock_acquire_exclusive
# releases the deploy lock THIS call just took and refuses, naming the
# holder — never the old check-then-acquire order, which left a window
# where two operations could both see the others free and both proceed.
echo "==> Acquiring the deploy lock for ${ENV} (then verifying data-tier and apply are free)"
LOCK_ACQUIRE_OUT="$(lock_acquire_exclusive "${ENV}" deploy "deploy service=${SERVICE} tag=${TAG}" data-tier apply)" || {
  echo "FAIL-CLOSED: could not acquire the deploy lock for ${ENV}, or the data-tier/apply lock is held — refusing to deploy. See above for which lock is held." >&2
  exit 1
}
echo "  ${LOCK_ACQUIRE_OUT}"
DEPLOY_TOKEN="$(printf '%s\n' "${LOCK_ACQUIRE_OUT}" | sed -n 's/.*token=\([^ ]*\).*/\1/p')"
lock_mark_for_auto_release "${ENV}" deploy "${DEPLOY_TOKEN}"
lock_install_exit_trap

# --- 1. preflight: source image exists, resolve digests ----------------------
echo "==> Preflight: verifying ${ECR_REPO}:${TAG} exists in ECR"
DEPLOY_DIGEST="$(ecr_digest_of "${TAG}")"
if [ -z "${DEPLOY_DIGEST}" ] || [ "${DEPLOY_DIGEST}" = "None" ]; then
  echo "FAIL-CLOSED: source image ${ECR_REPO}:${TAG} not found in ECR — nothing deployed." >&2
  exit 1
fi
PRIOR_STABLE_DIGEST="$(ecr_digest_of stable)"
echo "  source digest: ${DEPLOY_DIGEST}"
echo "  prior :stable: ${PRIOR_STABLE_DIGEST:-<none>}"

echo "==> Preflight: checking ${ENV} box state (FR15/NFR7/EC1)"
if ! run_preflight; then
  exit 1
fi
echo "  box currently serving: ${PRIOR_TAG:-<unknown>} (${ROLL_KEY})"
[ "${IS_BACKEND}" -eq 1 ] && echo "  pending migrations: ${PENDING_COUNT}"

report_init "${ENV}" "deploy-${SERVICE}" "tag=${TAG}" "digest=${DEPLOY_DIGEST}" "prior_tag=${PRIOR_TAG:-unknown}"
report_line "Source image: ${ECR_REPO}:${TAG} (digest ${DEPLOY_DIGEST})"
report_line "Prior :stable digest: ${PRIOR_STABLE_DIGEST:-<none>}"
report_line "Box was serving ${ROLL_KEY}=${PRIOR_TAG:-<unknown>} before this run."

# Re-check the data-tier lock (review bounce #1 item 6): preflight above can
# take a while (an SSM round-trip to the box). A park could start AFTER the
# first check at the top of this script but BEFORE we take a snapshot/roll
# against a now-parking database. Re-running the same free-check here
# narrows that window to "between this line and the snapshot/roll calls
# just below" — it does NOT close the race (a park could still start in
# that remaining gap); closing it fully is a lock-side change (taking the
# data-tier lock itself for the duration of the snapshot+roll) that is out
# of scope for this story.
echo "==> Re-checking the data-tier lock for ${ENV} is still free (post-preflight)"
if ! lock_require_free "${ENV}" data-tier; then
  echo "FAIL-CLOSED: the data-tier lock for ${ENV} is now held (parked during preflight) — refusing to snapshot/roll against it." >&2
  report_finish "failed-lock-race"
  exit 1
fi

# FR43 (AXI-1967): extend the same re-check to apply — a Terraform apply
# could likewise have started during the preflight SSM round-trip.
echo "==> Re-checking the apply lock for ${ENV} is still free (post-preflight)"
if ! lock_require_free "${ENV}" apply; then
  echo "FAIL-CLOSED: the apply lock for ${ENV} is now held (a Terraform apply started during preflight) — refusing to snapshot/roll against it." >&2
  report_finish "failed-lock-race"
  exit 1
fi

# --- 2. snapshot (FR16/FR17) — backend + pending migrations + production only
if [ "${IS_BACKEND}" -eq 1 ] && [ "${PENDING_COUNT}" != "0" ] && is_production_class; then
  if ! take_predeploy_snapshot; then
    report_line "Snapshot FAILED — stopped before migrating. :stable untouched."
    report_finish "failed-snapshot"
    exit 1
  fi
  report_line "Pre-deploy snapshot: ${SNAPSHOT_ID}"
  prune_old_snapshots
else
  if [ "${IS_BACKEND}" -eq 1 ]; then
    report_line "No pending migrations (or non-production env) — no snapshot taken."
  else
    report_line "${SERVICE} carries no schema (EC13) — no snapshot step."
  fi
fi

# --- 3. roll to the immutable source tag (runs the gate on the new image) ----
echo "==> Rolling ${SERVICE} on ${ENV} to ${TAG} (pull + migrate gate + up, old containers keep serving until the gate passes)"
ROLL_LOG="$(mktemp)"
ROLL_RC=0
if roll_on_box "${TAG}" > "${ROLL_LOG}" 2>&1; then
  ROLL_RC=0
else
  ROLL_RC=$?
fi
cat "${ROLL_LOG}"

if [ "${ROLL_RC}" -eq 2 ]; then
  # FR20: INDETERMINATE — the remote roll may have half-run. Never advance
  # :stable; do not blindly re-roll (the box's state is unknown, not known
  # bad) — tell the operator exactly what to check by hand.
  report_line "Roll result: INDETERMINATE (SSM wait expired, remote command cancelled). :stable NOT advanced."
  [ "${IS_BACKEND}" -eq 1 ] && report_rollback_caveat unknown
  report_finish "indeterminate"
  echo "FAIL-CLOSED: the roll result is INDETERMINATE — the remote command was cancelled after the wait expired and its final state is unknown. :stable was NOT advanced." >&2
  echo "Before retrying: SSM/SSH onto the ${ENV} box and check 'docker compose ps', 'docker compose logs migrate' and the ${ROLL_KEY} line in /opt/axiome/.env by hand. Do not assume the previous image is serving." >&2
  exit 1
fi

if [ "${ROLL_RC}" -ne 0 ]; then
  # Definite gate/roll failure: .env now names the FAILED tag even though
  # the old containers never swapped (AXI-1953 known gap #1). Restore it.
  report_line "Roll FAILED (exit ${ROLL_RC}) — migration gate did not pass. Restoring previous tag ${PRIOR_TAG:-<unknown>}."
  [ "${IS_BACKEND}" -eq 1 ] && report_rollback_caveat unknown
  if restore_previous_tag; then
    report_line "Restored and confirmed ${ROLL_KEY}=${PRIOR_TAG} is serving. :stable untouched."
    report_finish "failed-roll-restored"
  else
    report_line "Restore to ${PRIOR_TAG:-<unknown>} FAILED or could not be confirmed. :stable untouched but the box state needs manual verification."
    report_finish "failed-roll-restore-failed"
  fi
  echo "FAIL-CLOSED: ${ENV}/${SERVICE} roll failed — migration gate did not pass. :stable was never advanced." >&2
  exit 1
fi

# Capture this run's MIGRATION_FACTS (FR7). Decision: an unavailable-facts
# result does NOT fail the production deploy by itself — the containers are
# already serving (proven next by readiness); it is recorded as a WARNING
# only, same stance as AXI-1953's own roll contract (a separate
# qualification step, not this deploy, treats it as a hard failure).
MIGRATION_FACTS_TEXT="$(grep -E '^(MIGRATION_FACTS:|MIGRATION_FACTS_OVERRIDE:)' "${ROLL_LOG}" || true)"
MIGRATION_FACTS_UNAVAILABLE="$(grep -E '^MIGRATION_FACTS_UNAVAILABLE:' "${ROLL_LOG}" || true)"
rm -f "${ROLL_LOG}"
if [ -n "${MIGRATION_FACTS_TEXT}" ]; then
  while IFS= read -r fline; do
    [ -n "${fline}" ] && report_line "${fline}"
  done <<< "${MIGRATION_FACTS_TEXT}"
elif [ -n "${MIGRATION_FACTS_UNAVAILABLE}" ]; then
  report_line "WARNING: ${MIGRATION_FACTS_UNAVAILABLE}"
fi

# --- 4. readiness (FR24/FR26, EC12) -------------------------------------------
echo "==> Readiness check: ${HEALTH_URL}"
READY_OK=0
if [ "${IS_BACKEND}" -eq 1 ]; then
  poll_ready && READY_OK=1
else
  poll_simple_health && READY_OK=1
fi

if [ "${READY_OK}" -ne 1 ]; then
  REASONS="$([ "${IS_BACKEND}" -eq 1 ] && ready_failure_reasons || true)"
  echo "FAIL-CLOSED: ${ENV}/${SERVICE} did not become ready after ${HEALTH_RETRIES} attempts." >&2
  [ -n "${REASONS}" ] && { echo "Reasons:" >&2; printf '%s\n' "${REASONS}" >&2; }
  report_line "Readiness FAILED after ${HEALTH_RETRIES} attempts. Reasons: ${REASONS:-<none captured>}"
  [ "${IS_BACKEND}" -eq 1 ] && report_rollback_caveat confirmed
  if restore_previous_tag; then
    report_line "Restored and confirmed ${ROLL_KEY}=${PRIOR_TAG} is serving. :stable untouched."
    report_finish "failed-readiness-restored"
  else
    report_line "Restore to ${PRIOR_TAG:-<unknown>} FAILED or could not be confirmed. :stable untouched but the box state needs manual verification."
    report_finish "failed-readiness-restore-failed"
  fi
  exit 1
fi
report_line "Readiness PASS (${HEALTH_URL} = 200)."
echo "==> ${ENV}/${SERVICE} is ready, serving ${TAG} (digest ${DEPLOY_DIGEST})."

# --- 5. advance :stable — the LAST mutation (FR14) ----------------------------
echo "==> Advancing ECR :stable -> ${TAG}"
if ! ecr_retag_stable "${TAG}" "${DEPLOY_DIGEST}"; then
  report_line "Readiness passed and ${TAG} is serving, but advancing :stable FAILED. Production is now on a build :stable does not name."
  report_finish "stable-advance-failed"
  echo "FAIL-CLOSED: ${ENV}/${SERVICE} is healthy and serving ${TAG}, but advancing ECR :stable FAILED. Production is serving a build that :stable does NOT point at — retry 'aws ecr put-image --repository-name ${ECR_REPO} --image-tag stable' by hand with the digest ${DEPLOY_DIGEST}." >&2
  exit 1
fi
report_line "Advanced :stable to ${TAG}."

# --- 6. baseline verification (FR21) — backend only, warning only ------------
if [ "${IS_BACKEND}" -eq 1 ]; then
  echo "==> Read-only baseline verification (FR21)"
  BASELINE_OUT=""
  BASELINE_RC=0
  if BASELINE_OUT="$("${SEED_ENVIRONMENT_SCRIPT}" --check -e "${ENV}" 2>&1)"; then
    BASELINE_RC=0
  else
    BASELINE_RC=$?
  fi
  echo "${BASELINE_OUT}"
  if [ "${BASELINE_RC}" -eq 0 ]; then
    report_line "Baseline verification: OK (expected == actual for reference data, system rule pack, bootstrap roles)."
  elif [ "${BASELINE_RC}" -eq 3 ]; then
    # Exit 3 is seed-environment.sh's distinct "could not derive expected
    # counts" code (review bounce #1 item 4). In this workflow only
    # axiome-infra is checked out (deploy-production.yml does not add an
    # axiome-back checkout or any new token/secret to do so — an owner
    # decision, follow-up noted in the handback), so this branch is the
    # routine, expected case here — NOT a count mismatch. Reporting it as
    # MISMATCH would be false; report it as not performed instead.
    report_line "Baseline verification: NOT PERFORMED (expected counts unavailable — axiome-back is not checked out in this workflow). See the deploy log above for detail."
  else
    report_line "Baseline verification: MISMATCH (warning only — does not roll back). See the deploy log for the expected/actual table."
  fi
fi

report_finish "completed"
echo "==> Deploy OK: ${ENV}/${SERVICE} now serving ${TAG} (digest ${DEPLOY_DIGEST}); :stable advanced."
exit 0
