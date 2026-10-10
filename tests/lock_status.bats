#!/usr/bin/env bats
# tests/lock_status.bats — scripts/lock.sh status (AXI-1947, EC7, AC19/AC20).
# UT-INFRA-110..113, 390, 407.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-status.rules.sh"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-110: status reports FREE (exit 0) for an absent lock.
@test "UT-INFRA-110: lock.sh status reports FREE with exit 0" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev status data-tier

  assert_success
  assert_output --partial "data-tier: FREE"
}

# UT-INFRA-111: status reports HELD (exit 1) with actor/operation/age.
@test "UT-INFRA-111: lock.sh status reports HELD with holder details and exit 1" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev status deploy

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "HELD by me running deploy tag=x"
  assert_output --partial "age"
}

# UT-INFRA-112: status reports UNDETERMINED (exit 2) — distinct from both
# FREE and HELD — when the read itself fails (NFR2).
@test "UT-INFRA-112: lock.sh status reports UNKNOWN with a distinct exit code when it cannot read the lock" {
  run "${INFRA_ROOT}/scripts/lock.sh" staging status deploy

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "UNKNOWN"
}

# UT-INFRA-113: status with no <name> checks ALL THREE locks (AXI-1967
# added `apply` to LOCK_NAMES) and returns the worst code (HELD beats FREE
# here). Updated for AXI-1967: previously asserted "both locks"; now a
# third name (apply) is also checked and must be asserted FREE, or the
# fixture's new dev/apply arm would go unexercised.
@test "UT-INFRA-113: lock.sh status with no name checks all three locks and returns the worst code" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev status

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "deploy: HELD"
  assert_output --partial "data-tier: FREE"
  assert_output --partial "apply: FREE"
}

# UT-INFRA-390 (B2): a get-object call that returns rc 0 with a ZERO-BYTE
# body (metadata parses fine, the body file is empty) must map to UNKNOWN,
# never "HELD by blank" — a successful call is not itself proof of a body.
@test "UT-INFRA-390: lock.sh status maps a zero-byte lock body to UNKNOWN, never HELD" {
  run "${INFRA_ROOT}/scripts/lock.sh" production status deploy

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "UNKNOWN"
  refute_output --partial "HELD by"
}

# UT-INFRA-407 (bounce #2): the get-object call always passes `--output
# json` EXPLICITLY, so a runner/box with AWS_DEFAULT_OUTPUT=text (or yaml)
# cannot silently change the format the metadata ETag is parsed from.
@test "UT-INFRA-407: lock.sh status passes --output json explicitly regardless of AWS_DEFAULT_OUTPUT" {
  export AWS_DEFAULT_OUTPUT=text

  run "${INFRA_ROOT}/scripts/lock.sh" dev status deploy

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "HELD by me running deploy tag=x"
  run grep -c "^--output$" "$STUB_LOG"
  [ "$output" -ge 1 ]
  run grep -c "^json$" "$STUB_LOG"
  [ "$output" -ge 1 ]
}
