#!/usr/bin/env bash
# power-data.sh — park the DATA tier of an Axiome AWS environment for a long
# idle window (≥ days). SEPARATE from power.sh on purpose: this touches storage
# and is destructive-by-design for ElastiCache, so it must never be on the same
# safe daily path as the compute toggle.
#
# RDS Postgres       -> stop-db-instance / start-db-instance.
#                       ⚠ AWS auto-restarts a stopped RDS after 7 DAYS. For a
#                       longer window, re-run `down` around day 6, or accept the
#                       few days of restarted billing. Never deleted: prod has
#                       deletion_protection = true.
# ElastiCache Redis  -> snapshot -> delete -> restore (it cannot be "stopped").
#                       `down` captures the live config to S3 + takes a FINAL
#                       snapshot, then deletes the replication group. `up`
#                       recreates it from that snapshot with the captured config.
#
# ‼ terraform-cd MUST be gated for the whole down→up window. Deleting the
#   replication group leaves Terraform state referencing a resource that no
#   longer exists; a CD apply mid-window would recreate it EMPTY (data loss) and
#   drift. Recreate uses the same id/config so Terraform re-adopts it cleanly.
#
# Usage:  ./power-data.sh <dev|staging|production> <down|up|status>
# Env overrides: AWS_REGION, AXIOME_PROJECT, AXIOME_SYSTEM_BUCKET, REPORTS_DIR
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|production> <down|up|status>" >&2; exit 2; }
[ $# -eq 2 ] || usage
ENV="$1"; ACTION="$2"
case "$ENV" in dev|staging|production) ;; *) usage ;; esac

PROJECT="${AXIOME_PROJECT:-axiome}"
REGION="${AWS_REGION:-eu-west-3}"
SYSTEM_BUCKET="${AXIOME_SYSTEM_BUCKET:-${PROJECT}-${ENV}-system}"
RDS_ID="${PROJECT}-${ENV}-pg"
RG_ID="${PROJECT}-${ENV}-redis"
STATE_KEY="power-data/redis-state.env"
STATE_S3="s3://${SYSTEM_BUCKET}/${STATE_KEY}"

# Reports live at the repo root of whatever checkout/worktree this script runs
# from, so the audit log is versioned alongside the code that produced it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../../..")"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports}"

# --- versioned audit log (one appended entry per change) -----------------------
log_event() { # <resource> <change>
  mkdir -p "$REPORTS_DIR"
  local ts who
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  who="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"
  printf '| %s | %s | %s | %s | %s |\n' "$ts" "$ENV" "$1" "$2" "$who" \
    >> "${REPORTS_DIR}/power-operations.md"
  echo "  logged: $1 — $2"
}

rds_state()   { aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$RDS_ID" \
                  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent; }
redis_state() { aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$RG_ID" \
                  --query 'ReplicationGroups[0].Status' --output text 2>/dev/null || echo absent; }

# ------------------------------------------------------------------------------
capture_redis_config() {
  local stamp snap
  stamp="$(date -u +%Y%m%d-%H%M)"
  snap="${RG_ID}-final-${stamp}"
  # cluster-level attrs (SG, subnet group, engine version, param group)
  read -r EV PG SUBNET SG <<<"$(aws elasticache describe-cache-clusters --region "$REGION" \
     --cache-cluster-id "${RG_ID}-001" \
     --query 'CacheClusters[0].[EngineVersion,CacheParameterGroup.CacheParameterGroupName,CacheSubnetGroupName,SecurityGroups[0].SecurityGroupId]' \
     --output text)"
  # replication-group-level attrs (node type, encryption, kms, window, desc)
  read -r NODE KMS WINDOW <<<"$(aws elasticache describe-replication-groups --region "$REGION" \
     --replication-group-id "$RG_ID" \
     --query 'ReplicationGroups[0].[CacheNodeType,KmsKeyId,SnapshotWindow]' --output text)"
  DESC="$(aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$RG_ID" \
     --query 'ReplicationGroups[0].Description' --output text)"
  cat > /tmp/redis-state.env <<EOF
RG_ID="${RG_ID}"
NODE="${NODE}"
ENGINE_VERSION="${EV}"
PARAM_GROUP="${PG}"
SUBNET_GROUP="${SUBNET}"
SG_IDS="${SG}"
KMS="${KMS}"
WINDOW="${WINDOW}"
DESC="${DESC}"
SNAPSHOT_NAME="${snap}"
EOF
  aws s3 cp /tmp/redis-state.env "$STATE_S3" --region "$REGION" >/dev/null
  echo "$snap"
}

case "$ACTION" in
  status)
    echo "${ENV} data tier:"
    echo "  RDS   ${RDS_ID}: $(rds_state)"
    echo "  Redis ${RG_ID}: $(redis_state)"
    ;;

  down)
    echo "== ${ENV} data-tier DOWN =="
    # 1) RDS: stop (never delete — deletion_protection on prod)
    if [ "$(rds_state)" = "available" ]; then
      aws rds stop-db-instance --region "$REGION" --db-instance-identifier "$RDS_ID" >/dev/null
      log_event "RDS ${RDS_ID}" "available -> stopping (AWS auto-restarts after 7d)"
    else
      echo "  RDS not 'available' (state: $(rds_state)) — skipping stop"
    fi
    # 2) ElastiCache: capture config -> final snapshot -> delete
    if [ "$(redis_state)" = "available" ]; then
      SNAP="$(capture_redis_config)"
      echo "  config saved to ${STATE_S3}; taking final snapshot ${SNAP} and deleting RG..."
      aws elasticache delete-replication-group --region "$REGION" \
        --replication-group-id "$RG_ID" --final-snapshot-identifier "$SNAP" >/dev/null
      log_event "Redis ${RG_ID}" "snapshot ${SNAP} taken, replication group deleting"
    else
      echo "  Redis not 'available' (state: $(redis_state)) — skipping snapshot/delete"
    fi
    echo "done. REMINDER: keep terraform-cd gated until you run 'up'."
    ;;

  up)
    echo "== ${ENV} data-tier UP =="
    # 1) RDS: start if stopped (no-op if AWS already auto-restarted it)
    case "$(rds_state)" in
      stopped) aws rds start-db-instance --region "$REGION" --db-instance-identifier "$RDS_ID" >/dev/null
               log_event "RDS ${RDS_ID}" "stopped -> starting" ;;
      available) echo "  RDS already available — skipping start" ;;
      *) echo "  RDS state: $(rds_state) — not starting" ;;
    esac
    # 2) ElastiCache: recreate from snapshot + captured config
    if [ "$(redis_state)" = "absent" ]; then
      aws s3 cp "$STATE_S3" /tmp/redis-state.env --region "$REGION" >/dev/null
      # shellcheck disable=SC1091
      . /tmp/redis-state.env
      echo "  recreating ${RG_ID} from ${SNAPSHOT_NAME}..."
      aws elasticache create-replication-group --region "$REGION" \
        --replication-group-id "$RG_ID" \
        --replication-group-description "$DESC" \
        --snapshot-name "$SNAPSHOT_NAME" \
        --engine redis --engine-version "$ENGINE_VERSION" \
        --cache-node-type "$NODE" --num-cache-clusters 1 \
        --cache-subnet-group-name "$SUBNET_GROUP" \
        --security-group-ids $SG_IDS \
        --cache-parameter-group-name "$PARAM_GROUP" \
        --port 6379 --snapshot-retention-limit 0 --snapshot-window "$WINDOW" \
        --at-rest-encryption-enabled --kms-key-id "$KMS" \
        --transit-encryption-enabled --transit-encryption-mode required >/dev/null
      log_event "Redis ${RG_ID}" "recreating from snapshot ${SNAPSHOT_NAME}"
    else
      echo "  Redis state: $(redis_state) — not recreating"
    fi
    echo "waiting for RDS available + Redis available..."
    aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$RDS_ID" || true
    aws elasticache wait replication-group-available --region "$REGION" --replication-group-id "$RG_ID" || true
    echo "data tier UP. Now re-enable terraform-cd (a plan should show NO changes)."
    ;;

  *) usage ;;
esac
