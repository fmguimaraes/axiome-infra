# shellcheck shell=bash
# Fixture for the systemctl stub — install-mongo-backup-timer-remote.sh's
# happy path: daemon-reload, enable --now, is-enabled, is-active and
# list-timers all succeed for mongo-backup.timer.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"daemon-reload"*) return 0 ;;
    *"enable"*"--now"*"mongo-backup.timer"*) return 0 ;;
    *"is-enabled"*"mongo-backup.timer"*) return 0 ;;
    *"is-active"*"mongo-backup.timer"*) return 0 ;;
    *"list-timers"*"mongo-backup.timer"*)
      printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\nmongo-backup.timer mongo-backup.service'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
