#!/usr/bin/env bats
# tests/power_status.bats — exercises the EXISTING, untouched
# providers/aws/scripts/power.sh read-only through the aws stub, proving the
# harness against real lifecycle code (AXI-1945 seed test). UT-INFRA-005.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-status.rules.sh"
  # _power_lib.sh resolves REPO_ROOT via `git rev-parse --show-toplevel`
  # unless REPO_ROOT is already set — pre-set it (an officially supported
  # override, see _power_lib.sh's own `${REPO_ROOT:-...}`) so this test
  # exercises power.sh's own logic without needing a git stub fixture at
  # all; `git` thus stays correctly unconfigured/untouched by this script.
  export REPO_ROOT="${INFRA_ROOT}"
  # AXI-1967: power.sh now also sources scripts/lock.sh (lib/report.sh
  # transitively) — pre-set REPORT_REPO_ROOT too, same reason as REPO_ROOT
  # above, so no git stub call is ever needed here.
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-005 — given a stubbed `aws ec2 describe-instances`, when
# power.sh <env> status runs, then it reports the instance's state and makes
# no mutating call (status never calls stop/start-instances).
@test "UT-INFRA-005: power.sh dev status reports instance state via the aws stub" {
  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev status

  assert_success
  assert_output --partial "dev compute i-0123456789abcdef0: running"
  assert_stub_called aws "describe-instances"
  assert_stub_not_called terraform
}
