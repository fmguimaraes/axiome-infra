#!/usr/bin/env bats
# tests/verify-deploy.bats — scripts/verify-deploy.sh's readiness-aware
# check_ready() (AXI-1954, FR24/FR26/AC18). UT-INFRA-358..361.
#
# `dig` is not in tests/stubs/** (out of this story's file ownership) — a
# tiny local `dig` double is written into BATS_TEST_TMPDIR and prepended to
# PATH per-test instead, same pattern as any other fixture file this story
# owns, without touching the shared stub directory sibling stories rely on.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/verify-deploy.sh"

setup() {
  stub_setup
  stub_use_rules curl "${TESTS_DIR}/fixtures/verify-deploy-curl.rules.sh"
  cat > "${BATS_TEST_TMPDIR}/dig" <<'EOF'
#!/usr/bin/env bash
echo "${VERIFY_FIXTURE_DIG_ANSWER:-203.0.113.10}"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/dig"
  export PATH="${BATS_TEST_TMPDIR}:${PATH}"
  export FQDN="platform.example.test"
  export EXPECTED_IP="203.0.113.10"
  export VERIFY_FIXTURE_DIG_ANSWER="203.0.113.10"
}

# UT-INFRA-358 — HEALTH_PATH defaults to /api/v1/health/ready (AXI-1954; was
# /api/v1/health) and a 200 there counts as a pass.
@test "UT-INFRA-358: verify-deploy.sh defaults to /api/v1/health/ready and passes on 200" {
  run "$SCRIPT" production
  assert_success
  assert_output --partial "GET /api/v1/health/ready (200)"
}

# UT-INFRA-359 — a 503 is reported with the per-service reason from the
# readiness body, never masked behind a bare curl -f failure.
@test "UT-INFRA-359: verify-deploy.sh reports the per-service reason on a 503" {
  export VERIFY_FIXTURE_READY_CODE=503
  run "$SCRIPT" production
  assert_failure
  assert_output --partial "FAIL  GET /api/v1/health/ready (503)"
  assert_output --partial "back: schema_behind"
}

# UT-INFRA-360 — HEALTH_PATH is still override-able (same precedence as
# every other env-tunable default in this repo's scripts).
@test "UT-INFRA-360: verify-deploy.sh honors a HEALTH_PATH override" {
  export HEALTH_PATH="/custom/ready"
  run "$SCRIPT" production
  assert_success
  assert_output --partial "GET /custom/ready (200)"
}

# UT-INFRA-361 — a readiness pass plus a healthy ROOT_PATH both count; the
# DNS check also passes when dig's answer matches EXPECTED_IP.
@test "UT-INFRA-361: verify-deploy.sh passes DNS + readiness + root when all are healthy" {
  run "$SCRIPT" production
  assert_success
  assert_output --partial "PASS  ${FQDN} → 203.0.113.10"
  assert_output --partial "PASS  GET /"
  assert_output --partial "check(s) passed"
}
