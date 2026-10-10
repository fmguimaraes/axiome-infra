# shellcheck shell=bash
# Fixture for the aws stub — AXI-1950's scripts/asset-sync.sh tests.
# Emulates `aws s3 cp <s3-uri> <dest>` for BOTH directions (pull and
# publish) by copying through a local directory standing in for the
# bucket, keyed on the env vars the test's setup() exports:
#   ASSET_SYNC_FIXTURE_BUCKET  — local dir standing in for the bucket root
#   ASSET_SYNC_FIXTURE_PREFIX  — the s3://... prefix used in the test (no
#                                 trailing slash), so the suffix after it is
#                                 the key relative to ASSET_SYNC_FIXTURE_BUCKET
# A `cp` with a `s3://...` source is a PULL (bucket -> local); with a
# `s3://...` destination it is a PUBLISH (local -> bucket).
stub_respond() {
  local argv="$1" parts src dest
  read -ra parts <<< "$argv"
  [ "${parts[0]:-}" = "s3" ] && [ "${parts[1]:-}" = "cp" ] || { return 99; }
  src="${parts[2]:-}"
  dest="${parts[3]:-}"
  case "$src" in
    s3://*) fixture_pull "$src" "$dest" ;;
    *) fixture_publish "$src" "$dest" ;;
  esac
}

fixture_pull() {
  local src="$1" dest="$2" rel
  rel="${src#"${ASSET_SYNC_FIXTURE_PREFIX}"/}"
  [ -f "${ASSET_SYNC_FIXTURE_BUCKET}/${rel}" ] || return 1
  mkdir -p "$(dirname "$dest")"
  cp "${ASSET_SYNC_FIXTURE_BUCKET}/${rel}" "$dest"
  return 0
}

fixture_publish() {
  local src="$1" dest="$2" rel
  rel="${dest#"${ASSET_SYNC_FIXTURE_PREFIX}"/}"
  mkdir -p "$(dirname "${ASSET_SYNC_FIXTURE_BUCKET}/${rel}")"
  cp "$src" "${ASSET_SYNC_FIXTURE_BUCKET}/${rel}"
  return 0
}
