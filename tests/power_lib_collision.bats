#!/usr/bin/env bats
# tests/power_lib_collision.bats — AXI-1973 (FR63): providers/aws/scripts/
# _power_lib.sh's reporting functions no longer collide with
# scripts/lib/report.sh's same-shaped names when both are sourced together
# (power.sh's exact scenario). UT-INFRA-538.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/sts-actor.rules.sh"
  export REPORT_REPO_ROOT="${BATS_TEST_TMPDIR}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export REPO_ROOT="${BATS_TEST_TMPDIR}"
  export POWER_NO_COMMIT=1
}

# UT-INFRA-538 — sourcing scripts/lib/report.sh THEN
# providers/aws/scripts/_power_lib.sh (power.sh's own order) leaves BOTH
# libraries' functions intact and independently callable: report.sh's
# public report_is_secret_value/report_init/report_line/report_finish are
# never shadowed by _power_lib.sh's pl_report_* equivalents, and vice versa
# — proven by writing one of EACH library's report and checking both exist
# with their OWN distinct header text.
@test "UT-INFRA-538: sourcing report.sh then _power_lib.sh together defines both libraries' functions without collision" {
  run bash -c "
    source '${INFRA_ROOT}/scripts/lib/report.sh'
    source '${INFRA_ROOT}/providers/aws/scripts/_power_lib.sh'

    report_init dev rl-test
    report_line 'from report.sh'
    report_finish ok

    pl_report_init dev pl-test
    pl_report_line 'from _power_lib.sh'
    pl_report_finish

    report_is_secret_value 'AKIAIOSFODNN7EXAMPLE' && echo SECRET_DETECTED
  "
  assert_success
  assert_output --partial "SECRET_DETECTED"

  run grep -l "^# dev / rl-test" "${REPORTS_DIR}"/*dev-rl-test.md
  assert_success
  run grep -l "^# Power op — dev / pl-test" "${REPORTS_DIR}"/*dev-pl-test.md
  assert_success
  run cat "${REPORTS_DIR}"/*dev-rl-test.md
  assert_output --partial "from report.sh"
  run cat "${REPORTS_DIR}"/*dev-pl-test.md
  assert_output --partial "from _power_lib.sh"
}
