# shellcheck shell=bash
# Fixture for the ssh stub — scripts/pull-on-vm.sh (AXI-1953). Any ssh call
# that reaches this fixture (i.e. the environment was not refused) succeeds.
stub_respond() {
  case "$1" in
    *"ubuntu@"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
