#!/usr/bin/env bash
# providers/aws/onbox/boot.sh — AXI-1950 (epic AXI-1944 decision 8, FR10/FR11/
# FR12). Delivered to <dest>/scripts/boot.sh by scripts/asset-sync.sh and run
# by the axiome.service systemd unit (cloud-init/init.sh.tftpl) on every
# boot, and once at the end of cloud-init on a fresh box.
#
# Fixed order: asset sync (pull) -> .env refresh -> `docker compose up -d`.
# Steps 1 and 2 are NOT fatal to boot — a box with assets/.env already on
# disk must still come up (EC6, "same spirit as EC6" for the asset sync). The
# migrate-gate one-shot INSIDE `docker compose up -d` (AXI-1946, decision 4)
# is the real backend-safety gate and is never bypassed or swallowed here —
# step 3's own exit code is surfaced as this script's exit code.
set -uo pipefail
# Deliberately no `set -e`: a step 1/2 failure must fall through to step 3.

AXIOME_DIR="${AXIOME_DIR:-/opt/axiome}"
ONBOX_S3_PREFIX="${ONBOX_S3_PREFIX:?ONBOX_S3_PREFIX env var required}"

log() {
  logger -t axiome-boot -- "$1" 2>/dev/null || echo "axiome-boot: $1"
}

sync_assets() {
  if "${AXIOME_DIR}/scripts/asset-sync.sh" pull "$ONBOX_S3_PREFIX" "$AXIOME_DIR"; then
    log "asset-sync: on-box assets are current"
  else
    log "asset-sync: pull did not update assets (rc=$?) — continuing with what is on disk"
  fi
}

refresh_env() {
  if "${AXIOME_DIR}/scripts/refresh-env.sh" "${AXIOME_DIR}/.env"; then
    log "refresh-env: .env refreshed from SSM"
  else
    log "refresh-env: refresh did not update .env (rc=$?) — continuing with the existing file"
  fi
}

start_stack() {
  cd "$AXIOME_DIR" || return 1
  if docker compose up -d; then
    log "docker compose up -d: stack started (migrate-gate ran as part of this)"
    return 0
  fi
  log "docker compose up -d: FAILED — run 'docker compose logs migrate' on this box"
  return 1
}

main() {
  sync_assets
  refresh_env
  start_stack
}

main "$@"
