#!/usr/bin/env bats
# tests/run-shellcheck-cache.bats — AXI-1977 close-out sweep item 2: the
# pinned-shellcheck cache-hit branch in tests/run-shellcheck.sh now
# re-verifies the cached binary's own recorded sha256 on every hit instead
# of trusting "the file is executable" alone. UT-INFRA-580..582. No
# network: `curl` is stubbed and unused in these tests (the cache-hit path
# never calls it); SHELLCHECK_CACHE_DIR points at a fresh per-test
# directory via the script's own overridable variable.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/run-shellcheck.sh"

setup() {
  stub_setup
  export SHELLCHECK_CACHE_DIR="${BATS_TEST_TMPDIR}/shellcheck-cache"
  mkdir -p "$SHELLCHECK_CACHE_DIR"
}

# _source_fn — sources run-shellcheck.sh (guarded: BASH_SOURCE != 0 when
# sourced, so only function/variable definitions run, never the gate
# itself) inside the current bats test's own shell via `run bash -c`.
_call_ensure() {
  run bash -c "
    SHELLCHECK_CACHE_DIR='${SHELLCHECK_CACHE_DIR}'
    source '${SCRIPT}'
    _ensure_pinned_shellcheck
  "
}

# UT-INFRA-580 — a cache hit whose binary matches its recorded sha256
# sidecar succeeds without calling curl at all.
@test "UT-INFRA-580: run-shellcheck.sh cache hit with a matching recorded sha256 succeeds, no network" {
  local bin="${SHELLCHECK_CACHE_DIR}/shellcheck-v0.11.0"
  printf 'not a real shellcheck, just needs to be executable\n' > "$bin"
  chmod +x "$bin"
  sha256sum "$bin" | awk '{print $1}' > "${bin}.sha256"

  _call_ensure
  assert_success
  [ -z "$(cat "$STUB_LOG" 2>/dev/null | grep '^curl ' || true)" ]
}

# UT-INFRA-581 — a cache hit whose binary does NOT match its recorded
# sha256 (corruption or tampering) fails closed (exit 2) and names both
# checksums, rather than silently using the binary or silently
# re-downloading over it.
@test "UT-INFRA-581: run-shellcheck.sh cache hit with a mismatched sha256 fails closed" {
  local bin="${SHELLCHECK_CACHE_DIR}/shellcheck-v0.11.0"
  printf 'original content\n' > "$bin"
  chmod +x "$bin"
  sha256sum "$bin" | awk '{print $1}' > "${bin}.sha256"
  printf 'tampered content, different length\n' > "$bin"
  chmod +x "$bin"

  _call_ensure
  assert_failure 2
  assert_output --partial "does not match its recorded checksum"
}

# UT-INFRA-582 — a cache hit whose binary has NO recorded sha256 sidecar
# at all (an older cache, predating this verification) also fails closed
# rather than silently trusting it.
@test "UT-INFRA-582: run-shellcheck.sh cache hit with no recorded sha256 sidecar fails closed" {
  local bin="${SHELLCHECK_CACHE_DIR}/shellcheck-v0.11.0"
  printf 'a cache from before this verification existed\n' > "$bin"
  chmod +x "$bin"

  _call_ensure
  assert_failure 2
  assert_output --partial "has no recorded checksum"
}
