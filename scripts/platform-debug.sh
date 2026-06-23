#!/usr/bin/env bash
# platform-debug.sh — quick read-only debugging of a deployed platform host.
#
# Thin convenience wrapper over ssm-exec.sh for the things you reach for first
# when "the platform is misbehaving". All subcommands are read-only.
#
# Usage:
#   scripts/platform-debug.sh status                 # docker compose ps (all containers)
#   scripts/platform-debug.sh health                 # gateway /api/v1/health (real path)
#   scripts/platform-debug.sh logs gateway [N]       # tail N (default 80) lines of a service
#   scripts/platform-debug.sh login-test EMAIL       # POST /auth/login with the SSM admin pw
#   scripts/platform-debug.sh env                    # list .env KEYS (names only, no values)
#   scripts/platform-debug.sh shell '<cmd>'          # run an arbitrary command on the box
#
# Options (before the subcommand): -e ENV (default production), -r REGION.
#
# NOTE on health: the docker healthcheck probes /health and will show the gateway
# as "unhealthy" forever — the real endpoint is /api/v1/health (api/v1 global
# prefix). `status` flags this so you don't chase a phantom outage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSM="${SCRIPT_DIR}/ssm-exec.sh"
COMPOSE="docker compose -f /opt/axiome/docker-compose.yml"

ENVIRONMENT="production"
REGION="${AWS_REGION:-eu-west-3}"
ENV_ARGS=()
while getopts "e:r:h" opt; do
  case "${opt}" in
    e) ENVIRONMENT="${OPTARG}"; ENV_ARGS+=("-e" "${OPTARG}") ;;
    r) REGION="${OPTARG}"; ENV_ARGS+=("-r" "${OPTARG}") ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Run: $0 -h" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

run() { "${SSM}" "${ENV_ARGS[@]}" "$1"; }

SUBCMD="${1:-status}"
shift || true

case "${SUBCMD}" in
  status|ps)
    run "${COMPOSE} ps"
    echo "(reminder: gateway 'unhealthy' is usually the /health vs /api/v1/health probe bug — run 'health' to confirm app is up)" >&2
    ;;
  health)
    run "docker exec axiome-gateway wget -qO- http://localhost:3000/api/v1/health"
    ;;
  logs)
    SERVICE="${1:?usage: logs <service> [lines]}"
    LINES="${2:-80}"
    run "${COMPOSE} logs --tail=${LINES} ${SERVICE}"
    ;;
  login-test)
    EMAIL="${1:?usage: login-test <email>}"
    PARAM="/${ENVIRONMENT}/axiome-${ENVIRONMENT}/BOOTSTRAP_ADMIN_PASSWORD"
    # Fetch the admin password ON THE BOX from SSM (never travels through this CLI),
    # then POST it and print only the HTTP status line (no token, no password).
    # Uses GetParameter on the known path — the box's runtime role can Get but not
    # Describe parameters, so we never call describe-parameters here.
    run "set -e
PW=\$(aws ssm get-parameter --region ${REGION} --name ${PARAM} --with-decryption --query Parameter.Value --output text)
BODY=\$(printf '{\"email\":\"%s\",\"password\":\"%s\"}' '${EMAIL}' \"\$PW\")
docker exec axiome-gateway wget -S -qO /dev/null --post-data=\"\$BODY\" --header=Content-Type:application/json http://localhost:3000/api/v1/auth/login 2>&1 | grep -i 'HTTP/'"
    ;;
  env)
    run "grep -o '^[A-Z0-9_]*=' /opt/axiome/.env | sed 's/=$//' | sort"
    ;;
  shell)
    run "${1:?usage: shell '<command>'}"
    ;;
  *)
    echo "Unknown subcommand: ${SUBCMD}" >&2
    sed -n '2,20p' "$0" >&2
    exit 2
    ;;
esac
