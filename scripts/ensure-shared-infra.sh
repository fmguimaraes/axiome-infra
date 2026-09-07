#!/usr/bin/env bash
# ensure-shared-infra.sh — safeguard against the recurring "MinIO / RabbitMQ is
# down" failures.
#
# The shared commodity services (Postgres, Mongo, Redis, RabbitMQ, MinIO) live in
# the machine-wide `axiome-shared` compose project. They are created with NO
# restart policy, so a host reboot / Docker restart leaves them Exited while the
# per-worktree app stacks (restart=unless-stopped) come back — the backend then
# crash-loops with `EAI_AGAIN rabbitmq` and uploads fail because MinIO :9000 is
# unreachable.
#
# This script is idempotent. Run it any time (before `make demo-up`, at session
# start, or by hand after a reboot):
#   bash axiome-infra/scripts/ensure-shared-infra.sh
#
# It (1) ensures the external network exists, (2) brings up + health-waits every
# shared service, and (3) pins `restart=unless-stopped` on the live containers so
# they survive the NEXT reboot too — WITHOUT editing docker-compose.shared.yml
# (which project rules keep serialized/announced).
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_COMPOSE="${INFRA_DIR}/docker-compose.shared.yml"
SHARED_PROJECT="axiome-shared"
SHARED_NET="axiome-shared-net"

log() { printf '\033[36m[ensure-shared]\033[0m %s\n' "$*"; }

# 1. External network the app stacks attach to.
if ! docker network inspect "${SHARED_NET}" >/dev/null 2>&1; then
  log "creating network ${SHARED_NET}"
  docker network create "${SHARED_NET}" >/dev/null
fi

# 2. Start (or start-missing) all shared services and wait for their healthchecks.
log "bringing up shared stack and waiting for health…"
docker compose -p "${SHARED_PROJECT}" -f "${SHARED_COMPOSE}" up -d --wait

# 3. Re-pin the restart policy on the live containers (a compose recreate resets
#    it to 'no'). This is what makes them survive the next reboot.
mapfile -t CIDS < <(docker ps -q --filter "label=com.docker.compose.project=${SHARED_PROJECT}")
if [ "${#CIDS[@]}" -gt 0 ]; then
  docker update --restart unless-stopped "${CIDS[@]}" >/dev/null
  log "pinned restart=unless-stopped on ${#CIDS[@]} shared container(s)"
fi

log "shared infra ready:"
docker ps --filter "label=com.docker.compose.project=${SHARED_PROJECT}" \
  --format '  {{.Names}}\t{{.Status}}'
