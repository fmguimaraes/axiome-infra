# shellcheck shell=bash
# Fixture for UT-INFRA-640 (AXI-1981) — power.sh down acquires 'compute'
# instantly, passes the deploy/apply checks, then the SSM send-command
# backup step (the first genuinely in-flight AWS call after the lock is
# held) sleeps long enough to signal the process (TERM) while compute is
# still held — same stub-log-marker timing pattern as
# tests/asset-sync.bats's UT-INFRA-585 / tests/lock_cleanup.bats's
# UT-INFRA-536 (poll for the call's own argv line in $STUB_LOG, never a
# bare sleep race).
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"put-object"*"locks/compute.json"*)
      cat > "${BATS_TEST_TMPDIR:-/tmp}/power-compute-slow-lock.token.body"
      echo '{"ETag":"\"cl\""}'
      return 0
      ;;
    *"get-object"*"locks/compute.json"*)
      if [ -s "${BATS_TEST_TMPDIR:-/tmp}/power-compute-slow-lock.token.body" ]; then
        cat "${BATS_TEST_TMPDIR:-/tmp}/power-compute-slow-lock.token.body" > "${outfile}"
      else
        printf '%s' '{"name":"compute","actor":"me","operation":"x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"self-token"}' > "${outfile}"
      fi
      echo '{"ETag":"\"cl\""}'
      return 0
      ;;
    *"delete-object"*"locks/compute.json"*)
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
    *"describe-instances"*"InstanceId"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"describe-instances"*"State.Name"*)
      echo "running"
      return 0
      ;;
    *"ssm"*"send-command"*)
      sleep 5
      echo "cmd-ok-1"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
