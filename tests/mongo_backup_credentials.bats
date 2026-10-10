#!/usr/bin/env bats
# tests/mongo_backup_credentials.bats — FR51/AC44: the Mongo backup must
# never place the database password on any process's argument list, and
# the temporary credentials file it uses instead must be removed after
# success, after failure, and after a signal. UT-INFRA-460..464,
# UT-INFRA-610..611 (review bounce #1).
#
# `refute_secret_in_any_stub_argv` scans the WHOLE per-test stub log
# (tests/stubs/_common.sh writes one argv element per line, bracketed by
# "### CALL: <name>"/"### END") for the secret value as a SUBSTRING of any
# recorded argv element — catching it on any stub's call (docker's AND
# aws's), not just the one call site this story changed, and catching a
# `--password=<secret>` flag or a URI with the secret embedded in it, not
# just a bare argv element that equals the secret exactly.

load 'helpers/setup'

MONGO_SECRET='Ut1-460-Distinctive-Mongo-Root-Pw'

setup() {
  stub_setup
  export TMPDIR="$BATS_TEST_TMPDIR"
  export MONGO_BACKUP_LOG="${BATS_TEST_TMPDIR}/mongo-backup.log"
  export MONGO_BACKUP_ENV_FILE="${BATS_TEST_TMPDIR}/axiome.env"
  cat > "${MONGO_BACKUP_ENV_FILE}" <<EOF
S3_BUCKET_SYSTEM=test-system-bucket
MONGO_ROOT_USER=axiome
MONGO_ROOT_PASSWORD=${MONGO_SECRET}
EOF
}

# Substring match (review bounce #1), not a whole-argv-element match: a
# `--password=<secret>` flag or a `mongodb://user:<secret>@host` URI
# embeds the secret INSIDE a longer argv element, not as one on its own —
# an exact-line match would miss both.
refute_secret_in_any_stub_argv() {
  run grep -F "$MONGO_SECRET" "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "secret value found (as a substring of a recorded argv element) in ${STUB_LOG}"
}

config_file_count() {
  find "$TMPDIR" -maxdepth 1 -name 'mongo-backup-config.*' | wc -l | tr -d ' '
}

# UT-INFRA-460: a successful run never puts the password on any stub's
# argv (docker's `exec`/mongodump call, or aws's s3/head-object calls).
@test "UT-INFRA-460: mongo-backup.sh success never puts the password on any process argument list" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_success
  refute_secret_in_any_stub_argv
}

# UT-INFRA-461: the credentials tempfile is gone after a successful run.
@test "UT-INFRA-461: mongo-backup.sh removes the mongodump credentials tempfile after success" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_success
  [ "$(config_file_count)" -eq 0 ] || fail "credentials tempfile still present after success"
}

# UT-INFRA-462: a mongodump failure never puts the password on any stub's
# argv either, and still removes the credentials tempfile.
@test "UT-INFRA-462: mongo-backup.sh failure never leaks the password and still removes the credentials tempfile" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-partial-fail.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_failure
  refute_secret_in_any_stub_argv
  [ "$(config_file_count)" -eq 0 ] || fail "credentials tempfile still present after failure"
}

# UT-INFRA-463: a signal delivered while mongo-backup.sh is blocked in the
# docker exec call still removes the credentials tempfile — proves the
# cleanup is NOT relying solely on a bare EXIT trap (which bash does not
# guarantee fires on every signal), it's an explicit TERM/INT trap too.
# setsid + kill on the whole process group: a plain `kill $pid` would only
# ever reach the script, not the still-running docker-stub grandchild it is
# waiting on (same recipe used by tests/asset-sync*.bats, AXI-1969).
@test "UT-INFRA-463: mongo-backup.sh removes the credentials tempfile after being signalled mid-run" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-slow.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  setsid "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.5
  kill -TERM -- "-${pid}" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$(config_file_count)" -eq 0 ] || fail "credentials tempfile still present after SIGTERM"
}

# UT-INFRA-464: the password is file content, never a `set -x`-visible
# argument — `--config=/dev/stdin` (never the secret) is the only
# credential-related element on docker's recorded argv.
@test "UT-INFRA-464: mongo-backup.sh's docker exec argv carries only --config=/dev/stdin, never the password" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/mongo-backup-docker-ok.rules.sh"
  stub_use_rules aws "${TESTS_DIR}/fixtures/mongo-backup-aws-ok.rules.sh"

  run "${INFRA_ROOT}/providers/aws/onbox/mongo-backup.sh"

  assert_success
  assert_stub_called docker "--config=/dev/stdin"
  refute_secret_in_any_stub_argv
}

# decode_mongodump_password_yaml <file> — reverses the EXACT, documented
# format `mongodump_password_config_yaml` emits (one line, `password:
# '<escaped>'`) without a YAML library: strip the `password: '`/`'`
# wrapper, then un-double `''` -> `'`. This is a decoder for a known,
# narrow format, not a general YAML parser.
decode_mongodump_password_yaml() {
  local content stripped
  content="$(cat "$1")"
  stripped="${content#"password: '"}"
  stripped="${stripped%\'}"
  printf '%s' "${stripped//\'\'/\'}"
}

# UT-INFRA-610: review bounce #1 item (d) — a password containing every
# byte class mongodump's YAML config needs to survive (a double quote, a
# backslash, a colon, a hash, a single quote, a leading `*`, a trailing
# space) round-trips byte-for-byte through the REAL emitter function
# (sourced from mongo-backup.sh itself via MONGO_BACKUP_LIB_ONLY=1 — not a
# copy of it).
@test "UT-INFRA-610: mongodump_password_config_yaml round-trips a hostile password exactly" {
  local hostile=$'*a"b\\c\':#d '
  local out="${BATS_TEST_TMPDIR}/hostile-config.yaml"

  MONGO_BACKUP_LIB_ONLY=1 bash -c '
    source "'"${INFRA_ROOT}"'/providers/aws/onbox/mongo-backup.sh"
    mongodump_password_config_yaml "$1"
  ' _ "$hostile" > "$out"

  run decode_mongodump_password_yaml "$out"
  assert_output "$hostile"
}

# UT-INFRA-611: a password containing a literal newline is refused with a
# truthful message naming the variable, never printing the value, and
# produces no output file content.
@test "UT-INFRA-611: mongodump_password_config_yaml refuses a password containing a newline, without printing it" {
  local hostile=$'line-one\nline-two-SECRET'

  run env MONGO_BACKUP_LIB_ONLY=1 bash -c '
    source "'"${INFRA_ROOT}"'/providers/aws/onbox/mongo-backup.sh"
    mongodump_password_config_yaml "$1"
  ' _ "$hostile"

  assert_failure
  assert_output --partial "MONGO_ROOT_PASSWORD contains a newline"
  refute_output --partial "line-two-SECRET"
}
