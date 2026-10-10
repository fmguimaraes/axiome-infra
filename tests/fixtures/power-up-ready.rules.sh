# shellcheck shell=bash
# Fixture for the aws stub — power.sh <env> up, the FR26 readiness poll.
# UT-INFRA-185.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"describe-instances"*"InstanceId"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"describe-instances"*"State.Name"*)
      echo "running"
      return 0
      ;;
    *"start-instances"*)
      return 0
      ;;
    *"wait"*"instance-running"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
