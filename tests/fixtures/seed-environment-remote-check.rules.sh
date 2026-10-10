# shellcheck shell=bash
# Fixture for the aws stub — exercises scripts/seed-environment.sh's REMOTE
# `--check` path (AXI-1968: "the developer of AXI-1954 left it untested" —
# tests/seed-environment-check.bats's UT-INFRA-357 only covers usage
# parsing, never an actual ssm-exec.sh/aws round trip).
#
# count_remote() in seed-environment.sh ships a fresh `docker run ...
# psql -tAc <query>` one-liner to ssm-exec.sh for EACH of the 4 entities
# (rules/templates/roles/admin) it checks, one `aws ssm send-command` per
# entity. The query text (via ssm-exec.sh's `jq --arg c "${REMOTE_CMD}"`)
# is embedded in that send-command's own argv, so this fixture reads it
# there to pick a DISTINCT, content-derived COMMAND_ID per entity — the
# only way a single generic `aws` stub can hand back 4 DIFFERENT counts to
# 4 calls that otherwise look identical by the time get-command-invocation
# polls for a result (that call only carries --command-id, never the SQL).
#
# Env knobs (mirrors the local-mode fixture's naming):
#   SEED_FIXTURE_RULES_COUNT       (default 2, matches seed-environment-back)
#   SEED_FIXTURE_TEMPLATES_COUNT   (default 2)
#   SEED_FIXTURE_ROLES_COUNT       (default 5)
#   SEED_FIXTURE_ADMIN_COUNT       (default 1)
stub_respond() {
  local argv="$1"
  case "${argv}" in
    *"ec2 describe-instances"*)
      printf '%s' "i-fakebox"
      return 0
      ;;
    *"ssm send-command"*)
      case "${argv}" in
        *"organization_svc.rules"*)        printf '%s' "cmd-rules" ;;
        *"organization_svc.dataview_templates"*) printf '%s' "cmd-templates" ;;
        *"user_svc.roles"*)                printf '%s' "cmd-roles" ;;
        *"user_svc.users"*)                printf '%s' "cmd-admin" ;;
        *)                                  printf '%s' "cmd-unknown" ;;
      esac
      return 0
      ;;
    *"ssm cancel-command"*)
      return 0
      ;;
    *"--query Status"*)
      printf '%s' "Success"
      return 0
      ;;
    *"--query StandardOutputContent"*)
      case "${argv}" in
        *"cmd-rules"*)     printf '%s' "${SEED_FIXTURE_RULES_COUNT:-2}" ;;
        *"cmd-templates"*) printf '%s' "${SEED_FIXTURE_TEMPLATES_COUNT:-2}" ;;
        *"cmd-roles"*)     printf '%s' "${SEED_FIXTURE_ROLES_COUNT:-5}" ;;
        *"cmd-admin"*)     printf '%s' "${SEED_FIXTURE_ADMIN_COUNT:-1}" ;;
        *)                  printf '' ;;
      esac
      return 0
      ;;
    *"--query StandardErrorContent"*)
      printf ''
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
