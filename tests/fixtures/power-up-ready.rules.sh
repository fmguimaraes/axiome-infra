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
    # UT-INFRA-641/642/643 (bounce #1, AXI-1981): POWER_FIXTURE_DEPLOY_STATE /
    # POWER_FIXTURE_APPLY_STATE (free|held|unknown, default free) let the
    # `up`-side refusal tests simulate either lock being held, or its state
    # being undeterminable — same gating as power-down-backup-ok.rules.sh.
    *"get-object"*"locks/deploy.json"*)
      if [ "${POWER_FIXTURE_DEPLOY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"deploy","actor":"ci-deploy@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
      fi
      if [ "${POWER_FIXTURE_DEPLOY_STATE:-free}" = "unknown" ]; then
        echo "An error occurred (RequestTimeout) when calling the GetObject operation: transport error"
        return 254
      fi
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"get-object"*"locks/apply.json"*)
      if [ "${POWER_FIXTURE_APPLY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"apply","actor":"ci-apply@example.com","operation":"terraform apply","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"al\""}'
        return 0
      fi
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
