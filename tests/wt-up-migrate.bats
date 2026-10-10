#!/usr/bin/env bats
# tests/wt-up-migrate.bats — scripts/wt-up.sh's --migrate wiring (AXI-1952
# FR36): migration is off by default, on with --migrate (and the
# deprecated --seed alias), and a migration failure propagates.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-up-ok.rules.sh"
  export AXIOME_HOME="${BATS_TEST_TMPDIR}/axiome-home"
  export WT_ENV_FILE="${BATS_TEST_TMPDIR}/env"
  export WT_BACKUP_DIR="${BATS_TEST_TMPDIR}/backups"
  export WT_MIGRATE_LOCK_FILE="${BATS_TEST_TMPDIR}/migrate.lock"
  mkdir -p "${AXIOME_HOME}" "${WT_BACKUP_DIR}"
}

# UT-INFRA-254 — with neither --migrate nor --seed, wt-up.sh never touches
# migrate-gate or the control-plane migration.
@test "UT-INFRA-254: wt-up.sh without --migrate never runs any migration" {
  run "${INFRA_ROOT}/scripts/wt-up.sh"
  assert_success
  run grep -c "migrate-gate\|migrate deploy" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-255 — --migrate runs migrate-gate AFTER the app stack is started
# (the app `up -d --build` call precedes the migrate-gate apply call).
@test "UT-INFRA-255: wt-up.sh --migrate runs migrate-gate after the app stack is up" {
  run "${INFRA_ROOT}/scripts/wt-up.sh" --migrate
  assert_success
  up_line="$(grep -n -- "--build" "$STUB_LOG" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n "cli.js apply" "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "${up_line}" ]
  [ -n "${gate_line}" ]
  [ "${up_line}" -lt "${gate_line}" ]
}

# UT-INFRA-256 — the deprecated --seed alias still triggers the same
# migration path (back-compat: it must not silently become a no-op).
@test "UT-INFRA-256: wt-up.sh --seed (deprecated alias) still migrates" {
  run "${INFRA_ROOT}/scripts/wt-up.sh" --seed
  assert_success
  assert_stub_called docker "cli.js apply"
}

# UT-INFRA-257 — a migration failure makes wt-up.sh exit non-zero.
@test "UT-INFRA-257: wt-up.sh --migrate exits non-zero when the migration fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-up-migrate-fail.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-up.sh" --migrate
  assert_failure
}
