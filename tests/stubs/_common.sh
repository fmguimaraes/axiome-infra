#!/usr/bin/env bash
# tests/stubs/_common.sh — shared engine for the PATH-shim stubs (aws, docker,
# psql, curl, ssh, terraform, git). Sourced by each stub, never run directly.
# Configuration contract: see tests/README.md.

_stub_log() {
  local name="$1"; shift
  local log="${STUB_LOG:-/dev/null}"
  {
    echo "### CALL: ${name}"
    printf '%s\n' "$@"
    echo "### END"
  } >> "$log"
}

# An unconfigured call is recorded as an INDEPENDENT FACT — a file write,
# never only an exit code — so a caller doing `cmd 2>/dev/null || true`,
# `x="$(cmd)"`, `cmd & wait`, or running cmd in a subshell/pipeline can never
# make the detection disappear (NFR2/NFR5). tests/helpers/setup.bash's
# default `teardown()` reads $STUB_FAIL_LOG; a test file that defines its
# own teardown() MUST call `stub_teardown` — see tests/README.md.
_stub_record_unconfigured() {
  local name="$1" joined="$2" fail_log="${STUB_FAIL_LOG:-}"
  [ -n "$fail_log" ] && printf 'UNCONFIGURED: %s %s\n' "$name" "$joined" >> "$fail_log"
  echo "STUB FAIL: unconfigured call: ${name} ${joined}" >&2
}

_stub_rules_file() {
  local upper var
  upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  var="${upper}_STUB_RULES"
  printf '%s' "${!var:-}"
}

# stub_main <name> <argv...> — called by every stub's one-line body. Looks
# up <NAME>_STUB_RULES, sources it (it must define `stub_respond
# <joined-argv>`), and prints its stdout / exits with its code. A call with
# no rules file, or whose case arm falls through to `return 99`, is
# unconfigured — see _stub_record_unconfigured above.
stub_main() {
  local name="$1"; shift
  _stub_log "$name" "$@"
  local joined="$*" rules_file out rc
  rules_file="$(_stub_rules_file "$name")"
  if [ -z "$rules_file" ] || [ ! -f "$rules_file" ]; then
    _stub_record_unconfigured "$name" "$joined"
    exit 99
  fi
  # shellcheck disable=SC1090
  . "$rules_file"
  set +e
  out="$(stub_respond "$joined")"
  rc=$?
  set -e
  if [ "$rc" -eq 99 ]; then
    _stub_record_unconfigured "$name" "$joined"
    exit 99
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  exit "$rc"
}
