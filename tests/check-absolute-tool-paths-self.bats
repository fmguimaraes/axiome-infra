#!/usr/bin/env bats
# tests/check-absolute-tool-paths-self.bats — self-test for
# tests/check-absolute-tool-paths.sh (AXI-1972, scope item 1/FR62/AC56:
# "a script calling a guarded tool by absolute path is detected and
# fails the suite"). Before this story's checker existed, a script that
# wrote `/usr/bin/aws ...` instead of `aws ...` passed the suite silently
# (the PATH-shim stub never fires for an absolute path).
#
# Both the fixture-repo setup (real `git init`) and invoking the checker
# itself (which internally shells out to real `git ls-files`) must run
# with the REAL PATH, not the stub-shimmed one `stub_setup` installs for
# THIS test's own body — captured here at file-parse time, same pattern
# as tests/compose-call-sites.bats's `_ALL_REPO_SOURCES`.
_REAL_PATH="$PATH"

load 'helpers/setup'

setup() {
  stub_setup
}

CHECKER="${BATS_TEST_DIRNAME}/check-absolute-tool-paths.sh"

# UT-INFRA-558 (AXI-1972): a tracked script calling a guarded tool
# (`aws`) by absolute path is detected and fails the check.
@test "UT-INFRA-558: check-absolute-tool-paths.sh fails on /usr/bin/aws in a tracked script" {
  local dir="${BATS_TEST_TMPDIR}/abs-bad"
  mkdir -p "${dir}/scripts"
  PATH="$_REAL_PATH" git init -q "$dir"
  cat > "${dir}/scripts/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/aws sts get-caller-identity
EOF
  (cd "$dir" && PATH="$_REAL_PATH" git add -A && PATH="$_REAL_PATH" git -c user.email=a@b.c -c user.name=a commit -q -m init)
  run env PATH="$_REAL_PATH" "$CHECKER" "$dir"
  assert_failure
  assert_output --partial "calls 'aws' by absolute path"
}

# UT-INFRA-559 (AXI-1972): a tracked script calling the SAME tool by its
# bare name (through the PATH-shim stub) is not flagged.
@test "UT-INFRA-559: check-absolute-tool-paths.sh passes a bare 'aws' invocation" {
  local dir="${BATS_TEST_TMPDIR}/abs-ok"
  mkdir -p "${dir}/scripts"
  PATH="$_REAL_PATH" git init -q "$dir"
  cat > "${dir}/scripts/ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
aws sts get-caller-identity
EOF
  (cd "$dir" && PATH="$_REAL_PATH" git add -A && PATH="$_REAL_PATH" git -c user.email=a@b.c -c user.name=a commit -q -m init)
  run env PATH="$_REAL_PATH" "$CHECKER" "$dir"
  assert_success
}

# UT-INFRA-560 (AXI-1972): the real infra tree is clean today.
@test "UT-INFRA-560: check-absolute-tool-paths.sh is clean on the real repo" {
  run env PATH="$_REAL_PATH" "$CHECKER" "$INFRA_ROOT"
  assert_success
}
