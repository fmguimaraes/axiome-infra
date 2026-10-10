# shellcheck shell=bash
# Fixture for the aws stub — power.sh <env> down, the backup command FAILS
# over SSM. UT-INFRA-181. stop-instances/wait are deliberately NOT matched
# (any call to either is itself the proof FR31 was violated) — an
# unconfigured call fails the test independently of exit-code handling
# (tests/README.md), which is exactly the assertion we want here.
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
    *"ssm"*"send-command"*)
      echo "cmd-fail-1"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"Status"*)
      echo "Failed"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardOutputContent"*)
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardErrorContent"*)
      echo "MONGO_BACKUP_FAILED mongodump failed"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
