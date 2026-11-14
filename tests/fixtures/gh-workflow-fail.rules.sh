# shellcheck shell=bash
# Fixture for the gh stub — the toggle's API call errors (e.g. unauthenticated).
# UT-INFRA-807.
stub_respond() {
  case "$1" in
    "workflow disable "*|"workflow enable "*) echo "HTTP 401: Bad credentials" >&2; return 1 ;;
  esac
  return 99
}
