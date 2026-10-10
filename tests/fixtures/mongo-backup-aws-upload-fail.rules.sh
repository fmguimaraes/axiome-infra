# shellcheck shell=bash
# Fixture for the aws stub — mongo-backup.sh's upload of the archive itself
# fails. head-object/latest.json are deliberately NOT matched — reaching
# either is itself proof the failure wasn't caught.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"s3"*"cp"*"archive.gz"*)
      echo "An error occurred (InternalError) when calling the PutObject operation"
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
