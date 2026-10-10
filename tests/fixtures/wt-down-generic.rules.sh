# shellcheck shell=bash
# Fixture for the docker stub — generic successful responses for wt-down.sh
# plumbing (need_docker, shared_compose, pg_dump backup) so a test can reach
# the purge-guard / confirm-token logic under test without an unconfigured
# call elsewhere masking the real assertion. tests/wt-down-purge.bats.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"compose -p axiome-shared"*"ps"*) return 0 ;;
    *"compose -p axiome-"*"down"*"-v"*) return 0 ;;
    *"pg_dump"*)
      echo "-- pg_dump test output --"
      return 0
      ;;
    *) return 99 ;;
  esac
}
