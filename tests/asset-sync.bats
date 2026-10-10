#!/usr/bin/env bats
# tests/asset-sync.bats — scripts/asset-sync.sh (AXI-1950, epic AXI-1944
# decision 8, FR11/EC9/AC9/AC32). UT-INFRA-130..138.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/asset-sync.sh"

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/asset-sync-s3.rules.sh"
  stub_use_rules docker "${TESTS_DIR}/fixtures/asset-sync-compose.rules.sh"
  export ASSET_SYNC_FIXTURE_BUCKET="${BATS_TEST_TMPDIR}/bucket"
  export ASSET_SYNC_FIXTURE_PREFIX="s3://fakebucket/onbox"
  export ASSET_SYNC_FIXTURE_COMPOSE_RC=0
  DEST="${BATS_TEST_TMPDIR}/dest"
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET" "$DEST"
}

# Writes the manifest for whatever files currently exist in the fixture
# bucket (sha256sum -c compatible: "<sha>  <relpath>", one per line).
write_bucket_manifest() {
  (
    cd "$ASSET_SYNC_FIXTURE_BUCKET" || exit 1
    : > manifest.sha256
    find . -type f ! -name manifest.sha256 -print0 | sort -z | while IFS= read -r -d '' f; do
      printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "${f#./}" >> manifest.sha256
    done
  )
}

seed_bucket() {
  mkdir -p "${ASSET_SYNC_FIXTURE_BUCKET}/scripts"
  printf 'services:\n  a:\n    image: alpine\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/docker-compose.yml"
  printf '#!/bin/bash\necho boot\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/boot.sh"
  printf 'asset-sync-v1\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/asset-sync.sh"
  printf 'refresh-env-v1\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/refresh-env.sh"
  write_bucket_manifest
}

# UT-INFRA-130 — given a valid, checksum-matching, compose-valid publish,
# when asset-sync.sh pull runs, then every manifest-listed file (plus the
# manifest itself) is installed into dest-dir.
@test "UT-INFRA-130: asset-sync.sh pull installs every manifest-listed file" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  [ -f "${DEST}/docker-compose.yml" ]
  [ -f "${DEST}/scripts/boot.sh" ]
  [ -f "${DEST}/scripts/asset-sync.sh" ]
  [ -f "${DEST}/scripts/refresh-env.sh" ]
  [ -f "${DEST}/manifest.sha256" ]
}

# UT-INFRA-131 — given dest-dir already has an installed copy, when pull
# runs again with a changed file, then the previous copy is kept as
# "<file>.prev" (FR11's "keeps the previous copy").
@test "UT-INFRA-131: asset-sync.sh pull keeps the previous copy on reinstall" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  printf '#!/bin/bash\necho boot-v2\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/boot.sh"
  write_bucket_manifest
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  run cat "${DEST}/scripts/boot.sh"
  assert_output --partial "boot-v2"
  run cat "${DEST}/scripts/boot.sh.prev"
  assert_output --partial "echo boot"
}

# UT-INFRA-132 — given a downloaded file whose content does not match its
# manifest checksum, when pull runs, then nothing is installed and it exits
# non-zero (EC9).
@test "UT-INFRA-132: asset-sync.sh pull on checksum mismatch installs nothing" {
  seed_bucket
  # Corrupt the manifest's recorded hash for boot.sh without touching the
  # file, forcing a verification mismatch.
  sed -i 's/.*scripts\/boot.sh/0000000000000000000000000000000000000000000000000000000000000000  scripts\/boot.sh/' \
    "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_failure
  assert_output --partial "checksum mismatch"
  [ ! -e "${DEST}/scripts/boot.sh" ]
  [ ! -e "${DEST}/docker-compose.yml" ]
}

# UT-INFRA-133 — given a syntactically-downloadable but invalid
# docker-compose.yml, when pull runs, then nothing is installed (the
# previous copy, including none-yet, is effectively restored/kept) and it
# exits non-zero (EC9).
@test "UT-INFRA-133: asset-sync.sh pull on invalid compose installs nothing" {
  seed_bucket
  export ASSET_SYNC_FIXTURE_COMPOSE_RC=1
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_failure
  assert_output --partial "failed validation"
  [ ! -e "${DEST}/docker-compose.yml" ]
  [ ! -e "${DEST}/scripts/boot.sh" ]
}

# UT-INFRA-134 — given a bucket/manifest that cannot be reached, when pull
# runs, then existing assets are kept and it exits a defined non-zero code
# (EC6 "same spirit").
@test "UT-INFRA-134: asset-sync.sh pull on unreachable manifest keeps existing assets" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  export ASSET_SYNC_FIXTURE_BUCKET="${BATS_TEST_TMPDIR}/no-such-bucket"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 2 ]
  assert_output --partial "manifest unreachable"
  run cat "${DEST}/scripts/boot.sh"
  assert_output --partial "echo boot"
}

# UT-INFRA-135 — given the manifest is reachable but one listed file is not,
# when pull runs, then existing assets are kept and it exits the same
# "unreachable" code as a missing manifest.
@test "UT-INFRA-135: asset-sync.sh pull on a missing listed file keeps existing assets" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  rm "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/refresh-env.sh"
  # manifest.sha256 on the bucket side still lists refresh-env.sh (not
  # regenerated) — exactly the "manifest says it exists, fetch fails" case.
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 2 ]
  assert_output --partial "could not be fetched"
}

# UT-INFRA-136 — given a manifest-source file, when publish runs, then the
# uploaded manifest.sha256 has one correct sha256 line per listed file.
@test "UT-INFRA-136: asset-sync.sh publish builds a correct manifest.sha256" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/providers/aws/onbox/scripts" "${repo}/scripts"
  printf 'compose-content\n' > "${repo}/providers/aws/onbox/docker-compose.yml"
  printf 'boot-content\n' > "${repo}/providers/aws/onbox/boot.sh"
  printf 'sync-content\n' > "${repo}/scripts/asset-sync.sh"
  printf 'refresh-content\n' > "${repo}/scripts/refresh-env.sh"
  cat > "${repo}/providers/aws/onbox/publish-manifest.txt" <<'EOF'
providers/aws/onbox/docker-compose.yml:docker-compose.yml
providers/aws/onbox/boot.sh:scripts/boot.sh
scripts/asset-sync.sh:scripts/asset-sync.sh
scripts/refresh-env.sh:scripts/refresh-env.sh
EOF
  run "$SCRIPT" publish "$repo" "$ASSET_SYNC_FIXTURE_PREFIX"
  assert_success
  local expected
  expected="$(printf 'compose-content\n' | sha256sum | awk '{print $1}')"
  run grep "docker-compose.yml" "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256"
  assert_output --partial "$expected"
}

# UT-INFRA-137 — publish uploads every manifest-source file plus the
# manifest itself (not a subset).
@test "UT-INFRA-137: asset-sync.sh publish uploads every listed file and the manifest" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/providers/aws/onbox/scripts" "${repo}/scripts"
  printf 'c\n' > "${repo}/providers/aws/onbox/docker-compose.yml"
  printf 'b\n' > "${repo}/providers/aws/onbox/boot.sh"
  printf 's\n' > "${repo}/scripts/asset-sync.sh"
  printf 'r\n' > "${repo}/scripts/refresh-env.sh"
  cat > "${repo}/providers/aws/onbox/publish-manifest.txt" <<'EOF'
providers/aws/onbox/docker-compose.yml:docker-compose.yml
providers/aws/onbox/boot.sh:scripts/boot.sh
scripts/asset-sync.sh:scripts/asset-sync.sh
scripts/refresh-env.sh:scripts/refresh-env.sh
EOF
  run "$SCRIPT" publish "$repo" "$ASSET_SYNC_FIXTURE_PREFIX"
  assert_success
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/docker-compose.yml" ]
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/boot.sh" ]
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/asset-sync.sh" ]
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/refresh-env.sh" ]
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256" ]
}

# UT-INFRA-138 — a missing/incomplete argv for either mode is a usage error
# (exit 1), never an unconfigured stub call (no aws/docker invoked at all).
@test "UT-INFRA-138: asset-sync.sh exits 1 on a usage error without calling aws" {
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX"
  assert_failure
  assert_output --partial "usage:"
  assert_stub_not_called aws
}
