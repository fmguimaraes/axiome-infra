#!/usr/bin/env bats
# tests/compose-call-sites.bats — AXI-1971 FR54/FR55 structural checks.
#
# UT-INFRA-519 (widened by review bounce #1, BLOCKING 2): scans EVERY
# tracked shell script and Makefile in the whole repository (via
# `git ls-files`), not just the Makefile + scripts/*.sh this story owns —
# that narrower scope is exactly how analytics/test/e2e-analytics.sh's own
# fallback-to-v1 idiom went unseen. This is an EXCLUSION list, not an
# inclusion list, specifically so a brand-new file is scanned by default.
# Every excluded file below has a one-line, falsifiable reason; add to
# this list only with one of your own.
#
# Excluded files and why:
#   - tests/vendor/**                     : vendored third-party bats-core/
#     bats-support source (upstream, untouched); never invokes Compose for
#     this product.
#   - tests/fixtures/*.rules.sh,
#     tests/stubs/_common.sh              : test-harness STUB
#     CONFIGURATION — strings the fake `docker` stub matches against to
#     decide what canned output to print; never a real Compose invocation.
#   - scripts/lib/compose-resolve.sh      : the resolver's own
#     implementation/probe (this is the thing being required elsewhere,
#     not a call site that could bypass it).
#   - providers/aws/onbox/boot.sh         : runs ON the production/demo
#     EC2 box's own boot sequence, never on this dev machine's local PATH
#     (lead decision — out of scope).
#   - providers/aws/scripts/power.sh,
#     power-up-all.sh                     : the "docker compose ..." text
#     is a literal string embedded for an OPERATOR to paste into
#     ssm-exec.sh against a REMOTE box; never resolved or executed on this
#     machine's own PATH.
#   - providers/onprem/scripts/install.sh  : installs the stack onto a
#     CUSTOMER's target machine; never run locally against this repo's own
#     dev stack.
#   - scripts/asset-sync.sh, deploy-prod.sh, roll-service.sh : run ON the
#     production box over SSM/SSH; out of this story's file ownership per
#     its spawn brief.
#   - scripts/reset-admin-password.sh, pull-on-vm.sh, platform-debug.sh,
#     ssm-exec.sh                         : remote-exec tooling — the
#     literal "docker compose ..." text is a STRING shipped to a remote
#     shell over SSM/SSH, never resolved by THIS process's own PATH.
#   - scripts/seed-environment.sh is no longer excluded (AXI-1968 closed
#     this debt): both its local Compose call sites now go through
#     scripts/lib/compose-resolve.sh, same as every other local script.
#
# UT-INFRA-520: `make local-ps` / `make local-health` inspect the Compose
# PROJECT that `make local-up` (== `demo-up`) actually starts
# (axiome-demo), not the unrelated axiome-$(LEGACY_SLUG) project no
# `local-*` target starts (FR55/AC48) — the pre-existing bug named in the
# AXI-1944 epic doc's AXI-1955 follow-up (5).
#
# UT-INFRA-606: no in-scope file falls back from a failed/absent Compose
# v2 probe to the legacy v1 binary NAME (the exact AXI-1944 incident
# idiom: `docker compose version ... || echo "docker-compose"`, or
# `command -v docker-compose` used as a fallback decision) — the second
# AXI-1971 review bounce finding (BLOCKING 2), closed in
# analytics/test/e2e-analytics.sh (now resolver-routed) and guarded here so
# it cannot come back anywhere else in the repo.

load 'helpers/setup'

setup() {
  stub_setup
}

_EXCLUDED_FILES='^tests/vendor/|^tests/fixtures/.*\.rules\.sh$|^tests/stubs/_common\.sh$|^scripts/lib/compose-resolve\.sh$|^providers/aws/onbox/boot\.sh$|^providers/aws/scripts/power\.sh$|^providers/aws/scripts/power-up-all\.sh$|^providers/onprem/scripts/install\.sh$|^scripts/asset-sync\.sh$|^scripts/deploy-prod\.sh$|^scripts/roll-service\.sh$|^scripts/reset-admin-password\.sh$|^scripts/pull-on-vm\.sh$|^scripts/platform-debug\.sh$|^scripts/ssm-exec\.sh$'

# _repo_sources — every tracked shell script + Makefile in the WHOLE repo
# (not just this story's scripts/), relative to INFRA_ROOT. Captured once
# per test file, at file-parse time — i.e. BEFORE `setup()` ever prepends
# tests/stubs to PATH — so this always runs the REAL `git`, never the
# `git` stub (which would otherwise record an unconfigured-call failure).
_ALL_REPO_SOURCES="$(cd "${INFRA_ROOT}" && git ls-files 2>/dev/null | grep -E '(^|/)Makefile$|\.sh$')"

# _in_scope_abs_paths — the above, minus the excluded files, as absolute
# paths ready for grep.
_in_scope_abs_paths() {
  printf '%s\n' "${_ALL_REPO_SOURCES}" \
    | grep -vE "${_EXCLUDED_FILES}" \
    | sed "s|^|${INFRA_ROOT}/|"
}

# _bypass_scan <pattern> — repo-wide grep for <pattern> across every
# in-scope file, with full-line comments stripped. Non-empty output = a
# bypass was found. Deliberately `xargs -d '\n'` (never string-paste the
# newline-separated path list into a `bash -c '...'` SCRIPT — a path on
# every line after the first would then be parsed as its own COMMAND and
# actually RUN; that is exactly the bug this story's own first draft of
# UT-INFRA-519b had, caught only because it ran harmlessly inside the
# stub sandbox — see AXI-1971's handback for the full incident note).
_bypass_scan() {
  local pattern="$1"
  local files
  files="$(_in_scope_abs_paths)"
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | xargs -d '\n' grep -nE "$pattern" 2>/dev/null \
    | awk -F: '{
        line=$0
        sub(/^[^:]*:[^:]*:/, "", line)
        trimmed=line
        sub(/^[ \t]+/, "", trimmed)
        if (trimmed !~ /^#/) print $0
      }'
}

# UT-INFRA-519a — no line in scope STARTS a command with the literal
# "docker compose" / "docker-compose" (the exact shape of the incident:
# the Makefile's own fallback used the bare binary name directly).
@test "UT-INFRA-519: no in-scope file starts a command with a raw docker/docker-compose invocation" {
  run _bypass_scan '^[[:space:]]*(docker compose|docker-compose)([[:space:]]|$)'
  assert_output ""
  assert_success
}

# UT-INFRA-519b — no line in scope references the bare "docker-compose"
# token anywhere (mid-line call, e.g. inside a $(...) substitution) other
# than as a *.yml filename (docker-compose.yml / .shared.yml / .demo.yml /
# .demo.llm.yml / .analytics.yml) or inside a comment.
@test "UT-INFRA-519: no in-scope file references the docker-compose binary name outside a *.yml filename or a comment" {
  run _bypass_scan '\bdocker-compose\b'
  # The above also matches docker-compose.yml / .shared.yml / .demo.yml /
  # .demo.llm.yml / .analytics.yml FILENAME references (legitimate — a
  # *.yml path is not a binary invocation), so filter those out of its
  # output here rather than inside _bypass_scan (which other callers use
  # without that exception).
  output="$(printf '%s' "$output" | grep -vE 'docker-compose\.(yml|shared\.yml|demo\.yml|demo\.llm\.yml|analytics\.yml)' || true)"
  assert_success
  assert_output ""
}

# UT-INFRA-519c — same for the two-word form "docker compose" anywhere
# mid-line (not just line-start) outside a comment.
@test "UT-INFRA-519: no in-scope file references a raw 'docker compose' mid-line outside a comment" {
  run _bypass_scan '\bdocker compose\b'
  assert_output ""
  assert_success
}

# UT-INFRA-520 — local-ps and local-health inspect $(DEMO) (project
# axiome-demo), the project `local-up`/`demo-up` actually start, not
# $(APP) (axiome-$(LEGACY_SLUG), which no `local-*` target starts since
# `local-up` became a `demo-up` alias). DOCKER_COMPOSE is passed explicitly
# so this never depends on the resolver's own probe (see
# tests/demo-up-migrate.bats for the same convention); `make -n` only
# PRINTS each recipe line, it never executes one.
@test "UT-INFRA-520: make local-ps inspects the axiome-demo project, not axiome-local" {
  run make -C "${INFRA_ROOT}" -n local-ps DOCKER_COMPOSE="docker compose"
  assert_success
  assert_output --partial "docker compose -p axiome-demo -f docker-compose.demo.yml ps"
  refute_output --partial "axiome-local"
}

@test "UT-INFRA-520: make local-health inspects the axiome-demo project, not axiome-local" {
  run make -C "${INFRA_ROOT}" -n local-health DOCKER_COMPOSE="docker compose"
  assert_success
  assert_output --partial "docker compose -p axiome-demo -f docker-compose.demo.yml ps --format"
  refute_output --partial "axiome-local"
}

# UT-INFRA-606 — AXI-1971 review bounce #2 (BLOCKING 2): no in-scope file
# falls back from a failed/absent Compose v2 probe to the legacy v1
# binary NAME — the exact AXI-1944 incident idiom
# (`docker compose version ... || echo "docker-compose"`) that
# analytics/test/e2e-analytics.sh carried (unseen by the narrower,
# scripts/*.sh-only UT-INFRA-519 scan this story shipped at first). Also
# catches `command -v docker-compose` used the same way. The widened
# UT-INFRA-519 scan above would itself eventually catch a *.sh-only
# recurrence of this idiom too (it is literal "docker-compose" text
# outside a comment/yml-filename), but this test names the specific
# incident shape so a bounce on it is unambiguous.
@test "UT-INFRA-606: no in-scope file falls back from a Compose v2 probe to the legacy docker-compose v1 binary name" {
  run _bypass_scan '\|\|[[:space:]]*echo[[:space:]]+"?docker-compose"?|command -v docker-compose'
  assert_output ""
  assert_success
}
