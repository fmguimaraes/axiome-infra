# shellcheck shell=bash
# Fixture for the docker stub — sync-event-store-indexes.sh's AXI-1971
# review fix #3: the CONTAINER's own $MONGODB_URL host-read reports a
# local host ("mongodb", the compose-network alias), so the sync proceeds.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"MONGODB_URL"*)
      echo "mongodb"
      return 0
      ;;
    *"prisma db push"*)
      echo "Your database indexes are now in sync with your Prisma schema."
      return 0
      ;;
    *) return 99 ;;
  esac
}
