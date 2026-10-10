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
# recorded lock token, so no lock-RELEASE attempt (no get-object/
# delete-object on locks/data-tier.json specifically) is made; up still
# succeeds. Updated for AXI-1967: `up` now ALSO does a pre-mutation FR43
# check that deploy/apply are free (lock_require_free, which DOES call
# get-object on locks/deploy.json and locks/apply.json) — "no get-object at
# all" is no longer true and would be the wrong claim; the real invariant
# this test protects is still "data-tier's own lock is never touched here".
@test "UT-INFRA-208: power-data.sh up with nothing parked succeeds and never attempts a data-tier lock release" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-without-down.rules.sh"
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_success
  assert_output --partial "data tier UP (verified)"
  refute_stub_called_with aws "locks/data-tier.json"
  refute_stub_called_with aws "delete-object"
}

# UT-INFRA-209: up after an operator `scripts/lock.sh override` cleared the
# lock — a stale park-state.env with a real-looking token still exists, so
# release IS attempted (get-object), but the lock is already free so
# lock_release refuses WITHOUT ever calling delete-object; up still succeeds
# overall. Updated for AXI-1967/FR44 (AC36): `up` no longer just leaves the
# stale park-state record forever — once it sees the release was refused
# BECAUSE the lock is already free (not some other failure) and both tiers
# are verified available, it clears the record (`aws s3 rm`).
@test "UT-INFRA-209: power-data.sh up after an override attempts release, refuses cleanly, clears the stale park-state (FR44)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-after-override.rules.sh"
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_success
  assert_output --partial "lock is not held"
  assert_output --partial "clearing the stale park-state record"
  assert_stub_called aws "get-object"
  assert_stub_called aws "rm"
  refute_stub_called_with aws "delete-object"
}

# UT-INFRA-418 (AXI-1967, FR43): deploy is held — up must refuse BEFORE any
# RDS/Redis mutation, and must NEVER touch (release) the data-tier lock —
# that lock belongs to the earlier `down`, not to this `up` call.
@test "UT-INFRA-418: power-data.sh up refuses when the deploy lock is held, never touching data-tier (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-ok.rules.sh"
  export POWER_DATA_FIXTURE_DEPLOY_STATE=held
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_failure
  assert_output --partial "deploy lock"
  refute_stub_called_with aws "locks/data-tier.json"
  refute_stub_called_with aws "start-db-instance"
}

# UT-INFRA-419 (AXI-1967, FR43): same, for the apply lock.
@test "UT-INFRA-419: power-data.sh up refuses when the apply lock is held, never touching data-tier (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-up-ok.rules.sh"
  export POWER_DATA_FIXTURE_APPLY_STATE=held
  export DATA_UP_TIMEOUT=5
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev up

  assert_failure
  assert_output --partial "apply lock"
  refute_stub_called_with aws "locks/data-tier.json"
  refute_stub_called_with aws "start-db-instance"
}
