#!/usr/bin/env bats
# tests/mongo_backup.bats — providers/aws/onbox/mongo-backup.sh, run for
# real under the stub harness (bounce #1: a prior version only ever wrote
# its MONGO_BACKUP_OK/FAILED contract line to the log, never to the
# caller's actual stdout — this file is what catches that class of defect,
# since the earlier test suite only ever simulated the SSM response and
# never ran the real script). docker and aws resolve to tests/stubs/* for
# the whole file; the script never reaches a real Docker daemon or AWS.
# UT-INFRA-198..203.

load 'helpers/setup'

setup() {
  stub_setup
  export MONGO_BACKUP_LOG="${BATS_TEST_TMPDIR}/mongo-backup.log"
  export MONGO_BACKUP_ENV_FILE="${BATS_TEST_TMPDIR}/axiome.env"
  cat > "${MONGO_BACKUP_ENV_FILE}" <<'EOF'
S3_BUCKET_SYSTEM=test-system-bucket
MONGO_ROOT_USER=axiome
MONGO_ROOT_PASSWORD=S3cr3t-Pw-Never-Print-Me
EOF
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

# UT-INFRA-198: success puts the OK line on the caller's REAL stdout (fd 3),
# not just the log — this is the exact bug the bounce was filed against.
@test "UT-INFRA-198: mongo-backup.sh success puts MONGO_BACKUP_OK on the captured stdout" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_success
  assert_output --regexp '^MONGO_BACKUP_OK key=backups/mongo/[0-9TZ]+\.archive\.gz sha256=[0-9a-f]{64}$'
  [ -f "${MONGO_BACKUP_LOG}" ]
  run grep -q "MONGO_BACKUP_OK" "${MONGO_BACKUP_LOG}"
  assert_success
}

# UT-INFRA-199: an empty archive (docker exits 0 but writes nothing) fails
# with the FAILED line on stdout and a non-zero exit — never uploads.
@test "UT-INFRA-199: mongo-backup.sh fails on an empty archive, never uploads" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-empty.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_failure
  assert_output --partial "MONGO_BACKUP_FAILED archive is empty"
  assert_stub_not_called aws
}

# UT-INFRA-200: a mongodump failure caught by docker exec's OWN exit status
# — even though some bytes were already written to the archive — fails.
# Proves the check is the exit code, never the archive size alone.
@test "UT-INFRA-200: mongo-backup.sh fails on a mongodump exit-status failure even with partial bytes written" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-partial-fail.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_failure
  assert_output --partial "MONGO_BACKUP_FAILED mongodump failed"
  assert_stub_not_called aws
}

# UT-INFRA-201: an upload failure fails with the FAILED line and never
# reaches head-object or the marker.
@test "UT-INFRA-201: mongo-backup.sh fails when the upload itself fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-upload-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_failure
  assert_output --partial "MONGO_BACKUP_FAILED upload to s3://"
  refute_stub_called_with aws "head-object"
}

# UT-INFRA-202: a head-object verification failure fails — the script never
# claims success on an object it could not independently confirm.
@test "UT-INFRA-202: mongo-backup.sh fails when the post-upload head-object verification fails" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-headobject-fail.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_failure
  assert_output --partial "MONGO_BACKUP_FAILED head-object verification"
}

# UT-INFRA-203: the Mongo root password appears in neither the captured
# stdout nor the log file, on a full successful run.
@test "UT-INFRA-203: mongo-backup.sh never prints the Mongo password to stdout or the log" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_success
  refute_output --partial "S3cr3t-Pw-Never-Print-Me"
  run grep -q "S3cr3t-Pw-Never-Print-Me" "${MONGO_BACKUP_LOG}"
  assert_failure
}
