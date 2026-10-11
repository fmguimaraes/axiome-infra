# shellcheck shell=bash
# Fixture for UT-INFRA-585 (AXI-1977 close-out sweep item 3) — same
# bucket-via-local-dir emulation as asset-sync-s3.rules.sh, but the fetch
# of one specific file ("file-20.txt") sleeps BEFORE responding, long
# enough for a test to signal (TERM) the process while this stubbed `aws`
# call is genuinely in flight — same pattern as
# tests/fixtures/lock-signal-slow.rules.sh (UT-INFRA-536).
stub_respond() {
  local argv="$1" parts src dest
  read -ra parts <<< "$argv"
  [ "${parts[0]:-}" = "s3" ] && [ "${parts[1]:-}" = "cp" ] || { return 99; }
  src="${parts[2]:-}"
  dest="${parts[3]:-}"
  case "$src" in
    s3://*)
      case "$src" in
        *file-20.txt) sleep 5 ;;
      esac
      fixture_pull "$src" "$dest"
      ;;
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
