#!/usr/bin/env bats
# tests/deploy-production-workflow.bats — static checks on
# .github/workflows/deploy-production.yml (AXI-1954, epic AXI-1944).
# UT-INFRA-362..365.
#
# Text/grep-based on purpose: no `yq`/python-yaml dependency is otherwise
# required by this repo's test harness (see tests/README.md's "no network/
# package manager required" vendoring doctrine) — adding one just for this
# static check would widen that contract. These assertions are narrow and
# line-anchored enough to catch the facts that matter: the trigger set, and
# `shell: bash` on every pipeline-sensitive `run:` step (the epic-wide
# AXI-1953 learning — a step with no `shell:` key runs `bash -e` WITHOUT
# pipefail, silently hiding a piped command's failure).

load 'helpers/setup'

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/deploy-production.yml"

setup() {
  stub_setup
}

# UT-INFRA-362 — merging to main never starts a production deploy: only
# repository_dispatch(image-published) and workflow_dispatch trigger this
# workflow; there is no `on: push` / `on: pull_request`.
@test "UT-INFRA-362: deploy-production.yml has no push/pull_request trigger" {
  run grep -n "^  push:\|^  pull_request:" "$WORKFLOW"
  assert_failure
  run grep -c "repository_dispatch:" "$WORKFLOW"
  assert_success
  assert_output "1"
  run grep -c "workflow_dispatch:" "$WORKFLOW"
  assert_success
  assert_output "1"
}

# UT-INFRA-363 — every `run:` step declares `shell: bash` explicitly
# (epic AXI-1944 learning from AXI-1953's review bounce).
@test "UT-INFRA-363: deploy-production.yml declares shell: bash on every run: step" {
  run awk '
    /^[[:space:]]*run:/ { r++ }
    /^[[:space:]]*shell: bash/ { s++ }
    END { exit !(r > 0 && r == s) }
  ' "$WORKFLOW"
  assert_success
}

# UT-INFRA-364 — every `run:` step's script itself still sets
# `set -euo pipefail` (belt-and-suspenders with shell: bash, not a
# substitute for it).
@test "UT-INFRA-364: deploy-production.yml's run steps set -euo pipefail" {
  run grep -c "set -euo pipefail" "$WORKFLOW"
  assert_success
  [ "$output" -ge 2 ]
}

# UT-INFRA-365 — the production environment approval gate is still present
# and this story did not touch it (AXI-1954 is explicit it must not weaken
# any approval/if: guard).
@test "UT-INFRA-365: deploy-production.yml still gates the deploy job on the production environment" {
  run grep -n "environment: production" "$WORKFLOW"
  assert_success
  run grep -n "^jobs:" "$WORKFLOW"
  assert_success
}
