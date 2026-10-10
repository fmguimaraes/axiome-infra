#!/usr/bin/env bats
# tests/legacy-compose-safety.bats — AXI-1952 B1: the structural fix for the
# 2026-10 incident where the Makefile's `DOCKER_COMPOSE` auto-detection
# silently fell back to the real, un-stubbed legacy `docker-compose` v1
# binary (which renamed and crashed the real running demo containers via a
# `KeyError: 'ContainerConfig'` bug) when a test's docker-stub fixture
# didn't answer the `compose version` probe. Three independent layers:
#
#   1. Every test that drives `make` passes DOCKER_COMPOSE="docker compose"
#      explicitly on the command line (see tests/demo-up-migrate.bats) —
#      command-line assignments win over the Makefile's own `:=`, so this
#      never depends on a fixture answering the probe correctly.
#   2. tests/stubs/docker-compose: a PATH shim for the literal binary name
#      "docker-compose". It is intentionally never configured with rules —
#      ANY call to it is an unconfigured-call FACT (recorded independently
#      of exit-code handling, per _common.sh), so if anything ever reaches
#      for that name again it fails the test loudly instead of silently
#      running a real binary.
#   3. The Makefile itself (line ~38) no longer falls back to the literal
#      string "docker-compose" when `docker compose version` fails and no
#      override was given — it stops with $(error ...) instead.
#
# This file tests layers 2 and 3 directly. Layer 1 is exercised implicitly
# by every other *-migrate.bats file (they all now pass the override).

load 'helpers/setup'

setup() {
  stub_setup
}

# _safe_fallback_path <dir> — populates <dir> with symlinks to ONLY the
# handful of real binaries the "docker-compose" stub's own shebang/body
# needs to run at all (bash, dirname, tr — see tests/stubs/_common.sh;
# `env` is invoked via the shebang's own absolute /usr/bin/env path, never
# via PATH lookup, and cd/pwd/printf/echo/test are shell builtins). Neither
# `docker` nor `docker-compose` is ever linked in. Used as the PATH
# fallback AFTER the stubs dir in UT-INFRA-261 so that even if the stub
# file were missing or non-executable, PATH resolution dead-ends at 127
# instead of silently finding a real `docker-compose` binary further down
# a normal PATH (which is exactly how the 2026-10 incident happened).
_safe_fallback_path() {
  local dir="$1" bin
  mkdir -p "$dir"
  for bin in bash dirname tr; do
    ln -sf "$(command -v "$bin")" "${dir}/${bin}"
  done
}

# UT-INFRA-261 — layer 2, in isolation from make/the Makefile entirely:
# proves the "docker-compose" PATH shim itself fails loudly rather than
# silently succeeding, under a PATH whose only other entry is the curated
# safe fallback above — i.e. this test is safe even if the stub were
# missing or broken, because there is no real `docker-compose` reachable
# on PATH to fall through to.
@test "UT-INFRA-261: the docker-compose PATH stub is unconfigured-by-design and fails loudly" {
  local safe_dir="${BATS_TEST_TMPDIR}/safe-bin"
  _safe_fallback_path "$safe_dir"
  PATH="${TESTS_DIR}/stubs:${safe_dir}" run docker-compose version
  assert_failure
  [ -s "$STUB_FAIL_LOG" ]
  grep -q "docker_compose" "$STUB_FAIL_LOG"
  # This test's whole point is to TRIGGER the unconfigured-call fact — clear
  # it so the file's (default, shared) teardown() doesn't double-fail on
  # the very thing this test just asserted.
  : > "$STUB_FAIL_LOG"
}

# UT-INFRA-262 — layer 3: with no DOCKER_COMPOSE override and a docker stub
# that answers `compose version` with a (configured, non-unconfigured)
# failure — simulating a machine with only v1 installed — `make` must stop
# at the Makefile's own $(error ...) right after that one probe, BEFORE
# running any recipe at all. No fallback to the literal name
# "docker-compose", no migrate-gate call, no `up -d` — the var computation
# happens at parse time, before any target's commands run, so this is safe
# even for a destructive target name like demo-up.
@test "UT-INFRA-262: make fails closed when docker compose v2 is unavailable and no override is given" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/legacy-compose-v2-missing.rules.sh"
  run make -C "${INFRA_ROOT}" demo-up
  assert_failure
  assert_output --partial "Docker Compose v2 not found"
  assert_output --partial "AXI-1952"
  # Exactly one call happened: the v2 probe itself (`docker compose
  # version`) — nothing else, and it was CONFIGURED (not unconfigured).
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "1"
  assert_stub_called docker "version"
  run grep -c "cli.js\|up -d\|pg_dump" "$STUB_LOG"
  assert_output "0"
  [ ! -s "$STUB_FAIL_LOG" ]
}

# UT-INFRA-263 — layer 3's error path does not break the override path:
# passing DOCKER_COMPOSE explicitly still works even on a machine where the
# v2 probe would fail (confirms layer 1's override is a real bypass, not
# just an inert extra argument).
@test "UT-INFRA-263: an explicit DOCKER_COMPOSE override skips the v2 probe entirely" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/demo-up-ok.rules.sh"
  run make -C "${INFRA_ROOT}" demo-up MIGRATE=0 DOCKER_COMPOSE="docker compose"
  assert_success
  # The probe itself ("compose version") is never called when the override
  # is set — only the real recipe calls (migrate-gate status, up -d) are.
  run grep -c "compose version" "$STUB_LOG"
  assert_output "0"
}
