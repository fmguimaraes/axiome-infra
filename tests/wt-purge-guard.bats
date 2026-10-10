#!/usr/bin/env bats
# tests/wt-purge-guard.bats — wt_purge_guard (scripts/wt-common.sh), the
# guard behind AXI-1952 FR39/AC26 (2026-10-02 data-loss incident). Direct
# function tests: no docker involved, since a refusal must happen before any
# destructive call is even attempted.

load 'helpers/setup'

setup() {
  stub_setup
  # shellcheck source=../scripts/wt-common.sh
  . "${INFRA_ROOT}/scripts/wt-common.sh"
}

# wt_purge_guard's warn()/die() write to stderr; `run` only captures stdout
# unless merged explicitly.
_guard() { wt_purge_guard "$1" 2>&1; }

# A fully slug-scoped resource set (what a reverted, truly per-worktree
# layer would compute) — the baseline "allowed" case every refusal test
# below deviates from by exactly one variable.
_scoped_set() {
  local slug="$1"
  PG_DB="axiome_${slug}"; MONGO_DB="${slug}"; MQ_VHOST="${slug}"
  B_UPLOADS="${slug}-uploads"; B_ARTIFACTS="${slug}-artifacts"; B_SYSTEM="${slug}-system"
  REDIS_PREFIX="axiome:${slug}:"; REDIS_DB=7
}

# UT-INFRA-230 — given fully slug-scoped resource names, wt_purge_guard
# allows the purge (exits 0).
@test "UT-INFRA-230: wt_purge_guard allows a fully slug-scoped resource set" {
  _scoped_set "axi-9999"
  run _guard "axi-9999"
  assert_success
}

# UT-INFRA-231 — the known-shared Postgres DB name is refused even though it
# superficially has nothing to do with the slug under test.
@test "UT-INFRA-231: wt_purge_guard refuses the exact shared Postgres DB name" {
  _scoped_set "axi-9999"
  PG_DB="axiome"
  run _guard "axi-9999"
  assert_failure
  assert_output --partial "axiome"
}

# UT-INFRA-232 — the 2026-10-02 incident shape: EVERY resource is the shared
# constant, for a slug that is NOT one of them.
@test "UT-INFRA-232: wt_purge_guard refuses the live shared data layer for an unrelated slug" {
  PG_DB="axiome"; MONGO_DB="axiome-global-axi-1233"; MQ_VHOST="axiome-global-axi-1233"
  B_UPLOADS="axiome-global-axi-1233-uploads"; B_ARTIFACTS="axiome-global-axi-1233-artifacts"; B_SYSTEM="axiome-global-axi-1233-system"
  REDIS_PREFIX="axiome:shared:"; REDIS_DB=1
  run _guard "axiome-global-axi-1235"
  assert_failure
}

# UT-INFRA-233 — even the slug the shared names were themselves copied from
# must be refused: a slug being a SUBSTRING of a shared name is not enough
# to make that name "owned" by it (this is the denylist's whole point).
@test "UT-INFRA-233: wt_purge_guard refuses the shared layer even for its own namesake slug" {
  PG_DB="axiome"; MONGO_DB="axiome-global-axi-1233"; MQ_VHOST="axiome-global-axi-1233"
  B_UPLOADS="axiome-global-axi-1233-uploads"; B_ARTIFACTS="axiome-global-axi-1233-artifacts"; B_SYSTEM="axiome-global-axi-1233-system"
  REDIS_PREFIX="axiome:shared:"; REDIS_DB=1
  run _guard "axiome-global-axi-1233"
  assert_failure
}

# UT-INFRA-234 — a slug that is a bare substring of a shared name (e.g. just
# the jira number) must not "contain-match" its way to an allow.
@test "UT-INFRA-234: wt_purge_guard refuses when the slug is a mere substring of a shared name" {
  PG_DB="axiome"; MONGO_DB="axiome-global-axi-1233"; MQ_VHOST="axiome-global-axi-1233"
  B_UPLOADS="axiome-global-axi-1233-uploads"; B_ARTIFACTS="axiome-global-axi-1233-artifacts"; B_SYSTEM="axiome-global-axi-1233-system"
  REDIS_PREFIX="axiome:shared:"; REDIS_DB=1
  run _guard "1233"
  assert_failure
}

# UT-INFRA-235 — one stray shared bucket in an otherwise fully-scoped set is
# still refused (the WHOLE list is validated, not "mostly fine").
@test "UT-INFRA-235: wt_purge_guard refuses a single shared resource among otherwise-scoped ones" {
  _scoped_set "axi-9999"
  B_SYSTEM="axiome-global-axi-1233-system"
  run _guard "axi-9999"
  assert_failure
  assert_output --partial "B_SYSTEM"
}

# UT-INFRA-236 — the shared/reserved Redis DB indexes (0 and 1) are refused
# even when every other var looks slug-scoped.
@test "UT-INFRA-236: wt_purge_guard refuses the shared Redis DB index even with scoped names elsewhere" {
  _scoped_set "axi-9999"
  REDIS_DB=1
  run _guard "axi-9999"
  assert_failure
  assert_output --partial "Redis"
}

# UT-INFRA-237 — empty slug is refused outright.
@test "UT-INFRA-237: wt_purge_guard refuses an empty slug" {
  _scoped_set "axi-9999"
  run _guard ""
  assert_failure
  assert_output --partial "empty slug"
}

# UT-INFRA-238 — a slug carrying glob/regex metacharacters is refused before
# any containment check runs (defence against a future unquoted use).
@test "UT-INFRA-238: wt_purge_guard refuses a slug with glob/regex metacharacters" {
  _scoped_set "axi-9999"
  run _guard 'axi-*.[0-9]'
  assert_failure
  assert_output --partial "outside [a-z0-9-]"
}

# UT-INFRA-239 — an UNSET resource variable (e.g. a future `${VAR:-shared}`
# collapse) must never read as "owned" — it refuses exactly like an empty
# string, never silently passing containment.
@test "UT-INFRA-239: wt_purge_guard refuses when a resource variable is unset" {
  _scoped_set "axi-9999"
  unset B_ARTIFACTS
  run _guard "axi-9999"
  assert_failure
  assert_output --partial "B_ARTIFACTS"
}
