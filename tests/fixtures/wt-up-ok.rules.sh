# shellcheck shell=bash
# Fixture for the docker stub — a fully successful wt-up.sh run (shared
# stack health, vhost/bucket provisioning, app stack start, and the
# migrate-gate / control-plane migration calls it may make). AXI-1952.
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
      echo "MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=x APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped"
      return 0
      ;;
    *"control-plane"*"migrate deploy"*) return 0 ;;
    *"pg_dump"*)
      echo "-- pg_dump test output --"
      return 0
      ;;
    *) return 99 ;;
  esac
}
