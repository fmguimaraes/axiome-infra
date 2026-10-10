#!/usr/bin/env bats
# tests/roll-service.bats — scripts/roll-service.sh (AXI-1953, epic AXI-1944,
# FR13/FR18/FR20/NFR7, AC2/AC8/AC27). UT-INFRA-280..293.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/roll-service.sh"

setup() {
  stub_setup
  stub_use_rules docker "${TESTS_DIR}/fixtures/roll-service-docker.rules.sh"
  export SUDO=""
  export KEY="BACKEND_IMAGE_TAG"
  export IMAGE_TAG="sha-new123"
  export SERVICE="backend"
  ENV_FILE="${BATS_TEST_TMPDIR}/.env"
  COMPOSE_FILE="${BATS_TEST_TMPDIR}/docker-compose.yml"
  REFRESH_ENV_SCRIPT="${BATS_TEST_TMPDIR}/scripts/refresh-env.sh"
  export ENV_FILE COMPOSE_FILE REFRESH_ENV_SCRIPT
  cat > "$ENV_FILE" <<'EOF'
BACKEND_IMAGE_TAG=sha-old
EOF
  write_gated_compose
  unset SSM_PARAMETER_PREFIX || true
}

write_gated_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  migrate:
    image: backend
    command: ["migrate-gate", "apply"]
  gateway:
    image: backend
    depends_on:
      migrate:
        condition: service_completed_successfully
EOF
}

write_ungated_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  gateway:
    image: backend
EOF
}

# UT-INFRA-280 — a successful backend roll pulls and ups the four backend
# targets, updates ENV_FILE's KEY, and reports completion (FR18).
@test "UT-INFRA-280: roll-service.sh backend roll succeeds through the gate" {
  run "$SCRIPT"
  assert_success
  assert_output --partial "docker compose pull gateway user-service organization-service event-service"
  assert_output --partial "docker compose up -d gateway user-service organization-service event-service"
  assert_output --partial "Roll complete: backend -> sha-new123"
  run grep '^BACKEND_IMAGE_TAG=' "$ENV_FILE"
  assert_output "BACKEND_IMAGE_TAG=sha-new123"
}

# UT-INFRA-281 — a migration-gate failure (compose up -d fails) exits
# non-zero, never claims "Roll complete", and surfaces the migrate
# container's own log (which may carry the REFUSE/baseline instruction),
# without this script ever baselining anything itself (AC2).
@test "UT-INFRA-281: roll-service.sh surfaces a failed gate and does not swap" {
  export ROLL_FIXTURE_UP_RC=1
  export ROLL_FIXTURE_MIGRATE_LOG="REFUSE user-service: tables exist with no migration ledger. Run: migrate-gate baseline user-service"
  run "$SCRIPT"
  assert_failure
  refute_output --partial "Roll complete"
  assert_output --partial "FAIL-CLOSED"
  # The baseline instruction reaches the operator only via the echoed
  # migrate-container log — this script issues no `migrate-gate` call of
  # its own (no second gate implementation, no auto-baseline).
  assert_output --partial "migrate-gate baseline user-service"
}

# UT-INFRA-282 — a backend roll never passes --no-deps to `up -d` (the
# dependency on migrate must stay in force).
@test "UT-INFRA-282: roll-service.sh never uses --no-deps for a backend roll" {
  run "$SCRIPT"
  assert_success
  run grep -F -- '--no-deps' "$STUB_LOG"
  assert_failure
}

# UT-INFRA-283 — NFR7/AC8: a box whose compose file lacks the migrate
# service refuses before any docker call and names the asset-sync command.
@test "UT-INFRA-283: roll-service.sh refuses a backend roll with no migrate service in compose" {
  write_ungated_compose
  run "$SCRIPT"
  assert_failure
  assert_output --partial "REFUSE"
  assert_output --partial "asset-sync.sh"
  assert_stub_not_called docker
}

# UT-INFRA-284 — EC13: a biocompute roll is not gated and proceeds even
# when compose has no migrate service.
@test "UT-INFRA-284: roll-service.sh does not gate a biocompute roll" {
  write_ungated_compose
  export SERVICE="biocompute"
  export KEY="BIOCOMPUTE_IMAGE_TAG"
  run "$SCRIPT"
  assert_success
  assert_output --partial "docker compose up -d biocompute"
}

# UT-INFRA-285 — EC13: a frontend roll is not gated either.
@test "UT-INFRA-285: roll-service.sh does not gate a frontend roll" {
  write_ungated_compose
  export SERVICE="frontend"
  export KEY="FRONTEND_IMAGE_TAG"
  run "$SCRIPT"
  assert_success
  assert_output --partial "docker compose up -d frontend"
}

# UT-INFRA-286 — a missing ENV_FILE is a fast, pre-docker failure.
@test "UT-INFRA-286: roll-service.sh fails fast when ENV_FILE is missing" {
  rm -f "$ENV_FILE"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "does not exist"
  assert_stub_not_called docker
}

# UT-INFRA-287 — KEY already present in ENV_FILE is updated in place.
@test "UT-INFRA-287: roll-service.sh updates an existing KEY in place" {
  run "$SCRIPT"
  assert_success
  run grep -c '^BACKEND_IMAGE_TAG=' "$ENV_FILE"
  assert_output "1"
}

# UT-INFRA-288 — KEY absent from ENV_FILE is appended.
@test "UT-INFRA-288: roll-service.sh appends a KEY that is not yet present" {
  printf 'OTHER_KEY=x\n' > "$ENV_FILE"
  run "$SCRIPT"
  assert_success
  run grep '^BACKEND_IMAGE_TAG=' "$ENV_FILE"
  assert_output "BACKEND_IMAGE_TAG=sha-new123"
}

# UT-INFRA-289 — idempotent (NFR1): running twice with the same inputs
# leaves ENV_FILE's KEY line unchanged on the second run.
@test "UT-INFRA-289: roll-service.sh is idempotent on a repeat roll" {
  run "$SCRIPT"
  assert_success
  run "$SCRIPT"
  assert_success
  run grep -c '^BACKEND_IMAGE_TAG=sha-new123$' "$ENV_FILE"
  assert_output "1"
}

# UT-INFRA-290 — when SSM_PARAMETER_PREFIX is set and the on-box
# refresh-env.sh exists, it is invoked with that prefix (FR12).
@test "UT-INFRA-290: roll-service.sh invokes refresh-env.sh when configured" {
  mkdir -p "$(dirname "$REFRESH_ENV_SCRIPT")"
  cat > "$REFRESH_ENV_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "refresh-env called with prefix=${SSM_PARAMETER_PREFIX} file=$1"
exit 0
EOF
  chmod +x "$REFRESH_ENV_SCRIPT"
  export SSM_PARAMETER_PREFIX="/axiome/dev"
  run "$SCRIPT"
  assert_success
  assert_output --partial "refresh-env called with prefix=/axiome/dev file=${ENV_FILE}"
  assert_output --partial ".env refreshed from SSM"
}

# UT-INFRA-291 — SSM_PARAMETER_PREFIX unset: the roll still completes,
# warns, and never invokes refresh-env.sh.
@test "UT-INFRA-291: roll-service.sh skips refresh-env.sh when SSM_PARAMETER_PREFIX is unset" {
  mkdir -p "$(dirname "$REFRESH_ENV_SCRIPT")"
  cat > "$REFRESH_ENV_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "SHOULD NOT RUN" >> "${REFRESH_ENV_TRACE}"
exit 0
EOF
  chmod +x "$REFRESH_ENV_SCRIPT"
  export REFRESH_ENV_TRACE="${BATS_TEST_TMPDIR}/refresh.trace"
  : > "$REFRESH_ENV_TRACE"
  run "$SCRIPT"
  assert_success
  assert_output --partial "WARN: SSM_PARAMETER_PREFIX not set"
  run cat "$REFRESH_ENV_TRACE"
  assert_output ""
}

# UT-INFRA-292 — refresh-env.sh missing on an un-converted box: the roll
# still completes, warns, and does not fail the roll.
@test "UT-INFRA-292: roll-service.sh skips a missing refresh-env.sh without failing the roll" {
  export SSM_PARAMETER_PREFIX="/axiome/dev"
  run "$SCRIPT"
  assert_success
  assert_output --partial "not found on this box"
  assert_output --partial "Roll complete"
}

# UT-INFRA-293 — an unknown SERVICE value is a usage error, no docker call.
@test "UT-INFRA-293: roll-service.sh rejects an unknown SERVICE" {
  export SERVICE="unknown-thing"
  run "$SCRIPT"
  assert_failure
  assert_output --partial "unknown SERVICE"
  assert_stub_not_called docker
}

# --- review bounce #1: FR14 qualification facts + migrate-service scoping ---

# UT-INFRA-310 — require_migrate_service must not be fooled by a two-space
# `migrate:` key nested under a DIFFERENT top-level mapping (only a
# `migrate:` key under `services:` counts).
@test "UT-INFRA-310: roll-service.sh ignores a migrate: key outside the services: block" {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  gateway:
    image: backend
x-notes:
  migrate:
    not: a service
EOF
  run "$SCRIPT"
  assert_failure
  assert_output --partial "REFUSE"
  assert_stub_not_called docker
}

# UT-INFRA-311 — a successful backend roll prints this run's
# MIGRATION_FACTS lines (one per service), scoped via --since and
# unprefixed via --no-log-prefix (FR14).
@test "UT-INFRA-311: roll-service.sh emits this run's MIGRATION_FACTS on a successful backend roll" {
  export ROLL_FIXTURE_FACTS_NEW="MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20250101_init APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13
MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20250102_init APPLIED=1 PRE_COUNTS=2 POST_COUNTS=3"
  run "$SCRIPT"
  assert_success
  assert_line "MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20250101_init APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13"
  assert_line "MIGRATION_FACTS: SERVICE=user-service SCHEMA_VERSION=20250102_init APPLIED=1 PRE_COUNTS=2 POST_COUNTS=3"
  refute_output --partial "migrate-1  |"
  refute_output --partial "MIGRATION_FACTS_UNAVAILABLE"
}

# UT-INFRA-312 — a previous run's facts line must never appear: this
# fixture only returns ROLL_FIXTURE_FACTS_OLD when the real call has NO
# --since token (see tests/fixtures/roll-service-docker.rules.sh) — this
# test fails if roll-service.sh ever stops passing --since.
@test "UT-INFRA-312: roll-service.sh never surfaces a previous run's facts line" {
  export ROLL_FIXTURE_FACTS_OLD="MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=STALE_OLD_RUN APPLIED=9 PRE_COUNTS=1 POST_COUNTS=1"
  export ROLL_FIXTURE_FACTS_NEW="MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20250101_init APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13"
  run "$SCRIPT"
  assert_success
  refute_output --partial "STALE_OLD_RUN"
  assert_line "MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=20250101_init APPLIED=3 PRE_COUNTS=10 POST_COUNTS=13"
}

# UT-INFRA-313 — the gate passed but the facts log can't be read: a
# distinct, greppable MIGRATION_FACTS_UNAVAILABLE line is printed, and the
# roll's own exit code stays 0 (the containers are serving).
@test "UT-INFRA-313: roll-service.sh reports MIGRATION_FACTS_UNAVAILABLE when the facts log read fails" {
  export ROLL_FIXTURE_FACTS_RC=1
  run "$SCRIPT"
  assert_success
  assert_output --partial "MIGRATION_FACTS_UNAVAILABLE:"
  assert_output --partial "Roll complete"
}

# UT-INFRA-314 — the gate passed but no facts line is present at all
# (e.g. nothing was pending and migrate-gate printed nothing matching):
# same MIGRATION_FACTS_UNAVAILABLE treatment, still exit 0.
@test "UT-INFRA-314: roll-service.sh reports MIGRATION_FACTS_UNAVAILABLE when no facts line is found" {
  run "$SCRIPT"
  assert_success
  assert_output --partial "MIGRATION_FACTS_UNAVAILABLE:"
}

# UT-INFRA-315 — a non-backend roll never attempts to read migrate facts
# (there is no migrate dependency for biocompute/frontend — EC13).
@test "UT-INFRA-315: roll-service.sh never reads migrate facts for a non-backend roll" {
  write_ungated_compose
  export SERVICE="biocompute"
  export KEY="BIOCOMPUTE_IMAGE_TAG"
  export ROLL_FIXTURE_FACTS_NEW="MIGRATION_FACTS: SERVICE=organization-service SCHEMA_VERSION=x APPLIED=1 PRE_COUNTS=1 POST_COUNTS=2"
  run "$SCRIPT"
  assert_success
  refute_output --partial "MIGRATION_FACTS"
}
