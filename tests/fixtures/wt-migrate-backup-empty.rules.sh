# shellcheck shell=bash
# Fixture for the docker stub — pg_dump "succeeds" but writes nothing
# (empty dump); migrate-gate must never be reached.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"pg_dump"*) return 0 ;;
    *) return 99 ;;
  esac
}
