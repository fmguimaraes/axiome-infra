#!/usr/bin/env bats
# tests/doc-truth.bats — AXI-1955 (FR41, NFR9, AC33): fails when the
# Makefile help text or the new runbooks drift from the scripts/Makefile
# they describe. Three checks:
#
#   1. every Makefile target whose recipe actually drives Docker Compose
#      ($(APP)/$(SHARED)/$(DEMO)/$(ANALYTICS_COMPOSE)) is covered by the
#      AXI-1955 fix (a) gate list (DOCKER_COMPOSE_TARGETS) — a future target
#      added to the Makefile without updating that list would silently
#      regress to "probes/errors for every goal" or "never gated at all".
#   2. every script path this story's runbooks name in backtick-quoted
#      `scripts/...` / `providers/aws/scripts/...` form actually exists.
#   3. a curated set of refusal/contract strings the runbooks quote
#      verbatim exist verbatim in the script named alongside them.

load 'helpers/setup'

setup() {
  stub_setup
}

# UT-INFRA-386 — every Docker-Compose-driving Makefile target is in the
# fix-(a) gate list (one direction: macro-using => gated; the reverse would
# require full dependency-graph reasoning for alias targets like
# local-up: demo-up, which this test does not attempt).
@test "UT-INFRA-386: every Docker-Compose-driving Makefile target is gated by DOCKER_COMPOSE_TARGETS" {
  run awk '
    /^DOCKER_COMPOSE_TARGETS[[:space:]]*:=/ { in_list=1 }
    in_list { line=$0; gsub(/DOCKER_COMPOSE_TARGETS[[:space:]]*:=/, "", line); gsub(/\\/, "", line); printf "%s ", line }
    in_list && $0 !~ /\\$/ { in_list=0 }
  ' "${INFRA_ROOT}/Makefile"
  assert_success
  # Normalize all whitespace (the Makefile continuation lines are
  # tab-indented, not space-indented) to single spaces before matching.
  local gate_list; gate_list="$(printf '%s' "$output" | tr -s '[:space:]' ' ')"

  run awk '
    /^[a-zA-Z0-9_-]+:/ && !/^\t/ { split($0, a, ":"); cur=a[1]; next }
    /^\t/ && /\$\(APP\)|\$\(SHARED\)|\$\(DEMO\)|\$\(ANALYTICS_COMPOSE\)/ { print cur }
  ' "${INFRA_ROOT}/Makefile"
  assert_success
  local macro_targets="$output"

  local t missing=""
  for t in $macro_targets; do
    case " $gate_list " in
      *" $t "*) ;;
      *) missing="$missing $t" ;;
    esac
  done
  [ -z "$missing" ] || fail "target(s) drive Docker Compose but are missing from DOCKER_COMPOSE_TARGETS:$missing"
}

# UT-INFRA-387 — every scripts/** or providers/aws/scripts/** path named in
# this story's runbooks/guide actually exists on disk.
@test "UT-INFRA-387: every script path named in the AXI-1955 runbooks exists" {
  # Repo-relative only: a (?<![/A-Za-z0-9]) lookbehind excludes on-box
  # absolute paths like /opt/axiome/scripts/boot.sh (not a path in this repo).
  run grep -ohP '(?<![/A-Za-z0-9])(scripts|providers/aws/scripts)/[A-Za-z0-9_.-]+\.sh' \
    "${INFRA_ROOT}/docs/platform-lifecycle-operations.md" \
    "${INFRA_ROOT}/docs/migration-authoring-guide.md"
  assert_success
  # "scripts/boot.sh" is excluded: it is the ON-BOX install name
  # (/opt/axiome/scripts/boot.sh, installed FROM providers/aws/onbox/boot.sh
  # by asset-sync.sh) — the runbook quotes it verbatim from
  # scripts/deploy-prod.sh's own REFUSE message (see UT-INFRA-388), it is
  # not a claim that a repo-relative scripts/boot.sh exists.
  local paths; paths="$(printf '%s\n' "$output" | grep -v '^scripts/boot\.sh$' | sort -u)"
  [ -n "$paths" ] || fail "no script paths found in the runbooks — pattern or docs missing"

  local p missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "${INFRA_ROOT}/${p}" ] || missing="$missing $p"
  done <<< "$paths"
  [ -z "$missing" ] || fail "runbook names script path(s) that do not exist:$missing"
}

# UT-INFRA-388 — a curated set of refusal/contract strings the runbook
# quotes, verbatim, matches both files at once (AXI-1972 FR64/AC59
# rework): the previous version of this test carried its own hardcoded
# copy of the message text and checked it ONLY against the script — a
# runbook-only edit to the quoted wording could never fail it, because
# the runbook was never read. Each entry below still names the needle
# (there is no way to ask "find me the right quote" without knowing what
# it is), but the test now ALSO greps the RUNBOOK's own text for it —
# markdown decoration stripped and all whitespace (including the
# line-wraps Markdown prose uses) collapsed first, so a quote that wraps
# across source lines still matches as one string. A change to the
# runbook's wording, with the script untouched, now fails here.
# Each entry is "<script-relative-path>|<verbatim substring>".
@test "UT-INFRA-388: refusal strings are read from the runbook and must match both the runbook and their script" {
  local entries=(
    "scripts/roll-service.sh|has no 'migrate' service under services: — this box predates the migration gate"
    "scripts/deploy-prod.sh|it predates the AXI-1950 asset-sync conversion"
    "scripts/deploy-prod.sh|REFUSE <service>: tables exist with no migration ledger. Run: migrate-gate baseline <service>"
    "scripts/deploy-prod.sh|moved during this deploy"
    "scripts/deploy-prod.sh|The migration gate completed successfully before this failure"
    "scripts/deploy-prod.sh|Migrations may have PARTIALLY applied before this failure"
    "scripts/ssm-exec.sh|status: INDETERMINATE"
    "scripts/wt-down.sh|DELETE-ALL-LOCAL-DATA"
  )
  # These three are left SCRIPT-ONLY on purpose (not weakened — this is
  # exactly their pre-existing coverage): docs/platform-lifecycle-operations.md
  # is AXI-1977's file, not this story's, and this story may not edit its
  # prose. Checking them against the runbook found it genuinely does not
  # carry these quotes verbatim:
  #   - "has no automatic release by ANY route" — scripts/lock.sh:102 is a
  #     CODE COMMENT (not a printed message); the runbook's own prose says
  #     "by any route" (lowercase) at a different line — a case mismatch,
  #     not the same string.
  #   - "ABORT: backup not verified; compute NOT stopped" and "ABORT:
  #     could not acquire the data-tier lock" (providers/aws/scripts/
  #     power.sh, power-data.sh) — added by AXI-1967/1970's debt-closure
  #     lock-exclusion work; the runbook predates both and was never
  #     updated to quote either refusal. Reported for AXI-1977, not fixed
  #     here.
  local script_only_entries=(
    "scripts/lock.sh|has no automatic release by ANY route"
    "providers/aws/scripts/power.sh|ABORT: backup not verified; compute NOT stopped"
    "providers/aws/scripts/power-data.sh|ABORT: could not acquire the data-tier lock"
  )
  # The runbook's own text, markdown-stripped and whitespace-collapsed —
  # this, not a copy in this test, is what each dual-checked needle is
  # checked against.
  local runbook_text
  runbook_text="$(perl -0777 -pe 's/[`*]//g; s/\s+/ /g' "${INFRA_ROOT}/docs/platform-lifecycle-operations.md")"

  local e script needle missing_script="" missing_runbook=""
  for e in "${entries[@]}" "${script_only_entries[@]}"; do
    script="${e%%|*}"; needle="${e#*|}"
    grep -qF -- "$needle" "${INFRA_ROOT}/${script}" || missing_script="$missing_script\n  ${script}: ${needle}"
  done
  for e in "${entries[@]}"; do
    needle="${e#*|}"
    printf '%s' "$runbook_text" | grep -qF -- "$needle" || missing_runbook="$missing_runbook\n  ${needle}"
  done
  [ -z "$missing_script" ] || fail "quote(s) not found verbatim in their script:$(printf '%b' "$missing_script")"
  [ -z "$missing_runbook" ] || fail "quote(s) not found verbatim in the runbook (docs/platform-lifecycle-operations.md) — AC59:$(printf '%b' "$missing_runbook")"
}

# UT-INFRA-389 — the Makefile's own documented AWS-CLI-version constants
# (lock.sh) match what the runbook states as the minimum versions.
@test "UT-INFRA-389: the AWS CLI minimum versions quoted in the runbook match lock.sh's own constants" {
  run grep -oE 'LOCK_MIN_AWS_CLI_PUT="[0-9.]+"' "${INFRA_ROOT}/scripts/lock.sh"
  assert_success
  local put_ver; put_ver="$(printf '%s' "$output" | grep -oE '[0-9.]+')"
  run grep -oE 'LOCK_MIN_AWS_CLI_DELETE="[0-9.]+"' "${INFRA_ROOT}/scripts/lock.sh"
  assert_success
  local del_ver; del_ver="$(printf '%s' "$output" | grep -oE '[0-9.]+')"

  run grep -F "≥ ${put_ver}" "${INFRA_ROOT}/docs/platform-lifecycle-operations.md"
  assert_success
  run grep -F "≥ ${del_ver}" "${INFRA_ROOT}/docs/platform-lifecycle-operations.md"
  assert_success
}
