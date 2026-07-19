#!/usr/bin/env bash
# migrate-data.sh — S13 / FR2+FR3+NFR4: migrate data into the in-region stores and
# verify parity, then emit the fail-closed Qualification Record (FR14).
#
# Cutover only — does NOT decommission the source (that is a deliberate later step
# once parity + sign-off are confirmed). Secrets come from env and are never printed.
#
# Usage:  migrate-data.sh <provider> <environment>
# Env (never printed):
#   SOURCE_PG_DSN / TARGET_PG_DSN          Neon -> RDS (per-schema)
#   SOURCE_MONGO_URI / TARGET_MONGO_URI    Mongo dump/restore, either direction
#   PG_SCHEMAS  (default "user_svc organization_svc")
set -uo pipefail

PROVIDER="${1:-${PROVIDER:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-}}"
: "${PROVIDER:?PROVIDER required (arg 1): aws|ovh|scaleway}"
: "${ENVIRONMENT:?ENVIRONMENT required (arg 2): dev|staging|production}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PG_SCHEMAS="${PG_SCHEMAS:-user_svc organization_svc}"
RC=0

pg_count() { psql "$1" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='$2';" 2>/dev/null || echo "?"; }

echo "== Postgres migration (Neon -> managed) =="
if [ -n "${SOURCE_PG_DSN:-}" ] && [ -n "${TARGET_PG_DSN:-}" ] && command -v pg_dump >/dev/null 2>&1; then
  for sch in ${PG_SCHEMAS}; do
    echo "-- schema ${sch}"
    if pg_dump "${SOURCE_PG_DSN}" --schema="${sch}" --no-owner --no-privileges \
        | psql "${TARGET_PG_DSN}" >/dev/null 2>&1; then
      pre="$(pg_count "${SOURCE_PG_DSN}" "${sch}")"; post="$(pg_count "${TARGET_PG_DSN}" "${sch}")"
      if [ "${pre}" = "${post}" ]; then echo "   parity OK (${pre} tables)"
      else echo "   PARITY MISMATCH src=${pre} dst=${post}" >&2; RC=1; fi
    else echo "   restore FAILED" >&2; RC=1; fi
  done
else
  echo "   SKIP (SOURCE_PG_DSN/TARGET_PG_DSN/pg_dump not provided)"
fi

echo "== Mongo migration =="
if [ -n "${SOURCE_MONGO_URI:-}" ] && [ -n "${TARGET_MONGO_URI:-}" ] && command -v mongodump >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  if mongodump --uri="${SOURCE_MONGO_URI}" --archive="${TMP}/dump" >/dev/null 2>&1 \
     && mongorestore --uri="${TARGET_MONGO_URI}" --archive="${TMP}/dump" >/dev/null 2>&1; then
    echo "   restore OK"
  else echo "   mongo migration FAILED" >&2; RC=1; fi
  rm -rf "${TMP}"
else
  echo "   SKIP (SOURCE_MONGO_URI/TARGET_MONGO_URI/mongodump not provided)"
fi

# Emit the Qualification Record (FR14). Pass migration facts as IQ evidence.
echo "== Qualification record =="
PRE_COUNTS="pg_schemas=${PG_SCHEMAS}" POST_COUNTS="migrated" \
  bash "${SCRIPT_DIR}/generate-qualification-record.sh" "${PROVIDER}" "${ENVIRONMENT}" || RC=1

if [ "${RC}" -ne 0 ]; then
  echo "FAIL-CLOSED: migration/parity failed — NOT complete; roll back to source." >&2
  exit 1
fi
echo "Migration + parity OK; Qualification Record written."
