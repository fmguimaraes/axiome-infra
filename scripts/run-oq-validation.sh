#!/usr/bin/env bash
# run-oq-validation.sh — on-demand Operational Qualification validation of a
# LIVE environment (Workflow 6, IEC 62304 §5.8 / 82304-1), independent of any
# fresh deploy or migration event.
#
# Two callers, same evidence path:
#   - MANUAL: run this any time ("validate production right now") against
#     whatever is currently serving. Reads the box's own /opt/axiome/.env for
#     the per-service image tags it is serving (read-only, via ssm-exec.sh)
#     and probes the live gateway — no deploy, no roll, nothing mutated.
#   - CD: deploy-prod.sh calls this after a successful roll, passing the
#     MIGRATION_FACTS it already captured, so the SAME record also carries
#     the IQ migration evidence for that roll (see generate-qualification-record.sh).
#
# This script never rolls, migrates, or writes to the box — it only reads the
# currently-serving facts and emits the machine Qualification Record via
# scripts/generate-qualification-record.sh. The IQ/OQ/PQ documentation SET
# (axiome-docs/04 - architecture/qualification/<release-line>/) is assembled
# separately, by reference, per SDLC.md Workflow 6 — this script produces the
# evidence that assembly cites, it does not write the doc set itself.
#
# Usage:
#   scripts/run-oq-validation.sh [-e ENV] [-r REGION]
# Optional env passthrough (forwarded to generate-qualification-record.sh):
#   MIGRATION_FACTS_LINES   set by deploy-prod.sh on a fresh roll; unset on an
#                           ad-hoc manual run (IQ migration block then SKIPs,
#                           which is correct — nothing migrated THIS session).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSM="${SCRIPT_DIR}/ssm-exec.sh"

ENVIRONMENT="production"
REGION="${AWS_REGION:-eu-west-3}"
ENV_ARGS=()
while getopts "e:r:h" opt; do
  case "${opt}" in
    e) ENVIRONMENT="${OPTARG}"; ENV_ARGS+=("-e" "${OPTARG}") ;;
    r) REGION="${OPTARG}"; ENV_ARGS+=("-r" "${OPTARG}") ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Run: $0 -h" >&2; exit 2 ;;
  esac
done

case "${ENVIRONMENT}" in
  production) FQDN="platform.axiomebio.com" ;;
  staging)    FQDN="staging.axiomebio.com" ;;
  dev)        FQDN="dev.axiomebio.com" ;;
  *) echo "Unknown environment '${ENVIRONMENT}'" >&2; exit 2 ;;
esac
GATEWAY_URL="https://${FQDN}"

echo "==> Reading currently-serving image tags from ${ENVIRONMENT} (read-only)..."
SERVING="$("${SSM}" "${ENV_ARGS[@]}" "grep -E '^(BACKEND|FRONTEND|BIOCOMPUTE)_IMAGE_TAG=' /opt/axiome/.env")"
BACKEND_TAG="$(printf '%s\n' "${SERVING}" | sed -n 's/^BACKEND_IMAGE_TAG=//p')"
FRONTEND_TAG="$(printf '%s\n' "${SERVING}" | sed -n 's/^FRONTEND_IMAGE_TAG=//p')"
BIOCOMPUTE_TAG="$(printf '%s\n' "${SERVING}" | sed -n 's/^BIOCOMPUTE_IMAGE_TAG=//p')"
echo "    backend=${BACKEND_TAG:-?} frontend=${FRONTEND_TAG:-?} biocompute=${BIOCOMPUTE_TAG:-?}"

IMAGE_TAG="backend=${BACKEND_TAG:-?},frontend=${FRONTEND_TAG:-?},biocompute=${BIOCOMPUTE_TAG:-?}"

echo "==> Running OQ/PQ checks against ${GATEWAY_URL} and emitting the Qualification Record..."
IMAGE_TAG="${IMAGE_TAG}" \
  GATEWAY_URL="${GATEWAY_URL}" \
  MIGRATION_FACTS_LINES="${MIGRATION_FACTS_LINES:-}" \
  bash "${SCRIPT_DIR}/generate-qualification-record.sh" aws "${ENVIRONMENT}"
