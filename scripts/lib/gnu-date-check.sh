#!/usr/bin/env bash
# scripts/lib/gnu-date-check.sh — ONE shared preflight for every script that
# relies on GNU `date` extensions (FR53/AC46): `-d`/`--date` (parse an
# arbitrary date string into epoch seconds) and `%N` (nanoseconds, used for
# a cheap unique token). BSD/macOS `date` supports neither — `date -d
# <anything>` on BSD date either errors immediately or silently misparses,
# and `%N` is passed through literally instead of expanded. Call this at the
# very top of a script's entry point, BEFORE any mutating action.
#
# Usage (sourced, never executed on its own):
#   . "<repo-root>/scripts/lib/gnu-date-check.sh"
#   gnu_date_check || exit 1
#
# Sourced by:
#   - scripts/lock.sh (CLI entry point / `main`)
#   - providers/aws/scripts/power.sh
#   - providers/aws/scripts/power-data.sh
#   - scripts/deploy-prod.sh (review bounce #1, Blocker 2: it sources
#     scripts/lock.sh and calls lock_acquire_exclusive directly, which never
#     goes through lock.sh's own CLI `main()` preflight — it needs its own
#     call, right after arg parsing, before any lock/SSM/AWS action)
#
# Audited but NOT a caller (review bounce #1, Blocker 2 audit):
#   - providers/aws/scripts/power-up-all.sh sources _power_lib.sh but has no
#     lock_* call and no `date -d`/`%N` of its own — it only delegates to
#     power.sh/power-data.sh as subprocesses, each already covered above.
#   - providers/aws/scripts/_power_lib.sh and scripts/lib/report.sh have no
#     GNU-date dependency at all (only portable `date -u +FORMAT`).
#   - .github/workflows/terraform-cd.yml's "Acquire apply lock" step sources
#     scripts/lock.sh directly in a `run:` block (same bypass shape as
#     deploy-prod.sh), but it runs on a GitHub-hosted `ubuntu-latest` runner,
#     not an arbitrary operator's machine — GNU date is guaranteed there,
#     same rationale as the on-box exemption below.
#   - providers/aws/onbox/mongo-backup-timer-install-remote.sh is NOT a
#     caller: it runs on the box, where GNU `date` + GNU coreutils are
#     guaranteed by the AMI (Ubuntu) — see that file's own header.
#
# gnu_date_check — prints nothing on success (rc 0). On a non-GNU `date`,
# prints ONE truthful line to stderr naming the remedy and returns 1; the
# caller is expected to `exit` on a non-zero return so nothing runs after
# it. Never writes anything, never mutates anything — read-only probe.
gnu_date_check() {
  # `date -d @0` is accepted by GNU date (parses the epoch, prints the
  # 1970-01-01 date) and rejected by BSD/macOS date (unknown option / usage
  # error) — this single probe covers BOTH extensions this codebase needs
  # (`-d`/`--date` and `%N`): GNU date's `%N` support and its `-d` support
  # ship together in the same `date` binary (coreutils), so one probe for
  # `-d` is sufficient evidence for `%N` too; a BSD date that somehow
  # accepted `-d` but not `%N` is not a real-world case this codebase has
  # ever hit.
  if ! date -d @0 >/dev/null 2>&1; then
    echo "ERROR: GNU date is required (this script uses 'date -d'/'date --date' and 'date +%N', which only GNU coreutils' date supports) — on macOS run 'brew install coreutils' and put its gnubin directory first on PATH so 'date' resolves to GNU date, or run this from a GNU/Linux host (the AWS box itself is Ubuntu and is unaffected). Refusing before making any change." >&2
    return 1
  fi
  return 0
}
