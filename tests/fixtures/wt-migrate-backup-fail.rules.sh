# shellcheck shell=bash
# Fixture for the docker stub — pg_dump fails; migrate-gate must never be
# reached. If it is, this fixture's catch-all (99) fails the test loudly.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"pg_dump"*) return 1 ;;
    *) return 99 ;;
  esac
}
