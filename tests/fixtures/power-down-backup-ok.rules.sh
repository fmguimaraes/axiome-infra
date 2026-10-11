# shellcheck shell=bash
# AXI-1972 (scope item 5): LastModified was a hardcoded "2030-01-01" —
# fine until 2030, then this fixture would start reporting a STALE object
# (power.sh compares LastModified against the time the command was
# issued) and the test would fail for a reason that has nothing to do
# with what it tests. Computed relative to real "now" via the date stub's
# default passthrough instead, so it never expires.
# AXI-1967: get-object arms for locks/deploy.json and locks/apply.json added
# — power.sh down now also checks those locks (FR43) before the backup step
# above. POWER_FIXTURE_DEPLOY_STATE / POWER_FIXTURE_APPLY_STATE (free|held,
# default free) let UT-INFRA-414/415 simulate either lock being held.
# Fixture for the aws stub — power.sh <env> down, successful FR31 backup path.
# Drives BOTH power.sh's own ec2 calls AND the ssm-exec.sh backup run (SSM
# send-command/get-command-invocation) plus power.sh's own independent
# head-object re-verification. UT-INFRA-180, 414, 415.
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
      if [ "${POWER_FIXTURE_DEPLOY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"deploy","actor":"ci-deploy@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
      fi
      # UT-INFRA-593 (AXI-1981): a transport error that is NOT "Not
      # Found"/"NoSuchKey"/404 maps to UNKNOWN, never FREE (NFR2,
      # fail-closed) — POWER_FIXTURE_DEPLOY_STATE=unknown exercises this.
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
    *"ssm"*"send-command"*)
      echo "cmd-ok-1"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"Status"*)
      echo "Success"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardOutputContent"*)
      echo "MONGO_BACKUP_OK key=backups/mongo/20261010T020000Z.archive.gz sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardErrorContent"*)
      return 0
      ;;
    *"s3api"*"head-object"*"backups/mongo/20261010T020000Z.archive.gz"*)
      echo '{"ContentLength":12345,"LastModified":"'"$(date -u -d '+365 days' +%Y-%m-%dT%H:%M:%S+00:00)"'","Metadata":{"sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}'
      return 0
      ;;
    *"stop-instances"*)
      return 0
      ;;
    *"wait"*"instance-stopped"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
