#!/usr/bin/env bash
# power-up-all.sh — one-call TURN-ON for an Axiome AWS environment.
#
# Orchestrates the documented turn-on sequence (see docs/power-runbook.md) end to
# end, in the right order, with preflight safety checks:
#
#   preflight (read-only)  ->  data-up (RDS + Redis restore, wait healthy)
#                          ->  power-up (EC2 start, health-gated, time-to-up)
#                          ->  post: what to verify before un-gating terraform-cd
#
# It reuses the two single-tier scripts unchanged (power-data.sh, power.sh); this
# is only the orchestration + preflight + a consolidated report on top of them.
#
# SAFETY:
#   - Read-only preflight ALWAYS runs first and ABORTS before any mutation if a
#     restore input is missing (Redis snapshot / redis-state.env) — that snapshot
#     is the only copy of the Redis data.
#   - The mutating run requires an explicit opt-in: pass `--yes` (or POWER_CONFIRM=1).
#     Without it the script does preflight only and stops (a safe dry-run).
#   - ‼ terraform-cd must stay gated for the whole Redis restore window. Production
#     `apply` is already manual (GitHub Environment approval), so DO NOT approve an
#     apply until after this completes and `terraform plan` shows NO changes.
#
# Usage:
#   ./power-up-all.sh <dev|staging|production> [--yes] [--dry-run]
#   POWER_CONFIRM=1 ./power-up-all.sh production            # same as --yes
#
# Env overrides: AWS_REGION, AXIOME_PROJECT, AXIOME_SYSTEM_BUCKET, REPORTS_DIR
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: $0 <dev|staging|production> [--yes] [--dry-run]" >&2; exit 2; }

# --- args ---------------------------------------------------------------------
[ $# -ge 1 ] || usage
ENV="$1"; shift || true
case "$ENV" in dev|staging|production) ;; *) usage ;; esac
CONFIRM="${POWER_CONFIRM:-0}"; DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --yes) CONFIRM=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
done

PROJECT="${AXIOME_PROJECT:-axiome}"
REGION="${AWS_REGION:-eu-west-3}"
SYSTEM_BUCKET="${AXIOME_SYSTEM_BUCKET:-${PROJECT}-${ENV}-system}"
RG_ID="${PROJECT}-${ENV}-redis"
STATE_S3="s3://${SYSTEM_BUCKET}/power-data/redis-state.env"

# Shared reporting/audit helpers (report_*, log_event, REPORTS_DIR).
# shellcheck source=_power_lib.sh
. "${HERE}/_power_lib.sh"

redis_state() { aws elasticache describe-replication-groups --region "$REGION" \
  --replication-group-id "$RG_ID" --query 'ReplicationGroups[0].Status' \
  --output text 2>/dev/null || echo absent; }

die() { echo "ABORT: $*" >&2; exit 1; }

# --- preflight (read-only; must pass before any mutation) ---------------------
snapshot_name_from_state() {
  aws s3 cp "$STATE_S3" - --region "$REGION" 2>/dev/null \
    | sed -n 's/^SNAPSHOT_NAME="\(.*\)"$/\1/p'
}

assert_restore_inputs() { # only matters when Redis must be recreated
  [ "$(redis_state)" = "absent" ] || return 0
  echo "  Redis is absent -> restore path; verifying inputs exist..."
  aws s3 ls "$STATE_S3" --region "$REGION" >/dev/null 2>&1 \
    || die "redis-state.env not found at ${STATE_S3} (cannot restore Redis)."
  local snap; snap="$(snapshot_name_from_state)"
  [ -n "$snap" ] || die "SNAPSHOT_NAME missing from ${STATE_S3}."
  local st; st="$(aws elasticache describe-snapshots --region "$REGION" \
    --snapshot-name "$snap" --query 'Snapshots[0].SnapshotStatus' --output text 2>/dev/null || echo absent)"
  [ "$st" = "available" ] || die "Redis snapshot ${snap} not available (status: ${st})."
  echo "  OK: snapshot ${snap} available; state file present."
}

preflight() {
  echo "== TURN-ON preflight (${ENV}) =="
  local who; who="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo unknown)"
  [ "$who" != "unknown" ] || die "no AWS access (aws sts get-caller-identity failed)."
  echo "  aws: ${who} (region ${REGION})"
  echo "  current state:"
  "${HERE}/power.sh" "$ENV" status | sed 's/^/    /'
  "${HERE}/power-data.sh" "$ENV" status | sed 's/^/    /'
  assert_restore_inputs
  echo "  preflight OK."
}

# --- run ----------------------------------------------------------------------
preflight

if [ "$DRY_RUN" = "1" ] || [ "$CONFIRM" != "1" ]; then
  echo
  echo "DRY-RUN (no changes made). Re-run with --yes to execute the turn-on:"
  echo "    $0 ${ENV} --yes"
  exit 0
fi

report_init "$ENV" "turn-on"
report_section "Turn-on sequence"
report_line "Actor $(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"

echo
echo "== [1/2] DATA tier up (RDS start + Redis restore) =="
"${HERE}/power-data.sh" "$ENV" up
report_line "Data tier: data-up completed (RDS started; Redis restored if it was absent)."

echo
echo "== [2/2] COMPUTE up (EC2 start + health gate) =="
"${HERE}/power.sh" "$ENV" up
report_line "Compute: power-up completed (EC2 started; public health probe returned 200)."

report_section "Next (before un-gating terraform-cd)"
report_line "Run: cd providers/aws && scripts/deploy.sh ${ENV} --plan-only  # expect NO changes (Redis re-adopted by id/config)"
report_line "Only after a clean plan, allow terraform-cd apply again."
report_finish
log_event "$ENV" "platform" "TURN-ON completed (data + compute up)"

echo
echo "TURN-ON complete for ${ENV}."
echo "VERIFY next: terraform plan should show NO changes, then un-gate terraform-cd."
