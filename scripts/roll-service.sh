#!/usr/bin/env bash
# roll-service.sh — roll one compose service on the box through the
# migration gate (AXI-1953, epic AXI-1944, FR13/FR18/FR20/NFR7, AC2/AC8/AC27).
#
# Executed ON the target VM: dev via `ssh ... bash -s < scripts/roll-service.sh`
# from .github/workflows/dev-auto-promote.yml; staging/production the same
# way (today manually; AXI-1954 wires the automated production path).
# Reads from env:
#
#   KEY        — env var name in /opt/axiome/.env (e.g. BACKEND_IMAGE_TAG)
#   IMAGE_TAG  — new image tag (e.g. e0c8723c)
#   SERVICE    — docker compose service name (one of: backend|biocompute|frontend)
#                (backend rolls gateway/user-service/organization-service/
#                event-service together — they share one image)
#
# Overridable for tests (production default in parentheses; never overridden
# by a real caller):
#   ENV_FILE             (/opt/axiome/.env)
#   COMPOSE_FILE         (/opt/axiome/docker-compose.yml)
#   REFRESH_ENV_SCRIPT   (/opt/axiome/scripts/refresh-env.sh)
#   SUDO                 (sudo) — set SUDO="" to run every privileged command
#                        directly instead of through sudo. Tests do this so
#                        no real `sudo docker ...` is ever attempted; a real
#                        caller never sets it.
#   SSM_PARAMETER_PREFIX — passed through to refresh-env.sh when set. When
#                        unset, the roll still records KEY=IMAGE_TAG but
#                        skips the SSM refresh (warns, non-fatal).
#
# Idempotent (NFR1): re-running with the same KEY/IMAGE_TAG/SERVICE after a
# success is a no-op — the sed/tee into ENV_FILE is idempotent and the gate
# itself (migrate-gate, AXI-1946) is a no-op when nothing is pending.
#
# Migration gate (FR18, AC2, NFR7 — epic AXI-1944 decisions 2-4, AXI-1946/
# AXI-1950): a `backend` roll relies on the compose dependency graph shipped
# by AXI-1950 (providers/aws/onbox/docker-compose.yml) — gateway,
# user-service, organization-service and event-service all declare
# `depends_on: migrate: condition: service_completed_successfully`. This
# script therefore NEVER passes `--no-deps` on a backend roll: a plain
# `docker compose up -d <targets>` (no --no-deps) makes compose run the
# `migrate` one-shot (migrate-gate apply, baked into the same image) BEFORE
# recreating any backend container, and refuses to start them if migrate
# exits non-zero — the previous containers are left serving, untouched
# (AC2). `docker compose up -d --no-deps <service>` bypasses that dependency
# and is never used here for a backend target (see the AXI-1950 learning
# this story was briefed on).
#
# This script carries NO second implementation of the gate: it never calls
# `migrate-gate` or `prisma` directly, and it never baselines a service —
# baselining is an explicit, one-off operator act (AXI-1946 decision 3). If
# the new image's gate refuses a service because it has no migration
# ledger, the REFUSE line (naming `migrate-gate baseline <service>`) is
# already on the `migrate` container's own log output; on failure this
# script surfaces that log verbatim instead of swallowing it — it never
# runs the baseline on the operator's behalf.
#
# Old-box safety (NFR7/AC8): if the box's compose file predates AXI-1950
# (no `migrate` service declared) a backend roll refuses before pulling or
# upping anything and names the asset-sync command to run first. There is
# no fallback path that starts backend containers unguarded.
#
# Order of operations / pre-existing gap (confirmed for AXI-1954, not fixed
# here — out of this story's file ownership): `update_env_key` writes
# KEY=IMAGE_TAG into ENV_FILE BEFORE the gate (`up -d`) runs. If the gate
# then fails, ENV_FILE is left naming the FAILED image tag, even though the
# old containers are still serving the previous one. A reboot before the
# next successful roll would run the gate against the failed tag's
# migrations again (harmless if idempotent, but the record of "what tag is
# actually running" is wrong in the meantime). This script does not revert
# KEY on a gate failure.
#
# Qualification facts (FR14, review bounce #1): on a successful backend
# roll this script also prints this run's `MIGRATION_FACTS:` /
# `MIGRATION_FACTS_OVERRIDE:` lines (one per service) to stdout, scoped to
# ONLY this run via `docker compose logs --no-log-prefix --since <ts>`,
# where <ts> is captured BEFORE `up -d` is issued. See emit_migration_facts
# below for why that ordering cannot return a stale line or miss a fresh
# one. If the gate ran successfully but no facts can be read, it prints a
# single greppable `MIGRATION_FACTS_UNAVAILABLE:` line instead — the roll
# itself still exits 0 (the containers ARE serving), but a caller that
# wants a Qualification Record (dev-auto-promote.yml) must fail ITS OWN
# step on that line, never treat it as "nothing to qualify".
#
# Re-rolling with the SAME IMAGE_TAG (NFR1 idempotency, see above): `up -d`
# is a no-op for an unchanged image, so compose does not recreate the
# `migrate` one-shot container, `docker compose logs --since <ts>` has no
# new lines to return, and this run reports MIGRATION_FACTS_UNAVAILABLE and
# fails the qualification step by design — that step should be treated as
# evidence nothing changed, not as a real qualification gap, when the tag
# genuinely did not change.
set -euo pipefail

: "${KEY:?KEY env var required}"
: "${IMAGE_TAG:?IMAGE_TAG env var required}"
: "${SERVICE:?SERVICE env var required}"

ENV_FILE="${ENV_FILE:-/opt/axiome/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/axiome/docker-compose.yml}"
REFRESH_ENV_SCRIPT="${REFRESH_ENV_SCRIPT:-/opt/axiome/scripts/refresh-env.sh}"
SUDO="${SUDO-sudo}"

run_sudo() {
    if [ -n "${SUDO}" ]; then
        "${SUDO}" "$@"
    else
        "$@"
    fi
}

if ! run_sudo test -f "${ENV_FILE}"; then
    echo "ERROR: ${ENV_FILE} does not exist — has cloud-init finished?" >&2
    exit 1
fi

# NFR7/AC8 — refuse a backend roll on a box whose compose definition lacks
# the migrate service (predates AXI-1950); name the asset-sync command, no
# fallback to an unguarded `up -d`. This is a plain text scan (no `docker
# compose config` — the check must work before any docker call), but it
# must not be fooled by an unrelated top-level mapping that happens to
# nest a two-space `migrate:` key of its own (e.g. `x-notes:` or any
# other sibling of `services:`). Scoped with awk: only a `migrate:` key
# found between the `services:` line and the next 0-indent key counts.
require_migrate_service() {
    if ! run_sudo test -f "${COMPOSE_FILE}"; then
        echo "ERROR: ${COMPOSE_FILE} does not exist." >&2
        exit 1
    fi
    if ! run_sudo awk '
        /^services:[[:space:]]*$/ { in_services=1; next }
        in_services && /^[^[:space:]]/ { in_services=0 }
        in_services && /^  migrate:[[:space:]]*$/ { found=1 }
        END { exit !found }
    ' "${COMPOSE_FILE}"; then
        echo "REFUSE: ${COMPOSE_FILE} has no 'migrate' service under services: — this box predates the migration gate." >&2
        echo "Run: scripts/asset-sync.sh pull <s3-prefix> $(dirname "${COMPOSE_FILE}") on this box, then retry the roll." >&2
        exit 1
    fi
}

# FR14 (review bounce #1): print this run's MIGRATION_FACTS line(s) to
# stdout after a successful backend `up -d`, scoped to this run only.
#
#   - `--no-log-prefix`: without it, `docker compose logs` prefixes every
#     line with the container/service name ("migrate-1  | MIGRATION_FACTS: ...")
#     which breaks the `^MIGRATION_FACTS:` anchor the qualification step
#     greps on. With it, the line is exactly as migrate-gate printed it.
#   - `--since "$1"`, where $1 is a timestamp captured by the caller
#     BEFORE `up -d` was issued: the migrate container cannot log anything
#     with an earlier timestamp than that capture (it had not started
#     yet), so no line from an EARLIER run can leak through; `--since` is
#     inclusive of the boundary, and the container necessarily starts (and
#     logs) strictly after the capture, so a line from THIS run can never
#     be excluded either. Both directions hold because the two instants
#     are ordered by construction (capture happens-before `up -d`), not by
#     comparing clocks after the fact.
#
# If migrate-gate ran (the gate passed) but no facts line can be read —
# the `logs` call itself fails, or returns nothing for a backend roll —
# that is NOT the same as "nothing to qualify" (biocompute/frontend never
# call this at all). Print a single, distinct, greppable
# `MIGRATION_FACTS_UNAVAILABLE:` line and return 0: the roll's own exit
# code stays success (the containers are serving), but a caller building a
# Qualification Record must treat that line as its own failure.
emit_migration_facts() {
    local since="$1" log facts
    if ! log="$(run_sudo docker compose -f "${COMPOSE_FILE}" logs --no-log-prefix --since "${since}" migrate 2>/dev/null)"; then
        echo "MIGRATION_FACTS_UNAVAILABLE: could not read migrate service logs for this run" >&2
        return 0
    fi
    facts="$(printf '%s\n' "${log}" | grep -E '^(MIGRATION_FACTS:|MIGRATION_FACTS_OVERRIDE:)' || true)"
    if [ -z "${facts}" ]; then
        echo "MIGRATION_FACTS_UNAVAILABLE: migrate succeeded but no MIGRATION_FACTS line was found for this run" >&2
        return 0
    fi
    printf '%s\n' "${facts}"
}

# FR12 (epic decision 5): the roll records the image tag it is rolling,
# then lets the rest of .env come from SSM — never the other way round.
update_env_key() {
    echo "=== Updating ${KEY}=${IMAGE_TAG} in ${ENV_FILE} ==="
    if run_sudo grep -q "^${KEY}=" "${ENV_FILE}"; then
        run_sudo sed -i "s|^${KEY}=.*|${KEY}=${IMAGE_TAG}|" "${ENV_FILE}"
    else
        printf '%s=%s\n' "${KEY}" "${IMAGE_TAG}" | run_sudo tee -a "${ENV_FILE}" > /dev/null
    fi
}

refresh_env_from_ssm() {
    if [ -z "${SSM_PARAMETER_PREFIX:-}" ]; then
        echo "WARN: SSM_PARAMETER_PREFIX not set — skipping .env refresh (only ${KEY} was updated)." >&2
        return 0
    fi
    if ! run_sudo test -x "${REFRESH_ENV_SCRIPT}"; then
        echo "WARN: ${REFRESH_ENV_SCRIPT} not found on this box — skipping .env refresh (asset-sync.sh delivers it)." >&2
        return 0
    fi
    if run_sudo env "SSM_PARAMETER_PREFIX=${SSM_PARAMETER_PREFIX}" "${REFRESH_ENV_SCRIPT}" "${ENV_FILE}"; then
        echo "=== .env refreshed from SSM (${SSM_PARAMETER_PREFIX}) ==="
    else
        echo "WARN: .env refresh from SSM did not succeed — continuing with the existing file." >&2
    fi
}

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

# EC13: `frontend`/`biocompute` carry no schema and no `migrate` dependency
# — only `backend` is gated.
if [[ "${SERVICE}" == "backend" ]]; then
    require_migrate_service
fi

update_env_key
refresh_env_from_ssm

echo "=== docker compose pull ${TARGETS[*]} ==="
run_sudo docker compose -f "${COMPOSE_FILE}" pull "${TARGETS[@]}"

# Captured BEFORE `up -d` so a post-success facts read can be scoped to
# exactly this run (see emit_migration_facts above) — only meaningful for
# a backend roll, but harmless to compute otherwise.
GATE_START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# FR18/AC2 (see header): no --no-deps — a backend target's `up -d` runs the
# migrate one-shot first via the compose dependency graph and refuses to
# start the backend containers if it fails, leaving the previous containers
# serving. biocompute/frontend have no such dependency, so the same call is
# effectively --no-deps for them already — one code path, not two.
echo "=== docker compose up -d ${TARGETS[*]} ==="
if ! run_sudo docker compose -f "${COMPOSE_FILE}" up -d "${TARGETS[@]}"; then
    echo "FAIL-CLOSED: roll aborted — the migration gate did not pass. Previous containers keep serving." >&2
    echo "--- migrate service log (may name the baseline command to run) ---" >&2
    run_sudo docker compose -f "${COMPOSE_FILE}" logs --no-color --no-log-prefix migrate >&2 || true
    exit 1
fi

if [[ "${SERVICE}" == "backend" ]]; then
    emit_migration_facts "${GATE_START_TS}"
fi

echo "=== Roll complete: ${SERVICE} -> ${IMAGE_TAG} ==="
