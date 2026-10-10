# shellcheck shell=bash
# Fixture for the curl stub — scripts/verify-deploy.sh's check_ready() +
# the final ROOT_PATH check (AXI-1954, FR24/FR26/AC18). UT-INFRA-358..361.
#
# check_ready() uses the SAME wrapped-footer shape as deploy-prod.sh's
# poll_ready() (body + trailing `HTTP_STATUS:<code>` line); the ROOT_PATH
# check uses a plain `curl -fsS ... > /dev/null` (no body/footer wrapping —
# real curl's own exit code IS the pass/fail signal there, no stub-shape
# ambiguity to worry about, unlike the poll_simple_health() case this
# fixture's sibling (deploy-prod-curl.rules.sh) exists to avoid).
#
# Env knobs:
#   VERIFY_FIXTURE_READY_CODE   HTTP code check_ready()'s GET returns (200)
#   VERIFY_FIXTURE_READY_BODY   JSON body alongside a non-200 (default has a
#                                schema_behind reason for the "back" service)
#   VERIFY_FIXTURE_ROOT_RC      exit code of the plain `-fsS` ROOT_PATH call (0)
_verify_fixture_default_body() {
  printf '{"status":"not_ready","services":[{"service":"back","status":"unhealthy","reason":"schema_behind"}]}'
}

stub_respond() {
  local argv="$1"
  case "$argv" in
    *"-fsS"*)
      return "${VERIFY_FIXTURE_ROOT_RC:-0}" ;;
    *)
      local code="${VERIFY_FIXTURE_READY_CODE:-200}" body
      if [ "${code}" = "200" ]; then
        printf '{"status":"ready"}\nHTTP_STATUS:200'
      else
        body="${VERIFY_FIXTURE_READY_BODY:-$(_verify_fixture_default_body)}"
        printf '%s\nHTTP_STATUS:%s' "${body}" "${code}"
      fi
      return 0 ;;
  esac
}
