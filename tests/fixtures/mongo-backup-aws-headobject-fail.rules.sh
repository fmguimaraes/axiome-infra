# shellcheck shell=bash
# Fixture for the aws stub — mongo-backup.sh's archive upload succeeds, but
# the post-upload head-object verification fails (object not confirmed
# present). latest.json is deliberately NOT matched — reaching it is proof
# the script claimed success before verifying.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"s3"*"cp"*"archive.gz"*)
      return 0
      ;;
    *"s3api"*"head-object"*)
      echo "An error occurred (404) when calling the HeadObject operation: Not Found"
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
