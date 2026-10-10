# shellcheck shell=bash
# Fixture for the docker stub — scripts/roll-service.sh (AXI-1953, review
# bounce #1: facts emission must be scoped to this run and unprefixed).
#
#   compose ... pull <targets>                              -> rc ROLL_FIXTURE_PULL_RC (0)
#   compose ... up -d <targets>                              -> rc ROLL_FIXTURE_UP_RC (0)
#   compose ... logs --no-color --no-log-prefix migrate      -> the FAILURE-path
#       diagnostic call (no --since): prints ROLL_FIXTURE_MIGRATE_LOG.
#   compose ... logs --no-log-prefix --since <ts> migrate     -> the SUCCESS-path
#       facts read: prints ROLL_FIXTURE_FACTS_NEW only — NEVER
#       ROLL_FIXTURE_FACTS_OLD, which this fixture only returns when the
#       call has NO `--since` token at all (simulating real `docker compose
#       logs` returning the FULL history when unscoped). A regression that
#       drops --since from the real script's call would make
#       ROLL_FIXTURE_FACTS_OLD appear in this fixture's output.
#   Any "logs ... migrate" call that is MISSING `--no-log-prefix` gets a
#   fake "migrate-1  | " prefix added to every line (simulating real
#   compose's default), which breaks the script's own `^MIGRATION_FACTS:`
#   anchor — a regression that drops --no-log-prefix would make the
#   script report MIGRATION_FACTS_UNAVAILABLE instead of the facts.
#   rc ROLL_FIXTURE_FACTS_RC (default 0).
stub_respond() {
  case "$1" in
    *"logs "*"migrate"*)
      respond_logs "$1"
      ;;
    *" pull "*)
      return "${ROLL_FIXTURE_PULL_RC:-0}"
      ;;
    *" up -d "*)
      return "${ROLL_FIXTURE_UP_RC:-0}"
      ;;
    *)
      return 99
      ;;
  esac
}

respond_logs() {
  local argv="$1" body
  case "$argv" in
    *"--since"*)
      body="${ROLL_FIXTURE_FACTS_NEW:-}"
      ;;
    *)
      if [ -n "${ROLL_FIXTURE_FACTS_OLD:-}${ROLL_FIXTURE_FACTS_NEW:-}" ]; then
        body="$(printf '%s\n%s' "${ROLL_FIXTURE_FACTS_OLD:-}" "${ROLL_FIXTURE_FACTS_NEW:-}")"
      else
        body="${ROLL_FIXTURE_MIGRATE_LOG:-}"
      fi
      ;;
  esac
  case "$argv" in
    *"--no-log-prefix"*) : ;;
    *) body="$(printf '%s\n' "${body}" | sed 's/^/migrate-1  | /')" ;;
  esac
  printf '%s' "${body}"
  return "${ROLL_FIXTURE_FACTS_RC:-0}"
}
