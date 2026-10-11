#!/usr/bin/env bash
# tests/stubs/_common.sh — shared engine for the PATH-shim stubs (aws, docker,
# psql, curl, ssh, terraform, git). Sourced by each stub, never run directly.
# Configuration contract: see tests/README.md.

# _stub_fd_open <fd> — true if file descriptor <fd> is open for writing in
# THIS process. Used to pick between the fixed-FD path (survives a caller
# that execs with `env -i` / a replaced environment, FR62/AC56) and the
# env-var path (used only when a stub is invoked outside stub_setup, which
# is itself a contract violation — see tests/README.md).
_stub_fd_open() {
  { : >&"$1"; } 2>/dev/null
}

_stub_log() {
  local name="$1"; shift
  if _stub_fd_open 88; then
    {
      echo "### CALL: ${name}"
      printf '%s\n' "$@"
      echo "### END"
    } >&88
  else
    local log="${STUB_LOG:-/dev/null}"
    {
      echo "### CALL: ${name}"
      printf '%s\n' "$@"
      echo "### END"
    } >> "$log"
  fi
}

# An unconfigured call is recorded as an INDEPENDENT FACT — a file write,
# never only an exit code — so a caller doing `cmd 2>/dev/null || true`,
# `x="$(cmd)"`, `cmd & wait`, running cmd in a subshell/pipeline, OR execing
# with a cleared/replaced environment (`env -i PATH=… aws …`) can never
# make the detection disappear (NFR2/NFR5, FR62/AC56). Fixed FD 87, opened
# by stub_setup on the same file $STUB_FAIL_LOG points at, is inherited by
# every descendant process regardless of its own environment — env vars
# can be dropped, open file descriptors cannot. tests/helpers/setup.bash's
# default `teardown()` reads $STUB_FAIL_LOG; a test file that defines its
# own teardown() MUST call `stub_teardown` — see tests/README.md.
_stub_record_unconfigured() {
  local name="$1" joined="$2"
  if _stub_fd_open 87; then
    printf 'UNCONFIGURED: %s %s\n' "$name" "$joined" >&87
  else
    local fail_log="${STUB_FAIL_LOG:-}"
    [ -n "$fail_log" ] && printf 'UNCONFIGURED: %s %s\n' "$name" "$joined" >> "$fail_log"
  fi
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
