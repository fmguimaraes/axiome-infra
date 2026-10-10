# shellcheck shell=bash
# Fixture for the aws stub — power.sh <env> status (UT-INFRA-005).
# Sourced by tests/stubs/_common.sh; must define stub_respond().
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"describe-instances"*"InstanceId"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"describe-instances"*"State.Name"*)
      echo "running"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
