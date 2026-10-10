# shellcheck shell=bash
# Fixture shared by curl/git/terraform for tests/dev-auto-promote-workflow.bats
# UT-INFRA-322..325 — these calls come from
# scripts/generate-qualification-record.sh's own OQ/PQ probes and metadata
# lookups (git commit/operator, terraform version, gateway health/latency);
# they are incidental to the MIGRATION_FACTS branch logic under test here,
# so this fixture just answers them deterministically instead of leaving
# them UNCONFIGURED (which the shared teardown() fails the test for).
stub_respond() {
  case "$1" in
    *"rev-parse --short HEAD"*)
      printf 'testsha'
      ;;
    *"config user.email"*)
      printf 'test@example.com'
      ;;
    *"version -json"*)
      printf '{"terraform_version":"1.0.0"}'
      ;;
    *"-w %{http_code}"*)
      printf '200'
      ;;
    *"-w %{time_total}"*)
      printf '0.010'
      ;;
    *)
      return 99
      ;;
  esac
}
