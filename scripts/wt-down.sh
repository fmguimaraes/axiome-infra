#!/usr/bin/env bash
# wt-down.sh — tear THIS worktree's app stack down. Leaves the shared stack and
# every OTHER worktree fully running.
#
# Default (no --purge): `docker compose -p axiome-<slug> down -v` — stops and
# removes this worktree's app containers and its own node_modules volumes only.
# The worktree's data on the shared services (its Postgres DB, Mongo DB, Redis
# index, RabbitMQ vhost, buckets) is LEFT INTACT, and its registry allocation is
# kept, so a later wt-up.sh gets the same ports/index back.
#
# --purge   ALSO destroy this worktree's data and release its allocation: drop
#           the Postgres DB, drop the Mongo DB, FLUSHDB the Redis index, delete
#           the RabbitMQ vhost, remove the buckets, and free the registry entry.
#           Opt-in only — never the default. Only ever touches THIS worktree's
#           namespaced resources, never a shared instance or another worktree.
#
# --shared  Stop the SHARED stack itself (docker compose -p axiome-shared down).
#           This is a machine-wide action — do NOT do it as part of a feature
#           task; it stops everyone's data services. Add --purge-shared to also
#           delete the shared volumes (destroys ALL local data). Guarded.
#
#   --slug <name>   target a specific worktree slug instead of the current dir
#   -h | --help     this help
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

PURGE=0; SHARED=0; PURGE_SHARED=0; SLUG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)         PURGE=1 ;;
    --shared)        SHARED=1 ;;
    --purge-shared)  SHARED=1; PURGE_SHARED=1 ;;
    --slug)          SLUG_OVERRIDE="${2:?--slug needs a value}"; shift ;;
    -h|--help)       sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

need_docker

# --- Shared-stack teardown (machine-wide) ----------------------------------
if [ "${SHARED}" -eq 1 ]; then
  if [ "${PURGE_SHARED}" -eq 1 ]; then
    warn "About to STOP the shared stack AND DELETE all shared volumes (every worktree's data)."
    shared_compose down -v
    ok "Shared stack down; shared volumes removed."
  else
    warn "Stopping the shared stack (machine-wide). Every worktree's data services go down."
    shared_compose down
    ok "Shared stack stopped (volumes kept)."
  fi
  exit 0
fi

# --- Resolve the target worktree from the registry -------------------------
if [ -n "${SLUG_OVERRIDE}" ]; then
  # look the slug up in the registry to recover its offset + redis index
  entry="$(wt_registry_list | awk -F'\t' -v s="${SLUG_OVERRIDE}" '$1==s{print; exit}')"
  [ -n "${entry}" ] || die "slug '${SLUG_OVERRIDE}' not found in the registry"
  SLUG="$(printf '%s' "${entry}" | cut -f1)"
  OFFSET="$(printf '%s' "${entry}" | cut -f2)"
  REDIS_DB="$(printf '%s' "${entry}" | cut -f3)"
else
  SLUG="$(wt_derive_slug)"
  reg="$(wt_registry_get "${SLUG}")"
  [ -n "${reg}" ] || die "no registry entry for slug '${SLUG}' (${WORKTREE_ROOT}) — nothing to bring down (run wt-up.sh first, or pass --slug)."
  OFFSET="$(printf '%s' "${reg}" | cut -f2)"
  REDIS_DB="$(printf '%s' "${reg}" | cut -f3)"
fi

wt_derive_vars "${SLUG}" "${OFFSET}" "${REDIS_DB}"

# A throwaway env file so compose can interpolate the app file for `down`.
TMP_ENV="$(mktemp)"; trap 'rm -f "${TMP_ENV}"' EXIT
wt_write_env "${TMP_ENV}" "${SLUG}" "${OFFSET}" "${REDIS_DB}"

log "Bringing down app stack ${PROJECT} (down -v: containers + node_modules volumes)"
docker compose -p "${PROJECT}" --env-file "${TMP_ENV}" -f "${APP_COMPOSE}" down -v || \
  warn "compose down reported an issue (stack may already be down)"
ok "App stack ${PROJECT} stopped"

if [ "${PURGE}" -eq 0 ]; then
  ok "Done. Data + registry allocation kept — re-run wt-up.sh to resume with the same ports."
  exit 0
fi

# --- Purge: destroy THIS worktree's data on the shared services ------------
warn "--purge: destroying worktree '${SLUG}' data on the shared services"
if ! shared_running; then
  warn "Shared stack not running — cannot purge DB/redis/vhost/buckets. Start it (wt-up.sh --shared-only) and re-run --purge."
else
  # Postgres: terminate connections, then drop.
  pg_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PG_DB}' AND pid<>pg_backend_pid()" >/dev/null 2>&1 || true
  pg_admin -c "DROP DATABASE IF EXISTS \"${PG_DB}\"" >/dev/null 2>&1 && ok "Dropped Postgres DB \"${PG_DB}\"" || warn "Could not drop Postgres DB \"${PG_DB}\""
  # Mongo: drop the event-store DB.
  shared_compose exec -T mongodb mongosh -u "${MONGO_USER}" -p "${MONGO_PASS}" \
    --authenticationDatabase admin --quiet --eval "db.getSiblingDB('${MONGO_DB}').dropDatabase()" >/dev/null 2>&1 \
    && ok "Dropped Mongo DB '${MONGO_DB}'" || warn "Could not drop Mongo DB '${MONGO_DB}'"
  # Redis: flush only this worktree's DB index.
  redis_cli -n "${REDIS_DB}" FLUSHDB >/dev/null 2>&1 && ok "Flushed Redis DB index ${REDIS_DB}" || warn "Could not flush Redis DB ${REDIS_DB}"
  # RabbitMQ: delete the vhost.
  rabbitmqctl delete_vhost "${MQ_VHOST}" >/dev/null 2>&1 && ok "Deleted RabbitMQ vhost '${MQ_VHOST}'" || warn "Could not delete vhost '${MQ_VHOST}' (may not exist)"
  # MinIO: remove this worktree's buckets.
  mc_sh "for b in ${B_UPLOADS} ${B_ARTIFACTS} ${B_SYSTEM}; do mc rb --force local/\$b >/dev/null 2>&1 || true; done" >/dev/null 2>&1
  ok "Removed buckets ${B_UPLOADS}, ${B_ARTIFACTS}, ${B_SYSTEM}"
fi

# Release the registry allocation (the registry is keyed by slug).
wt_registry_release "${SLUG}"
ok "Released registry allocation for '${SLUG}'"
ok "Purge complete."
