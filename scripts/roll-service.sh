#!/usr/bin/env bash
# roll-service.sh — refresh /opt/axiome/.env from SSM and roll one compose service.
#
# Executed on the dev VM (via `ssh ... < scripts/roll-service.sh` from the
# auto-promote workflow). Reads from env:
#
#   KEY        — env var name in /opt/axiome/.env (e.g. BACKEND_IMAGE_TAG)
#   IMAGE_TAG  — new image tag (e.g. e0c8723c)
#   SERVICE    — docker compose service name (one of: backend|biocompute|frontend)
#                (handled below — backend rolls all 4 gateway/user/org/event containers
#                because they share an image)
#
# Idempotent: re-running with the same KEY/IMAGE_TAG/SERVICE is a no-op
# (sed in-place + `up -d` is safe).

set -euo pipefail

: "${KEY:?KEY env var required}"
: "${IMAGE_TAG:?IMAGE_TAG env var required}"
: "${SERVICE:?SERVICE env var required}"

ENV_FILE=/opt/axiome/.env
COMPOSE_FILE=/opt/axiome/docker-compose.yml

if ! sudo test -f "${ENV_FILE}"; then
    echo "ERROR: ${ENV_FILE} does not exist — has cloud-init finished?" >&2
    exit 1
fi

echo "=== Updating ${KEY}=${IMAGE_TAG} in ${ENV_FILE} ==="
if sudo grep -q "^${KEY}=" "${ENV_FILE}"; then
    sudo sed -i "s|^${KEY}=.*|${KEY}=${IMAGE_TAG}|" "${ENV_FILE}"
else
    echo "${KEY}=${IMAGE_TAG}" | sudo tee -a "${ENV_FILE}" > /dev/null
fi

# Map dispatch service name -> compose service names.
# Backend image is shared across 4 nest apps (gateway + user/org/event service).
case "${SERVICE}" in
    backend)
        TARGETS=("gateway" "user-service" "organization-service" "event-service")
        ;;
    biocompute)
        TARGETS=("biocompute")
        ;;
    frontend)
        TARGETS=("frontend")
        ;;
    *)
        echo "ERROR: unknown SERVICE '${SERVICE}'" >&2
        exit 1
        ;;
esac

echo "=== docker compose pull ${TARGETS[*]} ==="
sudo docker compose -f "${COMPOSE_FILE}" pull "${TARGETS[@]}"

echo "=== docker compose up -d ${TARGETS[*]} ==="
sudo docker compose -f "${COMPOSE_FILE}" up -d "${TARGETS[@]}"

echo "=== Roll complete: ${SERVICE} -> ${IMAGE_TAG} ==="
