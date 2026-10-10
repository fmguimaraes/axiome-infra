# shellcheck shell=bash
# Fixture for the curl stub — scripts/deploy-prod.sh readiness/health polling
# (AXI-1954, FR24/FR26, EC12). UT-INFRA-330..352.
#
# Env knobs:
#   DEPLOY_FIXTURE_READY_SEQUENCE   comma-separated HTTP codes returned on
#                                   successive polls (default "200"); the
#                                   last value repeats once exhausted.
#   DEPLOY_FIXTURE_READY_COUNTER    per-test scratch file for the sequence
#   DEPLOY_FIXTURE_READY_BODY       JSON body returned alongside a non-200
stub_respond() {
  # $1 (the joined curl argv) is unconditionally ignored here — every
  # invocation shape (poll_ready's full body+footer and poll_simple_health's
  # identical wrapped-footer call, see scripts/deploy-prod.sh) is served the
  # same next-code-in-sequence response regardless of URL/flags.
  local code
  code="$(next_code)"
  if [ "${code}" = "200" ]; then
    printf '{"status":"ready"}\nHTTP_STATUS:200'
  else
    printf '%s\nHTTP_STATUS:%s' "${DEPLOY_FIXTURE_READY_BODY:-{\"status\":\"not_ready\",\"services\":[{\"service\":\"user\",\"status\":\"unhealthy\",\"reason\":\"database_unreachable\"}]}}" "${code}"
  fi
  return 0
}

next_code() {
  local counter_file="${DEPLOY_FIXTURE_READY_COUNTER:-}" n=0 seq arr
  seq="${DEPLOY_FIXTURE_READY_SEQUENCE:-200}"
  IFS=',' read -r -a arr <<< "${seq}"
  if [ -n "${counter_file}" ] && [ -f "${counter_file}" ]; then
    n="$(cat "${counter_file}")"
  fi
  local code
  if [ "${n}" -lt "${#arr[@]}" ]; then
    code="${arr[$n]}"
  else
    code="${arr[$((${#arr[@]} - 1))]}"
  fi
  [ -n "${counter_file}" ] && printf '%s' "$((n + 1))" > "${counter_file}"
  printf '%s' "${code}"
}
