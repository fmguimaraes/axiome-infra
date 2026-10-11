#!/usr/bin/env bats
# tests/check-teardown-contract-self.bats — self-test for
# tests/check-teardown-contract.sh (AXI-1972, scope item 2: "teardown
# contract holds per test, not only per file"). Proves the checker is
# scoped to the body of the file's own teardown() function, not a
# whole-file grep: a comment mentioning stub_teardown must NOT satisfy it,
# and a teardown() that genuinely calls stub_teardown must pass.
load 'helpers/setup'

setup() {
  stub_setup
}

CHECKER="${BATS_TEST_DIRNAME}/check-teardown-contract.sh"

# UT-INFRA-545 (AXI-1972): a bats file whose teardown() body only mentions
# stub_teardown in a comment — never calls it — must fail the checker.
# Before this story's fix, a whole-file grep for the string 'stub_teardown'
# matched the comment and let the file pass; this is the regression test.
@test "UT-INFRA-545: check-teardown-contract.sh rejects a teardown() that only comments 'stub_teardown'" {
  local dir="${BATS_TEST_TMPDIR}/fixture-comment"
  mkdir -p "$dir"
  cat > "${dir}/fake.bats" <<'EOF'
#!/usr/bin/env bats
load 'helpers/setup'
teardown() {
  # NOTE: this does not actually call stub_teardown.
  true
}
@test "a test" {
  true
}
EOF
  run "$CHECKER" "$dir"
  assert_failure
  assert_output --partial "fake.bats defines its own teardown() whose body never calls stub_teardown"
}

# UT-INFRA-546 (AXI-1972): a bats file whose teardown() body genuinely
# calls stub_teardown passes.
@test "UT-INFRA-546: check-teardown-contract.sh accepts a teardown() that calls stub_teardown" {
  local dir="${BATS_TEST_TMPDIR}/fixture-real"
  mkdir -p "$dir"
  cat > "${dir}/fake.bats" <<'EOF'
#!/usr/bin/env bats
load 'helpers/setup'
teardown() {
  echo "cleanup"
  stub_teardown
}
@test "a test" {
  true
}
EOF
  run "$CHECKER" "$dir"
  assert_success
}

# UT-INFRA-547 (AXI-1972): a file with no teardown() override at all (the
# common case) is not flagged.
@test "UT-INFRA-547: check-teardown-contract.sh accepts a file with no teardown() override" {
  local dir="${BATS_TEST_TMPDIR}/fixture-none"
  mkdir -p "$dir"
  cat > "${dir}/fake.bats" <<'EOF'
#!/usr/bin/env bats
load 'helpers/setup'
setup() { stub_setup; }
@test "a test" {
  true
}
EOF
  run "$CHECKER" "$dir"
  assert_success
}
