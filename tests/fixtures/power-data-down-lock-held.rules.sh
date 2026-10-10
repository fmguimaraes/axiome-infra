# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev down when the data-tier lock
# is ALREADY held by someone else. UT-INFRA-188. No RDS/Redis call is
# expected to ever happen in this scenario (the bats test asserts that via
# refute_stub_called_with) — none are configured here on purpose; an
# unconfigured call would itself independently fail the test.
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"put-object"*"locks/data-tier.json"*)
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold"
      return 254
      ;;
    *"get-object"*"locks/data-tier.json"*)
      printf '%s' '{"name":"data-tier","actor":"someone@example.com","operation":"data-tier down","host":"ci-9","acquired_at":"2026-10-10T09:00:00Z","token":"holder-token"}' > "${outfile}"
      echo '{"ETag":"\"etag-held\""}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
