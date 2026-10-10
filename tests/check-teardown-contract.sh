#!/usr/bin/env bash
# tests/check-teardown-contract.sh — static guard (AXI-1945, blocking-2 fix).
#
# tests/helpers/setup.bash defines a default teardown() that calls
# stub_teardown (catches an unconfigured stub call independently of the
# caller's exit-code handling). A *.bats file that defines its OWN
# teardown() silently overrides that default. This guard catches a file
# that did so without calling stub_teardown itself.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TESTS_DIR"

status=0
for f in *.bats; do
  grep -qE '^[[:space:]]*teardown[[:space:]]*\(\)' "$f" || continue
  grep -q 'stub_teardown' "$f" && continue
  echo "ERROR: ${f} defines its own teardown() but never calls stub_teardown (tests/README.md)." >&2
  status=1
done
exit "$status"
