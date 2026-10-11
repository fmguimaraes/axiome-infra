#!/usr/bin/env bats
# tests/lock_acquire.bats — scripts/lock.sh acquire (AXI-1947, AC19, FR28/FR30).
# UT-INFRA-100..104, UT-INFRA-426, UT-INFRA-566..567.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-acquire.rules.sh"
  export LOCK_ACTOR="me@example.com"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-100: acquiring a free lock succeeds, prints the token/actor, and
# never calls delete-object.
@test "UT-INFRA-100: lock.sh acquire succeeds on a free lock and prints a token" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire deploy --operation "deploy tag=abc"

  assert_success
  assert_output --partial "ACQUIRED deploy"
  assert_output --partial "token="
  assert_output --partial "actor=me@example.com"
  assert_stub_called aws "put-object"
  assert_stub_not_called terraform
  run grep -c "delete-object" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-101: acquiring an already-held lock returns the distinct HELD
# code and names the holder (actor, operation, age).
@test "UT-INFRA-101: lock.sh acquire on a held lock names the holder with a distinct exit code" {
  run "${INFRA_ROOT}/scripts/lock.sh" staging acquire deploy --operation "deploy tag=new"

  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "someone@example.com"
  assert_output --partial "deploy tag=abc"
}

# UT-INFRA-102: a non-precondition put-object failure (AccessDenied) is a
# failure to acquire — never treated as acquired, never treated as free.
@test "UT-INFRA-102: lock.sh acquire on a generic aws error fails (never acquired)" {
  run "${INFRA_ROOT}/scripts/lock.sh" production acquire deploy --operation "deploy tag=z"

  assert_failure
  [ "$status" -eq 2 ]
  refute_output --partial "ACQUIRED"
  assert_output --partial "AccessDenied"
}

# UT-INFRA-103: an aws CLI older than the documented minimum is refused
# BEFORE any put-object attempt (the stub has no put-object arm — an
# attempt would itself fail the test as an unconfigured call).
@test "UT-INFRA-103: lock.sh acquire refuses on an aws CLI older than the minimum" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-cli-old.rules.sh"

  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire deploy --operation "deploy tag=z"

  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "2.17.34"
  run grep -c "put-object" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-104: an unknown lock name is refused before touching aws at all.
@test "UT-INFRA-104: lock.sh acquire refuses an unknown lock name before any aws call" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire bogus-lock --operation "x"

  assert_failure
  assert_output --partial "unknown lock name"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-426 (AXI-1967, FR42): 'apply' is a valid lock name across the
# CLI surface too — acquiring it on a free lock succeeds exactly like
# 'deploy'/'data-tier' (dev/deploy fixture arm reused, bucket-agnostic
# since the fixture doesn't gate on lock name).
@test "UT-INFRA-426: lock.sh acquire accepts 'apply' as a valid lock name" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-acquire-exclusive.rules.sh"

  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire apply --operation "terraform apply run=1"

  refute_output --partial "unknown lock name"
}

# UT-INFRA-566 (AXI-1972, follow-up h): a secret-shaped --operation is
# refused BEFORE the lock body is ever built or written (the fixture's
# catch-all arm returns 99 and would itself fail the test as an
# unconfigured call if put-object/get-object were ever reached — only the
# earlier, unconditional `aws --version` check is allowed through) — the
# lock is never acquired, and the secret-shaped value itself is never
# echoed back in the error message.
@test "UT-INFRA-566: lock.sh acquire refuses a secret-shaped --operation before writing the lock body" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire deploy --operation "password=hunter2hunter2"

  assert_failure
  [ "$status" -eq 3 ]
  assert_output --partial "REFUSED"
  assert_output --partial "resembles a secret-shaped string"
  refute_output --partial "hunter2hunter2"
  refute_output --partial "ACQUIRED"
  run grep -c "put-object\|get-object" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-567 (AXI-1972, follow-up h): an ordinary --operation (the kind
# every other test in this file already uses) is NOT refused by the new
# guard — proves it only fires on secret-shaped text, not on any
# "key=value"-looking text in general.
@test "UT-INFRA-567: lock.sh acquire does not refuse an ordinary --operation" {
  run "${INFRA_ROOT}/scripts/lock.sh" dev acquire deploy --operation "deploy tag=abc"

  assert_success
  assert_output --partial "ACQUIRED deploy"
}
