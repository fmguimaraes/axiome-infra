# shellcheck shell=bash
# Fixture for the curl stub — power.sh <env> up's readiness poll never turns
# 200 (EC12: a 503-with-reasons is never read as ready). UT-INFRA-186. The
# two call shapes power.sh makes against the SAME url are told apart by
# "-o" "/dev/null" (the polling call, -f so a non-2xx is a curl failure) vs
# its absence (the diagnostic body-capture call made once, after the
# deadline, with -sS only).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"-o"*"/dev/null"*"/api/v1/health/ready"*)
      return 22
      ;;
    *"/api/v1/health/ready"*)
      echo '{"status":"not_ready","services":[{"service":"organization","status":"unhealthy","reason":"schema_behind","timestamp":"2026-10-10T00:00:00Z"}]}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
