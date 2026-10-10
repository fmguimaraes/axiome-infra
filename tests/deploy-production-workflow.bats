#!/usr/bin/env bats
# tests/deploy-production-workflow.bats — static checks on
# .github/workflows/deploy-production.yml (AXI-1954, epic AXI-1944).
# UT-INFRA-362..365, UT-INFRA-487..491 (AXI-1968, FR45/AC37),
# UT-INFRA-630..631 (AXI-1968 review bounce, Item G).
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

# --- AXI-1968 (FR45/AC37): cross-repo checkouts ---------------------------

# UT-INFRA-487 — all three application repositories are checked out
# beside axiome-infra, via the same GH_PAT secret reusable-build.yml and
# terraform-cd.yml already use (no new secret introduced).
@test "UT-INFRA-487: deploy-production.yml checks out axiome-back, axiome-bio-compute and axiome-front using GH_PAT" {
  for repo in axiome-back axiome-bio-compute axiome-front; do
    run grep -c "repository: \${{ github.repository_owner }}/${repo}" "$WORKFLOW"
    assert_success
    [ "$output" -ge 1 ] || fail "no checkout of ${repo} found"
  done
  run grep -c 'token: ${{ secrets.GH_PAT }}' "$WORKFLOW"
  assert_success
  [ "$output" -ge 3 ]
}

# UT-INFRA-488 — every checkout step in this workflow sets
# persist-credentials: false (no checkout here ever needs to push).
@test "UT-INFRA-488: every actions/checkout step in deploy-production.yml sets persist-credentials: false" {
  run awk '
    /uses: actions\/checkout@/ { c++ }
    /persist-credentials: false/ { p++ }
    END { exit !(c > 0 && c == p) }
  ' "$WORKFLOW"
  assert_success
}

# UT-INFRA-489 — a missing GH_PAT secret fails the job before AWS
# credentials are configured and before any checkout of the three
# application repos (FR45: "before any production change, naming the
# missing secret").
@test "UT-INFRA-489: deploy-production.yml verifies GH_PAT before AWS credentials / app-repo checkouts, naming the secret" {
  run grep -n 'GH_PAT:?GH_PAT secret is required' "$WORKFLOW"
  assert_success
  local verify_line aws_line
  verify_line="$(grep -n 'Verify cross-repo checkout credential' "$WORKFLOW" | head -1 | cut -d: -f1)"
  aws_line="$(grep -n 'Configure AWS credentials' "$WORKFLOW" | head -1 | cut -d: -f1)"
  [ -n "$verify_line" ] && [ -n "$aws_line" ] || fail "could not locate both steps"
  [ "$verify_line" -lt "$aws_line" ] || fail "GH_PAT verification (line ${verify_line}) does not precede AWS credential configuration (line ${aws_line})"
}

# UT-INFRA-490 — the service being deployed is checked out at the
# DEPLOYED commit (resolved via the GitHub API from the image tag); the
# other two repositories are checked out at their default branch (no
# `ref:` key on those steps).
@test "UT-INFRA-490: deploy-production.yml pins only the deployed service's repo to the resolved commit" {
  run grep -c "ref: \${{ steps.resolve-commit.outputs.deployed_sha }}" "$WORKFLOW"
  assert_success
  assert_output "3"   # one pinned-checkout step per repo, gated by if: == <service>
  run grep -c "^      - name: Checkout .* (default branch)" "$WORKFLOW"
  assert_success
  assert_output "3"
}

# UT-INFRA-491 — AXIOME_BACK_PATH is exported to the deploy step so
# scripts/seed-environment.sh --check stops guessing a sibling directory.
@test "UT-INFRA-491: deploy-production.yml exports AXIOME_BACK_PATH to the deploy step" {
  run grep -n "AXIOME_BACK_PATH: \${{ github.workspace }}/axiome-back" "$WORKFLOW"
  assert_success
}

# --- AXI-1968 Item G (FR63): the resolve-commit step's own diagnostic -----

# UT-INFRA-630 — the "Resolve deployed commit" step scrubs the GitHub API
# response through report.sh's report_is_secret_value before ever printing
# it (sourcing axiome-infra/scripts/lib/report.sh, checked out as the very
# first step in this job, rather than reinventing a look-alike check) —
# and bounds how much of the response it will ever print.
@test "UT-INFRA-630: deploy-production.yml scrubs the resolve-commit step's API response before printing it" {
  run grep -n "report_is_secret_value" "$WORKFLOW"
  assert_success
  run grep -n "scripts/lib/report.sh" "$WORKFLOW"
  assert_success
  run grep -n "head -c 2000" "$WORKFLOW"
  assert_success
}

# UT-INFRA-631 — the resolve-commit step never runs curl with -v/--verbose
# or `set -x` (either would echo the Authorization header, i.e. GH_PAT,
# to the job log) anywhere in the whole workflow.
@test "UT-INFRA-631: deploy-production.yml never traces/verboses a curl call carrying GH_PAT" {
  run bash -c "grep -vE '^[[:space:]]*#' '${WORKFLOW}' | grep -nE -- '(^|[^#[:alnum:]_-])(-v |--verbose|set -x)'"
  assert_failure
}
