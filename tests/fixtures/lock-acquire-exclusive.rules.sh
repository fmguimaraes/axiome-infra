# shellcheck shell=bash
# Fixture for scripts/lock.sh's `lock_acquire_exclusive` helper (AXI-1967,
# FR42/FR43/AC34/AC35), exercised directly as a sourced library function
# (see tests/lock_acquire_exclusive.bats) rather than through any one
# caller script. All three lock names live under the same `dev` bucket;
# each case picks a distinct <name> to acquire so put-object/get-object
# arms don't collide. get-object writes the BODY to the outfile (the last
# argv token) and prints METADATA JSON (ETag) to stdout — the real
# aws-cli split scripts/lock.sh's header "Read path" documents.
# UT-INFRA-408..413.
stub_respond() {
  local argv="$1" outfile
  outfile="${argv##* }"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"
      return 0
      ;;

    # --- acquiring "deploy" always succeeds (UT-INFRA-408/409/411) ---------
    # The real body (with the real acquire token) is piped on stdin via
    # `--body /dev/stdin` — capture it to a scratch file so a later
    # get-object (release's own token check) sees the SAME token
    # lock_acquire generated, not a canned value that would make lock.sh's
    # "caller's token does not match" guard fire on every passing test.
    *"put-object"*"locks/deploy.json"*)
      cat > "${BATS_TEST_TMPDIR:-/tmp}/lock-acquire-exclusive.token.body"
      echo '{"ETag":"\"dep1\""}'
      return 0
      ;;
    *"get-object"*"locks/deploy.json"*)
      if [ -s "${BATS_TEST_TMPDIR:-/tmp}/lock-acquire-exclusive.token.body" ]; then
        cat "${BATS_TEST_TMPDIR:-/tmp}/lock-acquire-exclusive.token.body" > "${outfile}"
      else
        printf '%s' '{"name":"deploy","actor":"me","operation":"x","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"self-token"}' > "${outfile}"
      fi
      echo '{"ETag":"\"dep1\""}'
      return 0
      ;;
    *"delete-object"*"locks/deploy.json"*)
      return 0
      ;;

    # --- "data-tier" is FREE or HELD per LOCK_EXCLUSIVE_DATATIER_STATE ------
    *"get-object"*"locks/data-tier.json"*)
      if [ "${LOCK_EXCLUSIVE_DATATIER_STATE:-free}" = "held" ]; then
        printf '%s' '{"name":"data-tier","actor":"ops@example.com","operation":"park","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"dt-tok"}' > "${outfile}"
        echo '{"ETag":"\"dt1\""}'
        return 0
      fi
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;

    # --- "apply" is FREE or HELD per LOCK_EXCLUSIVE_APPLY_STATE -------------
    # put-object also exists here (UT-INFRA-426 — lock.sh acquire accepts
    # 'apply' as a lock name on the CLI surface too, acquiring it directly
    # rather than as one of lock_acquire_exclusive's <other> checks).
    *"put-object"*"locks/apply.json"*)
      echo '{"ETag":"\"ap1\""}'
      return 0
      ;;
    *"get-object"*"locks/apply.json"*)
      if [ "${LOCK_EXCLUSIVE_APPLY_STATE:-free}" = "held" ]; then
        printf '%s' '{"name":"apply","actor":"ci-apply@example.com","operation":"terraform apply","host":"h","acquired_at":"2026-10-10T10:00:00Z","token":"ap-tok"}' > "${outfile}"
        echo '{"ETag":"\"ap1\""}'
        return 0
      fi
      echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
      return 254
      ;;

    *)
      return 99
      ;;
  esac
}
