#!/usr/bin/env bash
# wt-up.sh — bring THIS worktree's isolated local stack up.
#
# Idempotent, safe to re-run. It:
#   1. derives a slug from the worktree dir and allocates a collision-free
#      PORT_OFFSET + Redis DB index (registry: ~/.axiome/worktree-registry.json)
#   2. writes/refreshes the gitignored per-worktree .env
#   3. brings up the SHARED stack (axiome-shared) if needed and waits for health
#   4. creates this worktree's Postgres DB, RabbitMQ vhost, and MinIO buckets
#      (all idempotent) — Mongo DB / Redis index are created lazily on first use
#   5. brings up the app stack:  docker compose -p axiome-<slug> up -d --build
#   6. runs migrations (best-effort) and prints the resolved resources
#
# Flags:
#   --shared-only      only bring up + health-check the shared stack, then exit
#   --provision-only   do everything EXCEPT starting the app services (writes
#                      .env, brings up shared, creates DB/vhost/buckets) — useful
#                      for tests/CI that talk to the shared services directly
#   --no-seed          skip the migrate/seed step
#   --rebuild          force `up --build` to rebuild images
#   -h | --help        this help
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

# DO_SEED defaults OFF (2026-09-04): every worktree now shares ONE Postgres DB
# (axiome-localhost), and the seed step below can fall back to `prisma db push
# --accept-data-loss`, which would DESTROY that shared DB's data if a worktree's
# schema differs. Opt in deliberately with `--seed` only when you intend to
# migrate the one shared DB (it affects every worktree).
SHARED_ONLY=0; PROVISION_ONLY=0; DO_SEED=0; BUILD_FLAG="--build"
while [ $# -gt 0 ]; do
  case "$1" in
    --shared-only)    SHARED_ONLY=1 ;;
    --provision-only) PROVISION_ONLY=1 ;;
    --no-seed)        DO_SEED=0 ;;
    --seed)           DO_SEED=1 ;;   # opt in: migrate the ONE shared DB (affects all worktrees)
    --rebuild)        BUILD_FLAG="--build" ;;
    -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

need_docker
ensure_shared_net

# --- 1. Bring up the shared stack (idempotent) -----------------------------
log "Bringing up shared stack (${SHARED_PROJECT}) and waiting for health…"
shared_compose up -d --wait
ok "Shared services healthy (postgres, mongodb, redis, rabbitmq, minio)"

if [ "${SHARED_ONLY}" -eq 1 ]; then
  ok "Shared-only: done. Host ports 5432 / 6379 / 9000-9001 / 27017 / 5672-15672."
  exit 0
fi

# --- 2. Slug + registry allocation -----------------------------------------
SLUG="$(wt_derive_slug)"
[ -n "${SLUG}" ] || die "could not derive a slug from ${WORKTREE_ROOT}"
alloc="$(wt_registry_allocate "${SLUG}")" || die "registry allocation failed"
SLUG="$(printf '%s' "${alloc}" | cut -f1)"
OFFSET="$(printf '%s' "${alloc}" | cut -f2)"
REDIS_DB="$(printf '%s' "${alloc}" | cut -f3)"

# Derives PROJECT, *_PORT, PG_DB, MONGO_DB, MQ_VHOST, B_*, REDIS_PREFIX.
wt_derive_vars "${SLUG}" "${OFFSET}" "${REDIS_DB}"
ok "Worktree '${SLUG}' → project ${PROJECT}, PORT_OFFSET=${OFFSET}, REDIS_DB=${REDIS_DB}"

# --- 3. Write the per-worktree .env ----------------------------------------
ENV_FILE="${WT_ENV_FILE:-${INFRA_DIR}/.env}"
log "Writing ${ENV_FILE}"
wt_write_env "${ENV_FILE}" "${SLUG}" "${OFFSET}" "${REDIS_DB}"
ok "Wrote per-worktree env"

# --- 4. Create per-worktree isolation on the shared services ---------------
log "Provisioning isolated resources on the shared services"

# Postgres: the ONE shared DB ("${PG_DB}") lives on the external `axiome-localhost`
# container (see docker-compose.yml), provisioned outside wt-up — NOT on the shared
# `postgres` service. Do not create it here: `pg_admin` targets `postgres`, so a
# CREATE would mint a junk DB on the wrong server and re-fragment the setup.
ok "Postgres DB \"${PG_DB}\" on axiome-localhost (shared; externally provisioned — not created here)"

# RabbitMQ vhost + full permissions for the app user (idempotent)
if rabbitmqctl list_vhosts --quiet 2>/dev/null | grep -qx "${MQ_VHOST}"; then
  ok "RabbitMQ vhost '${MQ_VHOST}' already exists"
else
  rabbitmqctl add_vhost "${MQ_VHOST}" >/dev/null
  ok "Created RabbitMQ vhost '${MQ_VHOST}'"
fi
rabbitmqctl set_permissions -p "${MQ_VHOST}" "${MQ_USER}" ".*" ".*" ".*" >/dev/null
ok "RabbitMQ permissions set for '${MQ_USER}' on '${MQ_VHOST}'"

# MinIO buckets (versioning on the artifacts bucket, matching the old init)
mc_sh "mc mb --ignore-existing local/${B_UPLOADS} local/${B_ARTIFACTS} local/${B_SYSTEM} && mc version enable local/${B_ARTIFACTS} >/dev/null" >/dev/null
ok "MinIO buckets: ${B_UPLOADS}, ${B_ARTIFACTS}, ${B_SYSTEM} (versioning on artifacts)"

# Mongo DB and the Redis DB index need no creation step — Mongo creates the DB
# on first write, and Redis DB ${REDIS_DB} always exists (0..15).

if [ "${PROVISION_ONLY}" -eq 1 ]; then
  ok "Provision-only: shared stack + isolated resources ready; app services NOT started."
  print_summary
  exit 0
fi

# --- 5. Bring up the app stack ---------------------------------------------
log "Building & starting app stack (${PROJECT})…"
docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" -f "${APP_COMPOSE}" up -d ${BUILD_FLAG}
ok "App containers started"

# --- 6. Migrations (best-effort) -------------------------------------------
if [ "${DO_SEED}" -eq 1 ]; then
  log "Applying Prisma migrations inside the backend container (best-effort)…"
  if docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" -f "${APP_COMPOSE}" \
       exec -T backend sh -lc '
         set -e
         command -v npx >/dev/null 2>&1 || { echo "npx not ready yet (npm install still running?)"; exit 42; }
         npx turbo run prisma:generate >/dev/null 2>&1 || true
         for app in user-service organization-service control-plane; do
           ( cd apps/$app && npx prisma migrate deploy --schema=src/prisma/schema.prisma ) \
             || ( cd apps/$app && npx prisma db push --accept-data-loss --schema=src/prisma/schema.prisma ) || true
         done
         ( cd apps/event-service && npx prisma db push --schema=src/prisma/schema.prisma ) || true
       '; then
    ok "Migrations applied (baseline reference data seeds on service boot)"
  else
    warn "Migration step skipped/failed — the backend may still be running 'npm install'."
    warn "Re-run 'scripts/wt-up.sh --no-seed' once it is up, or apply Prisma migrations by hand."
  fi
fi

print_summary
