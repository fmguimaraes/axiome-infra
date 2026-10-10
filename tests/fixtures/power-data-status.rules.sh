# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev status with RDS stopped
# (shows FR35 stopped-duration) and the data-tier lock FREE.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"describe-db-instances"*"DBInstanceStatus"*)
      echo "stopped"
      return 0
      ;;
    *"describe-replication-groups"*"Status"*)
      echo "absent"
      return 1
      ;;
    *"s3"*"cp"*"park-state.env"*)
      # fixed call shape: "s3 cp <src> <dst> --region <region>" — <dst> is
      # the 4th whitespace-separated word, regardless of what follows it.
      # shellcheck disable=SC2086
      set -- $argv
      case "$4" in
        s3://*) : ;;
        *) printf 'LOCK_TOKEN="t"\nRDS_STOPPED_AT="2026-10-08T00:00:00Z"\nPARKED_AT="2026-10-08T00:00:00Z"\n' > "$4" ;;
      esac
      return 0
      ;;
    *"get-object"*"locks/data-tier.json"*)
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;
    *)
      return 99
      ;;
  esac
}
