#!/usr/bin/env bats
# tests/power_data_status.bats — providers/aws/scripts/power-data.sh <env>
# status: FR35 stopped-duration display, and the lock status line surfaces
# without crashing the script under `set -e` even when the lock lookup
# itself errors (NoSuchKey -> FREE). UT-INFRA-193/194.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export AXIOME_SYSTEM_BUCKET="axiome-dev-system"
}

# UT-INFRA-193: status shows a stopped-duration line when RDS is 'stopped'.
@test "UT-INFRA-193: power-data.sh status shows the FR35 RDS stopped-duration" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-status.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev status

  assert_success
  assert_output --partial "stopped-duration"
  assert_output --partial "stopped at 2026-10-08T00:00:00Z"
}

# UT-INFRA-194: the data-tier lock status line is surfaced by `status`
# without aborting the script under `set -e` (the lock lookup here reports
# NoSuchKey -> FREE).
@test "UT-INFRA-194: power-data.sh status surfaces the data-tier lock status without crashing" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-status.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev status

  assert_success
  assert_output --partial "data-tier: FREE"
}
