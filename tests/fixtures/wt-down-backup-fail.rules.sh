# shellcheck shell=bash
# Fixture for the docker stub — same as wt-down-generic.rules.sh, except
# pg_dump fails, to prove --purge-shared refuses on a failed backup.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"compose version"*) return 0 ;;
    *"pg_dump"*) return 1 ;;
    *) return 99 ;;
  esac
}
