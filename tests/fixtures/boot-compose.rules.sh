# shellcheck shell=bash
# Fixture for the docker stub — AXI-1950's providers/aws/onbox/boot.sh tests.
# `docker compose up -d` appends a trace line to BOOT_TRACE_FILE (so a test
# can assert ordering against the fake asset-sync.sh/refresh-env.sh below)
# and exits BOOT_FIXTURE_COMPOSE_RC (default 0).
stub_respond() {
  case "$1" in
    *"compose up -d"*)
      echo "compose-up" >> "${BOOT_TRACE_FILE}"
      return "${BOOT_FIXTURE_COMPOSE_RC:-0}"
      ;;
    *)
      return 99
      ;;
  esac
}
