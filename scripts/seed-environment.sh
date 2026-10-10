#!/usr/bin/env bash
# seed-environment.sh — AXI-1001 (FR4/FR5/NFR4): one codified, idempotent
# command that seeds a clean environment to a known baseline and verifies it.
#
# Baseline = reference data, system rule packs, bootstrap users/roles, pilot
# fixtures. Each piece is ALREADY idempotent at the source:
#   - system rule pack + dataview templates: seeded by organization-service on
#     boot (apps/organization-service/src/rules/rules.service.ts,
#     .../templates/templates.service.ts) — skip-if-exists, safe to re-run.
#   - bootstrap admin user: seeded by user-service on boot
#     (apps/user-service/src/auth/admin-bootstrap.service.ts) — upsert.
#   - the 5 canonical workspace roles: axiome-back/scripts/seed_workspace_roles.sql
#     — ON CONFLICT DO NOTHING, not run automatically anywhere.
# What was missing (this script): ONE command an operator runs, plus the
# FR5 verification summary (expected vs actual per entity) that fails closed
# on any mismatch — no "seeded" success state on a partial/failed baseline.
#
# Usage:
#   scripts/seed-environment.sh --local
#   scripts/seed-environment.sh -e ENV [-r REGION]
#   scripts/seed-environment.sh --check -e ENV      # read-only (AXI-1954/FR21)
#
# Options:
#   --local      Target the local docker-compose stack (default POSTGRES_*
#                creds from docker-compose.yml). This is the path exercised
#                in CI/local dev.
#   -e ENV       Target a deployed environment (dev|staging|production) via
#                SSM — same access model as reset-admin-password.sh /
#                verify-deploy.sh. Requires AWS credentials with SSM access.
#   -r REGION    AWS region. Default: eu-west-3 (or $AWS_REGION).
#   -t SECONDS   Max seconds to wait for the DB / seed hooks to settle.
#                Default: 120. Ignored in --check mode (single read, no wait).
#   --check      Read-only baseline verification (FR21): never writes the
#                workspace-roles SQL, takes exactly one count per entity (no
#                settle-loop — the caller already proved readiness), and
#                prints the same expected-vs-actual table. Still exits
#                non-zero on a mismatch so this script's OWN contract stays
#                fail-closed for a direct/standalone invocation (FR5); a
#                caller that wants "warning only, never rolls back" (FR21,
#                e.g. scripts/deploy-prod.sh) must itself ignore this exit
#                code and only use the printed table — this script does not
#                weaken its own guarantee to make that caller's job easier.
#
# Distinct from the retrospective-dataset ingestion path (FR6) — this seeds
# baseline/reference data only, never the retrospective dataset.
#
# Exits non-zero and prints "SEED FAILED" on any expected-vs-actual mismatch
# (FR5, fail-closed). Exits 0 only when every seeded entity's actual count
# matches expected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACK_REPO="${AXIOME_BACK_PATH:-${INFRA_ROOT}/../axiome-back}"
ROLES_SQL="${BACK_REPO}/scripts/seed_workspace_roles.sql"

MODE="local"
ENVIRONMENT=""
REGION="${AWS_REGION:-eu-west-3}"
TIMEOUT="${TIMEOUT:-120}"
CHECK_MODE=0

usage() {
  sed -n '2,42p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    -e) MODE="remote"; ENVIRONMENT="${2:?-e requires an environment}"; shift 2 ;;
    -r) REGION="${2:?-r requires a region}"; shift 2 ;;
    -t) TIMEOUT="${2:?-t requires seconds}"; shift 2 ;;
    --check) CHECK_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "${MODE}" = "remote" ]; then
  case "${ENVIRONMENT}" in dev|staging|production) ;; *) echo "ERROR: -e must be dev, staging, or production" >&2; exit 1 ;; esac
fi

# ---------------------------------------------------------------------------
# run_sql <database-url> <sql-text-on-stdin>
# Runs SQL against one Postgres database and prints raw psql output.
# Local: exec into the already-running compose postgres container.
# Remote: no psql client on the host AMI (only docker) — run an ephemeral
# postgres:15-alpine container against the box's network (matches how
# reset-admin-password.sh reaches production: everything happens on-box via
# SSM, never over an exposed DB port).
# ---------------------------------------------------------------------------
run_sql_local() {
  # $1 = database name. SQL body comes from stdin (default table formatting —
  # used for the multi-statement roles migration, not for count queries).
  local db="$1"
  docker compose -p axiome-shared -f "${INFRA_ROOT}/docker-compose.shared.yml" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-axiome}" -d "${db}"
}

run_sql_remote() {
  # $1 = env var name holding the target DSN in /opt/axiome/.env. SQL body
  # comes from stdin, embedded in a heredoc shipped to the box via
  # ssm-exec.sh -f. The DSN is read ON-BOX — never passed as a literal
  # through this script or SSM command history.
  local var_name="$1"
  local sql
  sql="$(cat)"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  {
    echo "set -e"
    echo "cd /opt/axiome"
    echo "URL=\$(grep '^${var_name}=' .env | cut -d= -f2-)"
    echo "docker run --rm -i --network host postgres:15-alpine psql -v ON_ERROR_STOP=1 \"\${URL}\" <<'SEED_SQL'"
    printf '%s\n' "${sql}"
    echo "SEED_SQL"
  } > "${tmp}"
  "${SCRIPT_DIR}/ssm-exec.sh" -e "${ENVIRONMENT}" -r "${REGION}" -t "${TIMEOUT}" -f "${tmp}"
}

count_local() {
  # $1 = database name, $2 = a single "SELECT count(*) ..." query.
  # -tAc = tuples-only, unaligned, single command — prints just the bare number.
  local db="$1" sql="$2"
  docker compose -p axiome-shared -f "${INFRA_ROOT}/docker-compose.shared.yml" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -tAc "${sql}" -U "${POSTGRES_USER:-axiome}" -d "${db}"
}

count_remote() {
  # $1 = env var name holding the target DSN, $2 = count query.
  local var_name="$1" sql="$2"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  {
    echo "set -e"
    echo "cd /opt/axiome"
    echo "URL=\$(grep '^${var_name}=' .env | cut -d= -f2-)"
    printf 'docker run --rm --network host postgres:15-alpine psql -v ON_ERROR_STOP=1 -tAc %q "${URL}"\n' "${sql}"
  } > "${tmp}"
  "${SCRIPT_DIR}/ssm-exec.sh" -e "${ENVIRONMENT}" -r "${REGION}" -t "${TIMEOUT}" -f "${tmp}"
}

count_query() {
  # Runs a single-value COUNT query and prints a bare integer (or "?" on
  # any failure — never lets a broken query masquerade as a matching count).
  local db_or_var="$1" sql="$2"
  local out
  if [ "${MODE}" = "local" ]; then
    out="$(count_local "${db_or_var}" "${sql}" 2>/dev/null)" || { echo "?"; return; }
  else
    out="$(count_remote "${db_or_var}" "${sql}" 2>/dev/null)" || { echo "?"; return; }
  fi
  out="$(printf '%s' "${out}" | tr -d '[:space:]')"
  [ -n "${out}" ] && [[ "${out}" =~ ^[0-9]+$ ]] && echo "${out}" || echo "?"
}

# ---------------------------------------------------------------------------
# Step 1 — role/permission baseline (the one piece with no automatic seed
# hook: seed_workspace_roles.sql is idempotent SQL, never wired into app boot).
# SKIPPED in --check mode (FR21/AXI-1954): a baseline VERIFICATION never
# writes anything — it only reads expected-vs-actual counts.
# ---------------------------------------------------------------------------
USER_DB_VAR="USER_DATABASE_URL"
USER_DB_LOCAL="${POSTGRES_DB:-axiome}"
if [ "${CHECK_MODE}" -eq 1 ]; then
  echo "==> --check: read-only baseline verification — skipping the workspace-roles write"
else
  echo "==> Seeding baseline workspace roles (${ROLES_SQL#"${BACK_REPO}"/})"
  if [ ! -f "${ROLES_SQL}" ]; then
    echo "ERROR: ${ROLES_SQL} not found. Expected axiome-back checked out as a" >&2
    echo "       sibling of axiome-infra (set AXIOME_BACK_PATH to override)." >&2
    exit 1
  fi
  if [ "${MODE}" = "local" ]; then
    run_sql_local "${USER_DB_LOCAL}" < "${ROLES_SQL}" >/dev/null
  else
    run_sql_remote "${USER_DB_VAR}" < "${ROLES_SQL}" >/dev/null
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — the app-owned seeders (system rule pack, dataview templates,
# bootstrap admin) run automatically on service boot and are already
# idempotent, but organization-service and user-service boot independently —
# this command's job is to make sure both have actually finished seeding
# before verifying, so poll every async entity rather than assume readiness.
# The workspace roles just written in Step 1 are synchronous (already
# committed) and don't need polling.
# ---------------------------------------------------------------------------
if [ "${CHECK_MODE}" -eq 1 ]; then
  echo "==> --check: single read-only count per entity (no settle-wait — the caller already proved readiness)"
else
  echo "==> Waiting for organization-service / user-service seed hooks to settle (timeout ${TIMEOUT}s)"
fi

# Expected counts are derived from the same source the app seeds from, so
# this never drifts out of sync with axiome-back on its own.
# `grep -c` always prints a count (even "0") but still exits non-zero when
# that count is zero — a trailing `|| echo 0` fallback would then run TOO,
# because the grep-and-print already happened, doubling the captured value
# into "0\n0" and breaking the -eq comparison below. Capture grep's own
# output (blank only when the file itself is missing/unreadable), neutralise
# set -e with `|| true`, then default separately.
EXPECTED_RULES="$(grep -c "^    code: '" "${BACK_REPO}/apps/organization-service/src/rules/seed-rules.ts" 2>/dev/null)" || true
EXPECTED_RULES="${EXPECTED_RULES:-0}"
# Same class of trap as EXPECTED_RULES above, plus `set -o pipefail`: if
# grep finds zero matches it exits non-zero, and pipefail would propagate
# that through the pipe and abort the whole script under set -e even
# though awk itself succeeds — `|| true` on the whole pipeline neutralises it.
EXPECTED_TEMPLATES="$(grep -rhc "templateId:" "${BACK_REPO}"/apps/organization-service/src/templates/seed-templates/*.templates.ts 2>/dev/null | awk '{s+=$1} END{print s+0}')" || true
EXPECTED_TEMPLATES="${EXPECTED_TEMPLATES:-0}"
# The 5 canonical WORKSPACE roles are fixed by the same UUIDs seed_workspace_roles.sql
# assigns them (see that file's header) — not derived, since Step 1 is the SSoT for them.
EXPECTED_ROLES=5
ADMIN_EMAIL="${BOOTSTRAP_ADMIN_EMAIL:-admin@axiome.local}"

if [ "${EXPECTED_RULES}" -eq 0 ] || [ "${EXPECTED_TEMPLATES}" -eq 0 ]; then
  if [ "${CHECK_MODE}" -eq 1 ]; then
    # Distinct exit code (3, review bounce #1 item 4): a caller like
    # deploy-prod.sh's baseline step only checks out axiome-infra (the
    # production deploy workflow does not add an axiome-back checkout or
    # any new token/secret to do so — that is an owner decision, noted as
    # a follow-up), so THIS specific failure is expected and routine there,
    # not a real count mismatch. Exit 1 (below, non-check mode) still means
    # a real operator error — axiome-back missing during an actual seed is
    # not tolerable and must fail loudly as before.
    echo "BASELINE CHECK NOT PERFORMED: expected counts could not be derived — ${BACK_REPO} is not checked out (or its rule-pack/template files are unreadable). This is not a count mismatch; set AXIOME_BACK_PATH or run this check from a context where axiome-back is a sibling checkout." >&2
    exit 3
  fi
  echo "ERROR: could not derive expected counts from ${BACK_REPO} — is axiome-back checked out?" >&2
  exit 1
fi

ORG_DB_LOCAL="${POSTGRES_DB:-axiome}"
RULES_SQL="SELECT count(*) FROM organization_svc.rules WHERE scope='system' AND status='published' AND deleted_at IS NULL;"
TEMPLATES_SQL="SELECT count(*) FROM organization_svc.dataview_templates;"
ROLES_SQL_COUNT="SELECT count(*) FROM user_svc.roles WHERE scope='WORKSPACE' AND name IN ('Viewer','Sponsor Viewer','Editor','Approver','Admin');"
ADMIN_SQL="SELECT count(*) FROM user_svc.users WHERE email='${ADMIN_EMAIL}';"

org_db_arg() { [ "${MODE}" = "local" ] && echo "${ORG_DB_LOCAL}" || echo "ORGANIZATION_DATABASE_URL"; }
user_db_arg() { [ "${MODE}" = "local" ] && echo "${USER_DB_LOCAL}" || echo "USER_DATABASE_URL"; }

DEADLINE=$((SECONDS + TIMEOUT))
ACTUAL_RULES=0
ACTUAL_TEMPLATES=0
ACTUAL_ADMIN=0
if [ "${CHECK_MODE}" -eq 1 ]; then
  ACTUAL_RULES="$(count_query "$(org_db_arg)" "${RULES_SQL}")"
  ACTUAL_TEMPLATES="$(count_query "$(org_db_arg)" "${TEMPLATES_SQL}")"
  ACTUAL_ADMIN="$(count_query "$(user_db_arg)" "${ADMIN_SQL}")"
else
  while [ ${SECONDS} -lt ${DEADLINE} ]; do
    ACTUAL_RULES="$(count_query "$(org_db_arg)" "${RULES_SQL}")"
    ACTUAL_TEMPLATES="$(count_query "$(org_db_arg)" "${TEMPLATES_SQL}")"
    ACTUAL_ADMIN="$(count_query "$(user_db_arg)" "${ADMIN_SQL}")"
    if [ "${ACTUAL_RULES}" = "${EXPECTED_RULES}" ] && [ "${ACTUAL_TEMPLATES}" = "${EXPECTED_TEMPLATES}" ] && [ "${ACTUAL_ADMIN}" = "1" ]; then
      break
    fi
    sleep 3
  done
fi

ACTUAL_ROLES="$(count_query "$(user_db_arg)" "${ROLES_SQL_COUNT}")"

# ---------------------------------------------------------------------------
# Step 3 — verification summary (FR5): expected vs actual per entity,
# fail closed on any mismatch.
# ---------------------------------------------------------------------------
echo
echo "==> Seed verification summary"
printf '%-28s %10s %10s %8s\n' "ENTITY" "EXPECTED" "ACTUAL" "STATUS"

FAILED=0
report() {
  local name="$1" expected="$2" actual="$3"
  local status="OK"
  if [ "${actual}" != "${expected}" ]; then
    status="MISMATCH"
    FAILED=1
  fi
  printf '%-28s %10s %10s %8s\n' "${name}" "${expected}" "${actual}" "${status}"
}

report "system rule pack"       "${EXPECTED_RULES}"     "${ACTUAL_RULES}"
report "dataview templates"     "${EXPECTED_TEMPLATES}" "${ACTUAL_TEMPLATES}"
report "canonical workspace roles" "${EXPECTED_ROLES}"  "${ACTUAL_ROLES}"
report "bootstrap admin user"   1                        "${ACTUAL_ADMIN}"

echo
if [ "${FAILED}" -ne 0 ]; then
  if [ "${CHECK_MODE}" -eq 1 ]; then
    echo "BASELINE CHECK MISMATCH: expected-vs-actual mismatch above (read-only; nothing was written)." >&2
  else
    echo "SEED FAILED: expected-vs-actual mismatch above — environment is NOT marked as seeded." >&2
  fi
  exit 1
fi
if [ "${CHECK_MODE}" -eq 1 ]; then
  echo "BASELINE CHECK OK: expected-vs-actual counts match (read-only)."
else
  echo "SEED OK: environment baseline verified (idempotent, safe to re-run)."
fi
