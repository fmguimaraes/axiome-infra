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
SHELLCHECK_CACHE_DIR="${TESTS_DIR}/vendor/shellcheck"
SHELLCHECK_BIN="${SHELLCHECK_CACHE_DIR}/shellcheck-v${SHELLCHECK_VERSION}"

_ensure_pinned_shellcheck() {
  if [ -x "$SHELLCHECK_BIN" ]; then
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
}

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
