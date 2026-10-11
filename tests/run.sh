#!/usr/bin/env bash
# tests/run.sh — the single entry point CI runs (.github/workflows/infra-tests.yml
# runs exactly this). Local and CI never diverge: shellcheck-with-baseline, then
# the full bats suite. See tests/README.md.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS="${TESTS_DIR}/vendor/bats-core/bin/bats"

echo "==> shellcheck (baseline-gated, NFR8)"
"${TESTS_DIR}/run-shellcheck.sh"

echo
echo "==> teardown contract (every *.bats with its own teardown() calls stub_teardown)"
"${TESTS_DIR}/check-teardown-contract.sh"

echo
echo "==> absolute-path guard (no tracked script bypasses a PATH-shim stub, FR62/AC56)"
"${TESTS_DIR}/check-absolute-tool-paths.sh"

echo
echo "==> UT-INFRA id uniqueness (each id's own file-scope rule, FR62 follow-up a)"
"${TESTS_DIR}/check-ut-ids.sh"

echo
echo "==> bats suite (offline, stubbed cloud/container/db calls, NFR5)"
"${BATS}" "${TESTS_DIR}"/*.bats
