#!/usr/bin/env bats
# tests/seed-approval-runbook.bats — AXI-2464 (epic AXI-2455; TPL FR59, AC27).
# The prod deploy runbook must list the audited seed-approval script
# (axiome-back/scripts/approve_seeded_template_versions.sql) under
# "Post-migration data steps", with a command that stops on the script's
# own refusals and names the owner. The script lives in axiome-back, so its
# behaviour is tested there (UT-TMPL-750..757) and live on the demo
# (axiome-e2e-testing tests/AXI-2455/AXI-2464-seed-approvals.spec.ts).

load 'helpers/setup'

setup() {
  stub_setup
  RUNBOOK="${INFRA_ROOT}/docs/deploy-procedure.md"
}

# Prints the "Post-migration data steps" section: from its heading to the
# next heading or horizontal rule.
section() {
  awk '
    /^#+ Post-migration data steps[[:space:]]*$/ { on=1; next }
    on && (/^#/ || /^---[[:space:]]*$/) { exit }
    on { print }
  ' "$RUNBOOK"
}

# UT-INFRA-800
@test "UT-INFRA-800: the runbook has one Post-migration data steps section" {
  run grep -cE '^#+ Post-migration data steps[[:space:]]*$' "$RUNBOOK"
  assert_success
  assert_output "1"
}

# UT-INFRA-801
@test "UT-INFRA-801: the section lists the seed-approval script under AXI-2464" {
  run section
  assert_success
  assert_output --partial 'AXI-2464'
  assert_output --partial 'axiome-back/scripts/approve_seeded_template_versions.sql'
}

# UT-INFRA-802
@test "UT-INFRA-802: the listed command stops on error and passes owner_email" {
  run section
  assert_success
  local cmd
  cmd="$(printf '%s\n' "$output" | grep -A2 -E '^[[:space:]]*psql ' | tr -d '\\\n')"
  [[ "$cmd" == *"-v ON_ERROR_STOP=1"* ]] || fail "psql command lacks -v ON_ERROR_STOP=1: $cmd"
  [[ "$cmd" == *"-v owner_email="* ]] || fail "psql command lacks -v owner_email=: $cmd"
  [[ "$cmd" == *"-f axiome-back/scripts/approve_seeded_template_versions.sql"* ]] || fail "psql command does not run the script: $cmd"
}

# UT-INFRA-803
@test "UT-INFRA-803: the approver has no default and the runbook warns against re-running with another email" {
  run section
  assert_success
  # The AXI-2464 bullet only: from its heading line to the next bullet.
  local bullet
  bullet="$(printf '%s\n' "$output" | awk '/^- \*\*Owner approval of the boot-seeded/ { on=1 } on && /^- \*\*/ && !/Owner approval/ { exit } on { print }')"
  [ -n "$bullet" ] || fail "no AXI-2464 bullet in the section"
  [[ "$bullet" != *"BOOTSTRAP_ADMIN_EMAIL"* ]] || fail "the runbook still defaults the approver to BOOTSTRAP_ADMIN_EMAIL"
  [[ "$bullet" == *"Decide the approver first; never re-run with a different email."* ]] || fail "missing the decide-the-approver-first warning"
  [[ "$bullet" == *"There is no default"* ]] || fail "the runbook does not say the approver has no default"
}
