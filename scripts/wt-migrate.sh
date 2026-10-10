#!/usr/bin/env bash
# wt-migrate.sh — forward-only Prisma migration of the ONE shared local
# Postgres DB ("axiome" on the axiome-localhost container), AXI-1952 (FR36,
# FR37, EC11). Shared by `scripts/wt-up.sh --migrate` and `make demo-up`.
#
# `apply`:
#   1. acquires a machine-local lock (wt_acquire_migrate_lock) so two
#      worktrees never migrate at the same time — EC11: the second waits up
#      to the timeout, then refuses; it never runs concurrently.
#   2. takes a verified pg_dump backup of the shared DB BEFORE anything is
#      applied (FR37) — refuses on a failed or an empty dump; nothing is
#      migrated in that case.
#   3. runs migrate-gate (AXI-1946) forward-only, no schema-push fallback of
#      any kind, inside the target service's own container.
#
# `status` is read-only (no lock, no backup) — just prints migrate-gate's
# own PENDING lines, for the `make demo-up` opt-out (FR38).
#
# Why `node docker/migrate-gate/cli.js`, not the `migrate-gate` PATH binary:
# the gate is baked onto PATH in the backend's *production* Dockerfile image
# (AXI-1946 decision 2). Every local stack here (wt-up.sh's `backend`
# service AND the demo stack's `axiome-demo-node:local` image) instead runs
# `node:20-*` with the primary axiome-back checkout bind-mounted at /app and
# `npm run dev` — never that built image — so the PATH binary does not
# exist in this layout. The gate's own source ships inside that same
# bind-mounted checkout, so invoking it via `node docker/migrate-gate/cli.js
# <cmd>` from /app runs the identical, unmodified gate — just not through
# the PATH shim. MIGRATE_GATE_APP_ROOT defaults to /app, which matches cwd.
#
# Usage:
#   wt-migrate.sh apply|status \
#     --compose-project <p> --compose-file <f> \
#     [--env-file <f>] [--service <name, default backend>] \
#     [--mode exec|run (default exec; demo-up passes --mode run since its
#        backend container is not started yet at migrate time)]
set -euo pipefail
# shellcheck source=./wt-common.sh
. "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

CMD="${1:-}"; [ -n "${CMD}" ] || die "usage: wt-migrate.sh <apply|status> --compose-project <p> --compose-file <f> [...]"
shift

SERVICE="backend"; MODE="exec"
COMPOSE_PROJECT=""; COMPOSE_FILE=""; ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --compose-project) COMPOSE_PROJECT="${2:?--compose-project needs a value}"; shift ;;
    --compose-file)    COMPOSE_FILE="${2:?--compose-file needs a value}"; shift ;;
    --env-file)        ENV_FILE="${2:?--env-file needs a value}"; shift ;;
    --service)         SERVICE="${2:?--service needs a value}"; shift ;;
    --mode)            MODE="${2:?--mode needs exec or run}"; shift ;;
    *) die "wt-migrate.sh: unknown flag: $1" ;;
  esac
  shift
done
[ -n "${COMPOSE_PROJECT}" ] && [ -n "${COMPOSE_FILE}" ] || die "wt-migrate.sh: --compose-project and --compose-file are required"

_compose() {
  local args=(-p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}")
  [ -z "${ENV_FILE}" ] || args+=(--env-file "${ENV_FILE}")
  docker compose "${args[@]}" "$@"
}

# Regenerates Prisma clients, then runs migrate-gate's own subcommand. Both
# steps run inside the service's container/source checkout; `set -e` makes a
# generate failure visible as a distinct, non-swallowed failure.
_gate() {  # $1 = apply|status
  local remote="set -e; npx turbo run prisma:generate >/dev/null; node docker/migrate-gate/cli.js $1"
  if [ "${MODE}" = "run" ]; then
    _compose run --rm --no-deps -T "${SERVICE}" sh -lc "${remote}"
  else
    _compose exec -T "${SERVICE}" sh -lc "${remote}"
  fi
}

if [ "${CMD}" = "status" ]; then
  _gate status
  exit 0
fi
[ "${CMD}" = "apply" ] || die "wt-migrate.sh: unknown subcommand '${CMD}' (expected apply|status)"

log "Waiting for the machine-local migrate lock (${WT_MIGRATE_LOCK_FILE})…"
if ! wt_acquire_migrate_lock "${WT_MIGRATE_LOCK_TIMEOUT_SECS:-60}"; then
  die "another wt-migrate.sh apply is already running on this machine (lock: ${WT_MIGRATE_LOCK_FILE}) — refusing to run concurrently (EC11). Nothing was changed."
fi
ok "Migrate lock acquired."

wt_backup_shared_postgres || die "backup failed or was empty — refusing to migrate (FR37). Nothing was changed."

log "Running migrate-gate apply in ${SERVICE} (forward-only; no schema-push fallback)…"
if ! _gate apply; then
  die "migrate-gate apply failed — see its output above for which service/migration failed. Nothing further was started."
fi
ok "migrate-gate apply succeeded."
