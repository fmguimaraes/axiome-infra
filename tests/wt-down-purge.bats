#!/usr/bin/env bats
# tests/wt-down-purge.bats — wt-down.sh end-to-end through the docker stub:
# the purge guard (FR39/AC26) wired in, and the --purge-shared confirmation
# token + backup-first requirement (FR40). AXI-1952.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-down-generic.rules.sh"
  # Never touch the real machine-wide registry/backup dir.
  export AXIOME_HOME="${BATS_TEST_TMPDIR}/axiome-home"
  export WT_BACKUP_DIR="${BATS_TEST_TMPDIR}/backups"
  mkdir -p "${AXIOME_HOME}" "${WT_BACKUP_DIR}"
  # A registry entry for a slug under the CURRENT (always-shared) layer —
  # wt_derive_vars hardcodes the shared names regardless of offset/redis_db,
  # so any offset/redis_db pair here reproduces the live incident shape.
  # shellcheck source=../scripts/wt-common.sh
  . "${INFRA_ROOT}/scripts/wt-common.sh" >/dev/null
  wt_registry_allocate "axiome-global-axi-1235" >/dev/null
}

# UT-INFRA-240 — wt-down.sh --purge --slug <s> refuses under the live shared
# layer and makes NO destructive call at all (not pg_admin/mongosh/redis_cli/
# rabbitmqctl/mc — none of them are even reached, since the guard runs
# before the app stack is brought down).
@test "UT-INFRA-240: wt-down.sh --purge refuses end-to-end and destroys nothing" {
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge --slug axiome-global-axi-1235
  assert_failure
  run grep -E "DROP DATABASE|dropDatabase|FLUSHDB|delete_vhost|mc rb" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-241 — the guard validates the WHOLE target list before ANY
# deletion, including the (non-destructive but stack-stopping) app
# `down -v` that normally runs ahead of the purge step itself: a refused
# purge changes nothing at all, not even that.
@test "UT-INFRA-241: wt-down.sh --purge refuses before the app stack is even brought down" {
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge --slug axiome-global-axi-1235
  assert_failure
  run grep -c -- "down" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-242 — --purge-shared with no --confirm refuses; no backup, no
# `down -v` on the shared project.
@test "UT-INFRA-242: wt-down.sh --purge-shared without --confirm refuses and backs up nothing" {
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge-shared
  assert_failure
  assert_output --partial "DELETE-ALL-LOCAL-DATA"
  run grep -c "pg_dump" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-243 — --purge-shared with the WRONG token still refuses, including
# when stdin is closed (non-interactive; there is no prompt to satisfy).
@test "UT-INFRA-243: wt-down.sh --purge-shared with a wrong token refuses non-interactively" {
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge-shared --confirm "yes" < /dev/null
  assert_failure
}

# UT-INFRA-244 — the correct token backs up BEFORE the shared `down -v` is
# ever issued (call-log ordering, not just "both happened").
@test "UT-INFRA-244: wt-down.sh --purge-shared with the right token backs up before down -v" {
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge-shared --confirm "DELETE-ALL-LOCAL-DATA" < /dev/null
  assert_success
  pg_line="$(grep -n "pg_dump" "$STUB_LOG" | head -1 | cut -d: -f1)"
  down_line="$(grep -n "^-v$" "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "${pg_line}" ]
  [ -n "${down_line}" ]
  [ "${pg_line}" -lt "${down_line}" ]
}

# UT-INFRA-245 — a failed backup refuses --purge-shared; `down -v` is never
# reached.
@test "UT-INFRA-245: wt-down.sh --purge-shared refuses when the backup fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/wt-down-backup-fail.rules.sh"
  run "${INFRA_ROOT}/scripts/wt-down.sh" --purge-shared --confirm "DELETE-ALL-LOCAL-DATA" < /dev/null
  assert_failure
  run grep -c -- "-v" "$STUB_LOG"
  refute_output "1"
}
