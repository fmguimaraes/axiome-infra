# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev up run with NOTHING ever
# parked: RDS/Redis are already available (nobody stopped them), and
# park-state.env does not exist (NoSuchKey) — read_park_state_field must
# come back empty, and `up` must never attempt a lock release (no
# get-object/delete-object call at all) since there is nothing to release.
# UT-INFRA-208.
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
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
