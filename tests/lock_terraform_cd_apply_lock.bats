#!/usr/bin/env bats
# tests/lock_terraform_cd_apply_lock.bats — .github/workflows/terraform-cd.yml's
# new "Acquire apply lock" / "Release apply lock" steps (AXI-1967, FR42/FR43,
# AC34). Same approach as tests/dev-auto-promote-workflow.bats's
# qual_step_run(): extract the step's real `run:` text via python3+yaml and
# EXECUTE it as plain bash against the stub harness — not a GHA runner, no
# `gh workflow run`. UT-INFRA-421..425.

load 'helpers/setup'

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/terraform-cd.yml"

setup() {
  stub_setup
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github_env"
  : > "${GITHUB_ENV}"
}

py_step_run() {
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['apply-production']['steps']
for s in steps:
    if s.get('name') == sys.argv[2]:
        print(s['run'])
        sys.exit(0)
sys.exit(1)
" "$WORKFLOW" "$1"
}

# UT-INFRA-421: both other-env structural facts hold — the "Acquire apply
# lock" step appears strictly between "Check data-tier lock" and "Deploy
# production" (never before the approval-gated job even starts, and never
# after terraform apply already ran).
@test "UT-INFRA-421: terraform-cd's apply-lock acquire step sits between the data-tier check and Deploy production" {
  local lock_check_line acquire_line deploy_line
  lock_check_line="$(grep -n "Check data-tier lock" "$WORKFLOW" | tail -1 | cut -d: -f1)"
  acquire_line="$(grep -n "name: Acquire apply lock" "$WORKFLOW" | cut -d: -f1)"
  deploy_line="$(grep -n "name: Deploy production" "$WORKFLOW" | cut -d: -f1)"
  [ "$lock_check_line" -lt "$acquire_line" ]
  [ "$acquire_line" -lt "$deploy_line" ]
}

# UT-INFRA-422: the "Release apply lock" step runs with `if: always()`,
# immediately after "Deploy production" — a failed/cancelled deploy must
# still release the lock, never leaving it held forever.
@test "UT-INFRA-422: terraform-cd's apply-lock release step runs with if:always() right after Deploy production" {
  run python3 -c "
import yaml
d = yaml.safe_load(open('${WORKFLOW}'))
steps = d['jobs']['apply-production']['steps']
names = [s.get('name') for s in steps]
i = names.index('Release apply lock (FR42, always)')
assert names[i-1] == 'Deploy production', names
s = steps[i]
assert s.get('if') == 'always()', s.get('if')
print('OK')
"
  assert_success
  assert_output "OK"
}

# UT-INFRA-423: the acquire step's real run: text, executed against a fully
# free stub environment, acquires 'apply' and writes APPLY_LOCK_TOKEN to
# \$GITHUB_ENV.
@test "UT-INFRA-423: the acquire-apply-lock step's run text acquires the lock and records a token" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/terraform-cd-apply-lock.rules.sh"
  local script
  script="$(py_step_run 'Acquire apply lock (FR42/FR43, AC34)')"

  run bash -c "cd '${INFRA_ROOT}' && GITHUB_ENV='${GITHUB_ENV}' github_run_id=1 bash -c \"\$1\"" _ "${script//\$\{\{ github.run_id \}\}/1}"

  assert_success
  assert_output --partial "ACQUIRED"
  run grep -c "^APPLY_LOCK_TOKEN=" "${GITHUB_ENV}"
  assert_output "1"
}

# UT-INFRA-424: the SAME run: text, executed when 'deploy' is held, exits
# non-zero (naming the holder via lock_acquire_exclusive, see
# tests/lock_acquire_exclusive.bats) and writes NO token to \$GITHUB_ENV —
# a GitHub Actions step with a non-zero exit fails the job, so "Deploy
# production" never runs.
@test "UT-INFRA-424: the acquire-apply-lock step's run text refuses and records no token when deploy is held" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/terraform-cd-apply-lock.rules.sh"
  export TF_APPLY_LOCK_FIXTURE_DEPLOY_STATE=held
  local script
  script="$(py_step_run 'Acquire apply lock (FR42/FR43, AC34)')"

  run bash -c "cd '${INFRA_ROOT}' && GITHUB_ENV='${GITHUB_ENV}' bash -c \"\$1\"" _ "${script//\$\{\{ github.run_id \}\}/1}"

  assert_failure
  run grep -c "^APPLY_LOCK_TOKEN=" "${GITHUB_ENV}"
  assert_output "0"
}

# UT-INFRA-425: the release step's run: text releases the token it finds
# in APPLY_LOCK_TOKEN, and no-ops cleanly (exit 0, no lock.sh call at all)
# when the env var was never set (the acquire step refused earlier).
@test "UT-INFRA-425: the release-apply-lock step's run text releases on a token and no-ops without one" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-release.rules.sh"
  local script
  script="$(py_step_run 'Release apply lock (FR42, always)')"

  APPLY_LOCK_TOKEN="mytoken" run bash -c "cd '${INFRA_ROOT}' && bash -c \"\$1\"" _ "${script}"
  assert_success
  assert_output --partial "RELEASED"

  stub_setup
  run bash -c "cd '${INFRA_ROOT}' && unset APPLY_LOCK_TOKEN; bash -c \"\$1\"" _ "${script}"
  assert_success
  assert_output --partial "nothing to release"
  run grep -c "### CALL: aws" "$STUB_LOG"
  assert_output "0"
}
