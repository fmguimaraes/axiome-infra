#!/usr/bin/env bats
# tests/power_down_backup.bats — providers/aws/scripts/power.sh <env> down's
# FR31 pre-stop backup-and-verify step. UT-INFRA-180..184, 195..197.

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export POWER_NO_COMMIT=1
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
}

# refute_stub_called_with <name> <substring> — tests/helpers/setup.bash's own
# assert_stub_not_called ignores a second argument (it only checks whether
# <name> was called AT ALL); several assertions below need "aws WAS called,
# but never with THIS specific subcommand" — hence this local helper (mirrors
# assert_stub_called's own awk, inverted), not a change to the shared file.
refute_stub_called_with() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected NO call to '${name}' containing '${needle}' but one was recorded in ${STUB_LOG}"
}

# UT-INFRA-180: a verified backup allows the stop to proceed.
@test "UT-INFRA-180: power.sh down stops compute only after the backup is verified present (FR31)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_success
  assert_stub_called aws "head-object"
  assert_stub_called aws "stop-instances"
}

# UT-INFRA-181: a failed backup refuses the stop outright (no override given).
@test "UT-INFRA-181: power.sh down refuses to stop compute when the backup fails (FR31)" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "backup not verified"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-182: --skip-backup with a real reason stops anyway, audited.
@test "UT-INFRA-182: power.sh down --skip-backup stops without running the backup, override is audited" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "planned Mongo maintenance window"

  assert_success
  refute_stub_called_with aws "send-command"
  assert_stub_called aws "stop-instances"
  report_file="$(find "${REPORTS_DIR}" -name '*compute-down*.md' | head -1)"
  [ -n "$report_file" ]
  run grep -q "OVERRIDE skip-backup: planned Mongo maintenance window" "$report_file"
  assert_success
}

# UT-INFRA-183: a secret-shaped --skip-backup reason is refused before any stop.
@test "UT-INFRA-183: power.sh down --skip-backup refuses a secret-shaped reason before any stop" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup "token=abc123def456"

  assert_failure
  refute_stub_called_with aws "stop-instances"
  refute_stub_called_with aws "send-command"
}

# UT-INFRA-184: --skip-backup with no reason text is refused before any stop.
@test "UT-INFRA-184: power.sh down --skip-backup with no reason is refused before any stop" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down --skip-backup ""

  assert_failure
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-195: a zero-byte object is never trusted as a backup (freshness
# bounce #1 fix) — refuses the stop even though the OK line itself parsed.
@test "UT-INFRA-195: power.sh down refuses the stop when the verified object is zero-byte" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-zerobyte.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "zero-byte"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-196: a stale object (LastModified predates when the backup
# command was issued) is never trusted — refuses the stop.
@test "UT-INFRA-196: power.sh down refuses the stop when the verified object is stale" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-stale.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "stale object"
  refute_stub_called_with aws "stop-instances"
}

# UT-INFRA-197: a sha256 mismatch between the OK line and the object's own
# metadata is never trusted — refuses the stop.
@test "UT-INFRA-197: power.sh down refuses the stop on a checksum mismatch" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-down-backup-checksum-mismatch.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev down

  assert_failure
  assert_output --partial "checksum mismatch"
  refute_stub_called_with aws "stop-instances"
}
