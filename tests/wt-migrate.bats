#!/usr/bin/env bats
# tests/wt-migrate.bats — scripts/wt-migrate.sh (AXI-1952 FR36, FR37, EC11):
# backup-before-migrate ordering, failure handling, and the machine-local
# concurrency lock.

load 'helpers/setup'

COMPOSE_ARGS=(--compose-project axiome-test --compose-file docker-compose.yml --service backend --mode exec)

setup() {
  stub_setup
  export WT_BACKUP_DIR="${BATS_TEST_TMPDIR}/backups"
  export WT_MIGRATE_LOCK_FILE="${BATS_TEST_TMPDIR}/migrate.lock"
  export AXIOME_HOME="${BATS_TEST_TMPDIR}/axiome-home"
  mkdir -p "${WT_BACKUP_DIR}" "${AXIOME_HOME}"
}

# UT-INFRA-246 — `status` is read-only: no lock file is created, no backup
# attempted, and it prints migrate-gate's own PENDING lines.
@test "UT-INFRA-246: wt-migrate.sh status is read-only and prints pending migrations" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-ok.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-migrate.sh" status "${COMPOSE_ARGS[@]}"
  assert_success
  assert_output --partial "PENDING organization-service"
  run grep -c "pg_dump" "$STUB_LOG"
  assert_output "0"
  [ ! -e "${WT_MIGRATE_LOCK_FILE}" ]
}

# UT-INFRA-247 — `apply` backs up BEFORE calling migrate-gate apply (call
# log ordering, not just "both happened").
@test "UT-INFRA-247: wt-migrate.sh apply backs up before migrate-gate apply" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-ok.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-migrate.sh" apply "${COMPOSE_ARGS[@]}"
  assert_success
  pg_line="$(grep -n "pg_dump" "$STUB_LOG" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n "cli.js apply" "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "${pg_line}" ]
  [ -n "${gate_line}" ]
  [ "${pg_line}" -lt "${gate_line}" ]
}

# UT-INFRA-248 — a failed backup stops before migrate-gate is ever invoked,
# and the script exits non-zero.
@test "UT-INFRA-248: wt-migrate.sh apply stops before migrate when the backup fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-backup-fail.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-migrate.sh" apply "${COMPOSE_ARGS[@]}"
  assert_failure
  run grep -c "cli.js apply" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-249 — an empty dump is treated exactly like a failed one: refuses,
# never migrates.
@test "UT-INFRA-249: wt-migrate.sh apply stops before migrate when the backup is empty" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-backup-empty.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-migrate.sh" apply "${COMPOSE_ARGS[@]}"
  assert_failure
  run grep -c "cli.js apply" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-250 — a migrate-gate apply failure exits non-zero and no further
# fallback of any kind is attempted (no second docker-exec call after it).
@test "UT-INFRA-250: wt-migrate.sh apply exits non-zero on a migrate-gate failure with no fallback" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-gate-fail.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-migrate.sh" apply "${COMPOSE_ARGS[@]}"
  assert_failure
  run grep -c "### CALL: docker" "$STUB_LOG"
  assert_output "2"   # pg_dump, then the one migrate-gate apply attempt — nothing after
}

# UT-INFRA-251 — a second `apply` while the lock is already held waits up to
# its (short, test-configured) timeout, then refuses WITHOUT ever running
# the backup or the gate (never concurrently).
@test "UT-INFRA-251: a second concurrent wt-migrate.sh apply refuses without running" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-migrate-ok.rules.sh"
  marker="${BATS_TEST_TMPDIR}/holder-acquired"
  (
    exec 7>"${WT_MIGRATE_LOCK_FILE}"
    flock 7
    : > "${marker}"
    sleep 2
  ) &
  holder_pid=$!
  # wait until the holder genuinely holds the lock before racing it
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "${marker}" ] && break
    sleep 0.1
  done
  [ -e "${marker}" ]

  WT_MIGRATE_LOCK_TIMEOUT_SECS=1 run "${INFRA_ROOT}/scripts/wt-migrate.sh" apply "${COMPOSE_ARGS[@]}"
  assert_failure
  assert_output --partial "already running"
  run grep -c "### CALL: docker" "$STUB_LOG"
  assert_output "0"

  wait "${holder_pid}" 2>/dev/null || true
}
