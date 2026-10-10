# shellcheck shell=bash
# Fixture for the aws stub — exercises terraform-cd.yml's REAL "Acquire
# apply lock" step `run:` text (tests/lock_terraform_cd_apply_lock.bats,
# AXI-1967), acquiring 'apply' as its own lock and checking 'deploy' and
# 'data-tier' as the others, all under the production bucket. UT-INFRA-423/424.
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/ci-apply"
      return 0
      ;;
    *"put-object"*"locks/apply.json"*)
      return 0
      ;;
    *"get-object"*"locks/apply.json"*)
      printf '%s' '{"name":"apply","actor":"ci-apply","operation":"terraform apply run=1","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"self-token"}' > "${outfile}"
      echo '{"ETag":"\"ap1\""}'
      return 0
      ;;
    *"delete-object"*"locks/apply.json"*)
      return 0
      ;;
    *"get-object"*"locks/deploy.json"*)
      if [ "${TF_APPLY_LOCK_FIXTURE_DEPLOY_STATE:-free}" = "held" ]; then
        printf '%s' '{"name":"deploy","actor":"ci-deploy@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
      fi
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"get-object"*"locks/data-tier.json"*)
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *)
      return 99
      ;;
  esac
}
