# shellcheck shell=bash
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
    *"get-object"*"locks/deploy.json"*)
      if [ "${POWER_FIXTURE_DEPLOY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"deploy","actor":"ci-deploy@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
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
      echo '{"ContentLength":12345,"LastModified":"2030-01-01T00:00:00+00:00","Metadata":{"sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}'
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
