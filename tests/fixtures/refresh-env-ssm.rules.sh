# shellcheck shell=bash
# Fixture for the aws stub — scripts/refresh-env.sh's
# `aws ssm get-parameters-by-path` call. Responds from
# REFRESH_ENV_FIXTURE_SSM_TSV (pre-built "<path>\t<value>" lines, one per
# parameter, matching the real CLI's --output text shape for the
# `[Name,Value]` query) when REFRESH_ENV_FIXTURE_SSM_FAIL is unset/0;
# returns non-zero (simulating an unreachable/erroring call) otherwise.
stub_respond() {
  case "$1" in
    *"get-parameters-by-path"*)
      if [ "${REFRESH_ENV_FIXTURE_SSM_FAIL:-0}" = "1" ]; then
        return 1
      fi
      printf '%s' "${REFRESH_ENV_FIXTURE_SSM_TSV:-}"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
