# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev down: RDS stop succeeds (so
# park-state.env gets written TWICE before the abort — once immediately
# after lock_acquire, once with RDS_STOPPED_AT), then Redis's own
# describe-cache-clusters call fails outright. capture_redis_config must
# treat that as a hard failure (never save an incomplete config, never
# delete Redis). Every successful UPLOAD of park-state.env is copied to
# PARK_STATE_CAPTURE_FILE (if set) so the test can assert the lock's real
# token was still recoverable after the abort. UT-INFRA-205.
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
    *"get-object"*"locks/deploy.json"*)
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"get-object"*"locks/apply.json"*)
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
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
      echo "An error occurred (Throttling) when calling the DescribeCacheClusters operation"
      return 1
      ;;
    *"s3"*"cp"*"park-state.env"*)
      # shellcheck disable=SC2086
      set -- $argv
      case "$4" in
        s3://*)
          [ -n "${PARK_STATE_CAPTURE_FILE:-}" ] && cp "$3" "${PARK_STATE_CAPTURE_FILE}" 2>/dev/null
          ;;
        *) : ;;
      esac
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
