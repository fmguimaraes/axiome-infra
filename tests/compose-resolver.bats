#!/usr/bin/env bats
# tests/compose-resolver.bats — scripts/lib/compose-resolve.sh, the ONE
# shared Compose v2 resolver (AXI-1971, FR54/AC47). Exercises the library
# directly through its CLI mode (what the Makefile calls), never through a
# real `make` invocation — see tests/README.md / this story's isolation
# rule. Every scenario below either removes `docker`/`docker-compose` from
# PATH entirely, or answers the docker stub with a CONFIGURED (not
# unconfigured) rule; the real `tests/stubs/docker-compose` shim stays
# unconfigured-by-design the whole file, so any call to it is caught by the
# default `teardown()` (stub_teardown) even if a test forgot to assert it.

load 'helpers/setup'

setup() {
  stub_setup
}

RESOLVER="${BATS_TEST_DIRNAME}/../scripts/lib/compose-resolve.sh"

# _minimal_bin <dir> [extra-stub-names...] — a PATH entry with just enough
# real coreutils for the resolver script's own shebang/body to run, plus
# (optionally) symlinks to specific stubs from tests/stubs — never both
# `docker` AND `docker-compose` unless a test explicitly asks for both.
_minimal_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local bin
  for bin in bash dirname tr env cat; do
    ln -sf "$(command -v "$bin")" "${dir}/${bin}"
  done
  for bin in "$@"; do
    ln -sf "${TESTS_DIR}/stubs/${bin}" "${dir}/${bin}"
  done
}

# UT-INFRA-510 — only the legacy `docker-compose` v1 binary is reachable on
# PATH; there is no `docker` binary AT ALL (the strongest "v1 only" case).
# The resolver must refuse without ever invoking docker-compose.
@test "UT-INFRA-510: refuses when only legacy docker-compose is on PATH (no docker binary at all)" {
  local safe="${BATS_TEST_TMPDIR}/v1-only"
  _minimal_bin "$safe" docker-compose
  run env PATH="$safe" "$RESOLVER"
  assert_failure
  assert_output --partial "Docker Compose v2 not found"
  assert_output --partial "AXI-1952"
  assert_stub_not_called "docker_compose"
  [ ! -s "$STUB_FAIL_LOG" ]
}

# UT-INFRA-511 — `docker` exists but `docker compose version` fails (the
# v2 plugin is not installed — e.g. only a bare v1 install is present
# alongside a modern docker CLI). Still must never call docker-compose.
@test "UT-INFRA-511: refuses when docker exists but compose v2 is unavailable" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/legacy-compose-v2-missing.rules.sh"
  run "$RESOLVER"
  assert_failure
  assert_output --partial "Docker Compose v2 not found"
  assert_output --partial "compose version"
  assert_stub_called docker "version"
  assert_stub_not_called "docker_compose"
  # this test's whole point is the configured probe failure above — clear
  # the (irrelevant) unconfigured-call marker before the shared teardown.
  : > "$STUB_FAIL_LOG"
}

# UT-INFRA-512 — DOCKER_COMPOSE=docker-compose (exact literal) refuses.
@test "UT-INFRA-512: refuses DOCKER_COMPOSE=docker-compose" {
  run env DOCKER_COMPOSE="docker-compose" "$RESOLVER"
  assert_failure
  assert_output --partial "legacy v1 binary"
  assert_output --partial "docker-compose"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-513 — DOCKER_COMPOSE naming a PATH to the v1 binary refuses too
# (AXI-1955 follow-up: the old exact-string check let this through).
@test "UT-INFRA-513: refuses DOCKER_COMPOSE=/usr/bin/docker-compose" {
  run env DOCKER_COMPOSE="/usr/bin/docker-compose" "$RESOLVER"
  assert_failure
  assert_output --partial "legacy v1 binary"
}

# UT-INFRA-514 — DOCKER_COMPOSE with the v1 name PLUS extra arguments
# refuses too (same AXI-1955 follow-up).
@test "UT-INFRA-514: refuses DOCKER_COMPOSE=\"docker-compose -f x\"" {
  run env DOCKER_COMPOSE="docker-compose -f x" "$RESOLVER"
  assert_failure
  assert_output --partial "legacy v1 binary"
}

# UT-INFRA-515 — neither `docker` nor `docker-compose` is reachable at all.
@test "UT-INFRA-515: refuses when nothing Compose-shaped is on PATH" {
  local safe="${BATS_TEST_TMPDIR}/nothing"
  _minimal_bin "$safe"
  run env PATH="$safe" "$RESOLVER"
  assert_failure
  assert_output --partial "Docker Compose v2 not found"
  assert_output --partial "not on PATH"
}

# UT-INFRA-516 — happy path: Compose v2 present, no override, resolves to
# exactly "docker compose".
@test "UT-INFRA-516: resolves to docker compose when v2 is available" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/demo-up-ok.rules.sh"
  run "$RESOLVER"
  assert_success
  assert_output "docker compose"
  assert_stub_called docker "version"
}

# UT-INFRA-517 — an explicit v2 override skips the probe entirely, even on
# a PATH with no docker binary at all (proves it is a real bypass).
@test "UT-INFRA-517: an explicit docker compose override skips the probe, even with no docker on PATH" {
  local safe="${BATS_TEST_TMPDIR}/no-docker"
  _minimal_bin "$safe"
  run env PATH="$safe" DOCKER_COMPOSE="docker compose" "$RESOLVER"
  assert_success
  assert_output "docker compose"
}

# UT-INFRA-518 — AXI-1971 review bounce #1 (BLOCKING 1): an override that
# is not Compose-shaped AT ALL (not even a custom wrapper — just some other
# command) is refused, never passed through. Before the bounce, this
# resolver accepted ANY override not literally named "docker-compose" —
# a deny-list. A deny-list only ever covers forms someone already thought
# of; the fix is an ALLOW-shape instead (basename "docker" immediately
# followed by the literal word "compose"), which is why a one-word
# override like "echo" (or any other wrapper that isn't shaped like
# "docker compose …") is now refused too.
@test "UT-INFRA-518: refuses an override that is not Compose-shaped at all (echo)" {
  run env DOCKER_COMPOSE="echo" "$RESOLVER"
  assert_failure
  assert_output --partial "not shaped like a Compose v2 command"
  assert_stub_not_called "docker_compose"
}

# --- AXI-1971 review bounce #1 (BLOCKING 1) regression coverage ------------
# The bug: the old guard checked the first whitespace token of the RAW
# string (`${candidate%% *}`), but the command actually executed came from
# a SEPARATE re-split (`read -r -a`). The two disagreed on leading
# whitespace, and the guard only ever looked at word #1 — so a 'sudo'/
# 'env VAR=…' prefix, or any path decoration, slipped the real v1 binary
# straight through as word #2+. The fix (above) splits exactly ONCE, into
# the very array that is executed, and validates that array against an
# ALLOW-shape (docker + literal "compose") rather than a deny-list. Every
# test below failed against the pre-fix resolver (commit 2d62478) and must
# never run the docker/docker_compose stub.

# UT-INFRA-528 — leading whitespace before the v1 binary name.
@test "UT-INFRA-528: refuses DOCKER_COMPOSE with leading whitespace before docker-compose" {
  run env DOCKER_COMPOSE=" docker-compose" "$RESOLVER"
  assert_failure
  assert_stub_not_called "docker_compose"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-529 — trailing whitespace after the v1 binary name.
@test "UT-INFRA-529: refuses DOCKER_COMPOSE with trailing whitespace after docker-compose" {
  run env DOCKER_COMPOSE="docker-compose " "$RESOLVER"
  assert_failure
  assert_stub_not_called "docker_compose"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-600 — a TAB (not a space) between the binary name and an
# argument; `read -r -a`'s default IFS splits on tabs too, but a naive
# space-only split would not have.
@test "UT-INFRA-600: refuses DOCKER_COMPOSE with a tab-separated docker-compose and an argument" {
  run env DOCKER_COMPOSE="$(printf 'docker-compose\t-f\tx')" "$RESOLVER"
  assert_failure
  assert_stub_not_called "docker_compose"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-601 — a 'sudo' prefix in front of the v1 binary name. The old
# first-token check saw "sudo" and never looked further; "docker-compose"
# as word #2 ran unexamined.
@test "UT-INFRA-601: refuses DOCKER_COMPOSE=\"sudo docker-compose\"" {
  run env DOCKER_COMPOSE="sudo docker-compose" "$RESOLVER"
  assert_failure
  assert_output --partial "not shaped like a Compose v2 command"
  assert_stub_not_called "docker_compose"
}

# UT-INFRA-602 — an 'env VAR=…' prefix in front of the v1 binary name.
@test "UT-INFRA-602: refuses DOCKER_COMPOSE=\"env X=1 docker-compose\"" {
  run env DOCKER_COMPOSE="env X=1 docker-compose" "$RESOLVER"
  assert_failure
  assert_output --partial "not shaped like a Compose v2 command"
  assert_stub_not_called "docker_compose"
}

# UT-INFRA-603 — a path-decorated v1 binary with an extra flag (combines
# the AXI-1955 follow-up path case with the AXI-1971 bounce's trailing-
# argument case in one override).
@test "UT-INFRA-603: refuses DOCKER_COMPOSE=\"/opt/x/docker-compose --flag\"" {
  run env DOCKER_COMPOSE="/opt/x/docker-compose --flag" "$RESOLVER"
  assert_failure
  assert_output --partial "not shaped like a Compose v2 command"
  assert_stub_not_called "docker_compose"
}

# UT-INFRA-604 — the accepted shape still works with a path prefix.
@test "UT-INFRA-604: accepts DOCKER_COMPOSE=\"/usr/bin/docker compose\"" {
  run env DOCKER_COMPOSE="/usr/bin/docker compose" "$RESOLVER"
  assert_success
  assert_output "/usr/bin/docker compose"
}

# UT-INFRA-605 — the accepted shape still works with trailing arguments.
@test "UT-INFRA-605: accepts DOCKER_COMPOSE=\"docker compose --ansi never\"" {
  run env DOCKER_COMPOSE="docker compose --ansi never" "$RESOLVER"
  assert_success
  assert_output "docker compose --ansi never"
}
