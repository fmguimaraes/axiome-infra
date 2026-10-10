#!/usr/bin/env bats
# tests/lock_override.bats — scripts/lock.sh override (AXI-1947, FR30, EC7).
# UT-INFRA-114..117, 391..392.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-override.rules.sh"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# UT-INFRA-114: override without --reason is refused before any aws call.
@test "UT-INFRA-114: lock.sh override without --reason is refused before any aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev override deploy --confirm

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "--reason"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-115: override without --confirm is refused before any aws call.
@test "UT-INFRA-115: lock.sh override without --confirm is refused before any aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev override deploy --reason "stuck after a crash"

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "--confirm"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-116: override with both --reason and --confirm on a held lock
# writes a report (naming the previous holder + age) and THEN deletes.
@test "UT-INFRA-116: lock.sh override with reason+confirm reports then deletes a held lock" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev override deploy --reason "stuck after a crash" --confirm

  assert_success
  assert_output --partial "OVERRIDDEN deploy"
  assert_stub_called aws "delete-object"
  local report
  report="$(find "${REPORTS_DIR}" -name '*lock-override*.md' | head -1)"
  [ -n "$report" ]
  run grep -c "OVERRIDE deploy" "$report"
  [ "$output" -ge 1 ]
  run grep -c "someone" "$report"
  [ "$output" -ge 1 ]
  run grep -c "token=" "$report"
  assert_output "0"
}

# UT-INFRA-117: override on an already-free lock is refused; no delete call.
@test "UT-INFRA-117: lock.sh override on a free lock is refused and never deletes" {
  run "${INFRA_ROOT}/scripts/lock.sh" staging override data-tier --reason "just in case" --confirm

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "not held"
}

# UT-INFRA-391 (B1): a --reason that report.sh's secret-shaped-text guard
# refuses (report_override's own check) must ABORT the override BEFORE any
# delete — never swallow the report failure and delete anyway. Uses the
# production/deploy fixture arm, which deliberately has NO delete-object arm
# so a wrongly-issued delete fails the test as an unconfigured call.
@test "UT-INFRA-391: lock.sh override aborts (CLI path) when the audit report refuses the reason" {
  run "${INFRA_ROOT}/scripts/lock.sh" production override deploy --reason "password=hunter2" --confirm

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "ABORTED"
  assert_output --partial "NOT deleted"
  run grep -c "delete-object" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-392 (B1): the same refusal, exercised as a SOURCED library call
# with no `set -e` in the caller — proves lock_override itself returns
# LOCK_RC_REFUSED and skips the delete; it does not rely on the caller's
# errexit to stop it.
@test "UT-INFRA-392: lock_override aborts (sourced, no set -e) when the audit report refuses the reason" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_override production deploy 'password=hunter2' yes; echo \"rc=\$?\""

  assert_output --partial "ABORTED"
  assert_output --partial "NOT deleted"
  assert_output --partial "rc=3"
  run grep -c "delete-object" "$STUB_LOG"
  assert_output "0"
}
