# Unit Tests — axiome-infra

`UT-INFRA-<seq>` for every bats test in `tests/`. One behaviour each, AAA
(Arrange/Act/Assert). AXI-1945 owns `UT-INFRA-001`–`UT-INFRA-099`; later
ranges are allocated by the lead per sibling story.

| ID | Story | File | Behaviour |
|----|-------|------|-----------|
| UT-INFRA-001 | AXI-1945 | `tests/report.bats` | `report_init/section/line/finish` writes actor, UTC time, inputs and an outcome on every report (NFR4). |
| UT-INFRA-002 | AXI-1945 | `tests/report.bats` | `report_override` records the override name + reason used (NFR4). |
| UT-INFRA-003 | AXI-1945 | `tests/report.bats` | Every write path (`report_line`, `report_section`, `report_override`, `report_finish`, `log_event`) refuses every documented secret shape (postgres URL, `password=`/`PGPASSWORD=`/`secret=`/`token=`, `--password <value>`, bearer token, AKIA/ASIA access key, AWS-style 40-char secret key, JWT) — fail-closed, never masked (NFR3). |
| UT-INFRA-004 | AXI-1945 | `tests/report.bats` | Re-running the same report sequence twice does not collide or corrupt state — two distinct, well-formed report files result (NFR1 spirit). |
| UT-INFRA-005 | AXI-1945 | `tests/power_status.bats` | `providers/aws/scripts/power.sh <env> status` (existing, untouched script) reports the instance state via the stubbed `aws` CLI and makes no mutating call. |
| UT-INFRA-006 | AXI-1945 | `tests/report.bats` | `report_line` allows legitimate audit content that merely looks long — a git SHA, a `sha256:` image digest — because it is pure hex, never flagged as a secret. |
| UT-INFRA-007 | AXI-1945 | `tests/stub_detection.bats` | An unconfigured stub call is still caught when the caller does `cmd 2>/dev/null \|\| true` (exit code swallowed). |
| UT-INFRA-008 | AXI-1945 | `tests/stub_detection.bats` | An unconfigured stub call is still caught through a command substitution (`x="$(cmd)"`). |
| UT-INFRA-009 | AXI-1945 | `tests/stub_detection.bats` | An unconfigured stub call is still caught through a backgrounded subshell (`( cmd & wait )`). |
| UT-INFRA-100 | AXI-1947 | `tests/lock_acquire.bats` | `lock.sh acquire` on a free lock succeeds, prints the token/actor, and makes no `delete-object` call. |
| UT-INFRA-101 | AXI-1947 | `tests/lock_acquire.bats` | `lock.sh acquire` on an already-held lock returns a distinct exit code and names the holder (AC19). |
| UT-INFRA-102 | AXI-1947 | `tests/lock_acquire.bats` | A non-precondition `put-object` failure (e.g. AccessDenied) is a failure to acquire — never acquired, never free. |
| UT-INFRA-103 | AXI-1947 | `tests/lock_acquire.bats` | An aws CLI older than the documented minimum (2.13.5) is refused before any `put-object` attempt. |
| UT-INFRA-104 | AXI-1947 | `tests/lock_acquire.bats` | An unknown lock name is refused before any aws call. |
| UT-INFRA-105 | AXI-1947 | `tests/lock_release.bats` | `lock.sh release` by the holder removes its own lock via a conditional delete (`--if-match <etag>`). |
| UT-INFRA-106 | AXI-1947 | `tests/lock_release.bats` | `lock.sh release` with a non-matching token is refused and never calls `delete-object`. |
| UT-INFRA-107 | AXI-1947 | `tests/lock_release.bats` | `lock.sh release` of an already-free lock is refused. |
| UT-INFRA-108 | AXI-1947 | `tests/lock_release.bats` | `lock.sh release` refuses (fail-closed, NFR2) when the lock's state cannot be determined. |
| UT-INFRA-109 | AXI-1947 | `tests/lock_release.bats` | `lock.sh release` falls back to an unconditional delete, with a WARNING, when the CLI rejects `--if-match`. |
| UT-INFRA-110 | AXI-1947 | `tests/lock_status.bats` | `lock.sh status` reports FREE with exit 0 for an absent lock. |
| UT-INFRA-111 | AXI-1947 | `tests/lock_status.bats` | `lock.sh status` reports HELD with actor/operation/age and exit 1 (EC7). |
| UT-INFRA-112 | AXI-1947 | `tests/lock_status.bats` | `lock.sh status` reports UNKNOWN with a distinct exit code when the read fails (NFR2). |
| UT-INFRA-113 | AXI-1947 | `tests/lock_status.bats` | `lock.sh status` with no `<name>` checks both locks and returns the worst code. |
| UT-INFRA-114 | AXI-1947 | `tests/lock_override.bats` | `lock.sh override` without `--reason` is refused before any aws call. |
| UT-INFRA-115 | AXI-1947 | `tests/lock_override.bats` | `lock.sh override` without `--confirm` is refused before any aws call. |
| UT-INFRA-116 | AXI-1947 | `tests/lock_override.bats` | `lock.sh override` with `--reason`+`--confirm` on a held lock writes a `report_override` entry (previous holder + age, no token) then deletes (FR30, EC7). |
| UT-INFRA-117 | AXI-1947 | `tests/lock_override.bats` | `lock.sh override` on an already-free lock is refused and never deletes. |
| UT-INFRA-118 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_require_free` succeeds only when the lock is FREE; refuses on HELD. |
| UT-INFRA-119 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_require_free` treats UNDETERMINED the same as HELD (NFR2, fail-closed). |
| UT-INFRA-120 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_mark_for_auto_release` refuses to register `data-tier` (FR29) — no aws call. |
| UT-INFRA-121 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_release_held` releases a marked `deploy` lock; a second call is idempotent (no second delete). |
| UT-INFRA-122 | AXI-1947 | `tests/lock_lib_and_misc.bats` | Sourcing `lock.sh` has no side effects: no aws call, and it defines its public functions. |
| UT-INFRA-123 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock.sh` run with no arguments prints usage and exits non-zero without touching aws. |
| UT-INFRA-124 | AXI-1947 | `tests/lock_lib_and_misc.bats` | An unknown environment is refused before any aws call. |
| UT-INFRA-125 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock.sh status` refuses an unknown lock name before any aws call. |
| UT-INFRA-126 | AXI-1947 | `tests/lock_terraform_cd_workflow.bats` | `terraform-cd.yml`'s `ci-gate` job calls the data-tier lock check after credential export and before `terraform plan`. |
| UT-INFRA-127 | AXI-1947 | `tests/lock_terraform_cd_workflow.bats` | `terraform-cd.yml`'s `apply-production` job re-checks the data-tier lock after credential export and before `terraform apply`. |
| UT-INFRA-128 | AXI-1947 | `tests/lock_terraform_cd_workflow.bats` | The exact command the workflow invokes (`lock.sh <env> status data-tier`) exits non-zero on both HELD and UNDETERMINED. |
| UT-INFRA-390 | AXI-1947 | `tests/lock_status.bats` | A get-object call that returns rc 0 with a ZERO-BYTE body maps to UNKNOWN, never "HELD by blank" (B2, NFR2). |
| UT-INFRA-391 | AXI-1947 | `tests/lock_override.bats` | `lock.sh override` (CLI path) ABORTS before any delete when `report_override`'s secret-shaped-text guard refuses the `--reason` (B1, FR30/NFR4). |
| UT-INFRA-392 | AXI-1947 | `tests/lock_override.bats` | `lock_override` (sourced, no `set -e`) ABORTS before any delete on the same refused-report path; returns `LOCK_RC_REFUSED` without relying on the caller's errexit (B1). |
| UT-INFRA-393 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `_lock_require_jq` returns nonzero (never calls `exit`) when `jq` is absent from `PATH` — the sourcing shell survives the call (B3). |
| UT-INFRA-394 | AXI-1947 | `tests/lock_lib_and_misc.bats` | Sourcing `lock.sh` and calling its public functions never clobbers a caller's own `PROJECT`/`REGION`/`ENV`/`NAME`/`TOKEN` globals (B4). |
| UT-INFRA-395 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` CHAINS onto a pre-existing EXIT trap — the caller's own cleanup still runs (B5). |
| UT-INFRA-396 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` releases a marked lock on a normal (success) exit (B5). |
| UT-INFRA-397 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` releases a marked lock on an error (`exit 1`) exit (B5). |
| UT-INFRA-398 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` releases a marked lock on SIGTERM, routed through `exit` (B5). |
| UT-INFRA-399 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `data-tier` is never auto-released via `lock_install_exit_trap` — no aws call at all, by construction (B5, FR29). |
| UT-INFRA-400 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_release_held` with nothing registered is a no-op, rc 0, no aws call (B5). |
| UT-INFRA-401 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` survives a pre-existing EXIT trap whose command contains a single quote — both the release and the caller's trap body run (bounce #2, exit-trap chaining defect). |
| UT-INFRA-402 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` survives a pre-existing EXIT trap containing double quotes plus a `$VAR` reference, expanded at fire time (bounce #2). |
| UT-INFRA-403 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` survives a pre-existing EXIT trap spanning a newline / multiple commands (bounce #2). |
| UT-INFRA-404 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap` survives a pre-existing EXIT trap containing a backslash (bounce #2). |
| UT-INFRA-405 | AXI-1947 | `tests/lock_lib_and_misc.bats` | `lock_install_exit_trap`'s handler preserves the original exit status (`exit 7` still exits 7) across release + restored trap (bounce #2). |
| UT-INFRA-406 | AXI-1947 | `tests/lock_lib_and_misc.bats` | Calling `lock_install_exit_trap` twice does not self-chain the handler — exactly one delete-object call (bounce #2). |
| UT-INFRA-407 | AXI-1947 | `tests/lock_status.bats` | `lock.sh status`'s get-object call passes `--output json` explicitly, independent of `AWS_DEFAULT_OUTPUT` (bounce #2). |
