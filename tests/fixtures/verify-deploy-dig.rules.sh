# shellcheck shell=bash
# Fixture for the shared `dig` stub (tests/stubs/dig) — verify-deploy.sh's
# DNS check (`dig +short "${FQDN}" | tail -n1`). Prints the configured
# answer regardless of argv shape, matching the old per-test double's
# behaviour before it moved into tests/stubs/dig (AXI-1968).
stub_respond() {
  echo "${VERIFY_FIXTURE_DIG_ANSWER:-203.0.113.10}"
  return 0
}
