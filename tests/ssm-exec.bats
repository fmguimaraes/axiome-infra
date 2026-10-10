#!/usr/bin/env bats
# tests/ssm-exec.bats — scripts/ssm-exec.sh (AXI-1953, epic AXI-1944, FR20).
# UT-INFRA-294..300, 316..317 (review bounce #1: distinct exit codes, -t
# validation, and a STUB_LOG grep-needle fix — see UT-INFRA-299 below).

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/ssm-exec.sh"

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/ssm-exec.rules.sh"
  export SSM_EXEC_FIXTURE_COUNTER_FILE="${BATS_TEST_TMPDIR}/poll.counter"
  export SSM_EXEC_POLL_INTERVAL=0
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
}

# UT-INFRA-294 — the documented default wait is 900s (FR20).
@test "UT-INFRA-294: ssm-exec.sh documents a 900s default wait" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Default: 900"
}

# UT-INFRA-295 — a command that reaches Success within the wait exits 0,
# prints its output, and never calls cancel-command.
@test "UT-INFRA-295: ssm-exec.sh exits 0 on a Success reached within the wait" {
  export SSM_EXEC_FIXTURE_STATUS_SEQUENCE="Success"
  export SSM_EXEC_FIXTURE_STDOUT="ok"
  run "$SCRIPT" -t 5 'uptime'
  assert_success
  assert_output --partial "ok"
  refute_output --partial "INDETERMINATE"
  assert_stub_not_called_cancel
}

assert_stub_not_called_cancel() {
  run grep -F "cancel-command" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-296 — a command that reaches Failed within the wait exits 1
# (a known terminal failure), reported as Failed, never INDETERMINATE/exit
# 2, and cancel-command is never called (it already reached a terminal
# state).
@test "UT-INFRA-296: ssm-exec.sh exits 1 on a terminal Failed, not INDETERMINATE" {
  export SSM_EXEC_FIXTURE_STATUS_SEQUENCE="Failed"
  export SSM_EXEC_FIXTURE_STDERR="boom"
  run "$SCRIPT" -t 5 'false'
  [ "$status" -eq 1 ]
  assert_output --partial "status: Failed"
  refute_output --partial "INDETERMINATE"
  assert_stub_not_called_cancel
}

# UT-INFRA-297 — FR20: the wait expires before any terminal state (the
# fixture always answers Pending) — ssm-exec.sh cancels the command,
# reports INDETERMINATE (never Success, never a plain Failed) and exits
# with the DISTINCT code 2 (never 1, which means a known terminal
# failure) so a caller can branch without parsing stderr.
@test "UT-INFRA-297: ssm-exec.sh cancels and exits 2 (INDETERMINATE) when the wait expires" {
  export SSM_EXEC_FIXTURE_STATUS_SEQUENCE="Pending"
  run "$SCRIPT" -t 1 'sleep 999'
  [ "$status" -eq 2 ]
  assert_output --partial "INDETERMINATE"
  refute_output --partial "status: Success"
  run grep -F "cancel-command" "$STUB_LOG"
  assert_success
}

# UT-INFRA-298 — a cancel-command call that itself fails must not change
# the verdict: still exit 2/INDETERMINATE (fail-closed, never fail-open
# into a false Success or a plain exit 1).
@test "UT-INFRA-298: ssm-exec.sh stays at exit 2/INDETERMINATE even if cancel-command fails" {
  export SSM_EXEC_FIXTURE_STATUS_SEQUENCE="Pending"
  export SSM_EXEC_FIXTURE_CANCEL_RC=1
  run "$SCRIPT" -t 1 'sleep 999'
  [ "$status" -eq 2 ]
  assert_output --partial "INDETERMINATE"
}

# UT-INFRA-299 — an explicit -i instance id skips the describe-instances
# lookup (regression: the FR20 change must not disturb this path).
#
# Review bounce #1: the original assertion grepped STUB_LOG for the
# TWO-WORD needle "ec2 describe-instances", but _stub_log writes ONE
# argv element per line, so "ec2" and "describe-instances" are on
# separate lines and that needle can never match a single line — the
# assertion passed whether or not the call happened. Fixed to grep the
# single-token needle that actually appears on its own log line.
@test "UT-INFRA-299: ssm-exec.sh -i skips the describe-instances lookup" {
  export SSM_EXEC_FIXTURE_STATUS_SEQUENCE="Success"
  run "$SCRIPT" -t 5 -i i-explicit 'uptime'
  assert_success
  run grep -Fx "describe-instances" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-300 — no command given is a usage error (exit 1, not 2 — exit 2
# is reserved for INDETERMINATE) before any aws call.
@test "UT-INFRA-300: ssm-exec.sh with no command is a usage error" {
  run "$SCRIPT" -t 5
  [ "$status" -eq 1 ]
  assert_output --partial "no command given"
  assert_stub_not_called aws
}

# UT-INFRA-316 — a non-numeric -t is rejected before any aws call.
@test "UT-INFRA-316: ssm-exec.sh rejects a non-numeric -t" {
  run "$SCRIPT" -t abc 'uptime'
  assert_failure
  assert_output --partial "must be a positive integer"
  assert_stub_not_called aws
}

# UT-INFRA-317 — a zero -t is rejected (a zero-second wait can never let a
# real remote command reach a terminal state, so it always means a usage
# mistake, not a tiny timeout) before any aws call.
@test "UT-INFRA-317: ssm-exec.sh rejects a zero -t" {
  run "$SCRIPT" -t 0 'uptime'
  assert_failure
  assert_output --partial "must be a positive integer"
  assert_stub_not_called aws
}
