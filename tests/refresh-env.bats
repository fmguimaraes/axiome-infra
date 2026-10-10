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

# ---------------------------------------------------------------------------
# AXI-1969 (FR50/AC43) — a newline/tab inside an SSM value is detected and
# refused, never silently corrupting .env. UT-INFRA-440..447.
# ---------------------------------------------------------------------------

# UT-INFRA-440 — AC43: a parameter value containing a literal newline is
# refused — the previous .env is kept byte-identical, the parameter is
# named, exit is the dedicated non-zero code (4), and the value itself
# never appears in any output.
@test "UT-INFRA-440: refresh-env.sh refuses an SSM value containing a newline" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/JWT_SECRET","Value":"bad\nvalue-marker"},{"Name":"/axiome/prod/ECR_REGISTRY","Value":"999999999999.dkr.ecr.eu-west-3.amazonaws.com"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  assert_output --partial "JWT_SECRET"
  refute_output --partial "bad"
  refute_output --partial "value-marker"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-441 — AC43 (tab variant): same refusal for a value containing a
# literal tab instead of a newline.
@test "UT-INFRA-441: refresh-env.sh refuses an SSM value containing a tab" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/JWT_SECRET","Value":"bad\tvalue-marker"},{"Name":"/axiome/prod/ECR_REGISTRY","Value":"999999999999.dkr.ecr.eu-west-3.amazonaws.com"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  assert_output --partial "JWT_SECRET"
  refute_output --partial "bad"
  refute_output --partial "value-marker"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-442 — the refusal fires even when the bad value belongs to a
# preserved key (decision 5) — the box must never trust a malformed SSM
# response just because the key would have been ignored anyway.
@test "UT-INFRA-442: refresh-env.sh refuses a newline even on a preserved key's value" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/BACKEND_IMAGE_TAG","Value":"sha-bad\nextra-marker"},{"Name":"/axiome/prod/ECR_REGISTRY","Value":"999999999999.dkr.ecr.eu-west-3.amazonaws.com"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  assert_output --partial "BACKEND_IMAGE_TAG"
  refute_output --partial "extra-marker"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-443 — no newline/tab anywhere: the refresh proceeds normally
# (the detection has no false positive on ordinary values).
@test "UT-INFRA-443: refresh-env.sh refreshes normally when no value has a newline or tab" {
  export REFRESH_ENV_FIXTURE_SSM_TSV="$(ssm_tsv)"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  run grep '^JWT_SECRET=' "$ENV_FILE"
  assert_output "JWT_SECRET=new-secret-value"
}

# UT-INFRA-444 — no temp file is left behind when a value is refused (the
# decision to keep the old file is made before any write begins, same
# contract as the SSM-unreachable path, UT-INFRA-147).
@test "UT-INFRA-444: refresh-env.sh creates no temp file when a value is refused" {
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/JWT_SECRET","Value":"bad\nvalue"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  run find "$(dirname "$ENV_FILE")" -maxdepth 1 -name '*.tmp.*'
  assert_output ""
}

# UT-INFRA-448 — AXI-1969 review follow-up #3: a bare carriage return
# (no accompanying newline) is refused the same way as a newline/tab.
@test "UT-INFRA-448: refresh-env.sh refuses an SSM value containing a bare carriage return" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/JWT_SECRET","Value":"bad\rvalue-marker"},{"Name":"/axiome/prod/ECR_REGISTRY","Value":"999999999999.dkr.ecr.eu-west-3.amazonaws.com"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  assert_output --partial "JWT_SECRET"
  refute_output --partial "bad"
  refute_output --partial "value-marker"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-449 — same refusal for a CRLF pair.
@test "UT-INFRA-449: refresh-env.sh refuses an SSM value containing CRLF" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  export REFRESH_ENV_FIXTURE_SSM_JSON='{"Parameters":[{"Name":"/axiome/prod/JWT_SECRET","Value":"bad\r\nvalue-marker"},{"Name":"/axiome/prod/ECR_REGISTRY","Value":"999999999999.dkr.ecr.eu-west-3.amazonaws.com"}]}'
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 4 ]
  assert_output --partial "JWT_SECRET"
  refute_output --partial "bad"
  refute_output --partial "value-marker"
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# make_path_without_jq <path> — builds (in BATS_TEST_TMPDIR) a single
# mirror directory of symlinks to every executable reachable on <path>
# EXCEPT any named "jq", in PATH order (so a real tool is never removed
# or faked — only mirrored or, for the one name under test, omitted), and
# prints that mirror directory's path. A single `ln -s dir/* mirror/`
# per original PATH directory, not a per-file loop, keeps this fast
# (~1500 entries on a typical dev box's /usr/bin alone).
make_path_without_jq() {
  local mirror="${BATS_TEST_TMPDIR}/path-without-jq" dirs=() dir
  mkdir -p "$mirror"
  IFS=':' read -ra dirs <<< "$1"
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    ln -s "${dir}"/* "${mirror}/" 2>/dev/null || true
  done
  rm -f "${mirror}/jq"
  printf '%s' "$mirror"
}

# UT-INFRA-450 — AXI-1969 review follow-up #4: with no `jq` reachable on
# PATH at all (not a fake/broken jq — simply absent), refresh-env.sh exits
# 1, names the missing tool, makes no `aws` call, and leaves .env
# byte-identical.
@test "UT-INFRA-450: refresh-env.sh exits 1 and keeps .env byte-identical when jq is unavailable" {
  local before after
  before="$(sha256sum "$ENV_FILE")"
  PATH="$(make_path_without_jq "$PATH")"
  run "$SCRIPT" "$ENV_FILE"
  [ "$status" -eq 1 ]
  assert_output --partial "jq is required"
  assert_stub_not_called aws
  after="$(sha256sum "$ENV_FILE")"
  [ "$before" = "$after" ]
}

# UT-INFRA-451 — AXI-1969 review follow-up #4: a value containing a
# double quote, single quote, dollar sign, hash, equals sign, space,
# backslash, and a non-ASCII character round-trips byte-for-byte into the
# written KEY=VALUE line (the JSON fixture is built by `jq -n --arg`,
# which is trusted to encode correctly — this test is of the SCRIPT's own
# decode path, fetch_ssm's `.Name + "=" + .Value` raw concatenation).
@test "UT-INFRA-451: refresh-env.sh writes an odd-character SSM value byte-for-byte" {
  local raw_value ssm_json
  raw_value="$(printf 'dq=%s_sq=%s_dollar=%s_hash=%s_eq=%s_sp=[%s]_bs=%s_nonascii=%s' '"' "'" '$' '#' '=' ' ' '\' 'é')"
  # Every other non-preserved key the fixture ENV_FILE already carries must
  # still come back non-empty, or compose_new_env refuses before ever
  # reaching ODD_KEY (UT-INFRA-143's contract) — include them alongside.
  ssm_json="$(jq -n \
    --arg odd_name "/axiome/prod/ODD_KEY" --arg odd_value "$raw_value" \
    '{Parameters: [
      {Name: $odd_name, Value: $odd_value},
      {Name: "/axiome/prod/ORGANIZATION_DATABASE_URL", Value: "postgres://new-host/organization_svc"},
      {Name: "/axiome/prod/USER_DATABASE_URL", Value: "postgres://new-host/user_svc"},
      {Name: "/axiome/prod/JWT_SECRET", Value: "new-secret-value"}
    ]}')"
  export REFRESH_ENV_FIXTURE_SSM_JSON="$ssm_json"
  run "$SCRIPT" "$ENV_FILE"
  assert_success
  run grep '^ODD_KEY=' "$ENV_FILE"
  assert_output "ODD_KEY=${raw_value}"
}
