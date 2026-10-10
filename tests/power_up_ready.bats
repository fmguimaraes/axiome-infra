#!/usr/bin/env bats
# tests/power_up_ready.bats — providers/aws/scripts/power.sh <env> up's FR26
# readiness gate (now polling /health/ready, not /health/live). UT-INFRA-185/186.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export POWER_NO_COMMIT=1
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# UT-INFRA-185: power.sh up polls /api/v1/health/ready (FR26), not /health/live.
@test "UT-INFRA-185: power.sh up polls the readiness endpoint, not liveness (FR26)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/curl-health-ready.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_success
  assert_stub_called curl "/api/v1/health/ready"
}

# UT-INFRA-186: a readiness poll that never turns 200 is a bounded, reported
# failure — never a false 200 (EC12) — and the last response body is surfaced.
@test "UT-INFRA-186: power.sh up fails loudly and prints the last response when readiness never turns 200" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/curl-health-notready.rules.sh"
  export POWER_UP_HEALTH_TIMEOUT_SECONDS=1
  export POWER_UP_HEALTH_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_failure
  assert_output --partial "schema_behind"
}
