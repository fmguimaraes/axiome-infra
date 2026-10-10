#!/usr/bin/env bats
# tests/makefile-help-and-compose-gate.bats — AXI-1955 fixes (a) and (b) to
# the root Makefile's Docker Compose v2 guard (AXI-1952 debt, epic
# AXI-1944 learning #1):
#
#   (a) the v2 probe/$(error) used to run for EVERY goal, including `make
#       help` and every Terraform/seed/deploy-prod target — a machine with
#       no Docker at all could not even run `make help`. It is now gated on
#       $(MAKECMDGOALS) actually naming a Docker-Compose-using target.
#   (b) `DOCKER_COMPOSE=docker-compose` (command line OR environment) used
#       to be accepted verbatim, silently selecting the known-bad legacy v1
#       binary. It is now rejected with a clear $(error), from either
#       source.
#
# Test-isolation rule (epic AXI-1944 incident, binding for every story):
# every one of these tests either removes `docker` from PATH entirely (no
# candidate binary to resolve to), or drives `make -n` (dry run — GNU make
# never executes a dry-run recipe line) with the stub docker on PATH. No
# test here ever lets a real `docker`/`docker-compose` run.

load 'helpers/setup'

setup() {
  stub_setup
}

# _no_docker_path <dir> — a PATH with real make/bash/coreutils (needed for
# make itself and its shell recipes to parse) but NO docker/docker-compose
# binary anywhere on it — the strongest proof that a goal needs no Docker.
_no_docker_path() {
  local dir="$1" bin
  mkdir -p "$dir"
  for bin in make bash sh dirname grep sed awk cat tr mkdir rm cp ln env \
             printf test true false head tail wc sort cut date seq mktemp; do
    local p; p="$(command -v "$bin" 2>/dev/null)" || continue
    ln -sf "$p" "${dir}/${bin}"
  done
  printf '%s' "$dir"
}

# UT-INFRA-380 — fix (a): `make help` succeeds with no `docker` binary
# reachable on PATH at all.
@test "UT-INFRA-380: make help succeeds with no docker on PATH" {
  local nodocker; nodocker="$(_no_docker_path "${BATS_TEST_TMPDIR}/no-docker-bin")"
  run env -i PATH="${nodocker}" make -C "${INFRA_ROOT}" help
  assert_success
  assert_output --partial "Local stack"
}

# UT-INFRA-381 — fix (a), the other direction: a Docker-Compose-using goal
# (demo-up) still fails CLOSED with the documented message when no docker
# v2 is reachable, proving the gate is narrowed, not removed.
@test "UT-INFRA-381: make demo-up still fails closed with no docker v2 on PATH" {
  local nodocker; nodocker="$(_no_docker_path "${BATS_TEST_TMPDIR}/no-docker-bin")"
  run env -i PATH="${nodocker}" make -C "${INFRA_ROOT}" -n demo-up
  assert_failure
  assert_output --partial "Docker Compose v2 not found"
  assert_output --partial "AXI-1952"
}

# UT-INFRA-382 — fix (b): a command-line `DOCKER_COMPOSE=docker-compose`
# (the literal v1 binary name) is rejected with a clear message, even
# though it IS set (so the probe in fix (a) is skipped) — the gate must
# catch the override itself, not just a failed probe.
@test "UT-INFRA-382: make rejects a command-line DOCKER_COMPOSE=docker-compose override" {
  run make -C "${INFRA_ROOT}" -n demo-up DOCKER_COMPOSE=docker-compose
  assert_failure
  assert_output --partial "legacy v1 binary"
  assert_output --partial "AXI-1952/AXI-1955"
}

# UT-INFRA-383 — fix (b), same rejection from the ENVIRONMENT (not the
# command line) — `origin` reports both the same way, and the Makefile
# must not special-case one over the other.
@test "UT-INFRA-383: make rejects an environment DOCKER_COMPOSE=docker-compose override" {
  run env DOCKER_COMPOSE=docker-compose make -C "${INFRA_ROOT}" -n demo-up
  assert_failure
  assert_output --partial "legacy v1 binary"
}

# UT-INFRA-384 — the override escape hatch from fix (a)'s header comment
# still works for the real (v2) command string — proves the gate rejects
# only the literal v1 name, not every override.
@test "UT-INFRA-384: make accepts an explicit DOCKER_COMPOSE=\"docker compose\" override" {
  local nodocker; nodocker="$(_no_docker_path "${BATS_TEST_TMPDIR}/no-docker-bin")"
  run env -i PATH="${nodocker}" make -C "${INFRA_ROOT}" -n demo-up DOCKER_COMPOSE="docker compose"
  assert_success
  assert_output --partial "up -d"
}

# UT-INFRA-385 — fix (a) must not silently widen to targets that never
# touch Docker Compose at all: `make plan` (a Terraform target) also needs
# no docker on PATH and must not probe/error.
@test "UT-INFRA-385: make plan needs no docker on PATH either" {
  local nodocker; nodocker="$(_no_docker_path "${BATS_TEST_TMPDIR}/no-docker-bin")"
  run env -i PATH="${nodocker}" make -C "${INFRA_ROOT}" -n plan ENV=dev
  assert_success
  refute_output --partial "Docker Compose"
}
