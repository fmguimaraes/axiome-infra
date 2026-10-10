#!/usr/bin/env bats
# tests/lock_acquire_exclusive.bats — scripts/lock.sh's lock_acquire_exclusive
# helper, tested directly as a sourced library function (AXI-1967,
# FR42/FR43, AC34/AC35). deploy-prod.bats/power_data_*.bats/power_status.bats
# cover this helper's effect through each caller script; this file instead
# pins the helper's OWN return-code contract so a future edit to its
# internals (e.g. AXI-1973, which also edits this file) cannot silently
# regress it the way the
# `! cmd; then $?` negation trap did during this story (see git history —
# `other_rc=$?` inside `if ! lock_require_free ...; then` always read 0,
# the `!`-negated boolean, never lock_require_free's real rc, so a HELD
# other lock was always reported back as success).
# UT-INFRA-408..413.

load 'helpers/setup'

setup() {
  stub_setup
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-acquire-exclusive.rules.sh"
  export LOCK_ACTOR="me@example.com"
  export REPORT_REPO_ROOT="${INFRA_ROOT}"
}

# UT-INFRA-408: all three locks free — acquires 'deploy', prints the same
# ACQUIRED line a plain lock_acquire would, and returns success.
@test "UT-INFRA-408: lock_acquire_exclusive succeeds and prints ACQUIRED when every other lock is free" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_success
  assert_output --partial "ACQUIRED deploy"
  assert_output --partial "token="
  assert_output --partial "rc=0"
}

# UT-INFRA-409: 'data-tier' is held — lock_acquire_exclusive must acquire
# 'deploy' first, THEN discover data-tier held, release 'deploy' (its OWN
# just-acquired token, never data-tier's), and return a NON-ZERO rc. This
# is the exact defect the negation-trap bug hid: before the fix this
# test's rc assertion failed (rc=0 was returned regardless).
@test "UT-INFRA-409: lock_acquire_exclusive releases its own lock and refuses when data-tier is held" {
  export LOCK_EXCLUSIVE_DATATIER_STATE=held

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_output --partial "lock 'data-tier' is not free"
  assert_output --partial "acquired 'deploy' but 'data-tier' is not free — releasing 'deploy' and refusing"
  assert_output --partial "RELEASED deploy"
  refute_output --partial "rc=0"
  run grep -cx "delete-object" "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-410: 'apply' (the SECOND name in the list) is held while
# data-tier is free — proves the loop checks every <other>, not just the
# first, and still releases 'deploy' and refuses.
@test "UT-INFRA-410: lock_acquire_exclusive refuses when apply (checked second) is held" {
  export LOCK_EXCLUSIVE_APPLY_STATE=held

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_output --partial "lock 'apply' is not free"
  assert_output --partial "acquired 'deploy' but 'apply' is not free — releasing 'deploy' and refusing"
  assert_output --partial "RELEASED deploy"
  refute_output --partial "rc=0"
  run grep -cx "delete-object" "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-411: both data-tier and apply held — refuses on the FIRST one
# checked (data-tier, since it is listed first) and never even looks at
# apply (fail fast, not an exhaustive report of every holder).
@test "UT-INFRA-411: lock_acquire_exclusive refuses on the first held other-lock and stops checking" {
  export LOCK_EXCLUSIVE_DATATIER_STATE=held
  export LOCK_EXCLUSIVE_APPLY_STATE=held

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_output --partial "lock 'data-tier' is not free"
  run grep -c "locks/apply.json" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-412: AC35 race — data-tier is free at the moment
# lock_acquire_exclusive checks it (this helper makes exactly one
# get-object call per <other>, never re-polls), so acquiring 'deploy' and
# then observing both others free is exactly the contract: a park that
# starts AFTER this single check is not this helper's problem to catch —
# that is why every caller (deploy-prod.sh, power-data.sh) ALSO re-checks
# post-preflight. This test pins that lock_acquire_exclusive itself makes
# no more than one get-object per other-lock name (no internal retry/poll
# that could mask a race rather than surface it to the caller's re-check).
@test "UT-INFRA-412: lock_acquire_exclusive checks each other-lock exactly once (no hidden retry masking a race)" {
  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_success
  run grep -c "locks/data-tier.json" "$STUB_LOG"
  assert_output "1"
  run grep -c "locks/apply.json" "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-413: when acquiring 'deploy' itself fails (e.g. it is already
# held), lock_acquire_exclusive returns lock_acquire's own rc unchanged and
# never even looks at the other lock names — nothing was acquired, so
# there is nothing for it to release.
# UT-INFRA-430 (bounce #1, AXI-1967): if RELEASING the just-acquired lock
# itself fails (e.g. AccessDenied on the conditional delete), the refusal
# must never stay silent about it — one truthful line naming the lock,
# that it may still be HELD, and the remedy (status then override). The
# other-lock's own rc is still returned (non-zero either way).
@test "UT-INFRA-430: lock_acquire_exclusive warns when releasing its own lock fails, still returns non-zero" {
  export LOCK_EXCLUSIVE_DATATIER_STATE=held
  export LOCK_EXCLUSIVE_DEPLOY_RELEASE_FAIL=1

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive dev deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_output --partial "releasing 'deploy' failed"
  assert_output --partial "may still be HELD"
  assert_output --partial "lock.sh dev status deploy"
  refute_output --partial "rc=0"
}

@test "UT-INFRA-413: lock_acquire_exclusive passes through a failure to acquire its own lock untouched" {
  stub_use_rules aws "${TESTS_DIR}/fixtures/lock-acquire.rules.sh"

  run bash -c ". '${INFRA_ROOT}/scripts/lock.sh'; lock_acquire_exclusive staging deploy 'deploy test' data-tier apply; echo \"rc=\$?\""

  assert_output --partial "someone@example.com"
  assert_output --partial "rc=1"
  run grep -c "locks/data-tier.json" "$STUB_LOG"
  assert_output "0"
  run grep -c "locks/apply.json" "$STUB_LOG"
  assert_output "0"
}
