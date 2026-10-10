#!/usr/bin/env bash
# generate-qualification-record.sh — FR14: emit the machine Qualification Record
# (IQ/OQ/PQ evidence) for a migration run and commit it to axiome-docs/reports/infra/.
#
# FAIL-CLOSED: a migration is NOT complete unless every OQ and PQ check passes AND
# the record is written. Any failed check (or write error) exits non-zero so the
# pipeline fails and rolls back (Feature MIPP-Hosting-Environment.md FR14 / NFR4).
#
# The IQ/OQ/PQ *documentation set* (IEC 62304/82304-1) is assembled separately per
# CLAUDE.md Workflow 5 by REFERENCING this record — do not duplicate evidence there.
#
# Usage:
#   generate-qualification-record.sh <provider> <environment>
# Optional env (checks are SKIPPED, not failed, when inputs are absent):
#   PG_DSN        postgres DSN for connectivity/schema checks (never printed)
#   REDIS_URL     redis url for ping
#   GATEWAY_URL   base url for RBAC-reachable + PQ latency probe
#   PQ_MAX_MS     PQ latency budget in ms (default 2000)
#   REPORTS_DIR / COMMIT_SHA / OPERATOR
#
# IQ migration evidence — two mutually exclusive inputs (AXI-1953, review
# bounce #1: a roll now gates/migrates MULTIPLE services, not one):
#   MIGRATION_FACTS_LINES   zero or more full `MIGRATION_FACTS: ...` /
#                           `MIGRATION_FACTS_OVERRIDE: ...` lines (newline-
#                           separated, as printed verbatim by migrate-gate/
#                           scripts/roll-service.sh — one line per service).
#                           When set (even to a single line), this drives a
#                           PER-SERVICE IQ breakdown and takes priority over
#                           the single-value fields below.
#   SCHEMA_VERSION / IMAGE_TAG / PRE_COUNTS / POST_COUNTS
#                           legacy single-value IQ evidence, used only when
#                           MIGRATION_FACTS_LINES is unset/empty (kept for
#                           scripts/migrate-data.sh, which migrates one
#                           schema and has no per-service facts line).
#                           IMAGE_TAG is also read standalone either way.
set -uo pipefail

PROVIDER="${1:-${PROVIDER:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-}}"
: "${PROVIDER:?PROVIDER required (arg 1 or env): aws|ovh|scaleway}"
: "${ENVIRONMENT:?ENVIRONMENT required (arg 2 or env): dev|staging|production}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/../axiome-docs/reports/infra}"
TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
COMMIT_SHA="${COMMIT_SHA:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
OPERATOR="${OPERATOR:-$(git -C "${REPO_ROOT}" config user.email 2>/dev/null || whoami)}"
TF_VERSION="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p' | head -1)"

# --- check harness: record PASS/FAIL/SKIP per check; track failures ---
FAILURES=0
RESULTS=""
record() { # name  status(PASS|FAIL|SKIP)  detail
  RESULTS="${RESULTS}| ${1} | ${2} | ${3} |"$'\n'
  [ "${2}" = "FAIL" ] && FAILURES=$((FAILURES + 1))
  return 0
}

# --- IQ migration evidence: per-service (MIGRATION_FACTS_LINES) or
# legacy single-value — see usage header. Builds MIGRATION_IQ_ROWS (a
# markdown table body, one row per service) and MIGRATION_SUMMARY, and
# contributes one "OQ: Schema integrity" record per service (fail-closed:
# an unparseable line is a FAIL, not a SKIP — NFR2).
MIGRATION_IQ_ROWS=""
MIGRATION_SUMMARY=""
TOTAL_APPLIED=0
SERVICE_COUNT=0

if [ -n "${MIGRATION_FACTS_LINES:-}" ]; then
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    case "${line}" in
      MIGRATION_FACTS_OVERRIDE:*)
        # Override lines are evidence of an operator-approved row-loss
        # exception (FR6) — recorded verbatim, not folded into the
        # per-service APPLIED/schema-version table.
        MIGRATION_IQ_ROWS="${MIGRATION_IQ_ROWS}| _override_ | — | — | — | \`${line#MIGRATION_FACTS_OVERRIDE: }\` |"$'\n'
        continue
        ;;
    esac
    svc="$(printf '%s' "${line}" | grep -oP 'SERVICE=\K\S+' || true)"
    sver="$(printf '%s' "${line}" | grep -oP 'SCHEMA_VERSION=\K\S+' || true)"
    sapplied="$(printf '%s' "${line}" | grep -oP 'APPLIED=\K\S+' || true)"
    spre="$(printf '%s' "${line}" | grep -oP 'PRE_COUNTS=\K\S+' || true)"
    spost="$(printf '%s' "${line}" | grep -oP 'POST_COUNTS=\K\S+' || true)"
    if [ -z "${svc}" ] || [ -z "${sver}" ] || [ -z "${sapplied}" ]; then
      record "OQ: Schema integrity (unparseable facts line)" FAIL "could not parse SERVICE/SCHEMA_VERSION/APPLIED from: ${line}"
      continue
    fi
    SERVICE_COUNT=$((SERVICE_COUNT + 1))
    MIGRATION_IQ_ROWS="${MIGRATION_IQ_ROWS}| ${svc} | ${sver} | ${sapplied} | ${spre:-—} | ${spost:-—} |"$'\n'
    if [[ "${sapplied}" =~ ^[0-9]+$ ]]; then
      TOTAL_APPLIED=$((TOTAL_APPLIED + sapplied))
      record "OQ: Schema integrity (${svc})" PASS "schema_version=${sver} applied=${sapplied}"
    else
      record "OQ: Schema integrity (${svc})" FAIL "non-numeric APPLIED value: ${sapplied}"
    fi
  done <<< "${MIGRATION_FACTS_LINES}"

  if [ "${SERVICE_COUNT}" -gt 0 ] && [ "${TOTAL_APPLIED}" -eq 0 ]; then
    # review bounce #1: APPLIED=0 for every service must never read as "a
    # migration was qualified" — state plainly that none ran this run.
    MIGRATION_SUMMARY="No migration applied this run across ${SERVICE_COUNT} service(s) — schema was already current. This record qualifies the CURRENT schema state, not a migration event."
  elif [ "${SERVICE_COUNT}" -gt 0 ]; then
    MIGRATION_SUMMARY="Applied ${TOTAL_APPLIED} migration(s) across ${SERVICE_COUNT} service(s) this run."
  else
    MIGRATION_SUMMARY="MIGRATION_FACTS_LINES was set but contained no parseable per-service line."
  fi
elif [ -n "${SCHEMA_VERSION:-}" ]; then
  # Legacy single-value path (scripts/migrate-data.sh) — unchanged.
  record "OQ: Schema integrity" PASS "applied=${SCHEMA_VERSION}"
else
  record "OQ: Schema integrity" SKIP "SCHEMA_VERSION not provided"
fi

# ---------------- OQ: Operational Qualification ----------------
# Connectivity — Postgres
if [ -n "${PG_DSN:-}" ] && command -v pg_isready >/dev/null 2>&1; then
  if pg_isready -d "${PG_DSN}" >/dev/null 2>&1; then record "OQ: Postgres connectivity" PASS "pg_isready ok"
  else record "OQ: Postgres connectivity" FAIL "pg_isready failed"; fi
else
  record "OQ: Postgres connectivity" SKIP "PG_DSN/pg_isready not provided"
fi

# Connectivity — Redis
if [ -n "${REDIS_URL:-}" ] && command -v redis-cli >/dev/null 2>&1; then
  if redis-cli -u "${REDIS_URL}" ping 2>/dev/null | grep -q PONG; then record "OQ: Redis connectivity" PASS "PONG"
  else record "OQ: Redis connectivity" FAIL "no PONG"; fi
else
  record "OQ: Redis connectivity" SKIP "REDIS_URL/redis-cli not provided"
fi

# (Schema integrity is recorded above, per-service from MIGRATION_FACTS_LINES
# or as a single legacy value from SCHEMA_VERSION — see the IQ migration
# evidence block before the OQ section.)

# RBAC reachable
if [ -n "${GATEWAY_URL:-}" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "${GATEWAY_URL%/}/api/v1/health" 2>/dev/null || echo 000)"
  if [ "${code}" != "000" ]; then record "OQ: RBAC/gateway reachable" PASS "HTTP ${code}"
  else record "OQ: RBAC/gateway reachable" FAIL "unreachable"; fi
else
  record "OQ: RBAC/gateway reachable" SKIP "GATEWAY_URL not provided"
fi

# Audit-trail capture live (event-service writing events/audit_logs)
record "OQ: Audit-trail capture live" "${AUDIT_STATUS:-SKIP}" "${AUDIT_DETAIL:-verify event-service writes post-migration}"

# ---------------- PQ: Performance Qualification ----------------
PQ_MAX_MS="${PQ_MAX_MS:-2000}"
if [ -n "${GATEWAY_URL:-}" ]; then
  secs="$(curl -s -o /dev/null -w '%{time_total}' "${GATEWAY_URL%/}/api/v1/health" 2>/dev/null || echo 99)"
  ms="$(awk -v s="${secs}" 'BEGIN{printf "%d", s*1000}')"
  if [ "${ms}" -le "${PQ_MAX_MS}" ]; then record "PQ: health latency" PASS "${ms}ms <= ${PQ_MAX_MS}ms"
  else record "PQ: health latency" FAIL "${ms}ms > ${PQ_MAX_MS}ms"; fi
else
  record "PQ: representative-load latency" SKIP "GATEWAY_URL not provided"
fi

STATUS="$([ "${FAILURES}" -eq 0 ] && echo PASS || echo FAIL)"

# ---------------- write the record ----------------
mkdir -p "${REPORTS_DIR}"
REC="${REPORTS_DIR}/${TS}__${PROVIDER}__${ENVIRONMENT}__${COMMIT_SHA}__qualification.md"
# IQ migration block: a per-service table when MIGRATION_FACTS_LINES drove
# this run, otherwise the legacy single-value fields (migrate-data.sh).
if [ -n "${MIGRATION_FACTS_LINES:-}" ]; then
  MIGRATION_IQ_BLOCK="**Migration summary:** ${MIGRATION_SUMMARY}

| Service | Schema version | Applied | Pre-count | Post-count |
|---|---|---|---|---|
${MIGRATION_IQ_ROWS}"
else
  MIGRATION_IQ_BLOCK="| Schema version applied | \`${SCHEMA_VERSION:-—}\` |
| Pre-migration counts | \`${PRE_COUNTS:-—}\` |
| Post-migration counts | \`${POST_COUNTS:-—}\` |"
fi

cat > "${REC}" <<EOF
<!-- AUTO-GENERATED by scripts/generate-qualification-record.sh (FR14). Do not hand-edit.
     Secrets are never written here (NFR8). This is the evidence SSoT the IEC 62304/82304-1
     IQ/OQ/PQ doc set references (CLAUDE.md Workflow 5). -->
# Migration Qualification Record — ${PROVIDER}/${ENVIRONMENT}

**Overall: ${STATUS}** (${FAILURES} failed check(s)) — fail-closed: migration is complete only if PASS.

## IQ — Installation
| Field | Value |
|---|---|
| Generated (UTC) | \`${TS}\` |
| Provider / Environment | \`${PROVIDER}\` / \`${ENVIRONMENT}\` |
| Deployment / commit | \`${COMMIT_SHA}\` |
| Image tag | \`${IMAGE_TAG:-—}\` |
| Terraform | \`${TF_VERSION:-unknown}\` |
| Operator | \`${OPERATOR}\` |

${MIGRATION_IQ_BLOCK}

## OQ — Operational / PQ — Performance
| Check | Result | Detail |
|---|---|---|
${RESULTS}

## Notes
- SKIP = input not provided to this run (e.g. no live endpoint); not a failure.
- APPLIED=0 for every service means no migration ran this run — see "Migration summary" above; this record still qualifies the current schema state.
- The IQ/OQ/PQ documentation set (IEC 62304 §5.8 / 82304-1) references this record per Workflow 5.
EOF

if [ ! -s "${REC}" ]; then
  echo "FATAL: qualification record not written" >&2
  exit 1
fi

echo "Qualification record written: ${REC} (status=${STATUS}, failures=${FAILURES})"
# Fail-closed: non-zero exit if any OQ/PQ check failed.
[ "${FAILURES}" -eq 0 ] || { echo "FAIL-CLOSED: ${FAILURES} check(s) failed — migration NOT complete; roll back." >&2; exit 1; }
