# shellcheck shell=bash
# Fixture for the docker stub — scripts/seed-environment.sh --check mode
# (AXI-1954, FR21). UT-INFRA-353..357.
#
# --check mode (CHECK_MODE=1) never calls run_sql_local (Step 1 is skipped
# entirely) and takes exactly ONE count_local call per entity (no
# settle-loop) — so this fixture only needs to answer the four COUNT
# queries seed-environment.sh issues via `docker compose ... exec -T
# postgres psql -tAc "<SQL>" ...`. A call to `exec -T postgres psql` WITHOUT
# `-tAc` (i.e. the workspace-roles SQL file piped on stdin by Step 1) is
# intentionally left unconfigured — if --check ever reaches it, the test
# must fail loudly, not silently answer it.
#
# Env knobs:
#   SEED_FIXTURE_RULES_COUNT      (default 2, matches the fixture seed-rules.ts)
#   SEED_FIXTURE_TEMPLATES_COUNT  (default 2, matches the fixture templates file)
#   SEED_FIXTURE_ROLES_COUNT      (default 5 = matches)
#   SEED_FIXTURE_ADMIN_COUNT      (default 1 = matches)
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"-tAc"*"organization_svc.rules"*)
      echo "${SEED_FIXTURE_RULES_COUNT:-2}"; return 0 ;;
    *"-tAc"*"organization_svc.dataview_templates"*)
      echo "${SEED_FIXTURE_TEMPLATES_COUNT:-2}"; return 0 ;;
    *"-tAc"*"user_svc.roles"*)
      echo "${SEED_FIXTURE_ROLES_COUNT:-5}"; return 0 ;;
    *"-tAc"*"user_svc.users"*)
      echo "${SEED_FIXTURE_ADMIN_COUNT:-1}"; return 0 ;;
    *)
      return 99 ;;
  esac
}
