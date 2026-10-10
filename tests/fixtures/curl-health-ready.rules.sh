# shellcheck shell=bash
# Fixture for the curl stub — power.sh <env> up's readiness poll (FR26).
# UT-INFRA-185/186. The rule only cares whether the URL asked for is the
# readiness endpoint, not liveness — the whole point of this story's change.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"/api/v1/health/ready"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
