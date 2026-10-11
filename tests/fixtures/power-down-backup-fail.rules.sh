# shellcheck shell=bash
# AXI-1967: get-object arms for locks/deploy.json and locks/apply.json (both FREE) added — power.sh down now also checks those locks (FR43) before the backup step above.
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
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    # AXI-1981 (FR43): power.sh down/up now acquire their OWN compute
    # lock first (lock_acquire_exclusive) before checking deploy/apply.
    # Captures the real acquire token (same pattern as
    # lock-acquire-exclusive.rules.sh) so the auto-release on exit finds
    # the SAME token it wrote, rather than a canned one that would make
    # lock.sh's "caller's token does not match" guard fire.
    *"put-object"*"locks/compute.json"*)
      cat > "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body"
      echo '{"ETag":"\"cl\""}'
      return 0
      ;;
    *"get-object"*"locks/compute.json"*)
      local compute_outfile="${argv##* }"
      if [ -s "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body" ]; then
        cat "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body" > "${compute_outfile}"
      else
        printf '%s' '{"name":"compute","actor":"me","operation":"x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"self-token"}' > "${compute_outfile}"
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
