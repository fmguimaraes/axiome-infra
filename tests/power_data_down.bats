#!/usr/bin/env bats
# tests/power_data_down.bats — providers/aws/scripts/power-data.sh <env> down:
# data-tier lock integration (FR29) and the Redis final-snapshot verification
# before success (FR33). UT-INFRA-187..189, 204..207 (207 = double-down).

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

# UT-INFRA-187: down acquires the data-tier lock before any mutating call.
@test "UT-INFRA-187: power-data.sh down acquires the data-tier lock before touching RDS/Redis" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_success
  assert_output --partial "Data-tier LOCK HELD"
  assert_stub_called aws "put-object"
}

# UT-INFRA-188: a held lock refuses the whole park — no RDS/Redis call at all.
@test "UT-INFRA-188: power-data.sh down refuses when the data-tier lock is already held" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-lock-held.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  refute_stub_called_with aws "stop-db-instance"
  refute_stub_called_with aws "delete-replication-group"
}

# UT-INFRA-189: the final snapshot never reaches 'available' within the
# bounded timeout — down aborts, and the lock is NEVER released (FR29: no
# automatic release route exists for data-tier at all).
@test "UT-INFRA-189: power-data.sh down aborts and leaves the lock HELD when the Redis snapshot never verifies available (FR33)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-snapshot-timeout.rules.sh"
  export REDIS_SNAPSHOT_TIMEOUT=1
  export DATA_UP_POLL_INTERVAL=1

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "Lock HELD"
  refute_stub_called_with aws "delete-object"
}

# UT-INFRA-204: the immediate park-state write (before any RDS/Redis call)
# fails — down must release the lock it just took, touch nothing, and exit
# non-zero.
@test "UT-INFRA-204: power-data.sh down releases the lock and touches nothing when the immediate park-state write fails" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-parkstate-writefail.rules.sh"
  export LOCK_BODY_CAPTURE_FILE="${BATS_TEST_TMPDIR}/lock-body.json"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "releasing the lock now"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "stop-db-instance"
  refute_stub_called_with aws "describe-cache-clusters"
}

# UT-INFRA-205: a failed Redis describe call aborts BEFORE any delete,
# leaves Redis untouched, and — because park-state was written immediately
# after acquire and again right after the RDS stop — the real lock token is
# still recoverable from park-state.env after the abort.
@test "UT-INFRA-205: power-data.sh down aborts on a failed Redis describe call, Redis untouched, token still recoverable" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-redis-describe-fail.rules.sh"
  export PARK_STATE_CAPTURE_FILE="${BATS_TEST_TMPDIR}/park-state-captured.env"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "could not capture/verify a complete Redis configuration"
  # Capture TOKEN_FROM_OUTPUT from $output BEFORE calling any helper that
  # itself uses `run` (refute_stub_called_with does) — `run` clobbers
  # $output/$status globally; reading it after would silently see the
  # helper's own captured output instead (bats run-clobbering trap).
  TOKEN_FROM_OUTPUT="$(printf '%s\n' "$output" | sed -n 's/.*token=\([^ ]*\).*/\1/p' | head -1)"
  [ -n "$TOKEN_FROM_OUTPUT" ]
  refute_stub_called_with aws "delete-replication-group"
  [ -s "${PARK_STATE_CAPTURE_FILE}" ]
  run grep -F "LOCK_TOKEN=\"${TOKEN_FROM_OUTPUT}\"" "${PARK_STATE_CAPTURE_FILE}"
  assert_success
}

# UT-INFRA-206: every Redis describe call succeeds but one field comes back
# empty — treated exactly like a failed describe: aborts, Redis untouched.
@test "UT-INFRA-206: power-data.sh down aborts when a captured Redis field is empty" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-redis-empty-field.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "could not capture/verify a complete Redis configuration"
  refute_stub_called_with aws "delete-replication-group"
}

# UT-INFRA-207 (double down): a second `down` while the first's lock is
# still held refuses outright and makes no new RDS/Redis mutating call.
@test "UT-INFRA-207: a second power-data.sh down while the lock is still held changes nothing new" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"
  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down
  assert_success

  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-lock-held.rules.sh"
  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  refute_stub_called_with aws "stop-db-instance"
  refute_stub_called_with aws "delete-replication-group"
}

# UT-INFRA-416 (AXI-1967, FR43): data-tier is acquired FIRST, THEN deploy is
# found held — down must release the data-tier lock it just took and clear
# any park-state, never touching RDS/Redis.
@test "UT-INFRA-416: power-data.sh down releases data-tier and refuses when the deploy lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"
  export POWER_DATA_FIXTURE_DEPLOY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "deploy lock is held"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "stop-db-instance"
  refute_stub_called_with aws "delete-replication-group"
}

# UT-INFRA-417 (AXI-1967, FR43): same, for the apply lock.
@test "UT-INFRA-417: power-data.sh down releases data-tier and refuses when the apply lock is held (FR43)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"
  export POWER_DATA_FIXTURE_APPLY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "apply lock is held"
  assert_stub_called aws "delete-object"
  refute_stub_called_with aws "stop-db-instance"
  refute_stub_called_with aws "delete-replication-group"
}

# refute_park_state_rm — the stub log is ONE ARGV ELEMENT PER LINE (never a
# joined command string), so `aws s3 rm <key>` shows up as a "s3" line
# immediately followed by a "rm" line — never a single line containing
# both substrings. Fails if ANY such "s3" -> "rm" pair is recorded.
refute_park_state_rm() {
  run bash -c "grep -A1 -x 's3' '${STUB_LOG}' | grep -x 'rm'"
  [ "$status" -ne 0 ] || fail "expected NO 'aws s3 rm' call but one was recorded in ${STUB_LOG}"
}

# UT-INFRA-428 (bounce #1, AXI-1967): review bounce — `down` refused by a
# held DEPLOY lock must release ONLY the data-tier lock it just acquired;
# it must NEVER delete the park-state record (that record, if one exists,
# belongs to an EARLIER down/operator-override, not this refused run).
# Confirmed failing against head 24c2942 (clear_park_state was called
# unconditionally in this branch) before the fix removed that call.
@test "UT-INFRA-428: power-data.sh down refused by a held deploy lock releases data-tier but never deletes park-state (bounce #1)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"
  export POWER_DATA_FIXTURE_DEPLOY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "deploy lock is held"
  assert_stub_called aws "delete-object"
  refute_park_state_rm
}

# UT-INFRA-429 (bounce #1, AXI-1967): same, for a held APPLY lock.
@test "UT-INFRA-429: power-data.sh down refused by a held apply lock releases data-tier but never deletes park-state (bounce #1)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-data-down-ok.rules.sh"
  export POWER_DATA_FIXTURE_APPLY_STATE=held

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev down

  assert_failure
  assert_output --partial "apply lock is held"
  assert_stub_called aws "delete-object"
  refute_park_state_rm
}
