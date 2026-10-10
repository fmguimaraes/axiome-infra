# shellcheck shell=bash
# Fixture for the systemctl stub — `enable --now` reports success (rc 0)
# but the timer is NOT actually active afterwards (e.g. a transient
# start failure systemd still reports as "enable succeeded" because
# enabling and starting are tracked separately). Proves the installer
# verifies is-active independently rather than trusting enable's own exit
# code alone.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"daemon-reload"*) return 0 ;;
    *"enable"*"--now"*"mongo-backup.timer"*) return 0 ;;
    *"is-enabled"*"mongo-backup.timer"*) return 0 ;;
    *"is-active"*"mongo-backup.timer"*) return 1 ;;
    *)
      return 99
      ;;
  esac
}
