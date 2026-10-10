# shellcheck shell=bash
# Fixture for the docker stub — same as wt-up-ok.rules.sh, except the
# migrate-gate apply call fails (a genuine migration failure).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"network inspect"*) return 0 ;;
    *"up -d --wait"*) return 0 ;;
    *"rabbitmqctl list_vhosts"*)
      echo "axiome-global-axi-1233"
      return 0
      ;;
    *"rabbitmqctl set_permissions"*) return 0 ;;
    *"minio/mc:latest"*) return 0 ;;
    *"up -d --build"*) return 0 ;;
    *"docker/migrate-gate/cli.js apply"*)
      echo "FAIL organization-service: unfinished migration in the ledger"
      return 1
      ;;
    *"pg_dump"*)
      echo "-- pg_dump test output --"
      return 0
      ;;
    *) return 99 ;;
  esac
}
