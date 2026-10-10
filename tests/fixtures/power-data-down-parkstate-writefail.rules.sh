# shellcheck shell=bash
# Fixture for the aws stub — power-data.sh dev down where the lock is
# acquired successfully but the IMMEDIATE park-state.env write (before any
# RDS/Redis mutation) fails. Captures the real lock body (with its runtime-
# random token) via LOCK_BODY_CAPTURE_FILE on put-object, and replays it on
# the subsequent get-object so lock_release's token-match check actually
# matches the real token — this is what lets the test assert the lock was
# genuinely released, not just that release was attempted. UT-INFRA-204.
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
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
    *"put-object"*"locks/data-tier.json"*)
      [ -n "${LOCK_BODY_CAPTURE_FILE:-}" ] && cat > "$LOCK_BODY_CAPTURE_FILE"
      echo '{"ETag":"\"lock-etag-1\""}'
      return 0
      ;;
    *"get-object"*"locks/data-tier.json"*)
      if [ -n "${LOCK_BODY_CAPTURE_FILE:-}" ] && [ -s "${LOCK_BODY_CAPTURE_FILE}" ]; then
        cp "${LOCK_BODY_CAPTURE_FILE}" "${outfile}"
      else
        printf '{}' > "${outfile}"
      fi
      echo '{"ETag":"\"lock-etag-1\""}'
      return 0
      ;;
    *"delete-object"*"locks/data-tier.json"*)
      return 0
      ;;
    *"s3"*"cp"*"park-state.env"*)
      echo "An error occurred (SlowDown) when calling the PutObject operation"
      return 1
      ;;
    *)
      return 99
      ;;
  esac
}
