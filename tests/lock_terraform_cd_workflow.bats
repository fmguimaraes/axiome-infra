#!/usr/bin/env bats
# tests/lock_terraform_cd_workflow.bats — structural proof that
# .github/workflows/terraform-cd.yml gates BOTH its plan and apply steps on
# scripts/lock.sh (AXI-1947, AC20), plus a direct proof that the exact
# command the workflow invokes exits non-zero on a held/undetermined
# data-tier lock. The YAML itself is not executed by anything here (no
# `gh workflow run`, no real Actions runner) — see tests/README.md
# "Un-stubbed tools" for why a workflow file can only be checked
# structurally offline. UT-INFRA-126..128.

load 'helpers/setup'

setup() {
  stub_setup
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
  WORKFLOW="${INFRA_ROOT}/.github/workflows/terraform-cd.yml"
}

# UT-INFRA-126: the ci-gate job's lock check runs AFTER "Export provider
# credentials" and BEFORE "terraform plan (production)".
@test "UT-INFRA-126: terraform-cd ci-gate checks the data-tier lock before terraform plan" {
  run awk '/name: Infra CI gate/{p=1} /^  apply-production:/{p=0} p' "$WORKFLOW"
  assert_success
  local creds_line lock_line plan_line
  creds_line="$(grep -n "Export provider credentials" "$WORKFLOW" | head -1 | cut -d: -f1)"
  lock_line="$(grep -n "Check data-tier lock" "$WORKFLOW" | head -1 | cut -d: -f1)"
  plan_line="$(grep -n "terraform plan (production)" "$WORKFLOW" | head -1 | cut -d: -f1)"
  [ "$creds_line" -lt "$lock_line" ]
  [ "$lock_line" -lt "$plan_line" ]
}

# UT-INFRA-127: the apply-production job re-checks the lock AFTER its own
# credential export and BEFORE "Deploy production" (terraform apply).
@test "UT-INFRA-127: terraform-cd apply-production re-checks the data-tier lock before apply" {
  local creds_line lock_line deploy_line
  creds_line="$(grep -n "Export provider credentials" "$WORKFLOW" | tail -1 | cut -d: -f1)"
  lock_line="$(grep -n "Check data-tier lock" "$WORKFLOW" | tail -1 | cut -d: -f1)"
  deploy_line="$(grep -n "name: Deploy production" "$WORKFLOW" | cut -d: -f1)"
  [ "$creds_line" -lt "$lock_line" ]
  [ "$lock_line" -lt "$deploy_line" ]
}

# UT-INFRA-128: the exact command the workflow step runs
# (`scripts/lock.sh production status data-tier`) exits non-zero both when
# the lock is HELD and when it is UNDETERMINED — the two cases that must
# block terraform-cd (a GitHub Actions step with a non-zero exit fails the
# job by default, so no extra wrapper is needed in the YAML).
@test "UT-INFRA-128: the workflow's lock-check command fails on HELD and on UNDETERMINED" {
  run grep -c "scripts/lock.sh production status data-tier" "$WORKFLOW"
  [ "$output" -ge 2 ]

  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-status.rules.sh"
  run "${INFRA_ROOT}/scripts/lock.sh" dev status deploy
  assert_failure
  [ "$status" -eq 1 ]

  run "${INFRA_ROOT}/scripts/lock.sh" staging status deploy
  assert_failure
  [ "$status" -eq 2 ]
}
