# shellcheck shell=bash
# Fixture for the docker stub — backup succeeds, migrate-gate apply fails
# (e.g. a migration genuinely failed). No fallback of any kind is attempted.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"pg_dump"*)
      echo "-- pg_dump test output --"
      return 0
      ;;
    *"docker/migrate-gate/cli.js apply"*)
      echo "FAIL organization-service: unfinished migration in the ledger"
      return 1
      ;;
    *) return 99 ;;
  esac
}
