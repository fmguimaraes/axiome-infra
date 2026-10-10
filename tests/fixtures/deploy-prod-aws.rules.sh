# shellcheck shell=bash
# Fixture for the aws stub — scripts/deploy-prod.sh (AXI-1954, epic AXI-1944,
# FR14-21/EC1/EC13/AC11-14/18/19/28). UT-INFRA-330..352.
#
# deploy-prod.sh makes THREE kinds of SSM round-trip over the same `aws`
# binary: a read-only preflight, the roll-to-TAG, and (on failure) a
# restore-roll-to-PRIOR_TAG. Each is one `ssm send-command` + one or more
# `ssm get-command-invocation` calls. This fixture tells them apart by
# sniffing the EMBEDDED SCRIPT TEXT inside send-command's own --parameters
# argument (the real content ssm-exec.sh ships) and returns a distinct fake
# command-id per kind; every later get-command-invocation call carries that
# same --command-id, so Status/StandardOutputContent/StandardErrorContent
# can be served per-kind without any extra state file.
#
# Env knobs (all optional, sane defaults for the "everything passes" case):
#   DEPLOY_FIXTURE_TAG / DEPLOY_FIXTURE_PRIOR     tag strings the test used
#                                                  for IMAGE_TAG='<tag>' sniffing
#                                                  (default newtag123 / oldtag000)
#   DEPLOY_FIXTURE_INSTANCE_MISSING (0/1)         ec2 describe-instances finds
#                                                  nothing running (EC1)
#   DEPLOY_FIXTURE_SOURCE_MISSING (0/1)           TAG not found in ECR
#   DEPLOY_FIXTURE_SOURCE_DIGEST / _STABLE_DIGEST  default sha256:source / sha256:priorstable
#   DEPLOY_FIXTURE_RETAG_RC                       put-image :stable exit code (0)
#   DEPLOY_FIXTURE_DATATIER_STATE  free|held       (free)
#   DEPLOY_FIXTURE_DEPLOY_LOCK_STATE free|held     (free)
#   DEPLOY_FIXTURE_LOCK_TOKEN_FILE                 scratch file this fixture
#                                                   uses to remember the REAL
#                                                   token lock_acquire wrote
#                                                   via put-object, so a later
#                                                   get-object (release's own
#                                                   token check) agrees with
#                                                   it instead of a canned
#                                                   value that would make
#                                                   lock.sh's "caller's token
#                                                   does not match" guard fire
#                                                   on every passing test.
#   DEPLOY_FIXTURE_PREFLIGHT_OUT                   full canned stdout of the
#                                                   preflight remote script
#   DEPLOY_FIXTURE_PREFLIGHT_RC                    ssm-exec exit for preflight (0)
#   DEPLOY_FIXTURE_ROLL_OUT / _ROLL_RC             canned stdout/exit for the
#                                                   roll-to-TAG call
#   DEPLOY_FIXTURE_RESTORE_OUT / _RESTORE_RC       canned stdout/exit for the
#                                                   restore-to-PRIOR call
#   DEPLOY_FIXTURE_SNAPSHOT_CREATE_RC / _WAIT_RC   rds create/wait exit codes (0)
#   DEPLOY_FIXTURE_SNAPSHOT_LIST                   describe-db-snapshots TSV body
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"--version"*) echo "aws-cli/2.22.22 Python/3.11.6 Linux/5.10 exe/x86_64"; return 0 ;;
    *"sts get-caller-identity"*) echo "arn:aws:iam::111122223333:user/test"; return 0 ;;

    *"ec2 describe-instances"*)
      if [ "${DEPLOY_FIXTURE_INSTANCE_MISSING:-0}" = "1" ]; then echo "None"; else echo "i-fakebox"; fi
      return 0 ;;

    *"ecr describe-images"*"stable"*)
      echo "${DEPLOY_FIXTURE_STABLE_DIGEST:-sha256:priorstable}"; return 0 ;;
    *"ecr describe-images"*)
      if [ "${DEPLOY_FIXTURE_SOURCE_MISSING:-0}" = "1" ]; then echo "None"; return 0; fi
      # deploy-prod.sh calls this TWICE for the same TAG: once at preflight
      # (to set DEPLOY_DIGEST) and once again inside ecr_retag_stable just
      # before put-image (review bounce #1 item 5's re-check). A counter
      # file lets a test simulate the tag moving BETWEEN those two calls —
      # first call returns SOURCE_DIGEST, every call after that returns
      # SOURCE_DIGEST_RETAG (defaulting to the same value: no movement).
      local count_file="${DEPLOY_FIXTURE_DESCRIBE_CALL_COUNT_FILE:-}"
      if [ -n "${count_file}" ]; then
        local n=0
        [ -f "${count_file}" ] && n="$(cat "${count_file}")"
        n=$((n + 1))
        printf '%s' "${n}" > "${count_file}"
        if [ "${n}" -gt 1 ] && [ -n "${DEPLOY_FIXTURE_SOURCE_DIGEST_RETAG:-}" ]; then
          echo "${DEPLOY_FIXTURE_SOURCE_DIGEST_RETAG}"; return 0
        fi
      fi
      echo "${DEPLOY_FIXTURE_SOURCE_DIGEST:-sha256:source}"
      return 0 ;;
    *"ecr batch-get-image"*)
      echo '{"fake":"manifest"}'; return 0 ;;
    *"ecr put-image"*)
      return "${DEPLOY_FIXTURE_RETAG_RC:-0}" ;;

    *"get-object"*"locks/data-tier.json"*)
      # DEPLOY_FIXTURE_DATATIER_STATE_RACE_FILE (review bounce #1 item 6):
      # a counter file lets a test simulate a park STARTING between the two
      # lock_require_free calls (top-of-script, and the post-preflight
      # re-check) — first call "free", every call after that "held".
      local race_file="${DEPLOY_FIXTURE_DATATIER_STATE_RACE_FILE:-}" state="${DEPLOY_FIXTURE_DATATIER_STATE:-free}"
      if [ -n "${race_file}" ]; then
        local rn=0
        [ -f "${race_file}" ] && rn="$(cat "${race_file}")"
        rn=$((rn + 1))
        printf '%s' "${rn}" > "${race_file}"
        [ "${rn}" -gt 1 ] && state="held"
      fi
      if [ "${state}" = "held" ]; then
        local outfile="${argv##* }"
        printf '%s' '{"name":"data-tier","actor":"ops@example.com","operation":"park","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"t"}' > "${outfile}"
        echo '{"ETag":"\"dt\""}'
        return 0
      fi
      echo "An error occurred (404) when calling the GetObject operation: Not Found"
      return 254 ;;

    *"put-object"*"locks/deploy.json"*)
      if [ "${DEPLOY_FIXTURE_DEPLOY_LOCK_STATE:-free}" = "held" ]; then
        echo "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold"
        return 254
      fi
      # The real body (with the real acquire token) is piped on stdin via
      # `--body /dev/stdin` — capture it so a later get-object (release's
      # own token check) sees the SAME token lock_acquire generated, not a
      # canned one, or every release in every test would spuriously fail
      # lock.sh's "caller's token does not match" guard.
      local body token_file
      body="$(cat)"
      token_file="${DEPLOY_FIXTURE_LOCK_TOKEN_FILE:-}"
      if [ -n "${token_file}" ]; then
        printf '%s' "${body}" | jq -r '.token' > "${token_file}"
      fi
      echo '{"ETag":"\"dl\""}'
      return 0 ;;
    *"get-object"*"locks/deploy.json"*)
      local outfile="${argv##* }"
      if [ "${DEPLOY_FIXTURE_DEPLOY_LOCK_STATE:-free}" = "held" ]; then
        printf '%s' '{"name":"deploy","actor":"other@example.com","operation":"deploy tag=x","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"held-token"}' > "${outfile}"
        echo '{"ETag":"\"dl\""}'
        return 0
      fi
      local saved_token="self-token" token_file="${DEPLOY_FIXTURE_LOCK_TOKEN_FILE:-}"
      [ -n "${token_file}" ] && [ -f "${token_file}" ] && saved_token="$(cat "${token_file}")"
      printf '{"name":"deploy","actor":"test@example.com","operation":"deploy","host":"h","acquired_at":"2026-10-10T00:00:00Z","token":"%s"}' "${saved_token}" > "${outfile}"
      echo '{"ETag":"\"dl\""}'
      return 0 ;;
    *"delete-object"*"locks/deploy.json"*)
      return 0 ;;

    *"rds create-db-snapshot"*)
      return "${DEPLOY_FIXTURE_SNAPSHOT_CREATE_RC:-0}" ;;
    *"rds wait db-snapshot-available"*)
      return "${DEPLOY_FIXTURE_SNAPSHOT_WAIT_RC:-0}" ;;
    *"rds describe-db-snapshots"*)
      printf '%s' "${DEPLOY_FIXTURE_SNAPSHOT_LIST:-}"; return 0 ;;
    *"rds delete-db-snapshot"*)
      return 0 ;;

    *"ssm send-command"*)
      ssm_command_id "${argv}"
      return 0 ;;
    *"ssm cancel-command"*)
      return 0 ;;
    *"cmd-preflight"*"--query Status"*)
      echo "Success"; return 0 ;;
    *"cmd-preflight"*"--query StandardOutputContent"*)
      printf '%s' "${DEPLOY_FIXTURE_PREFLIGHT_OUT:-$(default_preflight_out)}"; return 0 ;;
    *"cmd-preflight"*"--query StandardErrorContent"*)
      return 0 ;;

    *"cmd-roll"*"--query Status"*)
      [ "${DEPLOY_FIXTURE_ROLL_RC:-0}" = "2" ] && { echo "Pending"; return 0; }
      [ "${DEPLOY_FIXTURE_ROLL_RC:-0}" = "1" ] && { echo "Failed"; return 0; }
      echo "Success"; return 0 ;;
    *"cmd-roll"*"--query StandardOutputContent"*)
      printf '%s' "${DEPLOY_FIXTURE_ROLL_OUT:-$(default_roll_out)}"; return 0 ;;
    *"cmd-roll"*"--query StandardErrorContent"*)
      return 0 ;;

    *"cmd-restore"*"--query Status"*)
      [ "${DEPLOY_FIXTURE_RESTORE_RC:-0}" = "1" ] && { echo "Failed"; return 0; }
      echo "Success"; return 0 ;;
    *"cmd-restore"*"--query StandardOutputContent"*)
      printf '%s' "${DEPLOY_FIXTURE_RESTORE_OUT:-$(default_roll_out)}"; return 0 ;;
    *"cmd-restore"*"--query StandardErrorContent"*)
      return 0 ;;

    *)
      return 99 ;;
  esac
}

# Assigns a fake command-id by sniffing the embedded script text shipped in
# send-command's own --parameters argument.
ssm_command_id() {
  local argv="$1" tag="${DEPLOY_FIXTURE_TAG:-newtag123}" prior="${DEPLOY_FIXTURE_PRIOR:-oldtag000}"
  case "${argv}" in
    *"MIGRATE_STATUS_RC"*) echo "cmd-preflight" ;;
    *"IMAGE_TAG='${prior}'"*) echo "cmd-restore" ;;
    *"IMAGE_TAG='${tag}'"*) echo "cmd-roll" ;;
    *) echo "cmd-unknown" ;;
  esac
}

default_preflight_out() {
  printf 'PRIOR_TAG=%s\nCOMPOSE_GATE=present\nMIGRATE_STATUS_RC=0\nPENDING_COUNT=0\n' "${DEPLOY_FIXTURE_PRIOR:-oldtag000}"
}

default_roll_out() {
  printf '=== docker compose pull gateway user-service organization-service event-service ===\n=== docker compose up -d gateway user-service organization-service event-service ===\n=== Roll complete: backend -> done ===\n'
}
