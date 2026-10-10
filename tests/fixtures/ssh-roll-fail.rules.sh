# shellcheck shell=bash
# Fixture for tests/dev-auto-promote-workflow.bats UT-INFRA-326 — simulates
# a remote roll-service.sh that prints some progress then fails the
# migration gate (exit 1), the same shape as the real script's own
# FAIL-CLOSED path. Used to prove the "Roll service on dev VM" step's own
# exit status tracks the remote failure (review bounce #2: `pipefail`).
stub_respond() {
  case "$1" in
    *)
      printf '=== docker compose up -d gateway user-service organization-service event-service ===\n'
      printf 'FAIL-CLOSED: roll aborted — the migration gate did not pass. Previous containers keep serving.\n' >&2
      return 1
      ;;
  esac
}
