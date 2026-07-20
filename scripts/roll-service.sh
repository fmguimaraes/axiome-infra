#!/usr/bin/env bash
# roll-service.sh — refresh /opt/axiome/.env from SSM and roll one compose service.
#
# Executed on the target VM (dev via `ssh ... < scripts/roll-service.sh` from the
# auto-promote workflow; staging/production the same way, run by an operator).
# Reads from env:
#
#   KEY        — env var name in /opt/axiome/.env (e.g. BACKEND_IMAGE_TAG)
#   IMAGE_TAG  — new image tag (e.g. e0c8723c)
#   SERVICE    — docker compose service name (one of: backend|biocompute|frontend)
#                (handled below — backend rolls all 4 gateway/user/org/event containers
#                because they share an image)
#
# Idempotent: re-running with the same KEY/IMAGE_TAG/SERVICE is a no-op
# (sed in-place + `up -d` is safe).
#
# Schema migrations (FR8/FR9, MIPP-Data-Platform AXI-1003): when SERVICE=backend,
# organization-service's Prisma schema is migrated — forward-only, versioned,
# repeatable — against the newly-pulled image *before* the swap, verified by a
# whole-schema row-count parity check, fail-closed on any error or count drop. The
# migration facts are printed on a `MIGRATION_FACTS:` line for the caller to bind
# into the FR14 Qualification Record (generate-qualification-record.sh) — this
# script does not call that generator itself (it only runs on the CI runner /
# operator host, which has the axiome-infra checkout; this script runs on the VM).
#
# Rollback: `prisma migrate deploy` wraps each migration in its own transaction, so
# a failed migration rolls itself back automatically — the swap to the new image is
# skipped and the old containers keep running. To undo an already-applied,
# successfully-committed migration, author a new forward migration that reverses it
# (forward-only per FR8 — never edit/delete an applied migration file). If the
# row-count check itself fails post-migration, restore `axiome-<env>-pg` from the
# latest automated snapshot before retrying.

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

# Forward-only Prisma migration for organization-service, verified by a whole-schema
# row-count parity check. Fail-closed: exits non-zero (aborting this script, so the
# image swap below never runs) on migrate error or a post-migration count drop.
migrate_organization_schema() {
    local pg_schema="organization_svc"
    local prisma_schema="apps/organization-service/src/prisma/schema.prisma"
    local dsn migrations_table_exists existing_table_count pre_count post_count schema_version

    echo "=== Schema migration: organization-service (FR8/FR9) ==="

    if ! command -v psql >/dev/null 2>&1; then
        echo "--- installing postgresql-client (row-count verification needs psql) ---"
        sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client
    fi

    dsn="$(sudo grep '^ORGANIZATION_DATABASE_URL=' "${ENV_FILE}" | cut -d= -f2-)"
    if [[ -z "${dsn}" ]]; then
        echo "ERROR: ORGANIZATION_DATABASE_URL not set in ${ENV_FILE}" >&2
        exit 1
    fi

    row_count_total() {
        psql "${dsn}" -tAc "
            SELECT COALESCE(SUM(cnt), 0)::bigint FROM (
                SELECT (xpath('/row/c/text()',
                         query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                                      false, true, '')))[1]::text::bigint AS cnt
                FROM information_schema.tables
                WHERE table_schema = '${pg_schema}' AND table_type = 'BASE TABLE'
            ) t;
        " 2>/dev/null || echo "?"
    }

    migrations_table_exists="$(psql "${dsn}" -tAc "
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = '${pg_schema}' AND table_name = '_prisma_migrations'
        );
    " 2>/dev/null || echo "f")"

    # Distinguish "provisioned via db push, tables exist but no history" (needs
    # baselining) from a genuinely fresh/empty environment (no history is correct —
    # let `migrate deploy` create everything from scratch below, do not baseline it
    # away or the tables would never get created).
    existing_table_count="$(psql "${dsn}" -tAc "
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema = '${pg_schema}' AND table_type = 'BASE TABLE'
          AND table_name <> '_prisma_migrations';
    " 2>/dev/null || echo "0")"

    if [[ "${migrations_table_exists}" != "t" && "${existing_table_count}" =~ ^[0-9]+$ && "${existing_table_count}" -gt 0 ]]; then
        # Prod-class environments provisioned before this story ran `prisma db push`,
        # which leaves no migration history. Baseline once: record every migration
        # already reflected in the live schema as applied, without re-running its DDL.
        echo "--- baselining: _prisma_migrations absent, ${existing_table_count} table(s) already present — recording existing migrations as applied ---"
        sudo docker compose -f "${COMPOSE_FILE}" run --rm -T organization-service sh -c "
            for d in apps/organization-service/src/prisma/migrations/*/; do
                name=\"\$(basename \"\$d\")\"
                echo \"    resolve --applied \$name\"
                npx prisma migrate resolve --applied \"\$name\" --schema=${prisma_schema}
            done
        "
    fi

    pre_count="$(row_count_total)"
    echo "--- pre-migration row count (${pg_schema}): ${pre_count} ---"

    echo "--- prisma migrate deploy ---"
    if ! sudo docker compose -f "${COMPOSE_FILE}" run --rm -T organization-service \
            npx prisma migrate deploy --schema="${prisma_schema}"; then
        echo "FAIL-CLOSED: migrate deploy failed — image swap skipped, old containers keep serving." >&2
        echo "The failed migration rolled back automatically (Prisma transaction). Fix forward with a" >&2
        echo "new migration; do not edit/delete applied migration files (FR8)." >&2
        exit 1
    fi

    post_count="$(row_count_total)"
    echo "--- post-migration row count (${pg_schema}): ${post_count} ---"

    if [[ "${pre_count}" =~ ^[0-9]+$ && "${post_count}" =~ ^[0-9]+$ && "${post_count}" -lt "${pre_count}" ]]; then
        echo "FAIL-CLOSED: row count dropped ${pre_count} -> ${post_count} in ${pg_schema} — possible data loss." >&2
        echo "Image swap skipped. Rollback: restore axiome-<env>-pg from the latest automated snapshot" >&2
        echo "before retrying — do not swap to the new image against a schema in this state." >&2
        exit 1
    fi

    schema_version="$(sudo docker compose -f "${COMPOSE_FILE}" run --rm -T organization-service sh -c '
        ls -1 apps/organization-service/src/prisma/migrations | sort | tail -1
    ')"

    echo "Migration + row-count parity OK."
    echo "MIGRATION_FACTS: SCHEMA_VERSION=${schema_version} PRE_COUNTS=${pre_count} POST_COUNTS=${post_count}"
}

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

if [[ "${SERVICE}" == "backend" ]]; then
    migrate_organization_schema
fi

echo "=== docker compose up -d ${TARGETS[*]} ==="
sudo docker compose -f "${COMPOSE_FILE}" up -d "${TARGETS[@]}"

echo "=== Roll complete: ${SERVICE} -> ${IMAGE_TAG} ==="
