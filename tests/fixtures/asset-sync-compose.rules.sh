# shellcheck shell=bash
# Fixture for the docker stub — AXI-1950's `docker compose -f <file> config
# -q` validation call inside scripts/asset-sync.sh. Exit code controlled by
# ASSET_SYNC_FIXTURE_COMPOSE_RC (default 0 = valid).
stub_respond() {
  case "$1" in
    *"compose -f"*"config -q"*)
      return "${ASSET_SYNC_FIXTURE_COMPOSE_RC:-0}"
      ;;
    *)
      return 99
      ;;
  esac
}
