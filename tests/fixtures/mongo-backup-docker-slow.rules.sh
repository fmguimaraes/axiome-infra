# shellcheck shell=bash
# Fixture for the docker stub — mongo-backup.sh's `docker exec ... mongodump`
# sleeps briefly before succeeding, giving a test a window to deliver a
# signal to the real script while it is blocked on this call (AC44: the
# credentials tempfile must be removed by a trap on a signal too, not just
# on a normal exit or `fail`'s explicit exit).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"exec"*"axiome-mongo"*"mongodump"*)
      sleep 5
      printf 'fake-mongodump-binary-archive-bytes-not-empty'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
