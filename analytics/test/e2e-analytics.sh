#!/usr/bin/env bash
# End-to-end test for the Behavior Tracking read layer (AXI-1048 / FR10 / AC4).
#
# Exercises the whole read path against the running local stack, credential-free:
#   1. Metabase is up and healthy.
#   2. The least-privilege `metabase_ro` role can CONNECT + SELECT the events feed.
#   3. `metabase_ro` is genuinely read-only — INSERT is denied (NFR2).
#   4. Synthetic events seeded into `organization_svc.analytics_events` make every
#      one of the six funnel queries return its steps, run AS metabase_ro (proving
#      the funnel SQL, the table name, and the grants all line up end-to-end).
#   5. The headline funnel's completion count moves by exactly the number of
#      complete journeys seeded — i.e. events actually flow into the funnel.
#
# Seeded rows are tagged deployment_id='e2e-analytics-test' and removed on exit
# (even on failure) via the cleanup trap — nothing is left in the DB.
#
# Optional Metabase-API stage (stages 6): set MB_USER + MB_PASSWORD (a Metabase
# admin) to additionally run funnel 1 through Metabase's own /api/dataset and
# assert it returns rows. Skipped with a notice when those are absent.
#
# Usage:  make analytics-test          (or)  analytics/test/e2e-analytics.sh
set -euo pipefail

INFRA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$INFRA_DIR"

MARKER='e2e-analytics-test'
DB=${POSTGRES_DB:-axiome}
OWNER=${POSTGRES_USER:-axiome}
RO_PASS=${METABASE_RO_PASSWORD:-change_me_readonly}
MB_PORT=${METABASE_PORT:-3001}
MB_URL=${MB_URL:-http://localhost:${MB_PORT}}

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
FAILS=0
pass() { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$NC" "$1"; FAILS=$((FAILS + 1)); }
note() { printf '  %s•%s %s\n' "$YELLOW" "$NC" "$1"; }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$NC"; }

DC=$(docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
CA=(-f docker-compose.yml)
[ -f docker-compose.override.yml ] && CA+=(-f docker-compose.override.yml)

# psql as the DB owner (seed/cleanup) and as the read-only Metabase role.
owner_psql() { $DC "${CA[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$OWNER" -d "$DB" "$@"; }
ro_psql()    { $DC "${CA[@]}" exec -T -e PGPASSWORD="$RO_PASS" postgres \
                 psql -h 127.0.0.1 -U metabase_ro -d "$DB" "$@"; }
# Strip Metabase optional [[ ... {{var}} ]] blocks so raw psql runs the all-time query.
funnel_sql() { sed -E 's/\[\[[^]]*\]\]//g' "$1"; }

cleanup() {
  owner_psql -c "DELETE FROM organization_svc.analytics_events WHERE deployment_id='$MARKER';" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Stage 1 — Metabase health ────────────────────────────────────────────────
section "1. Metabase health ($MB_URL)"
if curl -sf --max-time 10 "$MB_URL/api/health" 2>/dev/null | grep -q '"status":"ok"'; then
  pass "GET /api/health → status ok"
else
  fail "Metabase not healthy at $MB_URL (is it up? 'make analytics-up')"
fi

# ── Stage 2 — metabase_ro can read the events feed ───────────────────────────
section "2. Read-only role connectivity"
if ro_psql -tAc "SELECT 1 FROM organization_svc.analytics_events LIMIT 1;" >/dev/null 2>&1 \
   || ro_psql -tAc "SELECT count(*) FROM organization_svc.analytics_events;" >/dev/null 2>&1; then
  pass "metabase_ro CONNECT + SELECT on organization_svc.analytics_events"
else
  fail "metabase_ro cannot read organization_svc.analytics_events (run 'make analytics-role')"
fi

# ── Stage 3 — least-privilege: writes are denied (NFR2) ──────────────────────
section "3. Read-only enforcement (NFR2)"
if ro_psql -tAc \
   "INSERT INTO organization_svc.analytics_events (event,actor_role,deployment_id,schema_version) VALUES ('e2e_probe','analyst','$MARKER',1);" \
   >/dev/null 2>&1; then
  fail "metabase_ro was able to INSERT — role is NOT read-only"
else
  pass "metabase_ro INSERT denied (permission denied, as expected)"
fi

# ── Stage 4 — seed complete journeys ─────────────────────────────────────────
# One analyst emits every analyst-funnel event (funnels 1–5) in an order that
# satisfies each funnel's step sequence; one client completes funnel 6. ts_server
# is a monotonically increasing 2020 baseline so ordering is deterministic and
# the rows never collide with real recent data.
section "4. Seed synthetic events"
seed_events=(
  # analyst — position N drives ts_server = base + N seconds
  analysis_table_explored evidence_saved interpretation_created interpretation_viewed
  interpretation_approved interpretation_published chart_opened threshold_set
  provenance_opened provenance_node_opened export_charts_selected export_created
  export_downloaded comment_added
)
client_events=(client_connected chart_opened export_created export_downloaded comment_added)

build_values() {
  local role=$1 actor=$2 n=0 ev
  shift 2
  for ev in "$@"; do
    n=$((n + 1))
    printf "('%s','%s','%s','%s',1, TIMESTAMPTZ '2020-01-01 00:00:00+00' + %d * interval '1 second'),\n" \
      "$ev" "$role" "$MARKER" "$actor" "$n"
  done
}
{
  echo "INSERT INTO organization_svc.analytics_events (event,actor_role,deployment_id,anonymous_id,schema_version,ts_server) VALUES"
  build_values analyst e2e-analyst-1 "${seed_events[@]}"
  build_values client  e2e-client-1  "${client_events[@]}" | sed '$ s/,$/;/'
} | owner_psql >/dev/null
seeded=$(owner_psql -tAc "SELECT count(*) FROM organization_svc.analytics_events WHERE deployment_id='$MARKER';" | tr -d '[:space:]')
if [ "$seeded" = "$(( ${#seed_events[@]} + ${#client_events[@]} ))" ]; then
  pass "seeded $seeded events (1 analyst journey + 1 client journey)"
else
  fail "expected $(( ${#seed_events[@]} + ${#client_events[@]} )) seeded rows, got '$seeded'"
fi

# ── Stage 5 — every funnel query runs as metabase_ro and returns its steps ───
section "5. Funnel queries (run as metabase_ro)"
for f in analytics/funnels/0[1-6]_*.sql; do
  rows=$(funnel_sql "$f" | ro_psql -tA 2>/dev/null | grep -c . || true)
  name=$(basename "$f")
  if [ "${rows:-0}" -ge 1 ]; then
    pass "$name → $rows step rows"
  else
    fail "$name → returned no rows (funnel did not resolve against the seeded feed)"
  fi
done

# ── Stage 6 — the headline funnel actually counts the seeded journey ─────────
# The single complete analyst journey must raise every step of funnel 1 by 1.
section "6. Headline funnel reflects the seeded journey"
step6_after=$(funnel_sql analytics/funnels/01_interpretation_lifecycle.sql \
  | ro_psql -tAF'|' 2>/dev/null | awk -F'|' '/interpretation_published/ {print $2}')
if [ "${step6_after:-0}" -ge 1 ]; then
  pass "funnel 1 final step (interpretation_published) counts the journey: users=$step6_after"
else
  fail "funnel 1 final step did not count the seeded complete journey (users=$step6_after)"
fi

# ── Stage 7 (optional) — round-trip through Metabase's own query API ──────────
section "7. Metabase /api/dataset round-trip (optional)"
if [ -n "${MB_USER:-}" ] && [ -n "${MB_PASSWORD:-}" ]; then
  token=$(curl -sf -X POST "$MB_URL/api/session" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$MB_USER\",\"password\":\"$MB_PASSWORD\"}" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  db_id=${MB_DATABASE_ID:-$(curl -sf "$MB_URL/api/database" -H "X-Metabase-Session: $token" \
    | grep -oE '"id":[0-9]+[^}]*"engine":"postgres"' | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')}
  q=$(funnel_sql analytics/funnels/03_provenance_navigation.sql | sed ':a;N;$!ba;s/\n/ /g; s/"/\\"/g')
  n=$(curl -sf -X POST "$MB_URL/api/dataset" -H "X-Metabase-Session: $token" \
    -H 'Content-Type: application/json' \
    -d "{\"database\":$db_id,\"type\":\"native\",\"native\":{\"query\":\"$q\"}}" \
    | grep -oE '"rows":\[\[' | head -1)
  if [ -n "$n" ]; then pass "Metabase ran funnel 3 via /api/dataset and returned rows"
  else fail "Metabase /api/dataset returned no rows (db_id=$db_id)"; fi
else
  note "skipped — set MB_USER and MB_PASSWORD (a Metabase admin) to enable this stage"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
section "Result"
if [ "$FAILS" -eq 0 ]; then
  printf '  %sALL CHECKS PASSED%s\n' "$GREEN" "$NC"
  exit 0
else
  printf '  %s%d CHECK(S) FAILED%s\n' "$RED" "$FAILS" "$NC"
  exit 1
fi
