# shellcheck shell=bash
# Fixture for the aws stub — scripts/refresh-env.sh's
# `aws ssm get-parameters-by-path --output json` call. Two ways to shape
# the response, same call:
#
#   REFRESH_ENV_FIXTURE_SSM_JSON  — when set, returned VERBATIM (a full
#     `{"Parameters":[{"Name":...,"Value":...}]}` document). Use this when a
#     test needs to put an exact byte sequence (e.g. a literal newline or
#     tab, written as the JSON escapes \n / \t) into a Value — the simpler
#     TSV builder below cannot represent that unambiguously.
#
#   REFRESH_ENV_FIXTURE_SSM_TSV   — the older "<path>\t<value>" lines, one
#     per parameter (AXI-1950's original shape, matching the real CLI's
#     `--output text` for the `[Name,Value]` query). Still supported so
#     every AXI-1950 test keeps working unmodified: built into the same
#     JSON shape via jq before being returned, since the script itself now
#     always requests `--output json`.
#
# REFRESH_ENV_FIXTURE_SSM_FAIL=1 simulates an unreachable/erroring call
# (non-zero return, no output) regardless of which of the above is set.
stub_respond() {
  case "$1" in
    *"get-parameters-by-path"*)
      if [ "${REFRESH_ENV_FIXTURE_SSM_FAIL:-0}" = "1" ]; then
        return 1
      fi
      if [ -n "${REFRESH_ENV_FIXTURE_SSM_JSON:-}" ]; then
        printf '%s' "${REFRESH_ENV_FIXTURE_SSM_JSON}"
        return 0
      fi
      printf '%s' "${REFRESH_ENV_FIXTURE_SSM_TSV:-}" | jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t"))
        | map({Name: .[0], Value: (.[1:] | join("\t"))})
        | {Parameters: .}
      '
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
