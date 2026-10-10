#!/usr/bin/env bats
# tests/boot.bats — providers/aws/onbox/boot.sh (AXI-1950, epic AXI-1944
# decision 8, FR10/FR11/FR12). UT-INFRA-149..153.
#
# scripts/asset-sync.sh and scripts/refresh-env.sh are replaced with tiny
# fakes under AXIOME_DIR (boot.sh invokes them by path, not via PATH), so
# these tests exercise boot.sh's OWN ordering/fallthrough logic in
# isolation from asset-sync/refresh-env's own behaviour (covered by their
# own *.bats files). `docker` is the real PATH-shim stub.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../providers/aws/onbox/boot.sh"

setup() {
  stub_setup
  stub_use_rules docker "${TESTS_DIR}/fixtures/boot-compose.rules.sh"
  export AXIOME_DIR="${BATS_TEST_TMPDIR}/axiome"
  export ONBOX_S3_PREFIX="s3://fakebucket/onbox"
  export BOOT_TRACE_FILE="${BATS_TEST_TMPDIR}/trace.log"
  : > "$BOOT_TRACE_FILE"
  mkdir -p "${AXIOME_DIR}/scripts"
  fake_script "${AXIOME_DIR}/scripts/asset-sync.sh" pull "${FAKE_SYNC_RC:-0}"
  fake_script "${AXIOME_DIR}/scripts/refresh-env.sh" refresh "${FAKE_REFRESH_RC:-0}"
}

fake_script() {
  local path="$1" label="$2" rc="$3"
  cat > "$path" <<EOF
#!/usr/bin/env bash
echo "${label}" >> "${BOOT_TRACE_FILE}"
exit ${rc}
EOF
  chmod +x "$path"
}

# UT-INFRA-149 — the boot wrapper runs, in order: asset-sync pull, then
# .env refresh, then `docker compose up -d` (the gate runs inside that).
@test "UT-INFRA-149: boot.sh runs sync, then refresh-env, then compose up -d, in order" {
  run "$SCRIPT"
  assert_success
  run cat "$BOOT_TRACE_FILE"
  assert_line --index 0 "pull"
  assert_line --index 1 "refresh"
  assert_line --index 2 "compose-up"
}

# UT-INFRA-150 — a failed asset-sync pull does not block refresh-env or
# compose up (EC6 "same spirit" — boot continues on what's on disk).
@test "UT-INFRA-150: boot.sh continues to refresh-env and compose up when sync fails" {
  fake_script "${AXIOME_DIR}/scripts/asset-sync.sh" pull 2
  run "$SCRIPT"
  assert_success
  run cat "$BOOT_TRACE_FILE"
  assert_line --index 0 "pull"
  assert_line --index 1 "refresh"
  assert_line --index 2 "compose-up"
}

# UT-INFRA-151 — a failed .env refresh does not block compose up (EC6).
@test "UT-INFRA-151: boot.sh continues to compose up when refresh-env fails" {
  fake_script "${AXIOME_DIR}/scripts/refresh-env.sh" refresh 3
  run "$SCRIPT"
  assert_success
  run cat "$BOOT_TRACE_FILE"
  assert_line --index 2 "compose-up"
}

# UT-INFRA-152 — a failing migrate gate (surfaced by `docker compose up -d`
# exiting non-zero) is surfaced as boot.sh's own non-zero exit — never
# swallowed.
@test "UT-INFRA-152: boot.sh surfaces a failing compose up -d (the migrate gate) as its own failure" {
  export BOOT_FIXTURE_COMPOSE_RC=1
  run "$SCRIPT"
  assert_failure
  run cat "$BOOT_TRACE_FILE"
  assert_line --index 2 "compose-up"
}

# UT-INFRA-153 — a missing ONBOX_S3_PREFIX fails fast with a clear error,
# before anything runs.
@test "UT-INFRA-153: boot.sh fails fast when ONBOX_S3_PREFIX is unset" {
  unset ONBOX_S3_PREFIX
  run "$SCRIPT"
  assert_failure
  run cat "$BOOT_TRACE_FILE"
  assert_output ""
}
