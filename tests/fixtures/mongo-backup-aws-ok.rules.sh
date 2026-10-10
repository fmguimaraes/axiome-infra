# shellcheck shell=bash
# Fixture for the aws stub — mongo-backup.sh's upload + verify + marker path,
# all succeeding.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"s3"*"cp"*"latest.json"*)
      return 0
      ;;
    *"s3"*"cp"*"archive.gz"*)
      return 0
      ;;
    *"s3api"*"head-object"*)
      echo '"etag-1"'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
