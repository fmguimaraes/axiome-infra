# shellcheck shell=bash
# Fixture for the docker stub — simulates a machine where only legacy
# `docker-compose` v1 is installed: `docker compose version` is a
# CONFIGURED failure (exit 1), not an unconfigured call, so this fixture on
# its own never trips STUB_FAIL_LOG. Used by
# tests/legacy-compose-safety.bats UT-INFRA-262 to prove the Makefile's
# fail-closed $(error ...) stops before this (or any) call is ever reached.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 1 ;;
    *) return 99 ;;
  esac
}
