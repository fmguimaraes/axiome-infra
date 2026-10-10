# shellcheck shell=bash
# Fixture for UT-INFRA-536 (AXI-1973) — a get-object call that sleeps before
# responding, long enough to signal the process (TERM) while it is still
# the running step inside _lock_fetch, after the tmpfile has been created
# and registered but before it is read/removed.
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"get-object"*"axiome-dev-system"*"locks/deploy.json"*)
      sleep 5
      printf '%s' '{"name":"deploy","actor":"me","operation":"x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"t1"}' > "${outfile}"
      echo '{"ETag":"\"etag\""}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
