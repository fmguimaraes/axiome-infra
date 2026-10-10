#!/usr/bin/env bats
# tests/seed-environment-check.bats — scripts/seed-environment.sh --check
# mode (AXI-1954, FR21/AC28). UT-INFRA-353..357.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/seed-environment.sh"

setup() {
  stub_setup
  stub_use_rules docker "${TESTS_DIR}/fixtures/seed-environment-docker.rules.sh"
  export AXIOME_BACK_PATH="${TESTS_DIR}/fixtures/seed-environment-back"
  export POSTGRES_DB="axiome"
  export POSTGRES_USER="axiome"
}

# UT-INFRA-353 — --check never writes the workspace-roles SQL (Step 1 is
# skipped entirely): a call matching Step 1's exec (no -tAc) would be
# unconfigured in the fixture and fail the test via the teardown contract,
# so a plain --check run completing at all is already most of the proof;
# this also asserts the announcing line.
@test "UT-INFRA-353: seed-environment.sh --check skips the workspace-roles write" {
  run "$SCRIPT" --local --check
  assert_success
  assert_output --partial "skipping the workspace-roles write"
}

# UT-INFRA-354 — --check takes a single read per entity (no settle-wait
# banner) and reports success when counts match.
@test "UT-INFRA-354: seed-environment.sh --check takes one read-only pass, no settle-wait" {
  run "$SCRIPT" --local --check
  assert_success
  assert_output --partial "no settle-wait"
  refute_output --partial "Waiting for organization-service"
  assert_output --partial "BASELINE CHECK OK"
}

# UT-INFRA-355 — --check still exits non-zero on a mismatch (FR21's own
# standalone contract is unchanged; only a CALLER like deploy-prod.sh is
# responsible for treating this as a warning).
@test "UT-INFRA-355: seed-environment.sh --check exits non-zero on a mismatch" {
  export SEED_FIXTURE_ADMIN_COUNT=0
  run "$SCRIPT" --local --check
  assert_failure
  assert_output --partial "BASELINE CHECK MISMATCH"
  assert_output --partial "MISMATCH"
}

# UT-INFRA-356 — a normal (non --check) run still prints the settle-wait
# banner and the original SEED OK/FAILED language, unchanged by FR21.
@test "UT-INFRA-356: seed-environment.sh without --check keeps the original settle/SEED language" {
  # Step 1 in non-check mode writes the roles SQL via run_sql_local — stub
  # that specific call (no -tAc) as a no-op success so this test can reach
  # Step 2 without reconfiguring the whole fixture.
  cat > "${BATS_TEST_TMPDIR}/docker-rules-with-step1.sh" <<EOF
# shellcheck shell=bash
stub_respond() {
  local argv="\$1"
  case "\$argv" in
    *"compose version"*) return 0 ;;
    *"exec -T postgres psql -v ON_ERROR_STOP=1 -U axiome -d axiome"*) return 0 ;;
    *"-tAc"*"organization_svc.rules"*) echo "\${SEED_FIXTURE_RULES_COUNT:-2}"; return 0 ;;
    *"-tAc"*"organization_svc.dataview_templates"*) echo "\${SEED_FIXTURE_TEMPLATES_COUNT:-2}"; return 0 ;;
    *"-tAc"*"user_svc.roles"*) echo "\${SEED_FIXTURE_ROLES_COUNT:-5}"; return 0 ;;
    *"-tAc"*"user_svc.users"*) echo "\${SEED_FIXTURE_ADMIN_COUNT:-1}"; return 0 ;;
    *) return 99 ;;
  esac
}
EOF
  export DOCKER_STUB_RULES="${BATS_TEST_TMPDIR}/docker-rules-with-step1.sh"
  run "$SCRIPT" --local
  assert_success
  assert_output --partial "Waiting for organization-service"
  assert_output --partial "SEED OK"
}

# UT-INFRA-357 — --check is accepted together with -e/-r like the other
# flags (usage parsing only; no actual SSM call is exercised here — that
# path is the same ssm-exec.sh contract already covered by
# tests/ssm-exec.bats and roll-service's remote pattern).
@test "UT-INFRA-357: seed-environment.sh --check is a recognised flag (usage)" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "--check"
}

# UT-INFRA-376 — review bounce #1 item 4: when axiome-back is not checked
# out (or its rule-pack/template files are unreadable, as in
# deploy-production.yml which only checks out axiome-infra), --check exits
# with a DISTINCT code (3) and a "NOT PERFORMED" message — never the
# generic exit-1 "ERROR" used for a real mismatch, so a caller like
# deploy-prod.sh can tell the two apart.
@test "UT-INFRA-376: seed-environment.sh --check exits 3 with NOT PERFORMED when expected counts are unavailable" {
  export AXIOME_BACK_PATH="${BATS_TEST_TMPDIR}/no-such-axiome-back"
  run "$SCRIPT" --local --check
  assert_equal "$status" 3
  assert_output --partial "BASELINE CHECK NOT PERFORMED"
  refute_output --partial "ERROR: could not derive expected counts"
}

# UT-INFRA-377 — the same missing-axiome-back condition in NON --check mode
# keeps the original loud failure (exit 1, "ERROR") — axiome-back missing
# during a REAL seed run is a genuine operator error, not a routine,
# tolerable "not performed" case. (Non-check mode fails earlier, at the
# workspace-roles SQL step, before it would even reach the expected-counts
# derivation — still exit 1 with an ERROR line, never NOT PERFORMED/exit 3.)
@test "UT-INFRA-377: seed-environment.sh without --check still fails loudly (exit 1, ERROR) when axiome-back is missing" {
  export AXIOME_BACK_PATH="${BATS_TEST_TMPDIR}/no-such-axiome-back"
  run "$SCRIPT" --local
  assert_failure
  assert_output --partial "ERROR:"
  refute_output --partial "NOT PERFORMED"
}

# --- AXI-1968: the REMOTE --check path, left untested by AXI-1954 --------
#
# UT-INFRA-357 above only covers usage parsing ("no actual SSM call is
# exercised here"). These three tests exercise the real `-e ENV --check`
# path end to end: aws is stubbed (never docker — the remote path never
# calls this host's docker at all, it ships a one-line `docker run ...`
# command to the box over SSM), so every count_remote()/ssm-exec.sh/aws
# call in this script is genuinely walked.

setup_remote_check() {
  stub_use_rules aws "${TESTS_DIR}/fixtures/seed-environment-remote-check.rules.sh"
  export SSM_EXEC_POLL_INTERVAL=0
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
}

# UT-INFRA-492 — the remote --check path reaches OK when every remote
# count matches: proves count_remote()/ssm-exec.sh/aws send-command +
# get-command-invocation are genuinely exercised (not merely parsed), and
# that CHECK_MODE's single-read, no-settle-wait behaviour holds remotely
# too (never calls `aws ssm cancel-command`, i.e. never hits the
# INDETERMINATE/retry path meant for a real settle-wait).
@test "UT-INFRA-492: seed-environment.sh -e production --check walks the real SSM path and reports OK" {
  setup_remote_check
  run "$SCRIPT" -e production --check
  assert_success
  assert_output --partial "BASELINE CHECK OK"
  refute_output --partial "no running instance"
  run grep -F "cancel-command" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-493 — a genuine remote count mismatch (the bootstrap admin
# missing on the box) is reported the same way the local path reports it:
# non-zero exit, "BASELINE CHECK MISMATCH", the per-entity table shows
# MISMATCH — proving the fixture's per-entity differentiation (by the
# embedded SQL text in `ssm send-command`'s own argv, the only way four
# otherwise-identical polls can be told apart) actually reaches a
# DIFFERENT count for the admin entity than the others.
@test "UT-INFRA-493: seed-environment.sh -e production --check reports a real remote count mismatch" {
  setup_remote_check
  export SEED_FIXTURE_ADMIN_COUNT=0
  run "$SCRIPT" -e production --check
  assert_failure
  assert_output --partial "BASELINE CHECK MISMATCH"
  assert_output --partial "MISMATCH"
}

# UT-INFRA-494 — -e production --check never requires --confirm (read-only
# paths are exempt from the production-seed confirmation gate; AC39 names
# only the WRITE path) — the real SSM round trip above already proves this
# implicitly (no --confirm was passed), this test pins it explicitly so a
# future change to the confirm gate's condition can't silently widen it to
# also block --check.
@test "UT-INFRA-494: seed-environment.sh -e production --check never asks for --confirm" {
  setup_remote_check
  run "$SCRIPT" -e production --check
  assert_success
  refute_output --partial "SEED REFUSED"
}
