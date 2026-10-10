# shellcheck shell=bash
# Fixture for scripts/lock.sh acquire — the bats tests pick a DIFFERENT env
# per scenario (dev=free, staging=held, production=generic failure) so the
# S3 bucket name (axiome-<env>-system) distinguishes the case, since the
# lock NAME itself is restricted to deploy|data-tier. UT-INFRA-100..103.
# get-object writes the BODY to the outfile (the last argv token) and
# prints METADATA JSON (ETag) to stdout — the real aws-cli split this
# fixture must reproduce (see scripts/lock.sh header "Read path").
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"put-object"*"axiome-dev-system"*"locks/deploy.json"*)
      echo '{"ETag":"\"abc123\""}'
      return 0
      ;;
    *"put-object"*"axiome-staging-system"*"locks/deploy.json"*)
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold"
      return 254
      ;;
    *"get-object"*"axiome-staging-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"someone@example.com","operation":"deploy tag=abc","host":"ci-1","acquired_at":"2026-10-10T10:00:00Z","token":"holder-token"}' > "${outfile}"
      echo '{"ETag":"\"etag-held\""}'
      return 0
      ;;
    *"put-object"*"axiome-production-system"*"locks/deploy.json"*)
      echo "An error occurred (AccessDenied) when calling the PutObject operation: Access Denied"
      return 254
      ;;
    *)
      return 99
      ;;
  esac
}
