# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev down: every Redis describe
# call SUCCEEDS (exit 0) but one field (EngineVersion) comes back empty —
# AWS CLI's real behaviour for a missing scalar in --output text.
# capture_redis_config must refuse this as an incomplete config, never save
# it, never delete Redis. UT-INFRA-206.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"put-object"*"locks/data-tier.json"*)
      echo '{"ETag":"\"lock-etag-1\""}'
      return 0
      ;;
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "available"
      return 0
      ;;
    *"stop-db-instance"*)
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "available"
      return 0
      ;;
    *"describe-cache-clusters"*)
      # EngineVersion (1st field) comes back empty.
      printf '\tdefault.redis7\tsubnet-grp\tsg-123'
      return 0
      ;;
    *"describe-replication-groups"*"CacheNodeType,KmsKeyId,SnapshotWindow"*)
      printf 'cache.t3.micro\tarn:aws:kms:eu-west-3:111111111111:key/abc\t05:00-06:00'
      return 0
      ;;
    *"describe-replication-groups"*"Description"*)
      echo "axiome redis"
      return 0
      ;;
    *"s3"*"cp"*"park-state.env"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
