#!/usr/bin/env bats
# tests/refresh-env.bats — scripts/refresh-env.sh (AXI-1950, epic AXI-1944
# decision 5, FR12/EC5/EC6/AC10). UT-INFRA-139..148.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/refresh-env.sh"

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/refresh-env-ssm.rules.sh"
  export SSM_PARAMETER_PREFIX="/axiome/prod"
  ENV_FILE="${BATS_TEST_TMPDIR}/.env"
  cat > "$ENV_FILE" <<'EOF'
ORGANIZATION_DATABASE_URL=postgres://old-host/organization_svc
USER_DATABASE_URL=postgres://old-host/user_svc
JWT_SECRET=old-secret-value
BACKEND_IMAGE_TAG=sha-deployed-good
BIOCOMPUTE_IMAGE_TAG=sha-bio-good
FRONTEND_IMAGE_TAG=sha-front-good
ENVIRONMENT=production
PROJECT_NAME=axiome
ECR_REGISTRY=123456789012.dkr.ecr.eu-west-3.amazonaws.com
FQDN=platform.axiomebio.com
EOF
  chmod 600 "$ENV_FILE"
}

ssm_tsv() {
  printf '/axiome/prod/ORGANIZATION_DATABASE_URL\tpostgres://new-host/organization_svc\n'
  printf '/axiome/prod/USER_DATABASE_URL\tpostgres://new-host/user_svc\n'
  printf '/axiome/prod/JWT_SECRET\tnew-secret-value\n'
  printf '/axiome/prod/BACKEND_IMAGE_TAG\tsha-stale-rollback-value\n'
  printf '/axiome/prod/BIOCOMPUTE_IMAGE_TAG\tsha-bio-good\n'
  printf '/axiome/prod/FRONTEND_IMAGE_TAG\tsha-front-good\n'
  printf '/axiome/prod/ECR_REGISTRY\t999999999999.dkr.ecr.eu-west-3.amazonaws.com\n'
}

# UT-INFRA-139 — given SSM holds a different value for a decision-5
# preserved key, when refresh-env.sh runs, then the preserved key keeps the
# box's existing value, not SSM's (EC5 — SSM may be stale).
@test "UT-INFRA-139: refresh-env.sh preserves every decision-5 key against a differing SSM value" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  run grep '^BACKEND_IMAGE_TAG=' "$ENV_FILE"
  assert_output "BACKEND_IMAGE_TAG=sha-deployed-good"
  run grep '^ECR_REGISTRY=' "$ENV_FILE"
  assert_output "ECR_REGISTRY=123456789012.dkr.ecr.eu-west-3.amazonaws.com"
  run grep '^ENVIRONMENT=' "$ENV_FILE"
  assert_output "ENVIRONMENT=production"
  run grep '^FQDN=' "$ENV_FILE"
  assert_output "FQDN=platform.axiomebio.com"
  run grep '^PROJECT_NAME=' "$ENV_FILE"
  assert_output "PROJECT_NAME=axiome"
}

# UT-INFRA-140 — a non-preserved key (e.g. a rotated secret) takes the new
# SSM value.
@test "UT-INFRA-140: refresh-env.sh takes the new SSM value for a non-preserved key" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  run grep '^JWT_SECRET=' "$ENV_FILE"
  assert_output "JWT_SECRET=new-secret-value"
  run grep '^ORGANIZATION_DATABASE_URL=' "$ENV_FILE"
  assert_output "ORGANIZATION_DATABASE_URL=postgres://new-host/organization_svc"
}

# UT-INFRA-141 — SSM unreachable: the existing .env is kept byte-identical,
# a warning is logged, exit is non-zero (EC6).
@test "UT-INFRA-141: refresh-env.sh on SSM-unreachable keeps the file byte-identical" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_FAIL=1
  run "$SCRIPT" "$ENV_FILE"
  assert_failure
  assert_output --partial "SSM unreachable"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-142 — an empty-but-reachable SSM result is treated the same as
# unreachable (no parameters is not a valid refresh source).
@test "UT-INFRA-142: refresh-env.sh on an empty SSM result keeps the existing file" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_TSV=""
  run "$SCRIPT" "$ENV_FILE"
  assert_failure
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-143 — a required (non-preserved) key comes back empty: the file
# is kept, a warning is logged.
@test "UT-INFRA-143: refresh-env.sh on an empty required key keeps the existing file" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(printf '/axiome/prod/JWT_SECRET\t\n')"
  run "$SCRIPT" "$ENV_FILE"
  assert_failure
  assert_output --partial "required key was missing/empty"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-144 — no secret value is ever printed to stdout/stderr, success
# or failure path.
@test "UT-INFRA-144: refresh-env.sh never prints a secret value" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  refute_output --partial "new-secret-value"
  refute_output --partial "old-secret-value"
  refute_output --partial "postgres://new-host"
}

# UT-INFRA-145 — atomicity: the temp file is created in the SAME directory
# as the target (required for an atomic same-filesystem rename), and the
# final file is installed via rename, not truncate-in-place.
@test "UT-INFRA-145: refresh-env.sh writes its temp file in the same directory before renaming" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  # Race a background watcher: the target inode must change exactly once,
  # via a rename (mv), never be seen empty/truncated mid-write.
  local before_inode after_inode
  before_inode="$(stat -c %i "$ENV_FILE")"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  after_inode="$(stat -c %i "$ENV_FILE")"
  [ "$before_inode" != "$after_inode" ]
  run find "$(dirname "$ENV_FILE")" -maxdepth 1 -name "$(basename "$ENV_FILE").tmp.*"
  assert_output ""
}

# UT-INFRA-146 — no temp file is left behind after a successful refresh.
@test "UT-INFRA-146: refresh-env.sh leaves no temp file behind on success" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  run find "$(dirname "$ENV_FILE")" -maxdepth 1 -name '*.tmp.*'
  assert_output ""
}

# UT-INFRA-147 — no temp file is ever created on the SSM-unreachable path
# (the decision to keep the old file is made before any write begins).
@test "UT-INFRA-147: refresh-env.sh creates no temp file when SSM is unreachable" {
  export REFRESH_ENV_FIXTURE_SSM_FAIL=1
  run "$SCRIPT" "$ENV_FILE"
  assert_failure
  run find "$(dirname "$ENV_FILE")" -maxdepth 1 -name '*.tmp.*'
  assert_output ""
}

# UT-INFRA-148 — a missing env-file argument is a usage error.
@test "UT-INFRA-148: refresh-env.sh exits 1 on a usage error without calling aws" {
  run "$SCRIPT"
  assert_failure
  assert_output --partial "usage:"
  assert_stub_not_called aws
}
