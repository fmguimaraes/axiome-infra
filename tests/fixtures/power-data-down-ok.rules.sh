# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev down, the full successful
# path: lock acquired, RDS stopped, Redis final-snapshot requested and
# VERIFIED available before success is reported (FR33/FR29). UT-INFRA-187/188.
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
    *"get-object"*"locks/deploy.json"*)
      if [ "${POWER_DATA_FIXTURE_DEPLOY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"deploy","actor":"ci-deploy@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
      fi
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"get-object"*"locks/apply.json"*)
      if [ "${POWER_DATA_FIXTURE_APPLY_STATE:-free}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"apply","actor":"ci-apply@example.com","operation":"terraform apply","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"al\""}'
        return 0
      fi
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"put-object"*"locks/data-tier.json"*)
      # Capture the real acquire token (piped on stdin) so a later
      # get-object (release's own token check, exercised by the
      # deploy/apply FR43 refusal tests below) agrees with it instead of
      # a canned value that would make lock.sh's "caller's token does not
      # match" guard fire.
      cat > "${POWER_DATA_FIXTURE_TOKEN_FILE:-/tmp/power-data-down-ok.token}"
      echo '{"ETag":"\"lock-etag-1\""}'
      return 0
      ;;
    *"get-object"*"locks/data-tier.json"*)
      local outfile="${argv##* }" tf="${POWER_DATA_FIXTURE_TOKEN_FILE:-/tmp/power-data-down-ok.token}"
      if [ -s "$tf" ]; then
        cat "$tf" > "${outfile}"
      else
        printf '%s' '{"name":"data-tier","actor":"test","operation":"x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"self-token"}' > "${outfile}"
      fi
      echo '{"ETag":"\"lock-etag-1\""}'
      return 0
      ;;
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "available"
      return 0
      ;;
    *"stop-db-instance"*)
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "available"
      return 0
      ;;
    *"describe-cache-clusters"*)
      printf '7.1.0\tdefault.redis7\tsubnet-grp\tsg-123'
      return 0
      ;;
    *"describe-replication-groups"*"CacheNodeType,KmsKeyId,SnapshotWindow"*)
      printf 'cache.t3.micro\tarn:aws:kms:eu-west-3:111111111111:key/abc\t05:00-06:00'
      return 0
      ;;
    *"describe-replication-groups"*"Description"*)
      echo "axiome redis"
      return 0
      ;;
    *"s3"*"cp"*"redis-state.env"*)
      # shellcheck disable=SC2086
      set -- $argv
      case "$4" in
        s3://*) : ;;                          # upload — local file already has the content
        /tmp/redis-state.env) : ;;            # would be copying the file onto itself
        *) cp /tmp/redis-state.env "$4" 2>/dev/null || : ;;  # download/readback
      esac
      return 0
      ;;
    *"s3"*"cp"*"park-state.env"*)
      return 0
      ;;
    *"s3"*"rm"*"park-state.env"*)
      # AXI-1967: clear_park_state's own call, exercised when a deploy/apply
      # FR43 refusal releases the just-acquired data-tier lock and cleans up.
      return 0
      ;;
    *"delete-object"*"locks/data-tier.json"*)
      return 0
      ;;
    *"delete-replication-group"*)
      return 0
      ;;
    *"describe-snapshots"*)
      echo "available"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
