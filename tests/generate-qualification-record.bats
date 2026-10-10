#!/usr/bin/env bats
# tests/generate-qualification-record.bats — scripts/generate-qualification-record.sh
# (AXI-1953, review bounce #1: ownership extended to this file "for this
# purpose only" — handling MIGRATION_FACTS_LINES from a multi-service roll).
# UT-INFRA-318..321.
#
# NOTE on UT-ID range: AXI-1953 owns UT-INFRA-280..319. This file's last two
# IDs (320, 321) overrun one story into AXI-1954's reserved 320..379 block —
# flagged explicitly in the handback; nothing else currently occupies 320/321.
#
# review bounce #2: `terraform version -json` is called UNCONDITIONALLY by
# generate-qualification-record.sh (unlike pg_isready/redis-cli/curl, which
# are only called when PG_DSN/REDIS_URL/GATEWAY_URL are set) — a setup()
# that skips stub_setup reaches the REAL /usr/bin/terraform on this host.
# Read every external command the script calls (git, terraform, curl,
# pg_isready, redis-cli) before relying on any fixture: COMMIT_SHA/OPERATOR
# are set explicitly below so the `${VAR:-$(git ...)}` fallback is never
# evaluated at all, and PG_DSN/REDIS_URL/GATEWAY_URL stay unset so
# pg_isready/redis-cli/curl are never called either — only `terraform
# version -json` actually runs, so only it needs a rule, via the shared
# stub harness (tests/stubs/*) like every other test file.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/generate-qualification-record.sh"

setup() {
  stub_setup
  stub_use_rules terraform "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  stub_use_rules git "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export COMMIT_SHA="testsha"
  export OPERATOR="test@example.com"
  export IMAGE_TAG="sha-new123"
  unset PG_DSN REDIS_URL GATEWAY_URL MIGRATION_FACTS_LINES SCHEMA_VERSION PRE_COUNTS POST_COUNTS || true
}

latest_record() {
  ls -t "${REPORTS_DIR}"/*.md | head -1
}

# UT-INFRA-318 — a two-service MIGRATION_FACTS_LINES input (SERVICE=,
# SCHEMA_VERSION=, APPLIED=, PRE_COUNTS=, POST_COUNTS= per line) produces a
# PASS record with one IQ row per service and a summary naming the total
# applied count across both services.
@test "UT-INFRA-318: generate-qualification-record.sh renders a per-service table for a two-service roll" {
  export MIGRATION_FACTS_LINES=$'MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261001 APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13\nMIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261001 APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped'
  run env PROVIDER=aws ENVIRONMENT=dev "$SCRIPT" aws dev
  assert_success
  assert_output --partial "status=PASS, failures=0"
  rec="$(latest_record)"
  run grep -F "Applied 3 migration(s) across 2 service(s) this run." "$rec"
  assert_success
  run grep -F "| organization-service | 20261001 | 3 | 10 | 13 |" "$rec"
  assert_success
  run grep -F "| user-service | 20261001 | 0 | skipped | skipped |" "$rec"
  assert_success
  run grep -F "OQ: Schema integrity (organization-service) | PASS" "$rec"
  assert_success
  run grep -F "OQ: Schema integrity (user-service) | PASS" "$rec"
  assert_success
}

# UT-INFRA-319 — review bounce #1: every service reporting APPLIED=0 must
# read as "no migration ran, schema already current" — NOT as "a migration
# was qualified" — while the record still PASSes (the current schema state
# IS qualified, just not by a fresh migration).
@test "UT-INFRA-319: generate-qualification-record.sh states plainly when APPLIED=0 for every service" {
  export MIGRATION_FACTS_LINES=$'MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261001 APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped\nMIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261001 APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped'
  run env PROVIDER=aws ENVIRONMENT=dev "$SCRIPT" aws dev
  assert_success
  assert_output --partial "status=PASS, failures=0"
  rec="$(latest_record)"
  run grep -F "No migration applied this run across 2 service(s) — schema was already current. This record qualifies the CURRENT schema state, not a migration event." "$rec"
  assert_success
  run grep -Fi "a migration was qualified" "$rec"
  assert_failure
}

# UT-INFRA-320 — backward compatibility (NOT my overrun fix target, but the
# contract scripts/migrate-data.sh still relies on): when MIGRATION_FACTS_LINES
# is unset, the legacy single-value SCHEMA_VERSION/PRE_COUNTS/POST_COUNTS
# fields drive the record exactly as before.
@test "UT-INFRA-320: generate-qualification-record.sh keeps the legacy single-value path for migrate-data.sh" {
  export SCHEMA_VERSION="20261001"
  export PRE_COUNTS="pg_schemas=4"
  export POST_COUNTS="migrated"
  run env PROVIDER=aws ENVIRONMENT=dev "$SCRIPT" aws dev
  assert_success
  assert_output --partial "status=PASS, failures=0"
  rec="$(latest_record)"
  run grep -F "| Schema version applied | \`20261001\` |" "$rec"
  assert_success
  run grep -F "| Pre-migration counts | \`pg_schemas=4\` |" "$rec"
  assert_success
  run grep -F "| Post-migration counts | \`migrated\` |" "$rec"
  assert_success
  run grep -F "OQ: Schema integrity | PASS" "$rec"
  assert_success
}

# UT-INFRA-321 — fail-closed (NFR2): a MIGRATION_FACTS_LINES line that cannot
# be parsed (missing SERVICE/SCHEMA_VERSION/APPLIED) is a FAIL, never a
# silent SKIP, and the script exits non-zero.
@test "UT-INFRA-321: generate-qualification-record.sh fails closed on an unparseable facts line" {
  export MIGRATION_FACTS_LINES="MIGRATION_FACTS: SERVICE=organization-service garbage"
  run env PROVIDER=aws ENVIRONMENT=dev "$SCRIPT" aws dev
  assert_failure
  assert_output --partial "FAIL-CLOSED"
  rec="$(latest_record)"
  run grep -F "unparseable facts line" "$rec"
  assert_success
}
