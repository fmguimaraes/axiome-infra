# shellcheck shell=bash
# Fixture for the docker stub — `make demo-up`: the backup succeeds but
# migrate-gate apply fails; `up -d` must never be reached.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
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
