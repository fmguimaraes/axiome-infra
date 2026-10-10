# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev up, the full successful
# release path: RDS/Redis already 'available' (also covers EC8 — "treated
# as already started" takes exactly this branch), bounded verification
# passes immediately, then the data-tier lock is released and park-state
# cleared (FR29/FR34). UT-INFRA-190/192.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "available"
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "available"
      return 0
      ;;
    *"s3"*"cp"*"park-state.env"*)
      # fixed call shape: "s3 cp <src> <dst> --region <region>" — <dst> is
      # the 4th whitespace-separated word, regardless of what follows it.
      # shellcheck disable=SC2086
      set -- $argv
      case "$4" in
        s3://*) : ;;
        *) printf 'LOCK_TOKEN="release-me-token"\nRDS_STOPPED_AT=""\nPARKED_AT="2026-10-10T01:00:00Z"\n' > "$4" ;;
      esac
      return 0
      ;;
    *"s3"*"rm"*"park-state.env"*)
      return 0
      ;;
    *"get-object"*"locks/data-tier.json"*)
      printf '%s' '{"name":"data-tier","actor":"ci","operation":"data-tier down","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"release-me-token"}' > "${argv##* }"
      echo '{"ETag":"\"etag-x\""}'
      return 0
      ;;
    *"delete-object"*"locks/data-tier.json"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
