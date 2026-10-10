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
# Restored verbatim from origin/main (review bounce #1) — "password=
# hunter2" is refused by the sensitive-key-pair branch of
# report_is_secret_value; see tests/report_secret_and_cleanup.bats
# UT-INFRA-530 for the companion case of an innocent key name that is
# correctly ALLOWED through, and UT-INFRA-621 below for the dedicated
# override-path test of this same branch.
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

# UT-INFRA-543 (AXI-1973, FR63 rework): the companion case for
# UT-INFRA-391/392 — an override --reason whose key is a DIFFERENT, whole
# key that merely mentions a sensitive-sounding word ("password_policy", not
# "password") is ALLOWED through regardless of its value; the guard's
# whole-key match never treats it as a substring hit.
@test "UT-INFRA-543: lock.sh override succeeds with a reason that merely mentions a sensitive-sounding word" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev override deploy --reason "password_policy=rotation-only, no credential involved" --confirm

  assert_success
  assert_output --partial "OVERRIDDEN deploy"
  assert_stub_called aws "delete-object"
}

# UT-INFRA-621 (AXI-1973, FR63 rework, review bounce #1): the companion
# refusal — a reason pairing a WHOLE sensitive key with a real-looking
# value ("token=abc123def456") is refused before any delete, nothing is
# written to the report, and the refusal never echoes the offending value.
@test "UT-INFRA-621: lock.sh override refuses a sensitive key=value reason, nothing deleted, value never echoed" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev override deploy --reason "token=abc123def456, rotation planned" --confirm

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "ABORTED"
  refute_output --partial "abc123def456"
  run grep -c "delete-object" "$STUB_LOG"
  assert_output "0"
  run bash -c "find '${REPORTS_DIR}' -name '*lock-override*.md' 2>/dev/null | wc -l"
  assert_output "0"
}
