# shellcheck shell=bash
# Fixture for the docker stub — sync-event-store-indexes.sh's AXI-1968
# multi-host container-side check: the CONTAINER's own $MONGODB_URL has
# two hosts; the first is local, the second is remote. The real
# container-side POSIX snippet would print both hosts (one per line); this
# fixture plays that role directly since the stub never actually runs the
# embedded shell text.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"MONGODB_URL"*)
      printf 'localhost\nevil-remote.example.com\n'
      return 0
      ;;
    *) return 99 ;;
  esac
}
