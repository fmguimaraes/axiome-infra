#!/usr/bin/env bats
# tests/power_nightly_toggle.bats — providers/aws/scripts/power.sh disables
# the nightly prod E2E (OQ) workflow on `down` and re-enables it on `up`,
# best-effort, only for NIGHTLY_E2E_TOGGLE_ENVS. UT-INFRA-804..808.
# The tests point NIGHTLY_E2E_TOGGLE_ENVS at `dev` (the env every power.sh
# fixture is written for); `gh` is a PATH stub, never the real GitHub.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export POWER_NO_COMMIT=1
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# UT-INFRA-804
@test "UT-INFRA-804: power.sh down disables the nightly E2E workflow after stopping compute" {
  export NIGHTLY_E2E_TOGGLE_ENVS=dev
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"
  stub_use_rules gh "${TESTS_DIR}/fixtures/gh-workflow-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_success
  assert_output --partial "prod-e2e-daily.yml: disabled"
  # assert_stub_called itself uses `run`, clobbering $output — keep it last.
  assert_stub_called gh "disable"
  assert_stub_called gh "prod-e2e-daily.yml"
  assert_stub_called gh "fmguimaraes/axiome-e2e-testing"
}

# UT-INFRA-805
@test "UT-INFRA-805: power.sh up re-enables the nightly E2E workflow once the app is ready" {
  export NIGHTLY_E2E_TOGGLE_ENVS=dev
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/curl-health-ready.rules.sh"
  stub_use_rules gh "${TESTS_DIR}/fixtures/gh-workflow-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_success
  assert_stub_called gh "enable"
  assert_stub_called gh "prod-e2e-daily.yml"
}

# UT-INFRA-806
@test "UT-INFRA-806: power.sh up with AXIOME_SKIP_PUBLIC_HEALTH=1 (power-up-all path) still re-enables the nightly" {
  export NIGHTLY_E2E_TOGGLE_ENVS=dev
  export AXIOME_SKIP_PUBLIC_HEALTH=1
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules gh "${TESTS_DIR}/fixtures/gh-workflow-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_success
  assert_stub_called gh "enable"
  assert_stub_called gh "prod-e2e-daily.yml"
}

# UT-INFRA-807
@test "UT-INFRA-807: a failing gh call warns but never fails the power operation" {
  export NIGHTLY_E2E_TOGGLE_ENVS=dev
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"
  stub_use_rules gh "${TESTS_DIR}/fixtures/gh-workflow-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_success
  assert_output --partial "WARNING: could not disable nightly E2E workflow"
  assert_output --partial "stopped."
}

# UT-INFRA-808
@test "UT-INFRA-808: envs outside NIGHTLY_E2E_TOGGLE_ENVS (default production) never call gh" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_success
  assert_stub_not_called gh
}
