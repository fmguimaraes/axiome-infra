# shellcheck shell=bash
# Fixture for the docker stub — mongo-backup.sh's `docker exec ... mongodump`
# succeeds and writes real archive-shaped bytes to the redirected $ARCHIVE.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"exec"*"axiome-mongo"*"mongodump"*)
      printf 'fake-mongodump-binary-archive-bytes-not-empty'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
