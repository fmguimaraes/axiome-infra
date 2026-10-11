#!/usr/bin/env bash
# tests/check-ut-ids.sh — AXI-1972 follow-up (a): every UT-INFRA-<n> id
# used by an `@test` is unique ACROSS *.bats files, and UT.md has exactly
# one row per id. UT-INFRA-430 was used, independently, by two different
# files on main (AXI-1967's tests/lock_acquire_exclusive.bats and
# AXI-1969's tests/asset-sync.bats) before this story renumbered the
# newer one (AXI-1967's, to UT-INFRA-548 — AXI-1969's commit is the
# older of the two). This guard keeps that from recurring.
#
# One explicit, narrow exception: an id MAY repeat several @test entries
# WITHIN THE SAME FILE when it is deliberately used to label several
# widened variants of one acceptance criterion (UT-INFRA-519 and
# UT-INFRA-520 in tests/compose-call-sites.bats — see that file's own
# comments). That is the only form of repeat this check allows; it is a
# fixed allowlist below, not a general "same file is fine" rule — a new
# accidental copy-paste repeat within one file still fails.
#
# Usage: tests/check-ut-ids.sh [<bats-dir>] [<UT.md path>]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_DIR="${1:-$TESTS_DIR}"
UT_MD="${2:-${TESTS_DIR}/../UT.md}"
cd "$SCAN_DIR"

SAME_FILE_REPEAT_ALLOWED="UT-INFRA-519 UT-INFRA-520"

_is_allowed() {
  local id="$1" want
  for want in $SAME_FILE_REPEAT_ALLOWED; do
    [ "$id" = "$want" ] && return 0
  done
  return 1
}

declare -A FILES_FOR_ID
declare -A COUNT_FOR_ID

shopt -s nullglob
for f in *.bats; do
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    FILES_FOR_ID["$id"]="${FILES_FOR_ID[$id]:-}${FILES_FOR_ID[$id]:+ }${f}"
    COUNT_FOR_ID["$id"]=$(( ${COUNT_FOR_ID[$id]:-0} + 1 ))
  done < <(grep -ohE '@test "UT-INFRA-[0-9]+' "$f" | grep -oE 'UT-INFRA-[0-9]+')
done

status=0
for id in "${!FILES_FOR_ID[@]}"; do
  distinct_files="$(printf '%s\n' ${FILES_FOR_ID[$id]} | sort -u)"
  nfiles="$(printf '%s\n' "$distinct_files" | grep -c .)"
  if [ "$nfiles" -gt 1 ]; then
    echo "ERROR: ${id} is used in more than one *.bats file: $(printf '%s' "$distinct_files" | tr '\n' ' ')" >&2
    status=1
    continue
  fi
  if [ "${COUNT_FOR_ID[$id]}" -gt 1 ] && ! _is_allowed "$id"; then
    echo "ERROR: ${id} is used by ${COUNT_FOR_ID[$id]} @test entries in $(printf '%s' "$distinct_files") and is not in the explicit same-file-repeat allowlist." >&2
    status=1
  fi
done

if [ -f "$UT_MD" ]; then
  for id in "${!FILES_FOR_ID[@]}"; do
    n="$(grep -cE "^\| ${id} \|" "$UT_MD" || true)"
    if [ "$n" -eq 0 ]; then
      echo "ERROR: ${id} is used by a test but has no row in ${UT_MD}." >&2
      status=1
    elif [ "$n" -gt 1 ]; then
      echo "ERROR: ${id} has ${n} rows in ${UT_MD} — exactly one is required." >&2
      status=1
    fi
  done
fi

exit "$status"
