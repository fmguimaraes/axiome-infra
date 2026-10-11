# shellcheck shell=bash
# AXI-1972 (scope item 5): LastModified was a hardcoded "2030-01-01" —
# fine until 2030, then this fixture would start reporting a STALE object
# (power.sh compares LastModified against the time the command was
# issued) and the test would fail for a reason that has nothing to do
# with what it tests. Computed relative to real "now" via the date stub's
# default passthrough instead, so it never expires.
# AXI-1967: get-object arms for locks/deploy.json and locks/apply.json (both FREE) added — power.sh down now also checks those locks (FR43) before the backup step above.
# Fixture for the aws stub — power.sh <env> down, backup OK line parses, the
# object is non-empty and fresh, but its sha256 object METADATA does not
# match the sha256 the on-box script claimed on its OK line. stop-instances
# /wait are deliberately NOT matched — any call to either is the proof of a
# missed checksum check.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    # AXI-1981 (FR43): power.sh down/up now acquire their OWN compute
    # lock first (lock_acquire_exclusive) before checking deploy/apply.
    # Captures the real acquire token (same pattern as
    # lock-acquire-exclusive.rules.sh) so the auto-release on exit finds
    # the SAME token it wrote, rather than a canned one that would make
    # lock.sh's "caller's token does not match" guard fire.
    *"put-object"*"locks/compute.json"*)
      cat > "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body"
      echo '{"ETag":"\"cl\""}'
      return 0
      ;;
    *"get-object"*"locks/compute.json"*)
      local compute_outfile="${argv##* }"
      if [ -s "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body" ]; then
        cat "${BATS_TEST_TMPDIR:-/tmp}/power-compute-lock.token.body" > "${compute_outfile}"
      else
        printf '%s' '{"name":"compute","actor":"me","operation":"x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"self-token"}' > "${compute_outfile}"
      fi
      echo '{"ETag":"\"cl\""}'
      return 0
      ;;
    *"delete-object"*"locks/compute.json"*)
      return 0
      ;;
    *"get-object"*"locks/deploy.json"*)
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"get-object"*"locks/apply.json"*)
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254
      ;;
    *"describe-instances"*"InstanceId"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"describe-instances"*"State.Name"*)
      echo "running"
      return 0
      ;;
    *"ssm"*"send-command"*)
      echo "cmd-ok-1"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"Status"*)
      echo "Success"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardOutputContent"*)
      echo "MONGO_BACKUP_OK key=backups/mongo/20261010T020000Z.archive.gz sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardErrorContent"*)
      return 0
      ;;
    *"s3api"*"head-object"*"backups/mongo/20261010T020000Z.archive.gz"*)
      echo '{"ContentLength":12345,"LastModified":"'"$(date -u -d '+365 days' +%Y-%m-%dT%H:%M:%S+00:00)"'","Metadata":{"sha256":"0000000000000000000000000000000000000000000000000000000000000"}}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
