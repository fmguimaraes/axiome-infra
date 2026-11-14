# shellcheck shell=bash
# Fixture for the gh stub — power.sh's best-effort nightly E2E toggle.
# UT-INFRA-804..808.
stub_respond() {
  case "$1" in
    "workflow disable "*|"workflow enable "*) return 0 ;;
  esac
  return 99
}
