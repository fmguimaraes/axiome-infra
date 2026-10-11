#!/usr/bin/env bash
# tests/run-shellcheck.sh — shellcheck gate with a baseline (NFR8: "no new
# findings"). The repo was not shellcheck-clean before this story; rather
# than fix ~3,000 lines of untouched shell, every PRE-EXISTING finding is
# recorded once in tests/shellcheck-baseline.json and allowed to stay.
#
#   - A file already in the baseline may keep its recorded findings, but any
#     NEW finding in it (a different line/code) fails the gate.
#   - A file NOT in the baseline (new this story or any sibling's) must be
#     fully clean — zero findings, full stop.
#
# AXI-1972 (scope item 3/FR62/AC57): ONE pinned shellcheck version, used
# identically here and in CI — not whatever `apt`/the dev machine happens
# to have. CI was on 0.9.0 and this machine on 0.11.0 before this story;
# different versions can disagree on findings (SC2120/SC2119 history,
# AXI-1954's post-merge fix). The pinned binary is downloaded once (cached
# under tests/vendor/shellcheck/, gitignored — it is a 16 MB platform
# binary, not source, so it is NOT vendored into git like bats-core is)
# from the exact upstream release URL and verified against a SHA-256
# fetched and recorded by the developer who pinned it (see tests/README.md
# for how to re-verify this value against a fresh download). No `shellcheck`
# from PATH is ever used by this script.
#
# Usage: tests/run-shellcheck.sh [--write-baseline]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
BASELINE="${TESTS_DIR}/shellcheck-baseline.json"

SHELLCHECK_VERSION="0.11.0"
SHELLCHECK_PLATFORM="linux.x86_64"
SHELLCHECK_URL="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${SHELLCHECK_PLATFORM}.tar.xz"
# sha256 of the tarball above, recorded 2026-10-11 from the upstream
# GitHub release asset (koalaman/shellcheck v0.11.0, linux x86_64).
SHELLCHECK_TARBALL_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
# AXI-1977 close-out sweep item 2: overridable so a test can point at an
# isolated, throwaway cache directory instead of this repo's real
# tests/vendor/shellcheck/ — never network, never the real binary.
SHELLCHECK_CACHE_DIR="${SHELLCHECK_CACHE_DIR:-${TESTS_DIR}/vendor/shellcheck}"
SHELLCHECK_BIN="${SHELLCHECK_CACHE_DIR}/shellcheck-v${SHELLCHECK_VERSION}"
# AXI-1977: the binary's OWN sha256, recorded next to it the moment it is
# first extracted and verified (see "the honest design" note below).
SHELLCHECK_BIN_SHA256_FILE="${SHELLCHECK_BIN}.sha256"

# AXI-1977 close-out sweep item 2: the cache-hit branch below used to trust
# "the file is executable" as proof the binary is the one this script
# fetched and verified — a cache directory that is shared, backed up, or
# simply old (a previous pin's leftover, a corrupted write, a foreign
# binary placed there by something else) was never re-checked. The honest
# design chosen here: record the EXTRACTED BINARY's own sha256 (not the
# tarball's — the tarball is not kept) next to it, at the moment it is
# first verified and installed, and re-verify the binary against that
# recorded value on every cache hit. A missing or mismatched sidecar fails
# closed (exit 2) rather than silently re-trusting or silently
# re-downloading over a cache an operator may be relying on. This detects
# corruption, staleness, or a foreign binary in the cache — it is NOT a
# security control: anyone who can write to ${SHELLCHECK_CACHE_DIR} can
# write a matching sidecar too, so it does not protect against a
# write-capable attacker.
_ensure_pinned_shellcheck() {
  if [ -x "$SHELLCHECK_BIN" ]; then
    if [ ! -f "$SHELLCHECK_BIN_SHA256_FILE" ]; then
      echo "ERROR: cached shellcheck binary at ${SHELLCHECK_BIN} has no recorded checksum (${SHELLCHECK_BIN_SHA256_FILE} missing) — refusing to trust an unverifiable cache. Remove ${SHELLCHECK_CACHE_DIR} and re-run to re-fetch and re-verify." >&2
      exit 2
    fi
    local recorded got
    recorded="$(cat "$SHELLCHECK_BIN_SHA256_FILE")"
    got="$(sha256sum "$SHELLCHECK_BIN" | awk '{print $1}')"
    if [ "$got" != "$recorded" ]; then
      echo "ERROR: cached shellcheck binary at ${SHELLCHECK_BIN} does not match its recorded checksum (expected ${recorded}, got ${got}) — refusing to use a corrupted or stale/foreign cached binary. Remove ${SHELLCHECK_CACHE_DIR} and re-run to re-fetch." >&2
      exit 2
    fi
    return 0
  fi
  [ "$(uname -m)" = "x86_64" ] && [ "$(uname -s)" = "Linux" ] || {
    echo "ERROR: the pinned shellcheck binary is only fetched for linux/x86_64; this machine is $(uname -s)/$(uname -m). Install shellcheck ${SHELLCHECK_VERSION} yourself and place it at ${SHELLCHECK_BIN}." >&2
    exit 2
  }
  command -v curl >/dev/null 2>&1 || { echo "ERROR: 'curl' is required to fetch the pinned shellcheck (see tests/README.md)." >&2; exit 2; }
  mkdir -p "$SHELLCHECK_CACHE_DIR"
  local tmp_tar
  tmp_tar="$(mktemp "${TMPDIR:-/tmp}/shellcheck-XXXXXX.tar.xz")"
  trap 'rm -f "$tmp_tar"' RETURN
  echo "==> fetching pinned shellcheck v${SHELLCHECK_VERSION} (${SHELLCHECK_URL})" >&2
  curl -fsSL "$SHELLCHECK_URL" -o "$tmp_tar"
  local got_sha
  got_sha="$(sha256sum "$tmp_tar" | awk '{print $1}')"
  if [ "$got_sha" != "$SHELLCHECK_TARBALL_SHA256" ]; then
    echo "ERROR: downloaded shellcheck tarball checksum mismatch: got ${got_sha}, expected ${SHELLCHECK_TARBALL_SHA256}. Refusing to use an unverified download (NFR3-adjacent supply-chain rule)." >&2
    exit 2
  fi
  local extract_dir
  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/shellcheck-extract-XXXXXX")"
  tar -xf "$tmp_tar" -C "$extract_dir"
  install -m 0755 "${extract_dir}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$SHELLCHECK_BIN"
  rm -rf "$extract_dir"
  sha256sum "$SHELLCHECK_BIN" | awk '{print $1}' > "$SHELLCHECK_BIN_SHA256_FILE"
  # A `trap ... RETURN` set inside a function is NOT function-scoped — it
  # stays armed for the next RETURN event in this shell, which is `main`'s
  # own return at the end of the script, long after `$tmp_tar` (local to
  # THIS function) has gone out of scope: under `set -u` that fires
  # "tmp_tar: unbound variable" on a totally unrelated function's return.
  # Clear it explicitly once this function's own cleanup has run.
  trap - RETURN
}

main() {
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: 'jq' is required but not on PATH (see tests/README.md)." >&2
    exit 2
  }
  _ensure_pinned_shellcheck

  cd "$INFRA_ROOT"
  mapfile -t FILES < <(git ls-files -- '*.sh' | grep -v '^tests/vendor/')

  CURRENT="$("$SHELLCHECK_BIN" -S warning -f json1 "${FILES[@]}" 2>/dev/null || true)"
  CURRENT_FINDINGS="$(printf '%s' "$CURRENT" | jq -c '[.comments[] | {file, line, code}] | sort')"

  if [ "${1:-}" = "--write-baseline" ]; then
    printf '%s\n' "$CURRENT_FINDINGS" > "$BASELINE"
    echo "wrote $(printf '%s' "$CURRENT_FINDINGS" | jq length) findings to ${BASELINE}"
    exit 0
  fi

  [ -f "$BASELINE" ] || { echo "ERROR: ${BASELINE} missing — run with --write-baseline once." >&2; exit 2; }
  BASELINE_FINDINGS="$(cat "$BASELINE")"

  NEW_FINDINGS="$(jq -n --argjson cur "$CURRENT_FINDINGS" --argjson base "$BASELINE_FINDINGS" \
    '$cur - $base')"
  COUNT="$(printf '%s' "$NEW_FINDINGS" | jq length)"

  if [ "$COUNT" -gt 0 ]; then
    echo "shellcheck: ${COUNT} NEW finding(s) not in the baseline:" >&2
    printf '%s\n' "$NEW_FINDINGS" | jq -r '.[] | "  \(.file):\(.line): \(.code)"' >&2
    echo "(a genuinely new file must be fully clean; an existing baselined file must not regress)" >&2
    exit 1
  fi

  echo "shellcheck: no new findings ($(printf '%s' "$CURRENT_FINDINGS" | jq length) pre-existing, baselined)."
}

# AXI-1977 close-out sweep item 2: guarded so a test can `source` this file
# (to call _ensure_pinned_shellcheck directly, offline, against a fake
# cache dir) without running the full gate. Unguarded when actually
# executed (tests/run.sh invokes this file directly, so
# BASH_SOURCE[0] == $0 in that case, exactly as before this change).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
