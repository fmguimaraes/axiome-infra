#!/usr/bin/env bats
# tests/workflow-action-pinning.bats — AXI-1972, scope item 6/FR62: every
# GitHub Action referenced from this repo's workflows is pinned to a full
# commit SHA (with the human version in a trailing comment), not a mutable
# tag like `@v4`. A local composite action (`uses: ./...`) is excluded —
# it has no remote ref to pin, it is this repo's own checked-out code.
load 'helpers/setup'

setup() {
  stub_setup
}

# UT-INFRA-561 (AXI-1972): no workflow references a remote action by a
# short tag (`@v4`, `@v1`, `@main`, …) — every remote `uses:` is a 40-hex
# commit SHA.
@test "UT-INFRA-561: every remote action 'uses:' line is pinned to a 40-hex commit SHA" {
  local bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bad=1
    echo "NOT PINNED: $line"
  done < <(
    grep -rhoE 'uses: [^ ]+@[^ ]+' "${INFRA_ROOT}/.github/workflows"/*.yml \
      | grep -v '^uses: \./' \
      | grep -vE '@[0-9a-f]{40}$'
  )
  [ "$bad" -eq 0 ]
}

# UT-INFRA-562 (AXI-1972): every pinned SHA carries a trailing version
# comment (`# v4.4.0` etc.) — a bare SHA with no human-readable version is
# a maintenance trap, not what this story was asked to produce.
@test "UT-INFRA-562: every pinned action SHA has a trailing version comment" {
  local bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bad=1
    echo "NO VERSION COMMENT: $line"
  done < <(
    grep -rhoE 'uses: [^ ]+@[0-9a-f]{40}([^#]*)?$' "${INFRA_ROOT}/.github/workflows"/*.yml \
      | grep -vE '#\s*v[0-9]'
  )
  [ "$bad" -eq 0 ]
}

# UT-INFRA-563 (AXI-1972): regression guard — this test fails against the
# pre-pinning tree (bats-core tags like `@v4`/`@v1` present).
@test "UT-INFRA-563: a synthetic workflow using a bare tag is caught by the same check" {
  local dir="${BATS_TEST_TMPDIR}/wf"
  mkdir -p "${dir}/.github/workflows"
  cat > "${dir}/.github/workflows/x.yml" <<'EOF'
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
EOF
  local bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bad=1
  done < <(
    grep -rhoE 'uses: [^ ]+@[^ ]+' "${dir}/.github/workflows"/*.yml \
      | grep -v '^uses: \./' \
      | grep -vE '@[0-9a-f]{40}$'
  )
  [ "$bad" -eq 1 ]
}
