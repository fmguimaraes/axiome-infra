#!/usr/bin/env bash
# tests/helpers/setup.bash — `load`ed by every *.bats file. Wires the
# PATH-shim stubs in front of real binaries, blanks AWS credentials so a
# script under test can never reach a real endpoint, and gives tests a log
# to assert against. See tests/README.md for the full contract.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# INFRA_ROOT is used by every *.bats file that `load`s this helper.
# shellcheck disable=SC2034
INFRA_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

load "${TESTS_DIR}/vendor/bats-support/load.bash"
load "${TESTS_DIR}/vendor/bats-assert/load.bash"

# stub_setup — call from every test's `setup()`. Creates a fresh per-test
# stub log + unconfigured-call marker, prepends tests/stubs to PATH, and
# blanks every AWS credential/identity env var (NFR5: no real cloud endpoint
# is reachable from a test).
stub_setup() {
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log"
  : > "$STUB_LOG"
  export STUB_FAIL_LOG="${BATS_TEST_TMPDIR}/stub.unconfigured.log"
  : > "$STUB_FAIL_LOG"
  export PATH="${TESTS_DIR}/stubs:${PATH}"
  export AWS_ACCESS_KEY_ID="" AWS_SECRET_ACCESS_KEY="" AWS_SESSION_TOKEN=""
  export AWS_PROFILE="" AWS_SHARED_CREDENTIALS_FILE="/dev/null" AWS_CONFIG_FILE="/dev/null"
  export AWS_WEB_IDENTITY_TOKEN_FILE="" AWS_ROLE_ARN=""
}

# stub_teardown — called by the default teardown() below. Fails the test
# (via a non-zero teardown exit, which bats-core treats as a test failure
# regardless of the test body's own exit status) if any stub call went
# unconfigured — independent of whatever the caller did with that stub's
# exit code. A *.bats file that defines its OWN teardown() overrides the
# default below and MUST call stub_teardown itself; tests/run.sh statically
# checks that via tests/check-teardown-contract.sh.
stub_teardown() {
  local log="${STUB_FAIL_LOG:-}"
  [ -n "$log" ] && [ -s "$log" ] || return 0
  fail "$(printf 'unconfigured stub call(s) recorded independently of exit-code handling:\n%s' "$(cat "$log")")"
}

# Default teardown: every *.bats file that does NOT define its own
# teardown() gets this for free. See stub_teardown above.
teardown() {
  stub_teardown
}

# stub_use_rules <name> <fixture-file> — point <NAME>_STUB_RULES at a fixture
# (e.g. stub_use_rules aws "${TESTS_DIR}/fixtures/power-status.rules.sh").
stub_use_rules() {
  local upper
  upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  export "${upper}_STUB_RULES=$2"
}

# assert_stub_called <name> <substring> — fails unless the per-test log has a
# call to <name> whose recorded argv contains <substring> on some line.
# shellcheck disable=SC2154  # $status / $output are bats-core `run` globals.
assert_stub_called() {
  local name="$1" needle="$2"
  run awk -v n="$name" -v needle="$needle" '
    /^### CALL: /{cur=($0=="### CALL: " n)}
    cur && index($0, needle) {found=1}
    END{exit !found}
  ' "$STUB_LOG"
  [ "$status" -eq 0 ] || fail "expected a call to '${name}' containing '${needle}' in ${STUB_LOG}"
}

# assert_stub_not_called <name> — fails if <name> was invoked at all.
# shellcheck disable=SC2154
assert_stub_not_called() {
  local name="$1"
  run grep -qx "### CALL: ${name}" "$STUB_LOG"
  [ "$status" -ne 0 ] || fail "expected no call to '${name}' but one was recorded in ${STUB_LOG}"
}
