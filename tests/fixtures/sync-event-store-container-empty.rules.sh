# shellcheck shell=bash
# Fixture for the docker stub — sync-event-store-indexes.sh's AXI-1971
# review fix #3: the CONTAINER's own $MONGODB_URL host-read fails (prints
# nothing and exits non-zero, as if $MONGODB_URL were unset inside the
# container) — the sync must refuse rather than assume local, and
# `prisma db push` must never be invoked.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"MONGODB_URL"*)
      return 1
      ;;
    *) return 99 ;;
  esac
}
