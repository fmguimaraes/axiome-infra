#!/usr/bin/env bash
# tests/check-teardown-contract.sh — static guard (AXI-1945, hardened AXI-1972
# FR62/AC per debt item 2: "teardown contract holds per test, not only per
# file").
#
# tests/helpers/setup.bash defines a default teardown() that calls
# stub_teardown (catches an unconfigured stub call independently of the
# caller's exit-code handling). A *.bats file that defines its OWN
# teardown() silently overrides that default — bats-core runs that
# per-test, so the contract that matters is "does THIS FUNCTION's body
# actually call stub_teardown", not "does the string 'stub_teardown' occur
# anywhere in the file". The original check was a whole-file grep: a
# comment mentioning stub_teardown satisfied it, and it carried no
# per-function scoping at all. This version extracts only the body of the
# file's own teardown() function (brace-counted) and requires an actual
# call token inside it, ignoring comment-only lines.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional arg (test seam only — tests/run.sh never passes one): scan a
# different directory of *.bats fixtures instead of this repo's tests/.
SCAN_DIR="${1:-$TESTS_DIR}"
cd "$SCAN_DIR"

# _teardown_body <file> — prints the body of the top-level teardown()
# function (the opening line through its matching closing brace), or
# nothing if the file defines no such function. Written in bash, not awk,
# specifically to track heredocs: a bats fixture that EMBEDS a synthetic
# `teardown() { ... }` inside a `<<'EOF' ... EOF` block (this suite's own
# check-teardown-contract-self.bats does exactly that, to test this very
# script) must never be read as THIS FILE's own teardown() override — a
# naive line scan can't tell the two apart.
_teardown_body() {
  local file="$1" line in_fn=0 depth=0 in_heredoc=0 heredoc_marker=""
  while IFS= read -r line; do
    if [ "$in_heredoc" -eq 1 ]; then
      [ "$line" = "$heredoc_marker" ] && in_heredoc=0
      continue
    fi
    if [[ "$line" =~ \<\<[-~]?[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
      in_heredoc=1
      heredoc_marker="${BASH_REMATCH[1]}"
      continue
    fi
    if [ "$in_fn" -eq 0 ] && [[ "$line" =~ ^[[:space:]]*teardown[[:space:]]*\(\) ]]; then
      in_fn=1
    fi
    if [ "$in_fn" -eq 1 ]; then
      printf '%s\n' "$line"
      local o="${line//[^\{]/}" c="${line//[^\}]/}"
      depth=$(( depth + ${#o} - ${#c} ))
      [ "$depth" -le 0 ] && return 0
    fi
  done < "$file"
}

status=0
for f in *.bats; do
  body="$(_teardown_body "$f")"
  [ -n "$body" ] || continue
  # Drop comment-only lines, then require an actual stub_teardown call
  # token (word-boundary match — not a substring of another identifier,
  # and not merely quoted text).
  clean="$(printf '%s\n' "$body" | grep -vE '^[[:space:]]*#')"
  if printf '%s\n' "$clean" | grep -qE '(^|[^[:alnum:]_])stub_teardown([^[:alnum:]_]|$)'; then
    continue
  fi
  echo "ERROR: ${f} defines its own teardown() whose body never calls stub_teardown (tests/README.md)." >&2
  status=1
done
exit "$status"
