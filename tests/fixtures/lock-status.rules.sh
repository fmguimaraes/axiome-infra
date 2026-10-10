# shellcheck shell=bash
# Fixture for scripts/lock.sh status. dev/deploy=HELD, dev/data-tier=FREE
# (also exercises "status with no name" checking both), staging/deploy is
# UNDETERMINED (a transport error, never NoSuchKey), production/deploy
# returns rc 0 with a ZERO-BYTE body (proves B2: never "held by blank").
# get-object writes the BODY to the outfile (last argv token) and prints
# METADATA JSON (ETag) to stdout — see scripts/lock.sh header "Read path".
# UT-INFRA-110..113, 390 (zero-byte body).
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"get-object"*"axiome-dev-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"me","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"t1"}' > "${outfile}"
      echo '{"ETag":"\"etag-dev-deploy\""}'
      return 0
      ;;
    *"get-object"*"axiome-dev-system"*"locks/data-tier.json"*)
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;
    *"get-object"*"axiome-staging-system"*"locks/deploy.json"*)
      echo "An error occurred (RequestTimeout) when calling the GetObject operation: transport error"
      return 254
      ;;
    *"get-object"*"axiome-production-system"*"locks/deploy.json"*)
      : > "${outfile}"
      echo '{"ETag":"\"etag-empty\""}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
