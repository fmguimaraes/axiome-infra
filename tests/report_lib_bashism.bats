#!/usr/bin/env bats
# tests/report_lib_bashism.bats — AXI-1972 (follow-up b): scripts/lib/report.sh
# is sourced by every operator entry point (scripts/lock.sh, scripts/deploy-
# prod.sh, providers/aws/scripts/power.sh, providers/aws/scripts/power-data.sh,
# scripts/asset-sync.sh, scripts/seed-environment.sh) — a bash 4+-only
# construct in it (e.g. `${var,,}`/`${var^^}` case-conversion expansion,
# `declare -A`, `local -n` namerefs, `mapfile`/`readarray`) is a SYNTAX
# ERROR on bash 3.2 (macOS's shipped `/bin/bash`), which aborts the whole
# entry point the instant the file is parsed — not just when the
# offending line executes. This is a static source scan (no bash-3.2
# binary is assumed to exist on this machine to actually exercise against)
# precisely because the failure mode is "won't even parse", so running it
# under THIS machine's bash 5+ would prove nothing either way.
# UT-INFRA-568..569.

load 'helpers/setup'

setup() {
  stub_setup
}

# The shared scan: excludes full-line comments (trimmed first non-blank
# char `#`, same technique tests/ac6-no-push-fallback.bats uses) so a
# comment that merely MENTIONS one of these constructs in prose (as the
# follow-up-b fix comments in report.sh itself now do) is never mistaken
# for a real, parse-breaking occurrence.
_bashism_scan() {
  grep -nE '\$\{[A-Za-z0-9_]+(\[[^]]*\])?(,,|\^\^)\}|declare[[:space:]]+-A|local[[:space:]]+-n|\bmapfile\b|\breadarray\b' "$1" \
    | awk -F: '{line=$0; sub(/^[^:]*:/, "", line); trimmed=line; sub(/^[ \t]+/, "", trimmed); if (trimmed !~ /^#/) print}'
}

# UT-INFRA-568: report.sh itself contains none of the bash 4+-only
# constructs that would fail to parse on bash 3.2 (outside of comments).
@test "UT-INFRA-568: scripts/lib/report.sh contains no bash-4+-only constructs" {
  run _bashism_scan "${INFRA_ROOT}/scripts/lib/report.sh"
  assert_success
  [ -z "$output" ]
}

# UT-INFRA-569: regression guard for the scan itself — proves the pattern
# really does catch each of the four construct families (a synthetic
# fixture containing one of each, plus a comment-only mention that must be
# IGNORED), so UT-INFRA-568 passing is not just a vacuously-unmatchable
# regex.
@test "UT-INFRA-569: the bashism scan actually matches each construct family it claims to" {
  local fixture="${BATS_TEST_TMPDIR}/bashism-fixture.sh"
  cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
# a comment mentioning ${1,,} must NOT be counted
lower() { local v="${1,,}"; echo "$v"; }
upper() { local v="${1^^}"; echo "$v"; }
declare -A MAP=()
read_into() { local -n ref="$1"; ref="x"; }
mapfile -t ARR < /dev/null
readarray -t ARR2 < /dev/null
EOF

  run _bashism_scan "$fixture"
  assert_success
  local count
  count="$(printf '%s\n' "$output" | grep -c .)"
  [ "$count" -eq 6 ]
}
