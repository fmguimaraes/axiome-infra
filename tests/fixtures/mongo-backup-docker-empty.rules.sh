# shellcheck shell=bash
# Fixture for the docker stub — mongo-backup.sh's `docker exec ... mongodump`
# exits 0 but produces no output at all (an empty archive after a
# "successful" exit).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"exec"*"axiome-mongo"*"mongodump"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
