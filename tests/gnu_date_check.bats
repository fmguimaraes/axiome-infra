#!/usr/bin/env bats
# tests/gnu_date_check.bats — FR53/AC46: a script that depends on GNU `date`
# refuses before any change on a non-GNU `date`, with one truthful line
# naming the remedy. tests/stubs/date passes through to the real `date` by
# default; DATE_STUB_MODE=bsd makes it behave like BSD/macOS date (rejects
# `-d`/`--date`) for exactly these tests. UT-INFRA-474..479, UT-INFRA-612
# (review bounce #1, Blocker 2: deploy-prod.sh sources lock.sh and calls its
# functions directly, bypassing lock.sh's own CLI preflight).

load 'helpers/setup'

setup() {
  stub_setup
  export REPO_ROOT="${INFRA_ROOT}"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-612: scripts/deploy-prod.sh SOURCES scripts/lock.sh and calls
# lock_acquire_exclusive directly (review bounce #1, Blocker 2) — it does
# NOT go through lock.sh's own CLI `main()`, so it must carry its own
# gnu_date_check call. Refuses before any aws/curl call (no lock acquired,
# no SSM, no ECR, no deploy) on a BSD-shaped date.
@test "UT-INFRA-612: deploy-prod.sh refuses on a BSD date before any aws/curl call" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/deploy-prod-aws.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/deploy-prod-curl.rules.sh"
  export DATE_STUB_MODE=bsd
  export REPORT_REPO_ROOT="${BATS_TEST_TMPDIR}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export ENV=production
  export SERVICE=backend
  export TAG=newtag123

  run "${INFRA_ROOT}/scripts/deploy-prod.sh"

  assert_failure
  assert_output --partial "ERROR: GNU date is required"
  assert_stub_not_called aws
  assert_stub_not_called curl
}

# UT-INFRA-474: the shared helper itself is silent and returns 0 on a real
# (GNU) date.
@test "UT-INFRA-474: gnu_date_check succeeds silently on a real GNU date" {
  run bash -c '. "'"${INFRA_ROOT}"'/scripts/lib/gnu-date-check.sh"; gnu_date_check'
  assert_success
  assert_output ""
}

# UT-INFRA-475: the shared helper refuses with a truthful, remedy-naming
# line on a BSD-shaped date, and nothing else.
@test "UT-INFRA-475: gnu_date_check refuses with a remedy-naming line on a BSD date" {
  export DATE_STUB_MODE=bsd
  run bash -c '. "'"${INFRA_ROOT}"'/scripts/lib/gnu-date-check.sh"; gnu_date_check'
  assert_failure
  assert_output --partial "ERROR: GNU date is required"
  assert_output --partial "brew install coreutils"
  assert_output --partial "Refusing before making any change."
}

# UT-INFRA-476: scripts/lock.sh's CLI entry point refuses on a BSD date
# before any aws call at all (status would otherwise just read, but even a
# read-only aws call is a thing we can prove never happened).
@test "UT-INFRA-476: lock.sh CLI refuses on a BSD date before any aws call" {
  export DATE_STUB_MODE=bsd

  run "${INFRA_ROOT}/scripts/lock.sh" dev status

  assert_failure
  assert_output --partial "ERROR: GNU date is required"
  assert_stub_not_called aws
}

# UT-INFRA-477: providers/aws/scripts/power.sh refuses on a BSD date before
# any aws call — including before resolving the instance for `status`.
@test "UT-INFRA-477: power.sh refuses on a BSD date before any aws call" {
  export DATE_STUB_MODE=bsd

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev status

  assert_failure
  assert_output --partial "ERROR: GNU date is required"
  assert_stub_not_called aws
}

# UT-INFRA-478: providers/aws/scripts/power-data.sh refuses on a BSD date
# before any aws call.
@test "UT-INFRA-478: power-data.sh refuses on a BSD date before any aws call" {
  export DATE_STUB_MODE=bsd

  run "${INFRA_ROOT}/providers/aws/scripts/power-data.sh" dev status

  assert_failure
  assert_output --partial "ERROR: GNU date is required"
  assert_stub_not_called aws
}

# UT-INFRA-479: sanity/regression guard — with a real (GNU) date, power.sh
# status is completely unaffected by the new preflight and still reaches
# the aws stub as before (pins that the check does not false-positive on
# this host's own real `date`).
@test "UT-INFRA-479: power.sh status still reaches aws normally on a real GNU date" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/power-status.rules.sh"

  run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev status

  assert_success
  assert_output --partial "dev compute i-0123456789abcdef0: running"
  assert_stub_called aws "describe-instances"
}
