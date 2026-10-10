# shellcheck shell=bash
# Fixture for scripts/lock.sh override. dev/deploy=HELD (override succeeds,
# unconditional delete since override force-removes regardless of
# ownership); staging/data-tier=FREE (override refused, no delete call);
# production/deploy=HELD too, used ONLY for the "report write refused"
# scenario (B1) — deliberately has NO delete-object arm, so if override
# deletes anyway despite the refused report, the harness catches it as an
# unconfigured call. get-object writes the BODY to the outfile (last argv
# token) and prints METADATA JSON (ETag) to stdout — see scripts/lock.sh
# header "Read path". UT-INFRA-114..117, 391..392 (report-failure aborts).
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"get-caller-identity"*)
      echo "arn:aws:iam::123456789012:user/override-actor"
      return 0
      ;;
    *"get-object"*"axiome-dev-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"someone","operation":"deploy tag=z","host":"h","acquired_at":"2026-10-10T08:00:00Z","token":"t9"}' > "${outfile}"
      echo '{"ETag":"\"etag-dev-deploy-override\""}'
      return 0
      ;;
    *"delete-object"*"axiome-dev-system"*"locks/deploy.json"*)
      return 0
      ;;
    *"get-object"*"axiome-staging-system"*"locks/data-tier.json"*)
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;
    *"get-object"*"axiome-production-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"someone","operation":"deploy tag=q","host":"h","acquired_at":"2026-10-10T08:00:00Z","token":"t9"}' > "${outfile}"
      echo '{"ETag":"\"etag-prod-deploy\""}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
