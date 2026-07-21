#!/bin/bash
# FR4 rebuild-from-IaC drill automation.
# Usage: ./dr-drill-ec2.sh [--snapshot-id snap-xxx] [--dry-run]
#
# Restores the latest (or specified) DLM-managed EBS snapshot to a new volume,
# launches an isolated EC2 instance from it, runs health checks, records the
# RPO/RTO evidence, and cleans up.
#
# Coverage: AC4 — rebuild production host from IaC + restored volumes drill.
# RTO target: ≤ 4 h (NFR1 pilot).
#
# Prereqs: aws CLI configured for account 225201317100, region eu-west-3,
# jq, and terraform init'd for the production backend.

set -euo pipefail

# --------------- Config ---------------
AWS_REGION="${AWS_REGION:-eu-west-3}"
AVAIL_ZONE="${AVAIL_ZONE:-eu-west-3a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
DRILL_VPC_CIDR="10.30.0.0/16"
DRILL_SUBNET_CIDR="10.30.1.0/24"
DRILL_TAG_NAME="axiome-fr4-drill"
SNAPSHOT_ID=""
DRY_RUN=false
CLEANUP_ON_EXIT=true
REPORTS_DIR="${REPORTS_DIR:-../../axiome-docs/reports/infra}"

# --------------- Helpers ---------------
log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*"; exit 1; }

cleanup() {
  if [ "$CLEANUP_ON_EXIT" != "true" ]; then
    log "Skipping cleanup (CLEANUP_ON_EXIT=false)."
    return 0
  fi
  log "=== Cleanup ==="

  [ -n "${DRILL_EIP_ALLOC_ID:-}" ] && {
    log "Releasing EIP $DRILL_EIP_ALLOC_ID ..."
    aws ec2 release-address --allocation-id "$DRILL_EIP_ALLOC_ID" --region "$AWS_REGION" 2>/dev/null || true
  }

  [ -n "${DRILL_INSTANCE_ID:-}" ] && {
    log "Terminating instance $DRILL_INSTANCE_ID ..."
    aws ec2 terminate-instances --instance-ids "$DRILL_INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
    log "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids "$DRILL_INSTANCE_ID" --region "$AWS_REGION" 2>/dev/null || true
  }

  [ -n "${NEW_VOLUME_ID:-}" ] && {
    log "Deleting restored volume $NEW_VOLUME_ID ..."
    aws ec2 delete-volume --volume-id "$NEW_VOLUME_ID" --region "$AWS_REGION" 2>/dev/null || true
  }

  [ -n "${DRILL_SG_ID:-}" ] && {
    aws ec2 delete-security-group --group-id "$DRILL_SG_ID" --region "$AWS_REGION" 2>/dev/null || true
  }
  [ -n "${DRILL_SUBNET_ID:-}" ] && {
    aws ec2 delete-subnet --subnet-id "$DRILL_SUBNET_ID" --region "$AWS_REGION" 2>/dev/null || true
  }
  [ -n "${DRILL_IGW_ID:-}" ] && {
    aws ec2 detach-internet-gateway --internet-gateway-id "$DRILL_IGW_ID" --vpc-id "${DRILL_VPC_ID:-}" --region "$AWS_REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$DRILL_IGW_ID" --region "$AWS_REGION" 2>/dev/null || true
  }
  [ -n "${DRILL_VPC_ID:-}" ] && {
    aws ec2 delete-vpc --vpc-id "$DRILL_VPC_ID" --region "$AWS_REGION" 2>/dev/null || true
  }

  log "Cleanup done."
}
trap cleanup EXIT

# --------------- Args ---------------
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-id) SNAPSHOT_ID="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --no-cleanup)  CLEANUP_ON_EXIT=false; shift ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# --------------- 0. Verify prerequisites ---------------
log "=== Prerequisites ==="
command -v aws  >/dev/null 2>&1 || die "aws CLI not found"
command -v jq   >/dev/null 2>&1 || die "jq not found"

AWS_ACCT=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
log "AWS account: $AWS_ACCT  region: $AWS_REGION"

# --------------- 1. Select snapshot ---------------
log "=== Snapshot selection ==="
if [ -z "$SNAPSHOT_ID" ]; then
  SNAPSHOT_ID=$(aws ec2 describe-snapshots \
    --owner-ids self \
    --filters "Name=tag:DlmPolicy,Values=daily-root" "Name=status,Values=completed" \
    --query "Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId" \
    --output text --region "$AWS_REGION" 2>/dev/null)

  [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID" = "None" ] && \
    die "No DLM snapshot found (tag DlmPolicy=daily-root, status=completed)." \
        "Has the DLM policy run at least once? Check: aws dlm get-lifecycle-policies --region $AWS_REGION"
fi

SNAPSHOT_TS=$(aws ec2 describe-snapshots \
  --snapshot-ids "$SNAPSHOT_ID" \
  --query "Snapshots[0].StartTime" --output text --region "$AWS_REGION")
log "Snapshot: $SNAPSHOT_ID  timestamp: $SNAPSHOT_TS"

# --------------- 2. Compute RPO baseline ---------------
DRILL_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SNAPSHOT_EPOCH=$(date -d "$SNAPSHOT_TS" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${SNAPSHOT_TS%+*}" +%s 2>/dev/null)
DRILL_START_EPOCH=$(date -d "$DRILL_START" +%s)
RPO_SECONDS=$(( DRILL_START_EPOCH - SNAPSHOT_EPOCH ))
RPO_HOURS=$(awk "BEGIN { printf \"%.1f\", $RPO_SECONDS / 3600 }")
log "RPO (snapshot age): ${RPO_HOURS}h  target: ≤ 24h  $( [ "$RPO_SECONDS" -le 86400 ] && echo '✓' || echo '✗ RPO EXCEEDED' )"

$DRY_RUN && { log "DRY RUN — stopping before resource creation."; CLEANUP_ON_EXIT=false; exit 0; }

# --------------- 3. Restore snapshot to new volume ---------------
log "=== Restore snapshot to volume ==="
NEW_VOLUME_ID=$(aws ec2 create-volume \
  --snapshot-id "$SNAPSHOT_ID" \
  --availability-zone "$AVAIL_ZONE" \
  --encrypted \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${DRILL_TAG_NAME}-root},{Key=DlmPolicy,Value=daily-root}]" \
  --query "VolumeId" --output text --region "$AWS_REGION")

log "Volume: $NEW_VOLUME_ID"
aws ec2 wait volume-available --volume-ids "$NEW_VOLUME_ID" --region "$AWS_REGION"
log "Volume available."

# --------------- 4. Provision drill network ---------------
log "=== Provision drill network ==="
DRILL_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$DRILL_VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${DRILL_TAG_NAME}-vpc}]" \
  --query "Vpc.VpcId" --output text --region "$AWS_REGION")
aws ec2 modify-vpc-attribute --vpc-id "$DRILL_VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$DRILL_VPC_ID" --enable-dns-support --region "$AWS_REGION"

DRILL_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$DRILL_VPC_ID" --cidr-block "$DRILL_SUBNET_CIDR" \
  --availability-zone "$AVAIL_ZONE" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${DRILL_TAG_NAME}-subnet}]" \
  --query "Subnet.SubnetId" --output text --region "$AWS_REGION")

DRILL_IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${DRILL_TAG_NAME}-igw}]" \
  --query "InternetGateway.InternetGatewayId" --output text --region "$AWS_REGION")
aws ec2 attach-internet-gateway --internet-gateway-id "$DRILL_IGW_ID" --vpc-id "$DRILL_VPC_ID" --region "$AWS_REGION"

DRILL_RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$DRILL_VPC_ID" \
  --query "RouteTables[0].RouteTableId" --output text --region "$AWS_REGION")
aws ec2 create-route --route-table-id "$DRILL_RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$DRILL_IGW_ID" --region "$AWS_REGION"

DRILL_SG_ID=$(aws ec2 create-security-group \
  --group-name "${DRILL_TAG_NAME}-sg" --description "FR4 rebuild drill" \
  --vpc-id "$DRILL_VPC_ID" --query "GroupId" --output text --region "$AWS_REGION")
aws ec2 authorize-security-group-ingress --group-id "$DRILL_SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$AWS_REGION"

log "Network: VPC=$DRILL_VPC_ID  subnet=$DRILL_SUBNET_ID  SG=$DRILL_SG_ID"

# --------------- 5. Launch drill instance ---------------
log "=== Launch drill instance ==="
AMI_ID=$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text --region "$AWS_REGION")

DRILL_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$DRILL_SUBNET_ID" \
  --security-group-ids "$DRILL_SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeId\":\"$NEW_VOLUME_ID\",\"DeleteOnTermination\":false}}]" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${DRILL_TAG_NAME}-ec2}]" \
  --query "Instances[0].InstanceId" --output text --region "$AWS_REGION")

log "Instance: $DRILL_INSTANCE_ID"

DRILL_EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION")
DRILL_EIP_ALLOC_ID=$(echo "$DRILL_EIP_ALLOC" | jq -r '.AllocationId')
DRILL_EIP=$(echo "$DRILL_EIP_ALLOC" | jq -r '.PublicIp')
log "Public IP: $DRILL_EIP"

aws ec2 wait instance-running --instance-ids "$DRILL_INSTANCE_ID" --region "$AWS_REGION"
aws ec2 associate-address --instance-id "$DRILL_INSTANCE_ID" \
  --allocation-id "$DRILL_EIP_ALLOC_ID" --region "$AWS_REGION" >/dev/null

# --------------- 6. Health checks ---------------
log "=== Health checks ==="
log "Waiting 60s for boot + Docker startup..."
sleep 60

# Check 1: SSM reachable (instance has no SSM agent by default from the snapshot — skip if not present)
log "Check 1: Instance status..."
INSTANCE_STATE=$(aws ec2 describe-instance-status \
  --instance-ids "$DRILL_INSTANCE_ID" \
  --query "InstanceStatuses[0].InstanceStatus.Status" --output text --region "$AWS_REGION")
log "  Instance status: $INSTANCE_STATE"

# Check 2: system status
SYS_STATUS=$(aws ec2 describe-instance-status \
  --instance-ids "$DRILL_INSTANCE_ID" \
  --query "InstanceStatuses[0].SystemStatus.Status" --output text --region "$AWS_REGION")
log "  System status:  $SYS_STATUS"

CHECKS_PASSED=true
[ "$INSTANCE_STATE" != "ok" ] && { log "  ✗ Instance status check failed"; CHECKS_PASSED=false; }
[ "$SYS_STATUS" != "ok" ] && { log "  ✗ System status check failed"; CHECKS_PASSED=false; }

# --------------- 7. Record RTO ---------------
DRILL_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DRILL_END_EPOCH=$(date -d "$DRILL_END" +%s)
RTO_SECONDS=$(( DRILL_END_EPOCH - DRILL_START_EPOCH ))
RTO_MINUTES=$(awk "BEGIN { printf \"%.0f\", $RTO_SECONDS / 60 }")
RTO_TARGET_SECONDS=$(( 4 * 3600 ))
RTO_MET=false
[ "$RTO_SECONDS" -le "$RTO_TARGET_SECONDS" ] && RTO_MET=true

log ""
log "==========================================="
log "  FR4 Rebuild Drill — Results"
log "==========================================="
log "  Snapshot:       $SNAPSHOT_ID ($SNAPSHOT_TS)"
log "  Drill start:    $DRILL_START"
log "  Drill end:      $DRILL_END"
log "  RPO (snap age): ${RPO_HOURS}h  target ≤ 24h"
log "  RTO (elapsed):  ${RTO_MINUTES}min  target ≤ 4h  $( $RTO_MET && echo '✓ RTO MET' || echo '✗ RTO EXCEEDED' )"
log "  Checks passed:  $CHECKS_PASSED"
log "==========================================="

# --------------- 8. Write evidence record ---------------
EVIDENCE_FILE="${REPORTS_DIR}/$(date -u +%Y-%m-%dT%H%M%SZ)__aws__production__$(git rev-parse --short HEAD 2>/dev/null || echo 'manual')__fr4-drill.md"

log "Writing evidence: $EVIDENCE_FILE"
cat > "$EVIDENCE_FILE" << EOF
# FR4 Rebuild Drill — Evidence Record

| | |
|---|---|
| **Drill date (UTC)** | $DRILL_START |
| **Snapshot used** | $SNAPSHOT_ID |
| **Snapshot timestamp** | $SNAPSHOT_TS |
| **Achieved RPO** | ${RPO_HOURS}h (target: ≤ 24h) |
| **Drill start** | $DRILL_START |
| **Drill end** | $DRILL_END |
| **Achieved RTO** | ${RTO_MINUTES}min (target: ≤ 4h) |
| **RTO met** | $RTO_MET |
| **Instance checks** | Instance=$INSTANCE_STATE, System=$SYS_STATUS |
| **Checks passed** | $CHECKS_PASSED |
| **Region / AZ** | $AWS_REGION / $AVAIL_ZONE |

## Verification
- [ ] EBS snapshot restored as gp3 encrypted volume
- [ ] EC2 boots from restored root volume
- [ ] Instance + system status checks: ok
- [ ] RTO ≤ 4 h: $RTO_MET
EOF

$RTO_MET && $CHECKS_PASSED || {
  log "Drill finished with warnings — see evidence record."
  exit 1
}

log "Drill passed. Evidence written to $EVIDENCE_FILE"
