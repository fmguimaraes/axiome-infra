# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev up where RDS/Redis are
# already available, a STALE park-state.env exists from a previous down
# (with a real-looking token), but the lock itself was already cleared by
# an operator's `scripts/lock.sh override` (so it is FREE, not HELD).
# lock_release must refuse (the lock is not held) WITHOUT ever calling
# delete-object, and `up` must still succeed overall. UT-INFRA-209.
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
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "available"
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "available"
      return 0
      ;;
    *"s3"*"cp"*"park-state.env"*)
      # shellcheck disable=SC2086
      set -- $argv
      case "$4" in
        s3://*) : ;;
        *) printf 'LOCK_TOKEN="stale-token-from-before-the-override"\nRDS_STOPPED_AT=""\nPARKED_AT="2026-10-01T00:00:00Z"\n' > "$4" ;;
      esac
      return 0
      ;;
    *"get-object"*"locks/data-tier.json"*)
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
