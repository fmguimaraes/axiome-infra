#!/usr/bin/env bats
# tests/demo-up-migrate.bats — `make demo-up` (AXI-1952 FR38): migrates
# before starting the stack by default, MIGRATE=0 opts out and prints
# pending migrations instead, and a migration failure aborts before the
# stack starts.
#
# AXI-1952 B1 layer 1 (see tests/legacy-compose-safety.bats for layers 2/3
# and the 2026-10 incident they fix): every `make` invocation below passes
# DOCKER_COMPOSE="docker compose" explicitly on the command line so these
# tests never depend on the Makefile's own `docker compose version` probe
# (stub rules drift is exactly what caused the incident). GNU make gives
# command-line variable assignments priority over the Makefile's own `:=`,
# so this is not redundant with layer 3 — it is belt-and-braces on the
# exact path that failed.

load 'helpers/setup'

setup() {
  stub_setup
  export WT_BACKUP_DIR="${BATS_TEST_TMPDIR}/backups"
  export WT_MIGRATE_LOCK_FILE="${BATS_TEST_TMPDIR}/migrate.lock"
  mkdir -p "${WT_BACKUP_DIR}"
}

# UT-INFRA-258 — default MIGRATE=1: migrate-gate apply runs BEFORE `up -d`.
@test "UT-INFRA-258: make demo-up migrates before starting the stack" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/demo-up-ok.rules.sh"
  run make -C "${INFRA_ROOT}" demo-up DOCKER_COMPOSE="docker compose"
  assert_success
  gate_line="$(grep -n "cli.js apply" "$STUB_LOG" | head -1 | cut -d: -f1)"
  up_line="$(awk 'p=="up" && $0=="-d"{print NR} {p=$0}' "$STUB_LOG" | tail -1)"
  [ -n "${gate_line}" ]
  [ -n "${up_line}" ]
  [ "${gate_line}" -lt "${up_line}" ]
}

# UT-INFRA-259 — MIGRATE=0 skips migration, prints pending migrations
# (migrate-gate status), and backs up nothing.
@test "UT-INFRA-259: make demo-up MIGRATE=0 skips migration and prints pending migrations" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/demo-up-ok.rules.sh"
  run make -C "${INFRA_ROOT}" demo-up MIGRATE=0 DOCKER_COMPOSE="docker compose"
  assert_success
  assert_output --partial "PENDING organization-service"
  run grep -c "pg_dump" "$STUB_LOG"
  assert_output "0"
  run grep -c "cli.js apply" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-260 — a migration failure aborts BEFORE the stack is started
# (`up -d` for the demo project is never reached).
@test "UT-INFRA-260: make demo-up aborts before starting the stack when migration fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/demo-up-migrate-fail.rules.sh"
  run make -C "${INFRA_ROOT}" demo-up DOCKER_COMPOSE="docker compose"
  assert_failure
  # "up" immediately followed by "-d" as consecutive argv lines is the
  # `compose ... up -d` call specifically (pg_dump's own unrelated "-d
  # <dbname>" flag must not be mistaken for it).
  run awk 'p=="up" && $0=="-d"{found=1} {p=$0} END{exit !found}' "$STUB_LOG"
  assert_failure
}
