#!/usr/bin/env bats
# tests/stub_detection.bats — proves an unconfigured stub call is caught
# independently of how the caller script disposes of the exit code (NFR2,
# blocking finding #1 on AXI-1945's first review bounce). Each test runs a
# tiny synthetic bats file in a subprocess (its own fresh PATH/stub state)
# and asserts THAT inner run fails — i.e. the detection fired. If the
# marker-file mechanism were ripped out, the inner run would exit 0 and
# these assertions would fail.
# UT-INFRA-007..009.

load 'helpers/setup'

setup() {
  stub_setup
}

# Runs a one-line test body in a fresh nested bats process with no
# AWS_STUB_RULES configured, so any `aws` call it makes is unconfigured.
_run_inner() {
  local body="$1" tmp="${BATS_TEST_TMPDIR}/inner.bats"
  cat > "$tmp" <<INNER
load '${TESTS_DIR}/helpers/setup'
setup() { stub_setup; }
@test "inner" {
  ${body}
}
INNER
  "${TESTS_DIR}/vendor/bats-core/bin/bats" "$tmp"
}

# UT-INFRA-007 — "cmd 2>/dev/null || true" swallows the exit code entirely;
# detection must still fail the (inner) test.
@test "UT-INFRA-007: unconfigured call survives '|| true' exit-code swallowing" {
  run _run_inner 'aws sts get-caller-identity 2>/dev/null || true'
  assert_failure
}

# UT-INFRA-008 — command substitution / local assignment.
@test "UT-INFRA-008: unconfigured call survives command substitution" {
  run _run_inner 'local x; x="$(aws sts get-caller-identity 2>/dev/null)"; true'
  assert_failure
}

# UT-INFRA-009 — background job in a subshell, waited on, exit code ignored.
@test "UT-INFRA-009: unconfigured call survives background/subshell" {
  run _run_inner '( aws sts get-caller-identity >/dev/null 2>&1 & wait ); true'
  assert_failure
}
