#!/usr/bin/env bats
# tests/lock_release.bats — scripts/lock.sh release (AXI-1947, FR30, EC7).
# UT-INFRA-105..109.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-105: the holder releases its own lock; the conditional delete
# (--if-match <etag>) is used.
@test "UT-INFRA-105: lock.sh release removes the caller's own lock via a conditional delete" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev release deploy --token mytoken

  assert_success
  assert_output --partial "RELEASED deploy"
  assert_stub_called aws "delete-object"
  run grep -c "if-match" "$STUB_LOG"
  [ "$output" -ge 1 ]
}

# UT-INFRA-106: releasing with the wrong token is refused; no delete-object
# call is made (the fixture leaves it unconfigured on purpose).
@test "UT-INFRA-106: lock.sh release refuses a non-matching token and never deletes" {
  run "${INFRA_ROOT}/scripts/lock.sh" staging release deploy --token wrong-token

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "does not match"
}

# UT-INFRA-107: releasing an already-free lock is refused.
@test "UT-INFRA-107: lock.sh release refuses when the lock is already free" {
  run "${INFRA_ROOT}/scripts/lock.sh" staging release data-tier --token anything

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "not held"
}

# UT-INFRA-108: when the lock's state cannot be determined (NFR2 fail-closed)
# release refuses with the UNKNOWN code, never deletes.
@test "UT-INFRA-108: lock.sh release refuses when lock state cannot be determined" {
  run "${INFRA_ROOT}/scripts/lock.sh" production release deploy --token anything

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "undetermined"
}

# UT-INFRA-109: when the aws CLI rejects the conditional delete option,
# release WARNS and falls back to an unconditional delete rather than
# refusing outright (the documented race window).
@test "UT-INFRA-109: lock.sh release falls back to an unconditional delete when --if-match is unsupported" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev release data-tier --token mytoken

  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "RELEASED data-tier"
}
