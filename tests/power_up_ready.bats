#!/usr/bin/env bats
# tests/power_up_ready.bats — providers/aws/scripts/power.sh <env> up's FR26
# readiness gate (now polling /health/ready, not /health/live). UT-INFRA-185/186.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  # AXI-1967: power.sh now also sources scripts/lock.sh (lib/report.sh
  # transitively) — pre-set REPORT_REPO_ROOT too, same reason as REPO_ROOT
  # above, so no git stub call is ever needed here.
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
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

# UT-INFRA-637 (AXI-1981, FR43): new for this story — `up` also acquires its
# OWN compute lock first (same as `down`) and releases it before exiting on
# a successful run — not left behind on the happy path either.
@test "UT-INFRA-637: power.sh up acquires and then releases the compute lock on a successful run" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/curl-health-ready.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up
  local power_output="$output"

  assert_success
  assert_stub_called aws "delete-object"
  printf '%s' "$power_output" | grep -qF "RELEASED compute" \
    || fail "expected 'RELEASED compute' in output, got: ${power_output}"
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

# UT-INFRA-638 (AXI-1981, FR43): new for this story — compute is still
# released when the operation itself fails AFTER the lock was already
# acquired (the readiness-timeout path), not just on the "other lock
# held" refusals in power_down_backup.bats.
@test "UT-INFRA-638: power.sh up releases the compute lock when readiness never turns 200, after having acquired it" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/curl-health-notready.rules.sh"
  export POWER_UP_HEALTH_TIMEOUT_SECONDS=1
  export POWER_UP_HEALTH_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up
  local power_output="$output"

  assert_failure
  assert_stub_called aws "delete-object"
  printf '%s' "$power_output" | grep -qF "RELEASED compute" \
    || fail "expected 'RELEASED compute' in output, got: ${power_output}"
}

# UT-INFRA-641 (bounce #1, AXI-1981, FR43): mirrors UT-INFRA-414 for `up` —
# review bounce found `up`'s own refusal path untested. Acquires then
# releases compute when deploy is held, zero mutating calls (no
# start-instances), exit 1. Confirmed to fail without the fix by
# temporarily removing `up`'s lock_acquire_exclusive call (and separately
# by removing its `|| exit 1` dropdown) and re-running — both left
# start-instances called / exit 0, see handback for the exact method.
@test "UT-INFRA-641: power.sh up acquires then releases the compute lock when the deploy lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  export POWER_FIXTURE_DEPLOY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "'deploy' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with_up aws "start-instances"
}

# UT-INFRA-642 (bounce #1, AXI-1981, FR43): same, for the apply lock.
@test "UT-INFRA-642: power.sh up acquires then releases the compute lock when the apply lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  export POWER_FIXTURE_APPLY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "'apply' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with_up aws "start-instances"
}

# UT-INFRA-643 (bounce #1, AXI-1981, FR43): same, for a deploy-lock read
# whose state cannot be determined (UNKNOWN, a transport error) — treated
# as held, never as free (NFR2, fail-closed).
@test "UT-INFRA-643: power.sh up acquires then releases the compute lock when the deploy lock state is UNKNOWN (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-up-ready.rules.sh"
  export POWER_FIXTURE_DEPLOY_STATE=unknown

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev up

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "'deploy' is not free"
  assert_output --partial "releasing 'compute' and refusing"
  assert_output --partial "RELEASED compute"
  assert_stub_called aws "delete-object"
  refute_stub_called_with_up aws "start-instances"
}

# refute_stub_called_with_up <name> <substring> — local helper (this file has
# no shared one): the stub log is ONE ARGV ELEMENT PER LINE, so a mutating
# call like `aws ec2 start-instances ...` shows up as several consecutive
# lines, never one line containing both "aws" and "start-instances".
refute_stub_called_with_up() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected NO call to '${name}' containing '${needle}' but one was recorded in ${STUB_LOG}"
}
