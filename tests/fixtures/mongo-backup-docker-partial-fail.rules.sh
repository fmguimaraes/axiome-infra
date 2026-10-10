# shellcheck shell=bash
# Fixture for the docker stub — mongo-backup.sh's `docker exec ... mongodump`
# writes SOME bytes to stdout (so $ARCHIVE is non-empty) but then exits
# non-zero — proves the failure is caught by the exit STATUS check, never
# by the archive-size check alone (AXI-1951 bounce #1).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"exec"*"axiome-mongo"*"mongodump"*)
      printf 'partial-bytes-written-before-the-connection-dropped'
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
