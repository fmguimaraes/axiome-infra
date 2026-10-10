#!/usr/bin/env bats
# tests/ac6-no-push-fallback.bats — AC6 (FR2, FR36): no start or migrate path
# anywhere in this repo invokes a schema-push fallback or an explicit
# data-loss-accepting flag.
#
# Repo-wide, not just AXI-1952's owned files — a fallback introduced by any
# future change anywhere (lifecycle scripts, Makefiles, compose files,
# docker/**) is exactly the class of bug this AC exists to prevent. Full-line
# comments are skipped (a line whose first non-blank character is `#`, which
# covers both shell and YAML) so this story's own explanatory prose (e.g.
# this file's docstring, or the "no longer falls back" comments in Makefile/
# wt-up.sh) does not trip itself. Excluded: tests/** (fixtures/specs
# legitimately reference these strings to test for their absence), .git,
# and scripts/roll-service.sh — AXI-1953 is concurrently cleaning that file
# and owns it; it is not touched here.

load 'helpers/setup'

setup() {
  stub_setup
}

# _ac6_scan <pattern> — repo-wide grep for <pattern>, full-line comments
# and excluded paths filtered out. Prints any surviving matches (empty
# output = clean).
_ac6_scan() {
  local pattern="$1"
  grep -rn --include='*.sh' --include='Makefile' --include='*.yml' --include='*.yaml' \
    -E "$pattern" "${INFRA_ROOT}" \
    --exclude-dir=tests --exclude-dir=.git \
    2>/dev/null \
  | grep -v "^${INFRA_ROOT}/scripts/roll-service.sh:" \
  | awk -F: '{
      line=$0
      sub(/^[^:]*:[^:]*:/, "", line)
      trimmed=line
      sub(/^[ \t]+/, "", trimmed)
      if (trimmed !~ /^#/) print $0
    }'
}

# UT-INFRA-252 — no file in the repo (outside tests/** and
# scripts/roll-service.sh, AXI-1953's) contains the literal "db push"
# outside a comment.
@test "UT-INFRA-252: no repo file contains the literal 'db push' outside a comment" {
  run _ac6_scan 'db push'
  assert_output ""
  assert_success
}

# UT-INFRA-253 — same for "accept-data-loss".
@test "UT-INFRA-253: no repo file contains the literal 'accept-data-loss' outside a comment" {
  run _ac6_scan 'accept-data-loss'
  assert_output ""
  assert_success
}
