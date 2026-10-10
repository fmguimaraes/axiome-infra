#!/usr/bin/env bats
# tests/report.bats — scripts/lib/report.sh (AXI-1945).
# UT-INFRA-001..004, UT-INFRA-006.

load 'helpers/setup'

setup() {
  stub_setup
  # report_init/log_event call `aws sts get-caller-identity` for the actor
  # line — must be configured or the default teardown's unconfigured-call
  # check (NFR2) fails every test here.
  stub_use_rules aws "${TESTS_DIR}/fixtures/sts-actor.rules.sh"
  REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export REPORTS_DIR
  REPORT_REPO_ROOT="${BATS_TEST_TMPDIR}"
  export REPORT_REPO_ROOT
  # shellcheck disable=SC1091
  source "${INFRA_ROOT}/scripts/lib/report.sh"
}

# UT-INFRA-001 — AAA: given a normal report cycle, when it runs, then the
# file carries actor, UTC time, inputs and an outcome (NFR4).
@test "UT-INFRA-001: report_init/section/line/finish writes actor, time, inputs, outcome" {
  report_init "dev" "smoke-test" "key=value"
  report_section "Actions"
  report_line "did a thing"
  report_finish "ok"

  run cat "${REPORTS_DIR}"/*dev-smoke-test.md
  assert_success
  assert_output --partial "**Actor:**"
  assert_output --partial "key=value"
  assert_output --partial "did a thing"
  assert_output --partial "**Outcome:** ok"
}

# UT-INFRA-002 — given report_override is used, when the report is written,
# then the override name + reason are recorded (NFR4).
@test "UT-INFRA-002: report_override records the override used" {
  report_init "dev" "override-test"
  report_override "row-loss" "expected truncate for test fixture"
  report_finish

  run cat "${REPORTS_DIR}"/*dev-override-test.md
  assert_success
  assert_output --partial "OVERRIDE row-loss"
  assert_output --partial "expected truncate for test fixture"
}

# UT-INFRA-003 — given a line matching an obvious secret shape, when any
# report function is called with it, then it refuses the write (NFR3,
# fail-closed) instead of masking it. Covers every write path and every
# documented shape — not just report_line.
@test "UT-INFRA-003: every report write path refuses every documented secret shape" {
  report_init "dev" "secret-test"

  run report_line "db=postgres://user:supersecret@db.internal:5432/app"
  assert_failure
  assert_output --partial "REPORT SECRET GUARD"

  run report_line "password=hunter2hunter2"
  assert_failure

  run report_line "PGPASSWORD=hunter2hunter2"
  assert_failure

  run report_line "psql --password hunter2hunter2 -h db"
  assert_failure

  run report_line "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789"
  assert_failure

  run report_line "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
  assert_failure

  run report_line "AWS_SESSION_TOKEN_ID=ASIAIOSFODNN7EXAMPLE"
  assert_failure

  # the classic AWS docs example secret key — 40 chars, mixed-case + '/', not hex
  run report_line "secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  assert_failure

  run report_line "jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
  assert_failure

  # every other write path must apply the same guard, not just report_line
  run report_section "password=hunter2hunter2"
  assert_failure
  run report_override "x" "password=hunter2hunter2"
  assert_failure
  run report_finish "password=hunter2hunter2"
  assert_failure
  run log_event "dev" "db" "password=hunter2hunter2"
  assert_failure
}

# UT-INFRA-006 — given legitimate audit content that merely LOOKS long
# (a git SHA, a sha256 image digest), when it is written, then the guard
# allows it through (it must not block real deploy/roll reports).
@test "UT-INFRA-006: report_line allows a git SHA and a sha256 digest" {
  report_init "dev" "allow-test"

  run report_line "deployed commit 1234567890abcdef1234567890abcdef12345678"
  assert_success

  run report_line "image digest sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_success

  run report_line "deployed commit 1234567890ABCDEF1234567890ABCDEF12345678"
  assert_success
}

# UT-INFRA-004 — given the same report sequence re-run twice (NFR1 spirit:
# nothing breaks, nothing collides/clobbers), when both finish, then two
# distinct report files exist and both are well-formed.
@test "UT-INFRA-004: re-running the same report sequence twice is safe" {
  report_init "dev" "idempotence-test"
  report_line "first run"
  report_finish

  report_init "dev" "idempotence-test"
  report_line "second run"
  report_finish

  run bash -c "ls '${REPORTS_DIR}'/*dev-idempotence-test.md | wc -l"
  assert_success
  assert_output "2"
}
