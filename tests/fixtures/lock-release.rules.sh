# shellcheck shell=bash
# Fixture for scripts/lock.sh release — five scenarios distinguished by
# (env, lock name) since the lock NAME itself is restricted to
# deploy|data-tier. get-object writes the BODY to the outfile (last argv
# token) and prints METADATA JSON (ETag) to stdout, in ONE call — no
# separate head-object (see scripts/lock.sh header "Read path").
# Scenarios WITHOUT a delete-object arm are deliberate: if the script under
# test calls delete-object anyway, the harness records it as an
# unconfigured call and fails the test (UT-INFRA-105..109).
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    # dev / deploy — caller holds the token; conditional delete succeeds.
    *"get-object"*"axiome-dev-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"me","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"mytoken"}' > "${outfile}"
      echo '{"ETag":"\"etag-dev-deploy\""}'
      return 0
      ;;
    *"delete-object"*"axiome-dev-system"*"locks/deploy.json"*"--if-match"*"etag-dev-deploy"*)
      return 0
      ;;

    # dev / data-tier — caller holds the token, but the CLI rejects
    # --if-match; release must fall back to an unconditional delete.
    *"get-object"*"axiome-dev-system"*"locks/data-tier.json"*)
      printf '%s' '{"name":"data-tier","actor":"me","operation":"power-data down","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"mytoken"}' > "${outfile}"
      echo '{"ETag":"\"etag-dev-data\""}'
      return 0
      ;;
    *"delete-object"*"axiome-dev-system"*"locks/data-tier.json"*"--if-match"*)
      echo "Unknown options: --if-match, etag-dev-data"
      return 252
      ;;
    *"delete-object"*"axiome-dev-system"*"locks/data-tier.json"*)
      return 0
      ;;

    # staging / deploy — held by someone else; caller's token is wrong.
    *"get-object"*"axiome-staging-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"other","operation":"deploy tag=y","host":"h","acquired_at":"2026-10-10T09:00:00Z","token":"theirtoken"}' > "${outfile}"
      echo '{"ETag":"\"etag-staging-deploy\""}'
      return 0
      ;;

    # staging / data-tier — not held at all.
    *"get-object"*"axiome-staging-system"*"locks/data-tier.json"*)
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;

    # production / deploy — state cannot be determined (e.g. a transient
    # transport error), never a NoSuchKey.
    *"get-object"*"axiome-production-system"*"locks/deploy.json"*)
      echo "An error occurred (RequestTimeout) when calling the GetObject operation: transport error"
      return 254
      ;;

    *)
      return 99
      ;;
  esac
}
