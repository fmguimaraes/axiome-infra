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
#   6. with --migrate: forward-only migration of the shared DB, backed up
#      first, failing loudly on error (see wt-migrate.sh); always prints
#      the resolved resources
#
# Flags:
#   --shared-only      only bring up + health-check the shared stack, then exit
#   --provision-only   do everything EXCEPT starting the app services (writes
#                      .env, brings up shared, creates DB/vhost/buckets) — useful
#                      for tests/CI that talk to the shared services directly
#   --migrate          apply pending Prisma migrations to the ONE shared DB
#                      (organization-service + user-service via migrate-gate,
#                      forward-only, no schema-push fallback; backed up first —
#                      see wt-migrate.sh). Affects every worktree. Off by default.
#   --no-migrate       explicit no-op opt-out (same as omitting --migrate)
#   --seed             DEPRECATED alias for --migrate (AXI-1952): the only thing
#                      this flag ever did was trigger the migration, which then
#                      let each service's own boot-time baseline seeding run
#                      against a migrated schema. Kept so existing muscle-memory
#                      (`wt-up.sh --seed`) still migrates instead of silently
#                      doing nothing; prefer --migrate going forward.
#   --no-seed          DEPRECATED alias for the default (no migration)
#   --rebuild          force `up --build` to rebuild images
#   -h | --help        this help
set -euo pipefail
# shellcheck source=./wt-common.sh
. "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

# DO_MIGRATE defaults OFF (2026-09-04, hardened AXI-1952): every worktree now
# shares ONE Postgres DB (axiome-localhost). Migrating it is forward-only
# (migrate-gate; FR36) with a verified backup first (FR37) — opt in
# deliberately with --migrate only when you intend to migrate the one shared
# DB (it affects every worktree).
SHARED_ONLY=0; PROVISION_ONLY=0; DO_MIGRATE=0; BUILD_FLAG="--build"
while [ $# -gt 0 ]; do
  case "$1" in
    --shared-only)    SHARED_ONLY=1 ;;
    --provision-only) PROVISION_ONLY=1 ;;
    --no-migrate)     DO_MIGRATE=0 ;;
    --migrate)        DO_MIGRATE=1 ;;
    --no-seed)        DO_MIGRATE=0 ;;   # deprecated alias, see --no-migrate
    --seed)           DO_MIGRATE=1 ;;   # deprecated alias, see --migrate
    --rebuild)        BUILD_FLAG="--build" ;;
    -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
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

# --- 6. Migrations (forward-only; FR36/FR37) --------------------------------
# A failure here is NOT swallowed: it exits this script non-zero and says
# what failed (wt-migrate.sh / migrate-gate's own output). No schema-push
# fallback exists on this path for organization-service or user-service.
# event-service (MongoDB) and control-plane are out of scope for the gate
# (decision 3's default service list is organization-service,user-service);
# control-plane still gets its own forward-only `prisma migrate deploy`
# below, with its push fallback removed — never silently re-added.
if [ "${DO_MIGRATE}" -eq 1 ]; then
  log "Migrating the shared Postgres DB (organization-service, user-service) via migrate-gate…"
  "${WT_COMMON_DIR}/wt-migrate.sh" apply \
    --compose-project "${PROJECT}" --compose-file "${APP_COMPOSE}" --env-file "${ENV_FILE}" --service backend \
    || die "migration failed — see above. The app stack is up but its schema may be behind; do not treat this worktree as migrated."

  # NOTE (AXI-1952): this call is OUTSIDE wt-migrate.sh's gate AND outside
  # its flock (wt_acquire_migrate_lock) — it runs after that lock has
  # already been released by the `wt-migrate.sh apply` call above, which
  # is its own short-lived subprocess. This is tolerated, not an oversight:
  # (a) control-plane is explicitly out of scope for migrate-gate's
  # tracked-service list (decision 3, see the comment above), so there is
  # no gate contract to run it through; (b) `prisma migrate deploy` is
  # itself forward-only and idempotent/advisory-locked by Prisma's own
  # migration-history table, so two worktrees racing this specific command
  # fail safely (the loser gets Prisma's own "another migrate is already
  # running" error, not data loss) even without wt's own lock; (c) it has
  # no push-fallback, matching AC6. If control-plane is ever added to
  # MIGRATE_GATE_SERVICES, this call should move inside the gate/lock and
  # this block should be deleted.
  log "Migrating control-plane schema (forward-only, no push fallback)…"
  docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" -f "${APP_COMPOSE}" \
    exec -T backend sh -lc 'cd apps/control-plane && npx prisma migrate deploy --schema=src/prisma/schema.prisma' \
    || die "control-plane migration failed — see above."
  ok "Migrations applied (baseline reference data seeds on each service's own boot)."
else
  ok "Skipping migration (pass --migrate to apply pending Prisma migrations to the shared DB)."
fi

print_summary
