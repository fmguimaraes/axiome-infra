# shellcheck shell=bash
# Fixture for UT-INFRA-537 (AXI-1973) — proves scripts/lock.sh's tmp-file
# cleanup trap composes with lock_install_exit_trap's own release trap in
# the SAME process: a lock_status call (get-object, exercising _lock_fetch's
# tmpfile register/cleanup) followed by the installed exit trap releasing a
# lock marked with a FIXED token (so this fixture can assert the match
# without needing a real lock_acquire round trip first).
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"get-object"*"axiome-dev-system"*"locks/deploy.json"*)
      printf '%s' '{"name":"deploy","actor":"me","operation":"test op","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"fixed-token-537"}' > "${outfile}"
      echo '{"ETag":"\"etag1\""}'
      return 0
      ;;
    *"delete-object"*"axiome-dev-system"*"locks/deploy.json"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
