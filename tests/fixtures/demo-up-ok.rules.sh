# shellcheck shell=bash
# Fixture for the docker stub — `make demo-up`: migrate-gate apply/status
# succeed, and the final `up -d` of the demo stack succeeds.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"pg_dump"*)
      echo "-- pg_dump test output --"
      return 0
      ;;
    *"docker/migrate-gate/cli.js apply"*)
      echo "MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=x APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped"
      return 0
      ;;
    *"docker/migrate-gate/cli.js status"*)
      echo "PENDING organization-service 20261001_example"
      echo "PENDING_COUNT=1"
      return 0
      ;;
    *"axiome-demo"*"up -d"*) return 0 ;;
    *) return 99 ;;
  esac
}
