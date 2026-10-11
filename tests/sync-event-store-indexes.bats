#!/usr/bin/env bats
# tests/sync-event-store-indexes.bats — scripts/sync-event-store-indexes.sh
# (AXI-1971, FR56/AC49): the one explicit, opt-in command that syncs the
# local event-store (MongoDB) indexes, called by NO start/up/migrate/seed
# path.

load 'helpers/setup'

setup() {
  stub_setup
}

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sync-event-store-indexes.sh"

# UT-INFRA-521 — no MongoDB address anywhere (no $MONGODB_URL, no
# --env-file, no --mongodb-url): refuses rather than guessing. No docker
# call of any kind.
@test "UT-INFRA-521: refuses when no MongoDB address is available anywhere" {
  run env -u MONGODB_URL "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "no MongoDB address"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-522 — a non-local host (via $MONGODB_URL) refuses before any
# docker call — never touches a remote event store.
@test "UT-INFRA-522: refuses a non-local MongoDB host" {
  run env MONGODB_URL="mongodb://axiome:pw@db.example.com:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "not a recognized LOCAL address"
  assert_output --partial "db.example.com"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-523 — a --mongodb-url carrying embedded credentials on this
# command's OWN argv is refused outright — secrets never belong on argv —
# before any docker call, and the credentials are never echoed back.
@test "UT-INFRA-523: refuses --mongodb-url with embedded credentials on argv" {
  run "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml \
    --mongodb-url "mongodb://admin:s3cr3t@localhost:27017/axiome"
  assert_failure
  assert_output --partial "embedded credentials"
  refute_output --partial "s3cr3t"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-524 — a local (loopback) address is accepted: resolves Compose
# v2 through the shared resolver, then runs Prisma's own index sync inside
# the backend container, with NO data-loss-accepting flag anywhere on that
# command's argv.
@test "UT-INFRA-524: accepts localhost, resolves Compose, and runs with no data-loss flag" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-ok.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_success
  assert_stub_called docker "version"
  run grep -c "prisma db push" "$STUB_LOG"
  assert_output "1"
  run grep -c "accept-data-loss\|force-reset\|dropDatabase\|--drop" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-525 — the `mongodb` compose-network container alias (reachable
# only from inside the local docker network) is also accepted as local,
# read from --env-file (never printed, never passed as an argument).
@test "UT-INFRA-525: accepts the mongodb container alias host from --env-file" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-ok.rules.sh"
  local env_file="${BATS_TEST_TMPDIR}/.env"
  printf 'MONGODB_URL=mongodb://axiome:pw@mongodb:27017/axiome?authSource=admin\n' > "$env_file"
  run env -u MONGODB_URL "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml --env-file "$env_file"
  assert_success
}

# UT-INFRA-526 — structural: the script's own source never contains a
# data-loss-accepting flag on any command line (not just "didn't happen to
# use one at runtime" — it CANNOT, because the literal text is absent).
# Proven non-vacuous by first showing the same scan WOULD catch one.
@test "UT-INFRA-526: the script's source contains no data-loss-accepting flag outside a comment" {
  run bash -c '
    grep -nHE "accept-data-loss|force-reset|--drop|dropDatabase" "'"${SCRIPT}"'" \
      | awk -F: "{
          line=\$0
          sub(/^[^:]*:[^:]*:/, \"\", line)
          trimmed=line
          sub(/^[ \t]+/, \"\", trimmed)
          if (trimmed !~ /^#/) print \$0
        }"
  '
  assert_output ""
  assert_success
  # Prove the scan is not vacuous: a NON-comment line that WOULD trip it.
  run bash -c '
    printf "npx prisma db push --accept-data-loss\n" > "'"${BATS_TEST_TMPDIR}"'/bad.sh"
    grep -nHE "accept-data-loss|force-reset|--drop|dropDatabase" "'"${BATS_TEST_TMPDIR}"'/bad.sh" \
      | awk -F: "{
          line=\$0
          sub(/^[^:]*:[^:]*:/, \"\", line)
          trimmed=line
          sub(/^[ \t]+/, \"\", trimmed)
          if (trimmed !~ /^#/) print \$0
        }"
  '
  assert_output --partial "accept-data-loss"
}

# UT-INFRA-527 — structural: no start/up/migrate/seed path calls this
# script. wt-up.sh/wt-migrate.sh/ensure-shared-infra.sh are this story's
# own files; the Makefile's demo-up/local-up/shared-up targets are
# checked by name. (scripts/seed-environment.sh is out of this story's
# ownership but checked too, read-only, since FR56 names "seed" paths
# explicitly.)
@test "UT-INFRA-527: no start/up/migrate/seed path invokes sync-event-store-indexes.sh" {
  run grep -l "sync-event-store-indexes" \
    "${INFRA_ROOT}/scripts/wt-up.sh" "${INFRA_ROOT}/scripts/wt-migrate.sh" \
    "${INFRA_ROOT}/scripts/ensure-shared-infra.sh" "${INFRA_ROOT}/scripts/seed-environment.sh" \
    "${INFRA_ROOT}/Makefile"
  assert_failure   # grep -l finds nothing in any of them -> exit 1
  assert_output ""
}

# --- AXI-1971 review bounce #1, issue 3 ("ALSO CLOSE IN THE SAME PUSH") ---
# The host-side check (UT-INFRA-522) validates the URL THIS COMMAND was
# told about; `prisma db push` below actually runs INSIDE the backend
# container and reads the CONTAINER's OWN $MONGODB_URL, which can
# legitimately differ. These three tests exercise that second,
# independent check, which reads ONLY the host from inside the container
# (never the full URL — it may carry credentials) before the push runs.

# UT-INFRA-607 — the container's own MONGODB_URL host is local: the sync
# proceeds exactly as before (UT-INFRA-524), now via two local checks.
@test "UT-INFRA-607: accepts when the container's own MONGODB_URL host is local too" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-container-local.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_success
  run grep -c "prisma db push" "$STUB_LOG"
  assert_output "1"
}

# UT-INFRA-608 — the host-side URL is local, but the CONTAINER's own
# MONGODB_URL host is remote: refuses, and `prisma db push` is never
# invoked (the two checks are independent on purpose).
@test "UT-INFRA-608: refuses when the container's own MONGODB_URL host is remote, even though the host-side URL is local" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-container-remote.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "container's own MONGODB_URL host"
  assert_output --partial "evil-remote.example.com"
  assert_output --partial "not a recognized LOCAL address"
  run grep -c "prisma db push" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-609 — reading the container's own MONGODB_URL host fails
# outright (empty output / non-zero exit, e.g. the env var is unset
# inside the container): refuses rather than assuming local, and
# `prisma db push` is never invoked.
@test "UT-INFRA-609: refuses when the container's own MONGODB_URL host cannot be read" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-container-empty.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "could not read"
  assert_output --partial "container's own"
  run grep -c "prisma db push" "$STUB_LOG"
  assert_output "0"
}

# --- AXI-1968 (FR debt, three follow-ups left by AXI-1971) ---------------

# UT-INFRA-497 — a replica-set URL with a REMOTE second host is refused,
# even though the first host is local — before this story only the first
# host was ever checked.
@test "UT-INFRA-497: refuses a multi-host MongoDB URL whose SECOND host is remote" {
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017,evil-remote.example.com:27017/axiome?authSource=admin&replicaSet=rs0" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "not a recognized LOCAL address"
  assert_output --partial "evil-remote.example.com"
  run grep -c "^### CALL:" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-498 — a replica-set URL with EVERY host local is accepted.
@test "UT-INFRA-498: accepts a multi-host MongoDB URL when every host is local" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-ok.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017,mongodb:27017/axiome?authSource=admin&replicaSet=rs0" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_success
}

# UT-INFRA-499 — a password containing a literal '@' does not cause a
# false refusal (userinfo must be stripped with the LONGEST match, up to
# the LAST '@', not the first) when the actual host is local.
@test "UT-INFRA-499: accepts a local host even when the password contains an embedded '@'" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-ok.rules.sh"
  run env 'MONGODB_URL=mongodb://axiome:p@ss@localhost:27017/axiome?authSource=admin' \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_success
}

# UT-INFRA-500 — the same embedded-'@' password, against a REMOTE host:
# refuses (correctly, on the real host — never on a leftover userinfo
# fragment), and the refusal text never contains the password.
@test "UT-INFRA-500: refuses a remote host with an embedded-'@' password, without leaking a password fragment" {
  run env 'MONGODB_URL=mongodb://axiome:p@ss@db.example.com:27017/axiome?authSource=admin' \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "not a recognized LOCAL address"
  assert_output --partial "db.example.com"
  refute_output --partial "p@ss"
  refute_output --partial "axiome:p"
}

# UT-INFRA-501 — a bracketed IPv6 loopback address ([::1]:27017) is
# accepted as local; before this story the naive port-strip mishandled
# the brackets and refused it.
@test "UT-INFRA-501: accepts a bracketed IPv6 loopback host ([::1]:27017)" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-ok.rules.sh"
  run env 'MONGODB_URL=mongodb://axiome:pw@[::1]:27017/axiome?authSource=admin' \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_success
}

# UT-INFRA-502 — the CONTAINER-side check also validates every host in a
# replica-set URL, not just the first; a remote SECOND host refuses, and
# `prisma db push` is never invoked.
@test "UT-INFRA-502: refuses when the container's own MONGODB_URL has a remote SECOND host" {
  stub_use_rules docker "${TESTS_DIR}/fixtures/sync-event-store-container-multihost-remote.rules.sh"
  run env MONGODB_URL="mongodb://axiome:pw@localhost:27017/axiome?authSource=admin" \
    "$SCRIPT" --compose-project axiome-demo --compose-file docker-compose.demo.yml
  assert_failure
  assert_output --partial "container's own MONGODB_URL host"
  assert_output --partial "evil-remote.example.com"
  assert_output --partial "not a recognized LOCAL address"
  run grep -c "prisma db push" "$STUB_LOG"
  assert_output "0"
}

# UT-INFRA-503 — direct unit test of the CONTAINER-side POSIX sh snippet
# (review bounce #2 note: the snippet text is READ from the committed
# script's own source at test time — never hand-copied — so it cannot
# drift from what the script actually runs inside the container), run
# under plain `sh`, proving its multi-host/bracket/longest-match
# userinfo-strip behaviour independent of the docker stub's canned fixture
# strings.
@test "UT-INFRA-503: the container-side POSIX host-extraction snippet handles multi-host, embedded-'@' userinfo, and bracketed IPv6" {
  local script_file snippet_line snippet
  script_file="${BATS_TEST_DIRNAME}/../scripts/sync-event-store-indexes.sh"
  # The snippet is the single-quoted argument to `sh -lc` on the one line
  # of the script containing this exact marker — grab that line, then
  # take everything between its FIRST and LAST single quote (the snippet
  # itself only ever uses double quotes internally, so this is unambiguous).
  # AXI-1972 (follow-up e): a marker that matches ZERO or TWO-OR-MORE
  # lines must fail with a named message, not silently extract the wrong
  # (or an empty/concatenated) snippet. `grep -c` counts matches without
  # the ambiguity of inspecting a multi-line command-substitution result.
  local match_count
  match_count="$(grep -cF 'u="$MONGODB_URL"' "${script_file}")"
  case "$match_count" in
    0) fail "could not find the MONGODB_URL host-extraction line in ${script_file} — has it moved or been rewritten?" ;;
    1) ;;
    *) fail "the MONGODB_URL host-extraction marker matches ${match_count} lines in ${script_file} — expected exactly one; the single-quote extraction below is only unambiguous for a single match" ;;
  esac
  snippet_line="$(grep -F 'u="$MONGODB_URL"' "${script_file}")"
  snippet="$(printf '%s' "${snippet_line}" | sed -e "s/^[^']*'//" -e "s/'[^']*\$//")"
  [ -n "${snippet}" ] || fail "extracted an empty snippet from ${script_file} — the single-quote extraction did not match"

  run env MONGODB_URL='mongodb://axiome:p@ss@localhost:27017,[::1]:27018,evil-remote.example.com:27017/axiome?authSource=admin' \
    sh -c "${snippet}"
  assert_success
  assert_output $'localhost\n::1\nevil-remote.example.com'
}
