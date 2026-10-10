# shellcheck shell=bash
# Fixture for the docker stub — sync-event-store-indexes.sh's AXI-1971
# review fix #3: the CONTAINER's own $MONGODB_URL host-read reports a
# REMOTE host, even though the host-side URL this command was told about
# was local — the sync must refuse, and `prisma db push` must never be
# invoked (if it is, this fixture's `*) return 99` arm makes the test fail
# via an unconfigured-call teardown failure, since no case arm below
# matches a prisma invocation).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"MONGODB_URL"*)
      echo "evil-remote.example.com"
      return 0
      ;;
    *) return 99 ;;
  esac
}
