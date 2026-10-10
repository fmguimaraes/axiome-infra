# shellcheck shell=bash
# Fixture for the docker stub — sync-event-store-indexes.sh's happy path:
# Compose v2 probe succeeds, the container's own MONGODB_URL host-read
# (AXI-1971 review fix #3) reports a local host, and the Prisma db push
# inside the container succeeds.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"MONGODB_URL"*)
      echo "localhost"
      return 0
      ;;
    *"prisma db push"*)
      echo "Your database indexes are now in sync with your Prisma schema."
      return 0
      ;;
    *) return 99 ;;
  esac
}
