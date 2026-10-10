#!/usr/bin/env bats
# tests/dev-auto-promote-workflow.bats — .github/workflows/dev-auto-promote.yml
# (AXI-1953, epic AXI-1944, FR13/AC27). UT-INFRA-306..309 are structural-only
# (no workflow runner, just `python3 -c 'import yaml'`, same as
# tests/compose-structure.bats). UT-INFRA-322..325 (review bounce #1) go one
# step further: they extract the "Emit Qualification Record" step's `run:`
# text and actually EXECUTE it (as plain bash, not via a GHA runner) against
# a synthetic roll-output.log, to prove its three-way branch (facts
# unavailable -> fail / no facts -> pass, nothing to qualify / facts present
# -> build the record) really works, not just that it parses.
#
# NOTE on UT-ID range: AXI-1953 owns UT-INFRA-280..319. UT-INFRA-322..328
# overrun into AXI-1954's reserved 320..379 block (320/321 were already
# used by tests/generate-qualification-record.bats) — flagged explicitly in
# the handback. Per the coordinator (review bounce #2), UT-INFRA-326..328
# are assigned from that same pool with the coordinator's explicit go-ahead
# ("I will move the next story's range").
#
# UT-INFRA-326..328 (review bounce #2) cover the required fix: a step with
# no `shell:` key runs as `bash -e {0}` WITHOUT pipefail, so `ssh | tee`
# reported `tee`'s exit code, not the remote roll's, letting a failed roll
# look like a passing step.
#
# The extracted step script unconditionally computes
# GATEWAY_URL="https://${DEV_HOST}" and generate-qualification-record.sh
# probes it with curl for the RBAC-reachable/PQ-latency checks — those are
# incidental to the MIGRATION_FACTS branch logic under test here, so
# tests/fixtures/dev-auto-promote-qual.rules.sh answers curl (and the
# git/terraform metadata calls) deterministically via the PATH-shim stub,
# the same as every other *.bats file. No real network/box access occurs;
# DEV_HOST is left unset (the fixture matches on the curl flags, not the
# target URL).

load 'helpers/setup'

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/dev-auto-promote.yml"

setup() {
  stub_setup
  stub_use_rules curl "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  stub_use_rules git "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  stub_use_rules terraform "${TESTS_DIR}/fixtures/dev-auto-promote-qual.rules.sh"
  export WORKDIR="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${WORKDIR}/scripts"
  cp "${BATS_TEST_DIRNAME}/../scripts/generate-qualification-record.sh" "${WORKDIR}/scripts/"
  # The roll step's `run:` text does `< scripts/roll-service.sh` — only its
  # EXISTENCE matters here (ssh is stubbed and never actually reads it).
  : > "${WORKDIR}/scripts/roll-service.sh"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  mkdir -p "${REPORTS_DIR}"
}

# Executes the real "Roll service on dev VM" step script in WORKDIR, with
# the given ssh fixture standing in for the remote roll-service.sh.
run_roll_step() {
  local ssh_rules="$1"
  stub_use_rules ssh "${TESTS_DIR}/fixtures/${ssh_rules}"
  local script
  script="$(roll_step_run)"
  (cd "${WORKDIR}" && \
    KEY=BACKEND_IMAGE_TAG IMAGE_TAG=sha-new123 SERVICE=backend \
    DEV_USER=ubuntu DEV_HOST=dev.example.test SSM_PARAMETER_PREFIX=/dev/axiome-dev \
    bash -c "${script}")
}

py() {
  python3 -c "$1" "$WORKFLOW"
}

roll_step_run() {
  py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['deploy']['steps']
for s in steps:
    if s.get('name') == 'Roll service on dev VM':
        print(s['run'])
        sys.exit(0)
sys.exit(1)
"
}

qual_step_run() {
  py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['deploy']['steps']
for s in steps:
    if s.get('name') == 'Emit Qualification Record':
        print(s['run'])
        sys.exit(0)
sys.exit(1)
"
}

# Writes the given roll-output.log content into WORKDIR and executes the
# real "Emit Qualification Record" step script there (REPORTS_DIR is
# exported by setup() so generate-qualification-record.sh never touches the
# real axiome-docs/reports/infra tree).
run_qual_step() {
  printf '%s\n' "$1" > "${WORKDIR}/roll-output.log"
  local script
  script="$(qual_step_run)"
  # review bounce #2: the step now runs under `set -euo pipefail`, so
  # DEV_HOST (used unquoted in GATEWAY_URL="https://${DEV_HOST}") must be
  # exported here — real GHA supplies it from the workflow-level env: block.
  (cd "${WORKDIR}" && IMAGE_TAG="sha-new123" REPORTS_DIR="${REPORTS_DIR}" DEV_HOST="dev.example.test" bash -c "${script}")
}

# UT-INFRA-306 — the roll step still runs scripts/roll-service.sh (the
# single gated start path) and nothing else starts containers.
@test "UT-INFRA-306: dev-auto-promote.yml rolls only through roll-service.sh" {
  run roll_step_run
  assert_success
  assert_output --partial "scripts/roll-service.sh"
}

# UT-INFRA-307 — the roll step passes SSM_PARAMETER_PREFIX through to the
# remote roll-service.sh invocation (FR12 — the roll refreshes .env from
# SSM after recording the image tag it is rolling).
@test "UT-INFRA-307: dev-auto-promote.yml passes SSM_PARAMETER_PREFIX to the roll" {
  run roll_step_run
  assert_success
  assert_output --partial "SSM_PARAMETER_PREFIX="
}

# UT-INFRA-308 — no `run:` step anywhere in the workflow passes --no-deps
# to docker compose (comments documenting the design are not steps).
@test "UT-INFRA-308: dev-auto-promote.yml never bypasses the gate with --no-deps" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['deploy']['steps']:
    assert '--no-deps' not in (s.get('run') or ''), s.get('name')
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-309 — the trigger is unchanged: only repository_dispatch
# image-published starts a roll (no push/schedule trigger was added that
# could fire unexpectedly on merge).
@test "UT-INFRA-309: dev-auto-promote.yml still triggers only on repository_dispatch" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d[True] if True in d else d['on']
assert set(on.keys()) == {'repository_dispatch'}, on
assert on['repository_dispatch']['types'] == ['image-published']
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-322 — migrations applied: roll-output.log carries this run's
# MIGRATION_FACTS lines with APPLIED>0 for both services; the step passes
# and the generator writes a per-service qualification record.
@test "UT-INFRA-322: Emit Qualification Record builds a record when migrations were applied" {
  run run_qual_step "=== Rolling backend -> sha-new123 ===
MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261001 APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13
MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261001 APPLIED=1 PRE_COUNTS=5 POST_COUNTS=6
=== Roll complete: backend -> sha-new123 ==="
  assert_success
  rec="$(ls -t "${REPORTS_DIR}"/*.md | head -1)"
  run grep -F "Applied 4 migration(s) across 2 service(s) this run." "$rec"
  assert_success
}

# UT-INFRA-323 — nothing pending: both services report APPLIED=0 (migrate
# ran, found nothing to do); the step still passes and the record says so
# plainly rather than implying a migration happened.
@test "UT-INFRA-323: Emit Qualification Record passes and says so when nothing was pending" {
  run run_qual_step "=== Rolling backend -> sha-new123 ===
MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261001 APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20261001 APPLIED=0 PRE_COUNTS=skipped POST_COUNTS=skipped
=== Roll complete: backend -> sha-new123 ==="
  assert_success
  rec="$(ls -t "${REPORTS_DIR}"/*.md | head -1)"
  run grep -F "No migration applied this run across 2 service(s) — schema was already current." "$rec"
  assert_success
}

# UT-INFRA-324 — facts unavailable: the gate passed (containers serving)
# but roll-service.sh could not read this run's facts. The step must FAIL
# (distinct from both the pass-with-record and pass-nothing-to-qualify
# cases) and must never attempt to build a record from stale/absent data.
@test "UT-INFRA-324: Emit Qualification Record fails when facts are unavailable" {
  run run_qual_step "=== Rolling backend -> sha-new123 ===
MIGRATION_FACTS_UNAVAILABLE: migrate succeeded but no MIGRATION_FACTS line was found for this run
=== Roll complete: backend -> sha-new123 ==="
  assert_failure
  assert_output --partial "::error::"
  assert_output --partial "MIGRATION_FACTS_UNAVAILABLE"
  run bash -c "ls \"${REPORTS_DIR}\"/*.md 2>/dev/null"
  assert_failure
}

# UT-INFRA-325 — a non-backend (biocompute/frontend) roll never prints any
# MIGRATION_FACTS/_OVERRIDE/_UNAVAILABLE line at all: the step passes with
# "nothing to qualify" and never calls the generator.
@test "UT-INFRA-325: Emit Qualification Record passes with nothing to qualify on a non-backend roll" {
  run run_qual_step "=== Rolling biocompute -> sha-new123 ===
=== Roll complete: biocompute -> sha-new123 ==="
  assert_success
  assert_output --partial "nothing to qualify"
  run bash -c "ls \"${REPORTS_DIR}\"/*.md 2>/dev/null"
  assert_failure
}

# UT-INFRA-326 — review bounce #2 (required): a step with no `shell:` key
# runs as `bash -e {0}` WITHOUT `pipefail`, so `ssh ... | tee` reported
# `tee`'s exit status (always 0) instead of the remote roll's — a failed
# roll left this step green. This executes the REAL "Roll service on dev
# VM" step script with a stubbed `ssh` that fails (exit 1, after printing
# some progress, the same shape as a real FAIL-CLOSED roll) and asserts the
# step script itself exits non-zero. If `set -euo pipefail` (or `shell:
# bash`, which GitHub Actions maps to the same `-eo pipefail`) were ever
# removed, this test would start passing on a status that should be 0 —
# i.e. it would go from `ok` to silently matching a wrong expectation only
# if BOTH were removed from the extracted text; dropping just the inline
# `set -euo pipefail` line still fails because `shell: bash` alone also
# gets `-eo pipefail` from GitHub Actions — see UT-INFRA-327 for the
# `shell: bash` static check.
@test "UT-INFRA-326: Roll service on dev VM step fails when the remote roll fails" {
  run run_roll_step "ssh-roll-fail.rules.sh"
  assert_failure
  assert_output --partial "FAIL-CLOSED"
}

# UT-INFRA-327 — static check: the "Roll service on dev VM" step declares
# `shell: bash` explicitly (review bounce #2) rather than relying on the
# workflow/job-level default (there is none here) or GitHub's un-shelled
# `bash -e {0}` fallback, which drops `pipefail`.
@test "UT-INFRA-327: dev-auto-promote.yml declares shell: bash on the roll step" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['deploy']['steps']:
    if s.get('name') == 'Roll service on dev VM':
        assert s.get('shell') == 'bash', s.get('shell')
        print('OK')
        sys.exit(0)
sys.exit(1)
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-328 — review bounce #2 (required): a failed roll can still leave
# roll-output.log holding a MIGRATION_FACTS: line from a service that
# migrated successfully BEFORE the one that failed. The qualification step
# must refuse such a log by its OWN logic (not only by relying on the roll
# step's exit code) — no record is written, and the step exits non-zero.
@test "UT-INFRA-328: Emit Qualification Record refuses a failed roll even with a facts line present" {
  run run_qual_step "=== Rolling backend -> sha-new123 ===
MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20261001 APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13
=== docker compose up -d gateway user-service organization-service event-service ===
FAIL-CLOSED: roll aborted — the migration gate did not pass. Previous containers keep serving."
  assert_failure
  assert_output --partial "::error::"
  run bash -c "ls \"${REPORTS_DIR}\"/*.md 2>/dev/null"
  assert_failure
}
