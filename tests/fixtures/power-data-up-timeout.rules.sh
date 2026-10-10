# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev up where RDS never reaches
# 'available' within the bounded timeout (FR34). The data-tier lock must
# NEVER be released on this path. UT-INFRA-191.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"start-db-instance"*)
      return 0
      ;;
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "stopped"
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "available"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
