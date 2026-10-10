#!/usr/bin/env bats
# tests/power_data_up.bats — providers/aws/scripts/power-data.sh <env> up:
# the data-tier lock is released ONLY after verified availability (FR29),
# bounded by FR34, with EC8 (RDS already available) still fully verified.
# UT-INFRA-190..192, 208, 209 (up without down / up after an override).

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export AXIOME_SYSTEM_BUCKET="axiome-dev-system"
}

refute_stub_called_with() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected NO call to '${name}' containing '${needle}' but one was recorded in ${STUB_LOG}"
}

# UT-INFRA-190/192: RDS already 'available' at up-time (EC8 — may be AWS's own
# 7-day auto-restart) still gets fully verified, and the data-tier lock is
# released only after that verification — never from a trap/finally.
@test "UT-INFRA-190: power-data.sh up verifies availability (EC8) then releases the data-tier lock" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-ok.rules.sh"
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_success
  assert_output --partial "EC8"
  assert_output --partial "data tier UP (verified)"
  assert_stub_called aws "delete-object"
}

# UT-INFRA-191: RDS never becomes available within the bounded timeout — up
# fails, and the lock is NEVER released (no delete-object call at all).
@test "UT-INFRA-191: power-data.sh up fails and leaves the lock HELD when RDS never verifies available (FR34)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-timeout.rules.sh"
  export DATA_UP_TIMEOUT=1
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_failure
  assert_output --partial "Lock remains held"
  refute_stub_called_with aws "delete-object"
}

# UT-INFRA-208: up run with nothing ever parked (no prior down) — RDS/Redis
# are already available, park-state.env does not exist, and there is no
# recorded lock token, so no lock-release attempt (no get-object/delete-object
# at all) is made; up still succeeds.
@test "UT-INFRA-208: power-data.sh up with nothing parked succeeds and never attempts a lock release" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-without-down.rules.sh"
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_success
  assert_output --partial "data tier UP (verified)"
  refute_stub_called_with aws "get-object"
  refute_stub_called_with aws "delete-object"
}

# UT-INFRA-209: up after an operator `scripts/lock.sh override` cleared the
# lock — a stale park-state.env with a real-looking token still exists, so
# release IS attempted (get-object), but the lock is already free so
# lock_release refuses WITHOUT ever calling delete-object; up still succeeds
# overall and park-state is left for the operator to inspect.
@test "UT-INFRA-209: power-data.sh up after an override attempts release, refuses cleanly, still succeeds" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-after-override.rules.sh"
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_success
  assert_output --partial "lock is not held"
  assert_stub_called aws "get-object"
  refute_stub_called_with aws "delete-object"
}
