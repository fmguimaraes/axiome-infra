# shellcheck shell=bash
# Fixture for the systemctl stub — `enable --now mongo-backup.timer` itself
# fails (e.g. the unit file is malformed). is-enabled/is-active/list-timers
# must never be reached: the installer refuses right after `enable` fails.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"daemon-reload"*) return 0 ;;
    *"enable"*"--now"*"mongo-backup.timer"*)
      printf 'Failed to enable unit: Unit mongo-backup.timer is masked.'
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
