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
# Usage: tests/run-shellcheck.sh [--write-baseline]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
BASELINE="${TESTS_DIR}/shellcheck-baseline.json"

for tool in shellcheck jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' is required but not on PATH (see tests/README.md)." >&2
    exit 2
  }
done

cd "$INFRA_ROOT"
mapfile -t FILES < <(git ls-files -- '*.sh' | grep -v '^tests/vendor/')

CURRENT="$(shellcheck -S warning -f json1 "${FILES[@]}" 2>/dev/null || true)"
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
