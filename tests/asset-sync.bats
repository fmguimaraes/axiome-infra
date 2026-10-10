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

# ---------------------------------------------------------------------------
# AXI-1969 (FR48/FR49/AC41/AC42) — manifest path validation and all-or-
# nothing install, below. UT-INFRA-430..439.
# ---------------------------------------------------------------------------

# Writes a one-line manifest naming exactly <rel> (sha is irrelevant — path
# validation happens before any checksum is read), replacing whatever
# write_bucket_manifest would have built.
write_unsafe_manifest() {
  local rel="$1"
  printf '%s  %s\n' "$(printf 'x' | sha256sum | awk '{print $1}')" "$rel" \
    > "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256"
}

# UT-INFRA-430 — AC41: a manifest entry "../x" is rejected as a whole —
# exit non-zero, nothing fetched beyond the manifest itself, nothing
# installed, the offending entry named.
@test "UT-INFRA-430: asset-sync.sh pull rejects a manifest entry '../x'" {
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET"
  write_unsafe_manifest "../x"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 5 ]
  assert_output --partial "unsafe path"
  assert_output --partial "../x"
  [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ]
}

# UT-INFRA-431 — AC41: an absolute manifest entry "/etc/x" is rejected the
# same way.
@test "UT-INFRA-431: asset-sync.sh pull rejects a manifest entry '/etc/x'" {
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET"
  write_unsafe_manifest "/etc/x"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 5 ]
  assert_output --partial "unsafe path"
  assert_output --partial "/etc/x"
  [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ]
}

# UT-INFRA-432 — AC41: a manifest entry that resolves outside the install
# root via a buried ".." segment ("a/../../b") is rejected the same way.
@test "UT-INFRA-432: asset-sync.sh pull rejects a manifest entry 'a/../../b'" {
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET"
  write_unsafe_manifest "a/../../b"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 5 ]
  assert_output --partial "unsafe path"
  assert_output --partial "a/../../b"
  [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ]
}

# UT-INFRA-433 — FR48: an empty manifest path is rejected the same way.
@test "UT-INFRA-433: asset-sync.sh pull rejects a manifest entry with an empty path" {
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET"
  write_unsafe_manifest ""
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 5 ]
  assert_output --partial "unsafe path"
  [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ]
}

# UT-INFRA-434 — FR48: the WHOLE manifest is validated before any listed
# file is fetched — a manifest with two safe entries and one unsafe entry
# never fetches even the safe ones (only the manifest.sha256 download
# itself is recorded against the aws stub).
@test "UT-INFRA-434: asset-sync.sh pull fetches no listed file when any manifest path is unsafe" {
  seed_bucket
  {
    printf '%s  %s\n' "$(sha256sum "${ASSET_SYNC_FIXTURE_BUCKET}/docker-compose.yml" | awk '{print $1}')" "docker-compose.yml"
    printf '%s  %s\n' "$(sha256sum "${ASSET_SYNC_FIXTURE_BUCKET}/scripts/boot.sh" | awk '{print $1}')" "scripts/boot.sh"
    printf '%s  %s\n' "$(printf 'x' | sha256sum | awk '{print $1}')" "../escape"
  } > "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 5 ]
  assert_output --partial "../escape"
  [ -z "$(find "$DEST" -mindepth 1 2>/dev/null)" ]
  refute_output --partial "docker-compose.yml"
  run grep -c '^### CALL: aws$' "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-435 — AC42: a manifest of three files where the third fails to
# install — all three end up at their previous copy (the first two
# actually replaced then rolled back; the third was never touched),
# verified by content, and the sync exits non-zero naming the restore.
#
# The failure injection is root-proof (review follow-up #5): rather than
# relying on a permission bit (meaningless to uid 0), the THIRD entry's
# destination is made an existing directory that already contains an
# entry with the same basename as the file being installed — `mv` refuses
# to overwrite a directory with a non-directory regardless of who is
# running it (a plain type conflict, verified empirically: see the story's
# handback for the exact `mv` behaviour this relies on).
@test "UT-INFRA-435: asset-sync.sh pull on a mid-install failure restores every already-installed file" {
  mkdir -p "${ASSET_SYNC_FIXTURE_BUCKET}"
  printf 'a-old\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/a.txt"
  printf 'b-old\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/b.txt"
  write_bucket_manifest
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  run cat "${DEST}/a.txt"; assert_output "a-old"
  run cat "${DEST}/b.txt"; assert_output "b-old"

  printf 'a-new\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/a.txt"
  printf 'b-new\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/b.txt"
  mkdir -p "${ASSET_SYNC_FIXTURE_BUCKET}/locked"
  printf 'c-new\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/locked/c.txt"
  write_bucket_manifest
  # mv staged .../locked/c.txt -> "$DEST/locked/c.txt" will try to move the
  # staged file INTO this existing directory under its own basename
  # ("c.txt"), which already exists there as a directory -> type conflict.
  mkdir -p "${DEST}/locked/c.txt/c.txt"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 6 ]
  assert_output --partial "restoring"
  run cat "${DEST}/a.txt"; assert_output "a-old"
  run cat "${DEST}/b.txt"; assert_output "b-old"
  [ ! -e "${DEST}/a.txt.prev" ]
  [ ! -e "${DEST}/b.txt.prev" ]
  [ -d "${DEST}/locked/c.txt/c.txt" ]
}

# UT-INFRA-445 — AXI-1969 review follow-up #1: an already-current box
# whose files all match but whose installed manifest.sha256 bookkeeping
# copy is stale (e.g. a prior run's final write failed) gets ONLY that
# bookkeeping copy repaired — no asset file is rewritten.
@test "UT-INFRA-445: asset-sync.sh pull repairs a stale manifest.sha256 when every file already matches" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  local before
  before="$(stat -c %Y "${DEST}/scripts/boot.sh")"
  # Corrupt only the installed bookkeeping copy — no bucket change, no
  # asset file touched.
  printf '# stale\n' >> "${DEST}/manifest.sha256"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  assert_output --partial "repaired stale"
  run cmp "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256" "${DEST}/manifest.sha256"
  assert_success
  local after
  after="$(stat -c %Y "${DEST}/scripts/boot.sh")"
  [ "$before" = "$after" ]
}

# UT-INFRA-446 — AXI-1969 review follow-up #2: a mid-install failure must
# not disturb a "<file>.prev" that already existed from an EARLIER,
# successful run — only the live file is rolled back to ITS pre-this-run
# content; the older ".prev" keeps its own (even older) content untouched.
@test "UT-INFRA-446: asset-sync.sh pull on a mid-install failure never touches a pre-existing .prev" {
  mkdir -p "${ASSET_SYNC_FIXTURE_BUCKET}"
  printf 'v1\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/a.txt"
  write_bucket_manifest
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  [ ! -e "${DEST}/a.txt.prev" ]

  printf 'v2\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/a.txt"
  write_bucket_manifest
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  run cat "${DEST}/a.txt"; assert_output "v2"
  run cat "${DEST}/a.txt.prev"; assert_output "v1"

  printf 'v3\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/a.txt"
  mkdir -p "${ASSET_SYNC_FIXTURE_BUCKET}/locked"
  printf 'c\n' > "${ASSET_SYNC_FIXTURE_BUCKET}/locked/c.txt"
  write_bucket_manifest
  mkdir -p "${DEST}/locked/c.txt/c.txt"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  [ "$status" -eq 6 ]
  run cat "${DEST}/a.txt"; assert_output "v2"
  run cat "${DEST}/a.txt.prev"; assert_output "v1"
}

# UT-INFRA-436 — FR49: an already-current box (every manifest file already
# matches what is installed) writes nothing — verified by mtime.
@test "UT-INFRA-436: asset-sync.sh pull on an already-current box writes nothing" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  local before after
  before="$(stat -c %Y "${DEST}/scripts/boot.sh")"
  sleep 1
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  assert_output --partial "already current"
  after="$(stat -c %Y "${DEST}/scripts/boot.sh")"
  [ "$before" = "$after" ]
  [ ! -e "${DEST}/scripts/boot.sh.prev" ]
}

# UT-INFRA-437 — FR49: the staging directory is removed on a successful
# pull — no `.onbox-staging.*` entry is left under dest-dir.
@test "UT-INFRA-437: asset-sync.sh pull removes its staging directory on success" {
  seed_bucket
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_success
  run find "$DEST" -maxdepth 1 -name '.onbox-staging.*'
  assert_output ""
}

# UT-INFRA-438 — FR49: the staging directory is removed on a refused pull
# (checksum mismatch) too — not only on success.
@test "UT-INFRA-438: asset-sync.sh pull removes its staging directory on refusal" {
  seed_bucket
  sed -i 's/.*scripts\/boot.sh/0000000000000000000000000000000000000000000000000000000000000000  scripts\/boot.sh/' \
    "${ASSET_SYNC_FIXTURE_BUCKET}/manifest.sha256"
  run "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST"
  assert_failure
  run find "$DEST" -maxdepth 1 -name '.onbox-staging.*'
  assert_output ""
}

# UT-INFRA-439 — FR49: the staging directory is removed even on an
# unexpected abort (the process killed mid-run) — exercises the EXIT trap
# itself, not just the handled failure returns above.
@test "UT-INFRA-439: asset-sync.sh pull removes its staging directory on an aborted run" {
  mkdir -p "$ASSET_SYNC_FIXTURE_BUCKET"
  local i
  for i in $(seq 1 40); do
    printf 'content-%d\n' "$i" > "${ASSET_SYNC_FIXTURE_BUCKET}/file-${i}.txt"
  done
  write_bucket_manifest

  # setsid gives the script its own process group — a bare `kill -TERM
  # "$pid"` only signals the top-level script process, never the
  # grandchild it may be mid-fork/exec on (here, the aws-stub call inside
  # fetch_manifest). Under load that grandchild can outlive the killed
  # parent, finish moments later, and RECREATE the staging dir (with just
  # that one file) after the trap already removed it — a flaky false
  # negative, not a real defect. Signaling the whole process group (`kill
  # -TERM -- "-$pid"`) kills every descendant together, matching how a
  # real abort (systemd/OOM tearing down the whole process tree) behaves.
  setsid "$SCRIPT" pull "$ASSET_SYNC_FIXTURE_PREFIX" "$DEST" &
  local pid=$!
  local tries=0
  while [ -z "$(find "$DEST" -maxdepth 1 -name '.onbox-staging.*' 2>/dev/null)" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 1000 ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "staging directory never appeared — cannot exercise the abort path"
    fi
    sleep 0.005
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  run find "$DEST" -maxdepth 1 -name '.onbox-staging.*'
  assert_output ""
}
