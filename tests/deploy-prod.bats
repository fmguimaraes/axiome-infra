#!/usr/bin/env bats
# tests/deploy-prod.bats — scripts/deploy-prod.sh (AXI-1954, epic AXI-1944,
# FR14-21/EC1/EC13/AC11-14/18/19/28). UT-INFRA-330..352.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/deploy-prod.sh"

setup() {
  stub_setup
  command -v jq >/dev/null 2>&1 || skip "jq not installed on this host"
  stub_use_rules aws "${TESTS_DIR}/fixtures/deploy-prod-aws.rules.sh"
  stub_use_rules curl "${TESTS_DIR}/fixtures/deploy-prod-curl.rules.sh"
  export REPORT_REPO_ROOT="${BATS_TEST_TMPDIR}"
  export REPORTS_DIR="${BATS_TEST_TMPDIR}/reports"
  export SSM_EXEC_POLL_INTERVAL=0
  export HEALTH_POLL_INTERVAL=0
  export HEALTH_RETRIES=1
  export SSM_PREFLIGHT_WAIT=5
  export SSM_ROLL_WAIT=5
  export AWS_REGION="eu-west-3"
  export AXIOME_PROJECT="axiome"
  export ENV="production"
  export SERVICE="backend"
  export TAG="newtag123"
  export DEPLOY_FIXTURE_TAG="newtag123"
  export DEPLOY_FIXTURE_PRIOR="oldtag000"
  export DEPLOY_FIXTURE_READY_COUNTER="${BATS_TEST_TMPDIR}/ready.counter"
  export DEPLOY_FIXTURE_LOCK_TOKEN_FILE="${BATS_TEST_TMPDIR}/lock.token"
  export LOCK_ACTOR="test@example.com"
}

# UT-INFRA-330 — the full success path: lock taken, preflight OK, no pending
# migrations (no snapshot), roll succeeds, readiness passes, :stable
# advances LAST, baseline check runs, lock released.
@test "UT-INFRA-330: deploy-prod.sh full success path advances :stable last and releases the lock" {
  run "$SCRIPT"
  assert_success
  assert_output --partial "Deploy OK"
  assert_stub_called aws "put-image"
  run grep -F "locks/deploy.json" "$STUB_LOG"
  assert_success
  assert_stub_called aws "delete-object"
}

# UT-INFRA-331 — EC1: the box is stopped (no running instance) at preflight.
# The deploy fails before any mutation; :stable is never touched.
@test "UT-INFRA-331: deploy-prod.sh fails closed before any mutation when the box is unreachable (EC1)" {
  export DEPLOY_FIXTURE_INSTANCE_MISSING=1
  run "$SCRIPT"
  assert_failure
  assert_output --partial "FAIL-CLOSED"
  assert_stub_not_called_substring "put-image"
  assert_stub_called aws "delete-object"
}

assert_stub_not_called_substring() {
  run grep -F "$1" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-332 — FR28/AC19: a held deploy lock refuses and names the holder;
# no ECR call is ever made.
@test "UT-INFRA-332: deploy-prod.sh refuses when the deploy lock is held, naming the holder" {
  export DEPLOY_FIXTURE_DEPLOY_LOCK_STATE=held
  run "$SCRIPT"
  assert_failure
  assert_output --partial "other@example.com"
  assert_stub_not_called_substring "describe-images"
}

# UT-INFRA-333 (CHANGED by AXI-1967, FR42/FR43) — a held/unknown data-tier
# lock refuses a deploy, but the ORDER changed: FR43 requires acquire-then-
# check (acquire the deploy lock FIRST, then verify data-tier/apply free),
# not the old check-then-acquire (which left a window where two operations
# could both see the others free and both proceed). So this now DOES touch
# locks/deploy.json — it is acquired, then released when data-tier is found
# held, leaving nothing behind. See UT-INFRA-408 for the replacement
# assertion; this test id is kept (not deleted) with its assertions updated
# to match, per the "list any you change and why" instruction.
@test "UT-INFRA-333: deploy-prod.sh acquires then releases the deploy lock when data-tier is held (FR43)" {
  export DEPLOY_FIXTURE_DATATIER_STATE=held
  run "$SCRIPT"
  assert_failure
  assert_output --partial "data-tier"
  run grep -F "locks/deploy.json" "$STUB_LOG"
  assert_success
  assert_stub_called aws "delete-object"
  assert_stub_not_called_substring "describe-images"
}

# UT-INFRA-334 — EC13: a frontend deploy skips the migrate/snapshot/baseline
# steps but still takes the lock, rolls and advances :stable.
@test "UT-INFRA-334: deploy-prod.sh skips migrate/snapshot/baseline for a non-backend service (EC13)" {
  export SERVICE="frontend"
  export DEPLOY_FIXTURE_READY_SEQUENCE="200"
  run "$SCRIPT"
  assert_success
  # "carries no schema" is a report_line (written only into the markdown
  # report buffer, never to stdout) — assert against the report file, not
  # --output, or this would vacuously pass no matter what the script wrote.
  run bash -c "grep -l 'carries no schema' ${REPORTS_DIR}/*.md"
  assert_success
  # assert_stub_not_called(name) only checks whether `aws` was called AT
  # ALL (it takes no needle) — aws legitimately runs many other calls in
  # this path, so use the local substring helper instead or this would
  # always fail regardless of whether create-db-snapshot specifically ran.
  assert_stub_not_called_substring "create-db-snapshot"
  assert_stub_called aws "put-image"
}

# UT-INFRA-335 — NFR7/AC8: an unconverted box (no migrate: service) refuses
# and names the asset-sync command; no roll is attempted; :stable untouched.
@test "UT-INFRA-335: deploy-prod.sh refuses an unconverted box, naming asset-sync.sh" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=absent\n'
  run "$SCRIPT"
  assert_failure
  assert_output --partial "REFUSE"
  assert_output --partial "asset-sync.sh"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-336 (review bounce #1) — a non-zero `migrate-gate status` is NOT,
# by itself, evidence that any service needs baselining (confirmed by
# reading axiome-back's status.js: it folds a missing ledger into "every
# migration pending" and exits 0 — see UT-INFRA-366..368 for the full
# classification). A generic unreadable status still refuses (no :stable
# advance) but must NOT instruct an operator to baseline.
@test "UT-INFRA-336: deploy-prod.sh refuses an undetermined status without instructing baseline" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=1\nFAIL organization-service: could not determine status: connect ECONNREFUSED\n'
  run "$SCRIPT"
  assert_failure
  assert_output --partial "REFUSE"
  assert_output --partial "NOT evidence"
  refute_output --partial "Run: migrate-gate baseline"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-366 (review bounce #1, case a) — `migrate-gate`'s OWN ledger-less
# refusal line (quoted verbatim from axiome-back origin/main 5516e5be,
# docker/migrate-gate/lib/apply.js: `REFUSE <service>: tables exist with no
# migration ledger. Run: migrate-gate baseline <service>`) in the captured
# output is the ONLY case that may name `baseline`, and it must name the
# SAME service the output named.
@test "UT-INFRA-366: deploy-prod.sh names baseline + the exact service when the output carries migrate-gate's own ledger-less refusal" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=1\nREFUSE user-service: tables exist with no migration ledger. Run: migrate-gate baseline user-service\n'
  run "$SCRIPT"
  assert_failure
  assert_output --partial "REFUSE"
  assert_output --partial "migrate-gate baseline user-service"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-367 (review bounce #1, case b) — a connectivity error (no
# ledger-less refusal line present) must show the verbatim output and must
# NOT suggest baseline as the remedy. Mutation-check: this assertion fails
# against the pre-bounce code (which always said "at least one service has
# tables but no migration ledger" / "migrate-gate baseline <service>" for
# ANY non-zero status).
@test "UT-INFRA-367: deploy-prod.sh shows the verbatim connectivity error and never suggests baseline" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=1\nFAIL organization-service: could not determine status: connect ECONNREFUSED 10.0.0.5:5432\n'
  run "$SCRIPT"
  assert_failure
  assert_output --partial "configuration or connectivity"
  assert_output --partial "FAIL organization-service: could not determine status: connect ECONNREFUSED 10.0.0.5:5432"
  refute_output --partial "Run: migrate-gate baseline"
}

# UT-INFRA-368 (review bounce #1, case c) — a missing database URL
# (`not_configured`) is the same connectivity/configuration class, not a
# ledger problem: same verbatim-output treatment, same absence of a
# baseline instruction.
@test "UT-INFRA-368: deploy-prod.sh treats a missing database URL the same as a connectivity error, never baseline" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=1\nFAIL user-service: USER_DATABASE_URL not set\n'
  run "$SCRIPT"
  assert_failure
  assert_output --partial "configuration or connectivity"
  assert_output --partial "FAIL user-service: USER_DATABASE_URL not set"
  refute_output --partial "Run: migrate-gate baseline"
}

# UT-INFRA-337 — FR16/FR17: pending migrations on production take a
# pre-deploy snapshot (and wait for it) before rolling, and prune beyond
# retention.
@test "UT-INFRA-337: deploy-prod.sh takes a pre-deploy snapshot when migrations are pending (FR16/FR17)" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=0\nPENDING 1 20250101\nPENDING_COUNT=1\n'
  export SNAPSHOT_RETENTION=1
  # Three entries as prune_old_snapshots itself sees them (via the stubbed
  # describe-db-snapshots response): two old ones, and a third dated newest
  # — standing in for "the just-taken pre-deploy snapshot" (review bounce
  # #1 item 7). With retention=1, only the newest may survive.
  export DEPLOY_FIXTURE_SNAPSHOT_LIST=$'axiome-production-predeploy-20250101000000\t2025-01-01T00:00:00Z\naxiome-production-predeploy-20250102000000\t2025-01-02T00:00:00Z\naxiome-production-predeploy-20250103000000\t2025-01-03T00:00:00Z'
  run "$SCRIPT"
  assert_success
  run grep -F "create-db-snapshot" "$STUB_LOG"
  assert_success
  run grep -F "wait" "$STUB_LOG"
  assert_success
  assert_stub_called aws "delete-db-snapshot"
  # The two oldest are pruned, both carrying the axiome-<env>-predeploy-
  # prefix; the newest (just-taken) one is never deleted. Each CALL block
  # in STUB_LOG is one argv element per line, so pull out only the blocks
  # that are an actual delete-db-snapshot call before asserting on ids.
  run awk '
    /^### CALL: aws$/{blk=""; in_call=1; next}
    in_call && /^### END$/{print blk; blk=""; in_call=0; next}
    in_call{blk = blk $0 "\n"}
  ' "$STUB_LOG"
  assert_success
  DELETE_CALLS="$(printf '%s' "$output" | awk -v RS='' '/delete-db-snapshot/')"
  echo "${DELETE_CALLS}" | grep -qF "axiome-production-predeploy-20250101000000"
  echo "${DELETE_CALLS}" | grep -qF "axiome-production-predeploy-20250102000000"
  ! echo "${DELETE_CALLS}" | grep -qF "axiome-production-predeploy-20250103000000"
}

# UT-INFRA-338 — FR16: no pending migrations takes no snapshot.
@test "UT-INFRA-338: deploy-prod.sh takes no snapshot when nothing is pending" {
  run "$SCRIPT"
  assert_success
  run grep -F "create-db-snapshot" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-339 — a snapshot failure stops the deploy before migrating;
# :stable untouched; no roll attempted.
@test "UT-INFRA-339: deploy-prod.sh stops before migrating when the snapshot fails" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=0\nPENDING_COUNT=1\n'
  export DEPLOY_FIXTURE_SNAPSHOT_CREATE_RC=1
  run "$SCRIPT"
  assert_failure
  assert_output --partial "FAIL-CLOSED"
  assert_stub_not_called_substring "put-image"
  # The preflight step itself is one SSM round-trip (send-command), so a
  # bare "send-command" substring would also match it and pass vacuously
  # even if the roll DID run — check for the roll's own command-id instead.
  assert_stub_not_called_substring "cmd-roll"
}

# UT-INFRA-340 — FR18/AC2: a migration-gate failure during the roll restores
# the previous tag (via roll-service.sh, re-rolled to PRIOR_TAG) and
# confirms it; :stable is never advanced.
@test "UT-INFRA-340: deploy-prod.sh restores the previous tag when the roll's gate fails" {
  export DEPLOY_FIXTURE_ROLL_RC=1
  export DEPLOY_FIXTURE_READY_SEQUENCE="200"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "FAIL-CLOSED"
  assert_output --partial "Restoring"
  assert_output --partial "confirmed"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-341 — the restore roll ALSO fails: deploy says so loudly and
# names the manual recovery command; :stable still untouched.
@test "UT-INFRA-341: deploy-prod.sh reports loudly when the restore roll also fails" {
  export DEPLOY_FIXTURE_ROLL_RC=1
  export DEPLOY_FIXTURE_RESTORE_RC=1
  run "$SCRIPT"
  assert_failure
  assert_output --partial "ALSO FAILED"
  assert_output --partial "Manual intervention required"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-342 — FR20: an INDETERMINATE roll result never advances :stable
# and never attempts a blind restore roll.
@test "UT-INFRA-342: deploy-prod.sh never advances :stable or auto-restores on an INDETERMINATE roll" {
  export DEPLOY_FIXTURE_ROLL_RC=2
  run "$SCRIPT"
  assert_failure
  assert_output --partial "INDETERMINATE"
  assert_output --partial "Before retrying"
  run grep -F "cmd-restore" "$STUB_LOG"
  assert_failure
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-343 — AC12/FR15: a readiness failure after a successful roll
# restores the previous tag and confirms it; :stable untouched.
@test "UT-INFRA-343: deploy-prod.sh restores the previous tag when readiness fails (AC12)" {
  export DEPLOY_FIXTURE_READY_SEQUENCE="503,200"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "did not become ready"
  assert_output --partial "database_unreachable"
  assert_output --partial "confirmed"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-370 (review bounce #1, item 3) — a gate failure during the roll
# states plainly that migrations may have PARTIALLY applied, the schema's
# state relative to the restored image is UNKNOWN, and (with no pending
# migrations/no snapshot this run) that there is no automatic point-in-time
# rollback path.
@test "UT-INFRA-370: deploy-prod.sh's roll-failure report states partial-migration risk and no snapshot available" {
  export DEPLOY_FIXTURE_ROLL_RC=1
  export DEPLOY_FIXTURE_READY_SEQUENCE="200"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "may have PARTIALLY applied"
  assert_output --partial "UNKNOWN"
  assert_output --partial "No pre-deploy snapshot was taken"
}

# UT-INFRA-371 (review bounce #1, item 3) — when a pre-deploy snapshot WAS
# taken this run, the same roll-failure caveat must name its exact id as
# the point-in-time rollback path (never auto-restored).
@test "UT-INFRA-371: deploy-prod.sh's roll-failure report names the pre-deploy snapshot id when one was taken" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=0\nPENDING_COUNT=1\n'
  export DEPLOY_FIXTURE_ROLL_RC=1
  export DEPLOY_FIXTURE_READY_SEQUENCE="200"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "may have PARTIALLY applied"
  assert_output --regexp "pre-deploy snapshot axiome-production-predeploy-[0-9]+ is the point-in-time rollback path"
  assert_output --partial "does NOT restore it automatically"
}

# UT-INFRA-372 (review bounce #1, item 3) — the INDETERMINATE path carries
# the same partial-migration/unknown-schema caveat.
@test "UT-INFRA-372: deploy-prod.sh's INDETERMINATE report states partial-migration risk" {
  export DEPLOY_FIXTURE_ROLL_RC=2
  run "$SCRIPT"
  assert_failure
  assert_output --partial "may have PARTIALLY applied"
  assert_output --partial "UNKNOWN"
}

# UT-INFRA-373 (review bounce #1, item 3) — a readiness failure AFTER a
# successful roll is different: the gate definitely completed, so the
# schema is definitely ahead of the restored (older) image, not merely
# "may be" — state that with certainty, never "partially"/"unknown".
@test "UT-INFRA-373: deploy-prod.sh's readiness-failure report states the schema is definitely ahead, not merely possibly" {
  export DEPLOY_FIXTURE_READY_SEQUENCE="503,200"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "schema is now fully migrated"
  assert_output --partial "does NOT undo the schema change"
  refute_output --partial "may have PARTIALLY applied"
}

# UT-INFRA-344 — AC11/FR14: :stable advances strictly AFTER the roll's
# `up -d` call in the log, never before.
@test "UT-INFRA-344: deploy-prod.sh advances :stable only after the roll completes (ordering, FR14)" {
  run "$SCRIPT"
  assert_success
  run awk '
    /put-image/ { putline=NR }
    /cmd-roll/ { rollline=NR }
    END { exit !(putline > rollline) }
  ' "$STUB_LOG"
  assert_success
}

# UT-INFRA-345 — FR21/AC28: a baseline mismatch is a warning, never a
# rollback — the deploy still succeeds and :stable still advances.
@test "UT-INFRA-345: deploy-prod.sh treats a baseline mismatch as a warning only (FR21)" {
  cat > "${BATS_TEST_TMPDIR}/fake-seed-environment.sh" <<'EOF'
#!/usr/bin/env bash
echo "system rule pack 5 4 MISMATCH"
exit 1
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  export SEED_ENVIRONMENT_SCRIPT="${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  run "$SCRIPT"
  assert_success
  assert_output --partial "MISMATCH"
  assert_output --partial "Deploy OK"
  assert_stub_called aws "put-image"
}

# UT-INFRA-374 — FR21/AC28: a baseline MATCH (seed-environment.sh --check
# exits 0) is reported as OK, never as MISMATCH or NOT PERFORMED.
@test "UT-INFRA-374: deploy-prod.sh records a baseline match as OK" {
  cat > "${BATS_TEST_TMPDIR}/fake-seed-environment.sh" <<'EOF'
#!/usr/bin/env bash
echo "system rule pack 5 5 OK"
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  export SEED_ENVIRONMENT_SCRIPT="${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  run "$SCRIPT"
  assert_success
  assert_output --partial "OK"
  refute_output --partial "MISMATCH"
  refute_output --partial "NOT PERFORMED"
  assert_output --partial "report:"
  REPORT_FILE="$(echo "$output" | sed -n 's/^.*report: //p')"
  run cat "${REPORT_FILE}"
  assert_output --partial "Baseline verification: OK"
}

# UT-INFRA-375 — FR21/AC28 (review bounce #1 item 4): seed-environment.sh
# --check exiting 3 (expected counts unavailable, e.g. axiome-back not
# checked out in deploy-production.yml) is reported as NOT PERFORMED, never
# as MISMATCH — that would be a false claim of a real count difference.
@test "UT-INFRA-375: deploy-prod.sh records expected-counts-unavailable as NOT PERFORMED, not MISMATCH" {
  cat > "${BATS_TEST_TMPDIR}/fake-seed-environment.sh" <<'EOF'
#!/usr/bin/env bash
echo "BASELINE CHECK NOT PERFORMED: expected counts could not be derived — axiome-back is not checked out." >&2
exit 3
EOF
  chmod +x "${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  export SEED_ENVIRONMENT_SCRIPT="${BATS_TEST_TMPDIR}/fake-seed-environment.sh"
  run "$SCRIPT"
  assert_success
  assert_output --partial "NOT PERFORMED"
  assert_output --partial "Deploy OK"
  assert_output --partial "report:"
  REPORT_FILE="$(echo "$output" | sed -n 's/^.*report: //p')"
  run cat "${REPORT_FILE}"
  assert_output --partial "Baseline verification: NOT PERFORMED"
  refute_output --partial "Baseline verification: MISMATCH"
}

# UT-INFRA-346 — FR7: MIGRATION_FACTS lines from a successful roll are
# captured into the deploy report.
@test "UT-INFRA-346: deploy-prod.sh captures MIGRATION_FACTS lines into the report" {
  export DEPLOY_FIXTURE_ROLL_OUT=$'MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=v1 APPLIED=1 PRE_COUNTS=1 POST_COUNTS=2\n=== Roll complete: backend -> newtag123 ==='
  run "$SCRIPT"
  assert_success
  run bash -c "grep -l 'MIGRATION_FACTS: SERVICE=organization-service' ${REPORTS_DIR}/*.md"
  assert_success
}

# UT-INFRA-347 — an unavailable-facts result is recorded as a WARNING and
# does not fail the deploy (the containers are already proven serving by
# readiness).
@test "UT-INFRA-347: deploy-prod.sh records MIGRATION_FACTS_UNAVAILABLE as a warning, not a failure" {
  export DEPLOY_FIXTURE_ROLL_OUT=$'=== Roll complete: backend -> newtag123 ==='
  run "$SCRIPT"
  assert_success
  assert_output --partial "Deploy OK"
}

# UT-INFRA-348 — FR19: dry-run prints pending migrations and mutates
# nothing — no lock, no retag, no roll.
@test "UT-INFRA-348: deploy-prod.sh --dry-run reports the plan and mutates nothing" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=0\nPENDING 1 20250101\nPENDING_COUNT=1\n'
  run "$SCRIPT" --dry-run
  assert_success
  assert_output --partial "DRY-RUN"
  assert_output --partial "PENDING 1 20250101"
  assert_stub_not_called_substring "locks/deploy.json"
  assert_stub_not_called_substring "put-image"
  run grep -F "cmd-roll" "$STUB_LOG"
  assert_failure
}

# UT-INFRA-349 — FR19: dry-run with an unreachable box states plainly that
# pending migrations could not be determined.
@test "UT-INFRA-349: deploy-prod.sh --dry-run states it could not determine migrations when unreachable" {
  export DEPLOY_FIXTURE_INSTANCE_MISSING=1
  run "$SCRIPT" --dry-run
  assert_success
  assert_output --partial "could not determine"
  assert_output --partial "was not reachable over SSM"
}

# UT-INFRA-369 (review bounce #1, item 2) — a box that WAS reached but
# refused the preflight (e.g. an unconverted box) must not be reported as
# "not reachable" — that is a different, false, claim. Mutation-check: this
# assertion fails against the pre-bounce code (which always said "was not
# reachable over SSM" for any run_preflight failure, reachable or not).
@test "UT-INFRA-369: deploy-prod.sh --dry-run distinguishes a reachable-but-refused box from an unreachable one" {
  export DEPLOY_FIXTURE_PREFLIGHT_OUT=$'PRIOR_TAG=oldtag000\nCOMPOSE_GATE=absent\n'
  run "$SCRIPT" --dry-run
  assert_success
  assert_output --partial "could not determine"
  assert_output --partial "WAS reachable but the preflight check refused"
  refute_output --partial "was not reachable over SSM"
}

# UT-INFRA-350 — advancing :stable fails after a healthy roll: loud
# message, non-zero exit; the box keeps serving the new (healthy) tag.
@test "UT-INFRA-350: deploy-prod.sh reports loudly when advancing :stable fails after a healthy roll" {
  export DEPLOY_FIXTURE_RETAG_RC=1
  run "$SCRIPT"
  assert_failure
  assert_output --partial "advancing ECR :stable FAILED"
  assert_output --partial "does NOT point at"
}

# UT-INFRA-378 — review bounce #1 item 5: TAG's digest moves (something
# re-pushed it) between preflight and the :stable retag step. deploy-prod.sh
# must refuse to advance :stable to a digest it never actually rolled out
# and verified ready, say the tag moved during the deploy, exit non-zero,
# and say explicitly that the roll itself already succeeded (no restore).
@test "UT-INFRA-378: deploy-prod.sh refuses to advance :stable when TAG's digest moved during the deploy" {
  export DEPLOY_FIXTURE_DESCRIBE_CALL_COUNT_FILE="${BATS_TEST_TMPDIR}/describe-calls"
  export DEPLOY_FIXTURE_SOURCE_DIGEST_RETAG="sha256:movedduringdeploy"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "moved during this deploy"
  assert_output --partial "Refusing to advance :stable"
  assert_output --partial "roll itself already succeeded"
  assert_stub_not_called_substring "put-image"
}

# UT-INFRA-379 — review bounce #1 item 6: the data-tier lock is re-checked
# immediately after preflight (before the snapshot/roll step), catching a
# park that started DURING preflight — narrows, does not close, the race.
@test "UT-INFRA-379: deploy-prod.sh re-checks the data-tier lock after preflight and before snapshot/roll" {
  export DEPLOY_FIXTURE_DATATIER_STATE_RACE_FILE="${BATS_TEST_TMPDIR}/datatier-race"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "Re-checking the data-tier lock"
  assert_output --partial "now held (parked during preflight)"
  assert_stub_not_called_substring "put-image"
  assert_stub_not_called_substring "rds create-db-snapshot"
}

# UT-INFRA-351 — usage: a missing TAG is a fast usage error, no aws call.
@test "UT-INFRA-351: deploy-prod.sh requires --tag/TAG before any aws call" {
  unset TAG
  run "$SCRIPT"
  assert_failure
  assert_output --partial "required"
  assert_stub_not_called aws
}

# UT-INFRA-352 — usage: an unknown --service is rejected before any aws call.
@test "UT-INFRA-352: deploy-prod.sh rejects an unknown --service before any aws call" {
  run "$SCRIPT" --service bogus
  assert_failure
  assert_output --partial "unknown SERVICE"
  assert_stub_not_called aws
}
