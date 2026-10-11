#!/usr/bin/env bats
# tests/new-tool-stubs.bats — AXI-1972, scope item 1/FR62/AC56: a tool no
# test configures a fixture for, but that a script could still reach
# (scp, rsync, nc, wget, mongosh, mongodump, mongorestore — found by
# grepping scripts/ and providers/ for direct invocations: migrate-data.sh
# calls mongodump/mongorestore directly on the host when both are on PATH;
# wt-down.sh and mongo-backup.sh reach mongosh/mongodump through `docker
# exec`), must have a PATH-shim stub that fails loudly (unconfigured call,
# exit 99) rather than silently falling through to a real binary.
#
# Before this story these names had NO file at all under tests/stubs/: a
# script calling them with that binary present on the real PATH would
# reach it for real; this test fails against the pre-fix tree (no such
# file on PATH — "command not found", status 127) with a different
# status, proving the gap, and passes once the stub exists (status 99,
# recorded as unconfigured).
load 'helpers/setup'

setup() {
  stub_setup
}

# Every @test below deliberately provokes an unconfigured call to prove
# the stub exists and fails loudly; _expect_and_clear_unconfigured asserts
# the fact was recorded (the thing under test) then clears the per-test
# fail-log so the file's PRESENCE is what we assert on, not left for the
# default teardown() to also fail on (that default is exactly correct for
# every OTHER test in this suite — an unconfigured call nobody expected).
_expect_and_clear_unconfigured() {
  local log="${BATS_TEST_TMPDIR}/stub.unconfigured.log"
  [ -s "$log" ] || fail "expected an unconfigured-call record at ${log}, found none"
  : > "$log"
}

# UT-INFRA-551..557 (AXI-1972): each of the newly-stubbed tools is on PATH
# (the stub, not a real binary) and an unconfigured call fails loudly.
@test "UT-INFRA-551: scp has a failing stub and an unconfigured call is recorded" {
  run scp host:/a /b
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-552: rsync has a failing stub and an unconfigured call is recorded" {
  run rsync -a a/ b/
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-553: nc has a failing stub and an unconfigured call is recorded" {
  run nc -z localhost 80
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-554: wget has a failing stub and an unconfigured call is recorded" {
  run wget http://example.invalid
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-555: mongosh has a failing stub and an unconfigured call is recorded" {
  run mongosh --eval 'db.adminCommand("ping")'
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-556: mongodump has a failing stub and an unconfigured call is recorded" {
  run mongodump --uri mongodb://x
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}

@test "UT-INFRA-557: mongorestore has a failing stub and an unconfigured call is recorded" {
  run mongorestore --uri mongodb://x
  assert_equal "$status" 99
  _expect_and_clear_unconfigured
}
