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
| UT-INFRA-230 | AXI-1952 | `tests/wt-purge-guard.bats` | `wt_purge_guard` allows a purge when every resource name is genuinely slug-scoped. |
| UT-INFRA-231 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses the exact shared Postgres DB name (`axiome`), regardless of the slug. |
| UT-INFRA-232 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses the live shared data layer (2026-10-02 incident shape) for an unrelated slug. |
| UT-INFRA-233 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses the shared layer even for the slug its shared names were themselves copied from. |
| UT-INFRA-234 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses when the slug is a mere substring of a shared resource name (containment alone is not ownership). |
| UT-INFRA-235 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses when even ONE resource among an otherwise fully-scoped set is shared — validates the whole list, not "mostly fine" (FR39). |
| UT-INFRA-236 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses the shared/reserved Redis DB indexes (0, 1) even when every other name looks scoped. |
| UT-INFRA-237 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses an empty slug outright. |
| UT-INFRA-238 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses a slug containing glob/regex metacharacters before any containment check runs. |
| UT-INFRA-239 | AXI-1952 | `tests/wt-purge-guard.bats` | Refuses when a resource variable is unset (an unset-env collapse to a shared default must never read as "owned"). |
| UT-INFRA-240 | AXI-1952 | `tests/wt-down-purge.bats` | `wt-down.sh --purge` refuses end-to-end under the live shared layer and makes no DROP/dropDatabase/FLUSHDB/delete_vhost/mc rb call. |
| UT-INFRA-241 | AXI-1952 | `tests/wt-down-purge.bats` | A refused `--purge` changes nothing at all — not even the app stack's own `down`. |
| UT-INFRA-242 | AXI-1952 | `tests/wt-down-purge.bats` | `--purge-shared` without `--confirm` refuses and takes no backup (FR40). |
| UT-INFRA-243 | AXI-1952 | `tests/wt-down-purge.bats` | `--purge-shared --confirm <wrong>` refuses non-interactively (closed stdin; no prompt to satisfy). |
| UT-INFRA-244 | AXI-1952 | `tests/wt-down-purge.bats` | `--purge-shared` with the correct token backs up BEFORE the shared `down -v` (call-log ordering). |
| UT-INFRA-245 | AXI-1952 | `tests/wt-down-purge.bats` | `--purge-shared` refuses when the backup itself fails; `down -v` is never reached. |
| UT-INFRA-246 | AXI-1952 | `tests/wt-migrate.bats` | `wt-migrate.sh status` is read-only: no lock file, no backup, prints migrate-gate's own PENDING lines. |
| UT-INFRA-247 | AXI-1952 | `tests/wt-migrate.bats` | `wt-migrate.sh apply` backs up BEFORE calling migrate-gate apply (call-log ordering, FR37). |
| UT-INFRA-248 | AXI-1952 | `tests/wt-migrate.bats` | A failed backup stops before migrate-gate is ever invoked. |
| UT-INFRA-249 | AXI-1952 | `tests/wt-migrate.bats` | An empty backup is treated exactly like a failed one — refuses, never migrates. |
| UT-INFRA-250 | AXI-1952 | `tests/wt-migrate.bats` | A migrate-gate apply failure exits non-zero with no further call attempted (no fallback). |
| UT-INFRA-251 | AXI-1952 | `tests/wt-migrate.bats` | A second concurrent `apply` while the lock is held waits, then refuses without running the backup or the gate (EC11). |
| UT-INFRA-252 | AXI-1952 | `tests/ac6-no-push-fallback.bats` | No AXI-1952-owned file contains the literal `db push` (AC6). |
| UT-INFRA-253 | AXI-1952 | `tests/ac6-no-push-fallback.bats` | No AXI-1952-owned file contains the literal `accept-data-loss` (AC6). |
| UT-INFRA-254 | AXI-1952 | `tests/wt-up-migrate.bats` | `wt-up.sh` without `--migrate` never invokes migrate-gate or the control-plane migration. |
| UT-INFRA-255 | AXI-1952 | `tests/wt-up-migrate.bats` | `wt-up.sh --migrate` runs migrate-gate AFTER the app stack is started. |
| UT-INFRA-256 | AXI-1952 | `tests/wt-up-migrate.bats` | The deprecated `--seed` alias still triggers migration (back-compat; not a silent no-op). |
| UT-INFRA-257 | AXI-1952 | `tests/wt-up-migrate.bats` | A migration failure makes `wt-up.sh --migrate` exit non-zero. |
| UT-INFRA-258 | AXI-1952 | `tests/demo-up-migrate.bats` | `make demo-up` migrates before the final `up -d` (FR38, call-log ordering). |
| UT-INFRA-259 | AXI-1952 | `tests/demo-up-migrate.bats` | `make demo-up MIGRATE=0` skips migration and prints pending migrations instead; no backup, no apply. |
| UT-INFRA-260 | AXI-1952 | `tests/demo-up-migrate.bats` | A migration failure aborts `make demo-up` before `up -d` is ever reached. |
| UT-INFRA-261 | AXI-1952 | `tests/legacy-compose-safety.bats` | The `tests/stubs/docker-compose` PATH shim is unconfigured-by-design and fails loudly if anything ever calls the literal `docker-compose` binary name again (B1 layer 2). |
| UT-INFRA-262 | AXI-1952 | `tests/legacy-compose-safety.bats` | `make` fails closed with a clear `$(error ...)` when Docker Compose v2 is unavailable and no `DOCKER_COMPOSE` override is given — no fallback to legacy `docker-compose`, no recipe line ever runs (B1 layer 3). |
| UT-INFRA-263 | AXI-1952 | `tests/legacy-compose-safety.bats` | An explicit `DOCKER_COMPOSE` override passed on the `make` command line skips the v2 probe entirely and still works (B1 layer 1/3 interaction). |
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
| UT-INFRA-130 | AXI-1950 | `tests/asset-sync.bats` | `asset-sync.sh pull` installs every manifest-listed file into dest-dir (FR11/AC9). |
| UT-INFRA-131 | AXI-1950 | `tests/asset-sync.bats` | A re-pull with a changed file keeps the previous copy as `<file>.prev` (FR11). |
| UT-INFRA-132 | AXI-1950 | `tests/asset-sync.bats` | A checksum mismatch installs nothing and exits non-zero (EC9). |
| UT-INFRA-133 | AXI-1950 | `tests/asset-sync.bats` | An invalid `docker-compose.yml` installs nothing and exits non-zero (EC9). |
| UT-INFRA-134 | AXI-1950 | `tests/asset-sync.bats` | An unreachable manifest/bucket keeps existing assets and exits a defined code (EC6 spirit). |
| UT-INFRA-135 | AXI-1950 | `tests/asset-sync.bats` | A manifest-listed file that cannot be fetched keeps existing assets, same exit code as a missing manifest. |
| UT-INFRA-136 | AXI-1950 | `tests/asset-sync.bats` | `asset-sync.sh publish` builds a manifest.sha256 with the correct sha256 per listed file. |
| UT-INFRA-137 | AXI-1950 | `tests/asset-sync.bats` | `publish` uploads every manifest-source file plus the manifest itself. |
| UT-INFRA-138 | AXI-1950 | `tests/asset-sync.bats` | A usage error exits 1 without ever calling `aws`. |
| UT-INFRA-139 | AXI-1950 | `tests/refresh-env.bats` | Every decision-5 preserved key keeps its existing value against a differing SSM value (EC5). |
| UT-INFRA-140 | AXI-1950 | `tests/refresh-env.bats` | A non-preserved key takes the new SSM value. |
| UT-INFRA-141 | AXI-1950 | `tests/refresh-env.bats` | SSM unreachable keeps `.env` byte-identical, warns, exits non-zero (EC6). |
| UT-INFRA-142 | AXI-1950 | `tests/refresh-env.bats` | An empty SSM result is treated as unreachable — file kept. |
| UT-INFRA-143 | AXI-1950 | `tests/refresh-env.bats` | A required key coming back empty keeps `.env`, warns, exits non-zero. |
| UT-INFRA-144 | AXI-1950 | `tests/refresh-env.bats` | No secret value is ever printed to stdout/stderr (NFR3). |
| UT-INFRA-145 | AXI-1950 | `tests/refresh-env.bats` | The temp file is written in the same directory and installed via rename (atomicity). |
| UT-INFRA-146 | AXI-1950 | `tests/refresh-env.bats` | No temp file is left behind after a successful refresh. |
| UT-INFRA-147 | AXI-1950 | `tests/refresh-env.bats` | No temp file is ever created when SSM is unreachable. |
| UT-INFRA-148 | AXI-1950 | `tests/refresh-env.bats` | A missing env-file argument is a usage error, no `aws` call. |
| UT-INFRA-149 | AXI-1950 | `tests/boot.bats` | `boot.sh` runs asset-sync pull, then `.env` refresh, then `docker compose up -d`, in order (FR10/FR11/FR12). |
| UT-INFRA-430 | AXI-1969 | `tests/asset-sync.bats` | A manifest entry `../x` is rejected as a whole: exit 5, nothing installed, the entry named (FR48/AC41). |
| UT-INFRA-431 | AXI-1969 | `tests/asset-sync.bats` | A manifest entry `/etc/x` (absolute) is rejected the same way (FR48/AC41). |
| UT-INFRA-432 | AXI-1969 | `tests/asset-sync.bats` | A manifest entry `a/../../b` (buried `..`) is rejected the same way (FR48/AC41). |
| UT-INFRA-433 | AXI-1969 | `tests/asset-sync.bats` | A manifest entry with an empty path is rejected the same way (FR48). |
| UT-INFRA-434 | AXI-1969 | `tests/asset-sync.bats` | The whole manifest is validated before any listed file is fetched — one unsafe entry stops even the safe ones from being fetched (FR48). |
| UT-INFRA-435 | AXI-1969 | `tests/asset-sync.bats` | A mid-install failure (third file's destination path is blocked by a type conflict — root-proof, unlike `chmod 000`) restores every already-installed file to its previous copy, verified by content (FR49/AC42). |
| UT-INFRA-436 | AXI-1969 | `tests/asset-sync.bats` | An already-current box writes nothing, verified by mtime (FR49/AC42). |
| UT-INFRA-437 | AXI-1969 | `tests/asset-sync.bats` | The staging directory is removed on a successful pull (FR49). |
| UT-INFRA-438 | AXI-1969 | `tests/asset-sync.bats` | The staging directory is removed on a refused pull (checksum mismatch) too (FR49). |
| UT-INFRA-439 | AXI-1969 | `tests/asset-sync.bats` | The staging directory is removed even when the process is aborted mid-run (SIGTERM, EXIT trap) (FR49). |
| UT-INFRA-440 | AXI-1969 | `tests/refresh-env.bats` | An SSM value containing a literal newline is refused: exit 4, `.env` kept byte-identical, the parameter named, its value never printed (FR50/AC43). |
| UT-INFRA-441 | AXI-1969 | `tests/refresh-env.bats` | Same refusal for a value containing a literal tab (FR50/AC43). |
| UT-INFRA-442 | AXI-1969 | `tests/refresh-env.bats` | The refusal fires even when the bad value belongs to a decision-5 preserved key (FR50). |
| UT-INFRA-443 | AXI-1969 | `tests/refresh-env.bats` | No false positive: an ordinary SSM result (no newline/tab) still refreshes normally after the `--output json`/`jq` rewrite. |
| UT-INFRA-444 | AXI-1969 | `tests/refresh-env.bats` | No temp file is left behind when a value is refused (same contract as the SSM-unreachable path). |
| UT-INFRA-445 | AXI-1969 | `tests/asset-sync.bats` | Review follow-up #1: files already match but the installed `manifest.sha256` is stale — only that bookkeeping copy is repaired, no asset file rewritten. |
| UT-INFRA-446 | AXI-1969 | `tests/asset-sync.bats` | Review follow-up #2: a mid-install failure never disturbs a `.prev` that already existed from an earlier successful run (verified by content). |
| UT-INFRA-448 | AXI-1969 | `tests/refresh-env.bats` | Review follow-up #3: a bare carriage return is refused the same way as a newline/tab (exit 4). |
| UT-INFRA-449 | AXI-1969 | `tests/refresh-env.bats` | Review follow-up #3: a CRLF pair is refused the same way. |
| UT-INFRA-450 | AXI-1969 | `tests/refresh-env.bats` | Review follow-up #4: with `jq` genuinely absent from `PATH` (not faked), exits 1, names the missing tool, makes no `aws` call, `.env` byte-identical. |
| UT-INFRA-451 | AXI-1969 | `tests/refresh-env.bats` | Review follow-up #4: a value containing `"`, `'`, `$`, `#`, `=`, a space, a backslash, and a non-ASCII character round-trips byte-for-byte into `.env`. |
| UT-INFRA-150 | AXI-1950 | `tests/boot.bats` | A failed asset-sync pull does not block refresh-env or compose up (EC6 spirit). |
| UT-INFRA-151 | AXI-1950 | `tests/boot.bats` | A failed `.env` refresh does not block compose up (EC6). |
| UT-INFRA-152 | AXI-1950 | `tests/boot.bats` | A failing migrate gate (surfaced via `docker compose up -d` exit code) is surfaced as `boot.sh`'s own failure, never swallowed. |
| UT-INFRA-153 | AXI-1950 | `tests/boot.bats` | A missing `ONBOX_S3_PREFIX` fails fast before anything runs. |
| UT-INFRA-154 | AXI-1950 | `tests/compose-structure.bats` | The compose `migrate` service runs the gate with `restart: "no"` (FR10). |
| UT-INFRA-155 | AXI-1950 | `tests/compose-structure.bats` | gateway/user-service/organization-service/event-service all depend on `migrate` completing successfully (FR10/AC7). |
| UT-INFRA-156 | AXI-1950 | `tests/compose-structure.bats` | `biocompute` does not depend on `migrate` (different schema/database). |
| UT-INFRA-157 | AXI-1950 | `tests/compose-structure.bats` | Every backend service container declares a healthcheck (FR27/AC18). |
| UT-INFRA-158 | AXI-1950 | `tests/compose-structure.bats` | The gateway healthcheck still targets `/health/live`. |
| UT-INFRA-180 | AXI-1951 | `tests/power_down_backup.bats` | `power.sh <env> down` stops compute only after the on-box Mongo backup is run (over SSM) and independently verified present via `head-object` (FR31). |
| UT-INFRA-181 | AXI-1951 | `tests/power_down_backup.bats` | A failed/unverifiable backup refuses the stop outright — no `stop-instances` call, no override given (FR31). |
| UT-INFRA-182 | AXI-1951 | `tests/power_down_backup.bats` | `--skip-backup "<reason>"` stops without running the backup and records an audited `OVERRIDE skip-backup` line in the report (FR31 escape hatch). |
| UT-INFRA-183 | AXI-1951 | `tests/power_down_backup.bats` | A secret-shaped `--skip-backup` reason (e.g. `token=...`) is refused before any stop (NFR3). |
| UT-INFRA-184 | AXI-1951 | `tests/power_down_backup.bats` | `--skip-backup` with no reason text is refused before any stop. |
| UT-INFRA-185 | AXI-1951 | `tests/power_up_ready.bats` | `power.sh <env> up` polls `/api/v1/health/ready`, not `/health/live` (FR26). |
| UT-INFRA-186 | AXI-1951 | `tests/power_up_ready.bats` | A readiness poll that never turns 200 is a bounded, reported failure (never a false 200, EC12) and the last response body is surfaced. |
| UT-INFRA-187 | AXI-1951 | `tests/power_data_down.bats` | `power-data.sh <env> down` acquires the data-tier lock before touching RDS/Redis, and leaves it HELD on success (FR29 — no automatic release route). |
| UT-INFRA-188 | AXI-1951 | `tests/power_data_down.bats` | `power-data.sh <env> down` refuses the whole park when the data-tier lock is already held — no `stop-db-instance`/`delete-replication-group` call at all. |
| UT-INFRA-189 | AXI-1951 | `tests/power_data_down.bats` | `down` aborts and leaves the lock HELD when the Redis final snapshot never verifies `available` within the bounded timeout (FR33 — never reports success on an unverified snapshot). |
| UT-INFRA-190 | AXI-1951 | `tests/power_data_up.bats` | `power-data.sh <env> up` with RDS already `available` (EC8) still runs full verification, then releases the data-tier lock and clears park-state only after that verification (FR29/FR34). |
| UT-INFRA-191 | AXI-1951 | `tests/power_data_up.bats` | `up` fails and leaves the lock HELD (no `delete-object` call) when RDS never verifies `available` within the bounded timeout (FR34). |
| UT-INFRA-193 | AXI-1951 | `tests/power_data_status.bats` | `power-data.sh <env> status` shows the FR35 RDS stopped-duration, computed from the recorded park-state timestamp, when RDS is `stopped`. |
| UT-INFRA-194 | AXI-1951 | `tests/power_data_status.bats` | `status` surfaces the data-tier lock status line without aborting the script under `set -e`. |
| UT-INFRA-195 | AXI-1951 | `tests/power_down_backup.bats` | `power.sh <env> down`'s backup-freshness check refuses the stop when the verified S3 object is zero-byte (`ContentLength=0`), even though `head-object` itself succeeded. |
| UT-INFRA-196 | AXI-1951 | `tests/power_down_backup.bats` | `down`'s backup-freshness check refuses the stop when the verified object's `LastModified` predates the moment the backup was issued (a stale object). |
| UT-INFRA-197 | AXI-1951 | `tests/power_down_backup.bats` | `down`'s backup-freshness check refuses the stop when the object's `sha256` S3 metadata does not match the checksum reported by `MONGO_BACKUP_OK` (checksum mismatch). |
| UT-INFRA-198 | AXI-1951 | `tests/mongo_backup.bats` | The real `providers/aws/onbox/mongo-backup.sh`, run under the stub harness, puts exactly one `MONGO_BACKUP_OK key=... sha256=...` line on its captured stdout on success (closes the bounce-#1 B1 gap: the log redirect no longer swallows the contract line). |
| UT-INFRA-199 | AXI-1951 | `tests/mongo_backup.bats` | `mongo-backup.sh` fails with `MONGO_BACKUP_FAILED` and a nonzero exit when `mongodump` produces an empty archive, and never attempts an `aws s3 cp` upload. |
| UT-INFRA-200 | AXI-1951 | `tests/mongo_backup.bats` | `mongo-backup.sh` fails even when `mongodump` writes partial bytes before exiting nonzero inside the pipeline — the real `docker exec` exit status is checked, not just the archive size. |
| UT-INFRA-201 | AXI-1951 | `tests/mongo_backup.bats` | `mongo-backup.sh` fails with `MONGO_BACKUP_FAILED` when the `aws s3 cp` upload itself fails. |
| UT-INFRA-202 | AXI-1951 | `tests/mongo_backup.bats` | `mongo-backup.sh` fails with `MONGO_BACKUP_FAILED` when the post-upload `head-object` verification fails. |
| UT-INFRA-203 | AXI-1951 | `tests/mongo_backup.bats` | `mongo-backup.sh` never prints the Mongo root password, on stdout or in the log file, across the whole run. |
| UT-INFRA-204 | AXI-1951 | `tests/power_data_down.bats` | `down` releases the lock it just acquired and touches neither RDS nor Redis when the IMMEDIATE post-acquire `park-state.env` write fails (bounce-#1: park-state must be written before any destructive call, not only after). |
| UT-INFRA-205 | AXI-1951 | `tests/power_data_down.bats` | A failed Redis `describe-cache-clusters` call aborts the park before any `delete-replication-group` call, leaves Redis untouched, and — because park-state was already written immediately after acquire and again after the RDS stop — the real lock token is still recoverable from `park-state.env` after the abort. |
| UT-INFRA-206 | AXI-1951 | `tests/power_data_down.bats` | Every Redis describe call succeeds, but one captured field comes back empty — `capture_redis_config` refuses the incomplete config exactly like a failed describe: aborts, Redis untouched. |
| UT-INFRA-207 | AXI-1951 | `tests/power_data_down.bats` | A second `down` while the first's data-tier lock is still held refuses outright and makes no new RDS/Redis mutating call (double-down is safe by construction via `scripts/lock.sh`'s existing acquire-on-held refusal). |
| UT-INFRA-208 | AXI-1951 | `tests/power_data_up.bats` | `up` run with nothing ever parked (no prior `down`) succeeds — RDS/Redis already available, no recorded lock token, and no `get-object`/`delete-object` lock-release attempt is made at all. |
| UT-INFRA-209 | AXI-1951 | `tests/power_data_up.bats` | `up` after an operator `scripts/lock.sh override` (a stale `park-state.env` token exists but the lock is already free): release is attempted (`get-object`) but `lock_release` refuses cleanly (lock not held) without ever calling `delete-object`; `up` still succeeds overall. |
| UT-INFRA-280 | AXI-1953 | `tests/roll-service.bats` | A backend roll pulls and ups the four backend targets through the gate and reports completion (FR18). |
| UT-INFRA-281 | AXI-1953 | `tests/roll-service.bats` | A migration-gate failure exits non-zero, never claims completion, and surfaces the migrate container's own log (AC2). |
| UT-INFRA-282 | AXI-1953 | `tests/roll-service.bats` | A backend roll never passes `--no-deps` (the migrate dependency must stay in force) (FR18). |
| UT-INFRA-283 | AXI-1953 | `tests/roll-service.bats` | A box whose compose lacks `migrate` refuses before any docker call and names the asset-sync command (NFR7/AC8). |
| UT-INFRA-284 | AXI-1953 | `tests/roll-service.bats` | A biocompute roll is not gated, even with no `migrate` service in compose (EC13). |
| UT-INFRA-285 | AXI-1953 | `tests/roll-service.bats` | A frontend roll is not gated either (EC13). |
| UT-INFRA-286 | AXI-1953 | `tests/roll-service.bats` | A missing `ENV_FILE` fails fast before any docker call. |
| UT-INFRA-287 | AXI-1953 | `tests/roll-service.bats` | An existing `KEY` in `ENV_FILE` is updated in place. |
| UT-INFRA-288 | AXI-1953 | `tests/roll-service.bats` | A `KEY` absent from `ENV_FILE` is appended. |
| UT-INFRA-289 | AXI-1953 | `tests/roll-service.bats` | A repeat roll with the same inputs is idempotent (NFR1). |
| UT-INFRA-290 | AXI-1953 | `tests/roll-service.bats` | `refresh-env.sh` is invoked with `SSM_PARAMETER_PREFIX` when configured and present (FR12). |
| UT-INFRA-291 | AXI-1953 | `tests/roll-service.bats` | The roll skips `refresh-env.sh` (warns, non-fatal) when `SSM_PARAMETER_PREFIX` is unset. |
| UT-INFRA-292 | AXI-1953 | `tests/roll-service.bats` | The roll skips a missing `refresh-env.sh` on an un-converted box without failing (non-fatal). |
| UT-INFRA-293 | AXI-1953 | `tests/roll-service.bats` | An unknown `SERVICE` value is a usage error, no docker call. |
| UT-INFRA-294 | AXI-1953 | `tests/ssm-exec.bats` | The documented default wait is 900s (FR20). |
| UT-INFRA-295 | AXI-1953 | `tests/ssm-exec.bats` | A command reaching `Success` within the wait exits 0 and never calls `cancel-command`. |
| UT-INFRA-296 | AXI-1953 | `tests/ssm-exec.bats` | A command reaching `Failed` within the wait exits non-zero, reported as `Failed`, never `INDETERMINATE`. |
| UT-INFRA-297 | AXI-1953 | `tests/ssm-exec.bats` | A wait that expires before any terminal state cancels the command and reports `INDETERMINATE` (FR20). |
| UT-INFRA-298 | AXI-1953 | `tests/ssm-exec.bats` | A `cancel-command` failure does not change the verdict — still `INDETERMINATE`, still non-zero (fail-closed). |
| UT-INFRA-299 | AXI-1953 | `tests/ssm-exec.bats` | An explicit `-i` instance id still skips the `describe-instances` lookup (regression). |
| UT-INFRA-300 | AXI-1953 | `tests/ssm-exec.bats` | No command given is a usage error before any `aws` call. |
| UT-INFRA-301 | AXI-1953 | `tests/pull-on-vm.bats` | `pull-on-vm.sh production` refuses and never calls `ssh` (FR13/AC27). |
| UT-INFRA-302 | AXI-1953 | `tests/pull-on-vm.bats` | `pull-on-vm.sh staging` refuses the same way (FR13). |
| UT-INFRA-303 | AXI-1953 | `tests/pull-on-vm.bats` | `pull-on-vm.sh dev` proceeds over `ssh`. |
| UT-INFRA-304 | AXI-1953 | `tests/pull-on-vm.bats` | An unknown environment name is still rejected. |
| UT-INFRA-305 | AXI-1953 | `tests/pull-on-vm.bats` | No argument is a usage error, no `ssh` call. |
| UT-INFRA-306 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | The roll step still runs `scripts/roll-service.sh` as the single gated start path (FR13/AC27). |
| UT-INFRA-307 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | The roll step passes `SSM_PARAMETER_PREFIX` through to the remote `roll-service.sh` (FR12). |
| UT-INFRA-308 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | No `run:` step passes `--no-deps` to docker compose anywhere in the workflow. |
| UT-INFRA-309 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | The trigger is unchanged: only `repository_dispatch: image-published` starts a roll. |
| UT-INFRA-310 | AXI-1953 | `tests/roll-service.bats` | `require_migrate_service` is not fooled by a `migrate:` key outside the `services:` block (review bounce #1). |
| UT-INFRA-311 | AXI-1953 | `tests/roll-service.bats` | A successful backend roll prints this run's `MIGRATION_FACTS` lines, unprefixed (review bounce #1, FR14). |
| UT-INFRA-312 | AXI-1953 | `tests/roll-service.bats` | A previous run's facts line is never surfaced — only the `--since`-scoped read is used (review bounce #1). |
| UT-INFRA-313 | AXI-1953 | `tests/roll-service.bats` | A gate that passed but whose facts log read fails reports `MIGRATION_FACTS_UNAVAILABLE` (review bounce #1). |
| UT-INFRA-314 | AXI-1953 | `tests/roll-service.bats` | A gate that passed but has no facts line at all also reports `MIGRATION_FACTS_UNAVAILABLE` (review bounce #1). |
| UT-INFRA-315 | AXI-1953 | `tests/roll-service.bats` | A non-backend roll never attempts to read migrate facts (review bounce #1). |
| UT-INFRA-316 | AXI-1953 | `tests/ssm-exec.bats` | A non-numeric `-t` is rejected before any `aws` call (review bounce #1). |
| UT-INFRA-317 | AXI-1953 | `tests/ssm-exec.bats` | A zero `-t` is rejected before any `aws` call (review bounce #1). |
| UT-INFRA-318 | AXI-1953 | `tests/generate-qualification-record.bats` | A two-service `MIGRATION_FACTS_LINES` input renders a per-service IQ table and summary (review bounce #1, FR14). |
| UT-INFRA-319 | AXI-1953 | `tests/generate-qualification-record.bats` | Every service reporting `APPLIED=0` states plainly that no migration ran, never implying one was qualified (review bounce #1). |
| UT-INFRA-320 | AXI-1953 | `tests/generate-qualification-record.bats` | **Overruns into AXI-1954's reserved range.** The legacy single-value path (`SCHEMA_VERSION`/`PRE_COUNTS`/`POST_COUNTS`) still works unchanged for `scripts/migrate-data.sh` (review bounce #1). |
| UT-INFRA-321 | AXI-1953 | `tests/generate-qualification-record.bats` | **Overruns into AXI-1954's reserved range.** An unparseable `MIGRATION_FACTS_LINES` entry fails closed (exit non-zero), never a silent SKIP (review bounce #1, NFR2). |
| UT-INFRA-322 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range.** The "Emit Qualification Record" step builds a record when migrations were applied (review bounce #1). |
| UT-INFRA-323 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range.** The step passes and states plainly when nothing was pending (all services `APPLIED=0`) (review bounce #1). |
| UT-INFRA-324 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range.** The step fails when facts are unavailable, distinct from both pass cases (review bounce #1). |
| UT-INFRA-325 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range.** The step passes with "nothing to qualify" on a non-backend roll and never calls the generator (review bounce #1). |
| UT-INFRA-326 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range (coordinator-authorized, review bounce #2).** The "Roll service on dev VM" step fails when the remote roll fails (no `pipefail`, a failed `ssh | tee` previously left the step green). |
| UT-INFRA-327 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range (coordinator-authorized, review bounce #2).** Static check: the roll step declares `shell: bash` explicitly. |
| UT-INFRA-328 | AXI-1953 | `tests/dev-auto-promote-workflow.bats` | **Overruns into AXI-1954's reserved range (coordinator-authorized, review bounce #2).** The "Emit Qualification Record" step refuses a failed roll by its own logic even when a facts line is present. |
| UT-INFRA-330 | AXI-1954 | `tests/deploy-prod.bats` | The full success path takes the deploy lock, preflights OK, rolls, passes readiness, advances `:stable` LAST, runs the baseline check, and releases the lock (FR14/AC11). |
| UT-INFRA-331 | AXI-1954 | `tests/deploy-prod.bats` | EC1: the box is unreachable at preflight — fails closed before any mutation, `:stable` never touched, lock still released. |
| UT-INFRA-332 | AXI-1954 | `tests/deploy-prod.bats` | FR28/AC19: a held deploy lock refuses and names the holder; no ECR call is made. |
| UT-INFRA-333 | AXI-1954 | `tests/deploy-prod.bats` | FR29/AC20: a held/unknown data-tier lock refuses before the deploy lock is even attempted. |
| UT-INFRA-334 | AXI-1954 | `tests/deploy-prod.bats` | EC13: a frontend (non-backend) deploy skips migrate/snapshot/baseline but still takes the lock, rolls, and advances `:stable`. |
| UT-INFRA-335 | AXI-1954 | `tests/deploy-prod.bats` | NFR7/AC8: an unconverted box (no `migrate:` service) refuses and names the exact `asset-sync.sh` conversion command. |
| UT-INFRA-336 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 1: a non-zero `migrate-gate status` with no ledger-less refusal line refuses WITHOUT instructing `baseline` — status-undetermined is not evidence of a ledger-less service. |
| UT-INFRA-337 | AXI-1954 | `tests/deploy-prod.bats` | FR16/FR17: pending migrations on production take a pre-deploy RDS snapshot (and wait for it) before rolling, and prune beyond retention; pruned ids carry the `axiome-<env>-predeploy-` prefix and the newest (just-taken) one is never deleted (review bounce #1 item 7). |
| UT-INFRA-338 | AXI-1954 | `tests/deploy-prod.bats` | FR16: no pending migrations takes no snapshot. |
| UT-INFRA-339 | AXI-1954 | `tests/deploy-prod.bats` | A snapshot-create failure stops the deploy before migrating; no roll (`cmd-roll`) is ever attempted. |
| UT-INFRA-340 | AXI-1954 | `tests/deploy-prod.bats` | FR18/AC12: a migration-gate failure during the roll restores the previous tag and confirms it; `:stable` never advances. |
| UT-INFRA-341 | AXI-1954 | `tests/deploy-prod.bats` | The restore roll ALSO fails: the deploy reports loudly and names the manual recovery command; `:stable` still untouched. |
| UT-INFRA-342 | AXI-1954 | `tests/deploy-prod.bats` | FR20: an INDETERMINATE roll result never advances `:stable` and never attempts a blind restore roll. |
| UT-INFRA-343 | AXI-1954 | `tests/deploy-prod.bats` | AC12/FR15: a readiness failure after a successful roll restores the previous tag and confirms it; `:stable` untouched. |
| UT-INFRA-344 | AXI-1954 | `tests/deploy-prod.bats` | AC11/FR14: `:stable` advances strictly AFTER the roll's `up -d` call in the stub log, never before (ordering). |
| UT-INFRA-345 | AXI-1954 | `tests/deploy-prod.bats` | FR21/AC28: a read-only baseline mismatch is a warning only — the deploy still succeeds and `:stable` still advances. |
| UT-INFRA-346 | AXI-1954 | `tests/deploy-prod.bats` | FR7: `MIGRATION_FACTS` lines from a successful roll are captured into the deploy report. |
| UT-INFRA-347 | AXI-1954 | `tests/deploy-prod.bats` | `MIGRATION_FACTS_UNAVAILABLE` is recorded as a warning, not a deploy failure. |
| UT-INFRA-348 | AXI-1954 | `tests/deploy-prod.bats` | `--dry-run` reports the plan and mutates nothing (no lock, no AWS/SSM mutation beyond one read-only query). |
| UT-INFRA-349 | AXI-1954 | `tests/deploy-prod.bats` | `--dry-run` states plainly it could not determine pending migrations when the box is unreachable (NFR2, fail-closed reporting). |
| UT-INFRA-350 | AXI-1954 | `tests/deploy-prod.bats` | Advancing `:stable` itself failing after a healthy roll is reported loudly and names that `:stable` does NOT point at the new tag. |
| UT-INFRA-351 | AXI-1954 | `tests/deploy-prod.bats` | A missing `--tag`/`TAG` is a usage error before any `aws` call. |
| UT-INFRA-352 | AXI-1954 | `tests/deploy-prod.bats` | An unknown `--service` is rejected before any `aws` call. |
| UT-INFRA-353 | AXI-1954 | `tests/seed-environment-check.bats` | FR21: `seed-environment.sh --check` skips the workspace-roles write (Step 1) entirely. |
| UT-INFRA-354 | AXI-1954 | `tests/seed-environment-check.bats` | `--check` takes a single read-only pass per entity, no settle-wait loop. |
| UT-INFRA-355 | AXI-1954 | `tests/seed-environment-check.bats` | `--check` still exits non-zero on a mismatch — its own standalone contract is unchanged; only a caller may treat it as warning-only. |
| UT-INFRA-356 | AXI-1954 | `tests/seed-environment-check.bats` | Without `--check`, the original settle-wait banner and `SEED OK`/`SEED FAILED` language are unchanged. |
| UT-INFRA-357 | AXI-1954 | `tests/seed-environment-check.bats` | `--check` is documented in `--help` usage. |
| UT-INFRA-358 | AXI-1954 | `tests/verify-deploy.bats` | FR24/FR26/AC18: `verify-deploy.sh` defaults to `/api/v1/health/ready` and passes on 200. |
| UT-INFRA-359 | AXI-1954 | `tests/verify-deploy.bats` | A 503 is reported with the per-service reason from the readiness body, never masked behind a bare `curl -f` failure. |
| UT-INFRA-360 | AXI-1954 | `tests/verify-deploy.bats` | `HEALTH_PATH` remains override-able. |
| UT-INFRA-361 | AXI-1954 | `tests/verify-deploy.bats` | DNS + readiness + root-path checks all pass together when the environment is healthy. |
| UT-INFRA-362 | AXI-1954 | `tests/deploy-production-workflow.bats` | `deploy-production.yml` has no `push`/`pull_request` trigger — only `repository_dispatch`/`workflow_dispatch` can start a run. |
| UT-INFRA-363 | AXI-1954 | `tests/deploy-production-workflow.bats` | Every `run:` step declares `shell: bash` explicitly (epic AXI-1944 learning from AXI-1953's review bounce). |
| UT-INFRA-364 | AXI-1954 | `tests/deploy-production-workflow.bats` | Every `run:` step's script sets `set -euo pipefail` itself. |
| UT-INFRA-365 | AXI-1954 | `tests/deploy-production-workflow.bats` | The `environment: production` approval gate is still present and untouched. |
| UT-INFRA-366 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 1: when the preflight output DOES carry migrate-gate's own ledger-less `REFUSE <svc>: tables exist with no migration ledger` line, the message names `baseline` + that exact service. |
| UT-INFRA-367 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 1: a connectivity/status-undetermined error shows the verbatim preflight output and never suggests `Run: migrate-gate baseline` as the remedy (mutation-checked against the pre-fix code). |
| UT-INFRA-368 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 1: a missing-database-URL error is treated the same as a connectivity error — never `baseline` (mutation-checked against the pre-fix code). |
| UT-INFRA-369 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 2: `--dry-run` distinguishes "box not reachable over SSM" from "box reachable but preflight refused". |
| UT-INFRA-370 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 3: the roll-failure report states migrations may have partially applied and that no snapshot is available when none was taken. |
| UT-INFRA-371 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 3: the roll-failure report names the pre-deploy snapshot id as the point-in-time rollback path when one was taken. |
| UT-INFRA-372 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 3: the INDETERMINATE-roll report states the same partial-migration risk. |
| UT-INFRA-373 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 3: the readiness-failure report states the schema is definitely (not merely possibly) ahead of the restored image. |
| UT-INFRA-374 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 4: a real baseline count match is recorded as OK, never MISMATCH/NOT PERFORMED. |
| UT-INFRA-375 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 4: `seed-environment.sh --check` exiting 3 (expected counts unavailable) is recorded as `Baseline verification: NOT PERFORMED`, never MISMATCH. |
| UT-INFRA-376 | AXI-1954 | `tests/seed-environment-check.bats` | Review bounce #1 item 4: `--check` exits a distinct code (3) with a `BASELINE CHECK NOT PERFORMED` message when expected counts cannot be derived (e.g. axiome-back not checked out). |
| UT-INFRA-377 | AXI-1954 | `tests/seed-environment-check.bats` | Review bounce #1 item 4: without `--check`, the same missing-axiome-back condition still fails loudly (exit 1, `ERROR`) — a real seed run must not silently treat this as routine. |
| UT-INFRA-378 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 5: `ecr_retag_stable` refuses to advance `:stable` when TAG's digest moved during the deploy, states the roll already succeeded, and exits non-zero. |
| UT-INFRA-379 | AXI-1954 | `tests/deploy-prod.bats` | Review bounce #1 item 6: the data-tier lock is re-checked immediately after preflight (before snapshot/roll), catching a park started during preflight. |
| UT-INFRA-380 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | `make help` succeeds with no `docker` binary reachable on PATH at all (fix a). |
| UT-INFRA-381 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | `make demo-up` still fails closed with the documented message when no docker v2 is on PATH (fix a, narrowed not removed). |
| UT-INFRA-382 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | A command-line `DOCKER_COMPOSE=docker-compose` (legacy v1) override is rejected with a clear message (fix b). |
| UT-INFRA-383 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | Same rejection from an environment `DOCKER_COMPOSE=docker-compose`, not just the command line (fix b). |
| UT-INFRA-384 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | An explicit `DOCKER_COMPOSE="docker compose"` (v2) override is still accepted and skips the probe. |
| UT-INFRA-385 | AXI-1955 | `tests/makefile-help-and-compose-gate.bats` | A non-Docker goal (`make plan`) also needs no docker on PATH and never probes/errors. |
| UT-INFRA-386 | AXI-1955 | `tests/doc-truth.bats` | FR41/AC33: every Makefile target whose recipe drives Docker Compose is covered by the `DOCKER_COMPOSE_TARGETS` gate list — a future target added without updating that list is caught. |
| UT-INFRA-387 | AXI-1955 | `tests/doc-truth.bats` | FR41/AC33: every `scripts/**`/`providers/aws/scripts/**` path named in this story's runbooks actually exists on disk. |
| UT-INFRA-388 | AXI-1955 | `tests/doc-truth.bats` | FR41/AC33: a curated set of refusal/contract strings quoted verbatim in the runbook exist verbatim in the script named alongside them. |
| UT-INFRA-389 | AXI-1955 | `tests/doc-truth.bats` | FR41/AC33: the AWS CLI minimum versions quoted in the runbook match `scripts/lock.sh`'s own `LOCK_MIN_AWS_CLI_PUT`/`LOCK_MIN_AWS_CLI_DELETE` constants. |
| UT-INFRA-408 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | `lock_acquire_exclusive` succeeds and prints the same `ACQUIRED` line as a plain `lock_acquire` when every other lock is free (FR42/FR43). |
| UT-INFRA-409 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | `lock_acquire_exclusive` releases its own just-acquired lock and refuses when `data-tier` is held — pins the fix for the `! cmd; then $?` negation-trap bug that made this always report success. |
| UT-INFRA-410 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | `lock_acquire_exclusive` also refuses when `apply` (checked second) is held, proving the loop checks every `<other>`, not just the first. |
| UT-INFRA-411 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | When both `data-tier` and `apply` are held, `lock_acquire_exclusive` refuses on the first one checked and never looks at the second (fail fast, not exhaustive). |
| UT-INFRA-412 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | `lock_acquire_exclusive` checks each other-lock exactly once (no hidden retry/poll that could mask a race the caller must re-check for, AC35). |
| UT-INFRA-413 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | When acquiring its own lock fails, `lock_acquire_exclusive` returns `lock_acquire`'s rc unchanged and never checks any other-lock name. |
| UT-INFRA-414 | AXI-1967 | `tests/power_down_backup.bats` | `power.sh down` refuses to stop compute when the `deploy` lock is held (FR43), before the FR31 backup step. |
| UT-INFRA-415 | AXI-1967 | `tests/power_down_backup.bats` | `power.sh down` refuses to stop compute when the `apply` lock is held (FR43). |
| UT-INFRA-416 | AXI-1967 | `tests/power_data_down.bats` | `power-data.sh down` acquires `data-tier` first, then releases it and refuses when the `deploy` lock is held (FR43/AC34). |
| UT-INFRA-417 | AXI-1967 | `tests/power_data_down.bats` | `power-data.sh down` releases `data-tier` and refuses when the `apply` lock is held (FR43). |
| UT-INFRA-418 | AXI-1967 | `tests/power_data_up.bats` | `power-data.sh up` refuses when the `deploy` lock is held, before any RDS/Redis mutation, and never touches its own `data-tier` lock on refusal (FR43). |
| UT-INFRA-419 | AXI-1967 | `tests/power_data_up.bats` | `power-data.sh up` refuses when the `apply` lock is held, same contract. |
| UT-INFRA-420 | AXI-1967 | `tests/power_data_status.bats` | `power-data.sh status` reports a stale park-state record PRESENT alongside an explicit WARNING naming `up` as the remedy when the lock is free but the record remains (FR44/AC36). |
| UT-INFRA-421 | AXI-1967 | `tests/lock_terraform_cd_apply_lock.bats` | `terraform-cd.yml`'s "Acquire apply lock" step sits strictly between the existing data-tier check and "Deploy production". |
| UT-INFRA-422 | AXI-1967 | `tests/lock_terraform_cd_apply_lock.bats` | `terraform-cd.yml`'s "Release apply lock" step runs with `if: always()` immediately after "Deploy production". |
| UT-INFRA-423 | AXI-1967 | `tests/lock_terraform_cd_apply_lock.bats` | The acquire step's real `run:` text, executed against stubs, acquires `apply` and records `APPLY_LOCK_TOKEN` to `$GITHUB_ENV`. |
| UT-INFRA-424 | AXI-1967 | `tests/lock_terraform_cd_apply_lock.bats` | The same `run:` text refuses (non-zero exit) and records no token when `deploy` is held, so "Deploy production" never runs. |
| UT-INFRA-425 | AXI-1967 | `tests/lock_terraform_cd_apply_lock.bats` | The release step's real `run:` text releases `APPLY_LOCK_TOKEN` when set, and no-ops cleanly (no `aws` call at all) when it was never captured. |
| UT-INFRA-426 | AXI-1967 | `tests/lock_acquire.bats` | `lock.sh acquire` accepts `apply` as a valid lock name across the CLI surface (FR42). |
| UT-INFRA-427 | AXI-1967 | `tests/power_up_all_delegation.bats` | `power-up-all.sh` contains no direct mutating RDS/EC2/Redis call of its own and never calls `down` on either sub-script — it cannot bypass the FR42/FR43 rule. |
| UT-INFRA-428 | AXI-1967 | `tests/power_data_down.bats` | Bounce #1: `power-data.sh down` refused by a held `deploy` lock releases only the data-tier lock it just acquired and NEVER deletes a pre-existing park-state record (confirmed failing against head `24c2942` before the `clear_park_state` removal). |
| UT-INFRA-429 | AXI-1967 | `tests/power_data_down.bats` | Bounce #1: same, for a held `apply` lock. |
| UT-INFRA-430 | AXI-1967 | `tests/lock_acquire_exclusive.bats` | Bounce #1: when releasing the just-acquired lock itself fails, `lock_acquire_exclusive` prints a truthful WARNING naming the lock, that it may still be HELD, and the `status`/`override` remedy — still returns the other lock's non-zero rc. |
| UT-INFRA-510 | AXI-1971 | `tests/compose-resolver.bats` | FR54/AC47: refuses when only the legacy `docker-compose` v1 binary is reachable on PATH (no `docker` binary at all); `docker-compose` is never invoked. |
| UT-INFRA-511 | AXI-1971 | `tests/compose-resolver.bats` | FR54: refuses when `docker` exists but `docker compose version` fails (no v2 plugin); `docker-compose` is never invoked. |
| UT-INFRA-512 | AXI-1971 | `tests/compose-resolver.bats` | AC47: refuses `DOCKER_COMPOSE=docker-compose` (exact literal); zero stub calls. |
| UT-INFRA-513 | AXI-1971 | `tests/compose-resolver.bats` | AC47: refuses `DOCKER_COMPOSE=/usr/bin/docker-compose` (a path to the v1 binary) — the AXI-1955 exact-match gap. |
| UT-INFRA-514 | AXI-1971 | `tests/compose-resolver.bats` | AC47: refuses `DOCKER_COMPOSE="docker-compose -f x"` (the v1 binary plus extra arguments) — the AXI-1955 exact-match gap. |
| UT-INFRA-515 | AXI-1971 | `tests/compose-resolver.bats` | FR54: refuses when nothing Compose-shaped (`docker` or `docker-compose`) is on PATH at all. |
| UT-INFRA-516 | AXI-1971 | `tests/compose-resolver.bats` | FR54: resolves to exactly `docker compose` when Compose v2 is available and no override is set. |
| UT-INFRA-517 | AXI-1971 | `tests/compose-resolver.bats` | FR54: an explicit `docker compose` override skips the probe entirely, even with no `docker` on PATH. |
| UT-INFRA-518 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1): refuses an override that is not Compose-shaped at all (`echo`) — the deny-list this ID used to cover was replaced by an allow-shape (`docker` + literal `compose`). |
| UT-INFRA-519 | AXI-1971 | `tests/compose-call-sites.bats` | FR54 (widened by review bounce #1/#2): structural — no tracked shell script or Makefile ANYWHERE in the repo (`git ls-files`, exclusion list not inclusion list) invokes Compose any way other than through the one shared resolver (three scan variants: line-start, mid-line `docker-compose`, mid-line `docker compose`). |
| UT-INFRA-520 | AXI-1971 | `tests/compose-call-sites.bats` | FR55/AC48: `make local-ps` and `make local-health` inspect the `axiome-demo` Compose project `local-up`/`demo-up` actually start, not the unrelated `axiome-$(LEGACY_SLUG)` project. |
| UT-INFRA-521 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: `sync-event-store-indexes.sh` refuses when no MongoDB address is available anywhere (no env, file, or `--mongodb-url`) — fails closed rather than guessing; zero docker calls. |
| UT-INFRA-522 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: refuses a non-local MongoDB host; zero docker calls. |
| UT-INFRA-523 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: refuses `--mongodb-url` carrying embedded credentials on this command's own argv; the credential value is never echoed; zero docker calls. |
| UT-INFRA-524 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: accepts `localhost`, resolves Compose v2 through the shared resolver, and runs the index sync with no data-loss-accepting flag anywhere on the executed command line. |
| UT-INFRA-525 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56: accepts the `mongodb` compose-network container alias as local, read from `--env-file` (never printed, never passed as an argument). |
| UT-INFRA-526 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: structural — the script's own source contains no data-loss-accepting flag outside a comment; the scan is proven non-vacuous against a synthetic bad line. |
| UT-INFRA-527 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49: structural — no start/up/migrate/seed path (`wt-up.sh`, `wt-migrate.sh`, `ensure-shared-infra.sh`, `seed-environment.sh`, the Makefile) invokes `sync-event-store-indexes.sh`. |
| UT-INFRA-528 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses `DOCKER_COMPOSE` with leading whitespace before `docker-compose` — the raw-string first-token check and the real `read -r -a` split disagreed here. |
| UT-INFRA-529 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses `DOCKER_COMPOSE` with trailing whitespace after `docker-compose`. |
| UT-INFRA-600 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses a tab-separated `DOCKER_COMPOSE="docker-compose\t-f\tx"`. |
| UT-INFRA-601 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses `DOCKER_COMPOSE="sudo docker-compose"` — a `sudo` prefix hid the v1 binary from the old first-token-only check. |
| UT-INFRA-602 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses `DOCKER_COMPOSE="env X=1 docker-compose"`. |
| UT-INFRA-603 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1, BLOCKING 1): refuses `DOCKER_COMPOSE="/opt/x/docker-compose --flag"` (path-decorated v1 binary plus an argument). |
| UT-INFRA-604 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1): the accepted allow-shape still works with a path prefix: `DOCKER_COMPOSE="/usr/bin/docker compose"`. |
| UT-INFRA-605 | AXI-1971 | `tests/compose-resolver.bats` | FR54 (review bounce #1): the accepted allow-shape still works with trailing arguments: `DOCKER_COMPOSE="docker compose --ansi never"`. |
| UT-INFRA-606 | AXI-1971 | `tests/compose-call-sites.bats` | FR54 (review bounce #1, BLOCKING 2): structural — no in-scope file anywhere in the repo falls back from a failed/absent Compose v2 probe to the legacy `docker-compose` v1 binary name (the exact AXI-1944 incident idiom, plus `command -v docker-compose`). |
| UT-INFRA-607 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49 (review bounce #1, issue 3): accepts when the backend container's OWN `$MONGODB_URL` host (read from inside the container, never the full URL) is also local. |
| UT-INFRA-608 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49 (review bounce #1, issue 3): refuses when the container's own `MONGODB_URL` host is remote, even though the host-side URL this command was told about is local; `prisma db push` is never invoked. |
| UT-INFRA-609 | AXI-1971 | `tests/sync-event-store-indexes.bats` | FR56/AC49 (review bounce #1, issue 3): refuses when reading the container's own `MONGODB_URL` host fails or returns nothing; `prisma db push` is never invoked. |
| UT-INFRA-460 | AXI-1970 | `tests/mongo_backup_credentials.bats` | FR51/AC44: a successful `mongo-backup.sh` run never puts the Mongo password on any stub's (docker's or aws's) recorded argv. |
| UT-INFRA-461 | AXI-1970 | `tests/mongo_backup_credentials.bats` | FR51/AC44: the mongodump credentials tempfile is removed after a successful run. |
| UT-INFRA-462 | AXI-1970 | `tests/mongo_backup_credentials.bats` | FR51/AC44: a mongodump failure never leaks the password either, and still removes the credentials tempfile. |
| UT-INFRA-463 | AXI-1970 | `tests/mongo_backup_credentials.bats` | FR51/AC44: the credentials tempfile is removed after the script is signalled (SIGTERM) mid-run — proves the trap is not relying solely on a bare EXIT trap. |
| UT-INFRA-464 | AXI-1970 | `tests/mongo_backup_credentials.bats` | FR51/AC44: `docker exec`'s recorded argv carries only `--config=/dev/stdin`, never the password. |
| UT-INFRA-465 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: a fresh install copies both unit files, reloads the daemon exactly once, enables+starts the timer, and removes the cron entry. |
| UT-INFRA-466 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: a second run with no unit-file changes reports "unchanged" and skips `daemon-reload`. |
| UT-INFRA-467 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: a changed unit file is re-copied and the daemon reloaded exactly once. |
| UT-INFRA-468 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: `systemctl enable --now` failing leaves the cron entry in place and exits non-zero. |
| UT-INFRA-469 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: `enable --now` reporting success but the timer being inactive afterwards still leaves the cron entry in place (never trusts enable's exit code alone). |
| UT-INFRA-470 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: an already-absent cron entry does not fail the installer. |
| UT-INFRA-471 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: missing source unit files refuse before any `systemctl` call or cron removal. |
| UT-INFRA-472 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: mutation-checked pairing with UT-INFRA-468/469 — cron removal never happens before `systemctl enable` is called (confirmed failing against the pre-fix "remove cron unconditionally" ordering). |
| UT-INFRA-473 | AXI-1970 | `tests/mongo_backup_timer_install.bats` | FR52/AC45: the operator-run `install-mongo-backup-timer.sh` sends `providers/aws/onbox/install-mongo-backup-timer-remote.sh`'s own content as the SSM command text. |
| UT-INFRA-474 | AXI-1970 | `tests/gnu_date_check.bats` | FR53/AC46: `gnu_date_check` succeeds silently on a real GNU `date`. |
| UT-INFRA-475 | AXI-1970 | `tests/gnu_date_check.bats` | FR53/AC46: `gnu_date_check` refuses with a truthful, remedy-naming line on a BSD-shaped `date`. |
| UT-INFRA-476 | AXI-1970 | `tests/gnu_date_check.bats` | FR53/AC46: `scripts/lock.sh`'s CLI entry point refuses on a BSD `date` before any `aws` call. |
| UT-INFRA-477 | AXI-1970 | `tests/gnu_date_check.bats` | FR53/AC46: `power.sh` refuses on a BSD `date` before any `aws` call. |
| UT-INFRA-478 | AXI-1970 | `tests/gnu_date_check.bats` | FR53/AC46: `power-data.sh` refuses on a BSD `date` before any `aws` call. |
| UT-INFRA-479 | AXI-1970 | `tests/gnu_date_check.bats` | Regression guard: `power.sh status` is unaffected by the new preflight on this host's real GNU `date`. |
| UT-INFRA-610 | AXI-1970 | `tests/mongo_backup_credentials.bats` | Review bounce #1 (Blocker 1d): `mongodump_password_config_yaml` round-trips a hostile password (`*`, `"`, `\`, `'`, `:`, `#`, trailing space) byte-for-byte through the real emitter function. |
| UT-INFRA-611 | AXI-1970 | `tests/mongo_backup_credentials.bats` | Review bounce #1 (Blocker 1d): a password containing a literal newline is refused with a truthful, value-free message naming the variable, never printed. |
| UT-INFRA-612 | AXI-1970 | `tests/gnu_date_check.bats` | Review bounce #1 (Blocker 2): `deploy-prod.sh` sources `lock.sh` and calls its functions directly, bypassing `lock.sh`'s own CLI preflight — refuses on a BSD `date` before any `aws`/`curl` call (confirmed failing against the pre-fix script). |
| UT-INFRA-530 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | `report_is_secret_value` (public, FR63) allows an innocent WHOLE key name (`password_policy=strict`, `token_ttl=3600`) and a sensitive key whose value is an allowlisted placeholder (`override_token=none`, `password=<redacted>`, `password=****`). |
| UT-INFRA-531 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | `report_is_secret_value` refuses a credential-shaped value regardless of its key name (AKIA/postgres-URL/JWT/bearer under an arbitrary key). |
| UT-INFRA-532 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | The pure-hex exemption is restricted to git-SHA (40) and sha256 (64) lengths; any other all-hex run of 40+ chars is refused (closes the "all-hex secret" gap). |
| UT-INFRA-533 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | An abandoned report sequence (report_init runs, report_finish never does) leaves no temp buffer behind (AC58). |
| UT-INFRA-534 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | A report sequence signalled (TERM) mid-run leaves no temp buffer behind (AC58). |
| UT-INFRA-535 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | report.sh's shared cleanup trap composes with a pre-existing caller EXIT trap — both run, and the script's own exit status is preserved. |
| UT-INFRA-536 | AXI-1973 | `tests/lock_cleanup.bats` | scripts/lock.sh's lock-body read temp file is removed when the read is signalled (TERM) mid get-object (AC58). Review bounce #2: signals once the `aws` stub is actually reached (polling `$STUB_LOG`), not once a file merely appears in `$TMPDIR` — deterministic about which phase of `_lock_fetch` is interrupted. |
| UT-INFRA-537 | AXI-1973 | `tests/lock_cleanup.bats` | lock.sh's tmp-file cleanup trap composes with `lock_install_exit_trap` — both the lock release and the tmp-file cleanup run. |
| UT-INFRA-538 | AXI-1973 | `tests/power_lib_collision.bats` | Sourcing `scripts/lib/report.sh` then `providers/aws/scripts/_power_lib.sh` together (power.sh's own order) defines both libraries' report functions without collision (FR63). |
| UT-INFRA-539 | AXI-1973 | `tests/power_down_backup.bats` | `power.sh down --skip-backup` allows an innocuous reason whose WHOLE key differs from any sensitive name (`token_ttl=3600`, not `token=...`) — never a substring match. |
| UT-INFRA-540 | AXI-1973 | `tests/asset-sync.bats` | Review follow-up #1: a pass-3 `.prev` rotation failure exits 6 with a truthful message naming the remedy; every already-installed file stays installed (not rolled back). |
| UT-INFRA-541 | AXI-1973 | `tests/cleanup_lib.bats` | `axiome_run_cleanup` never removes a registered directory or an empty registration — only an existing plain file. |
| UT-INFRA-542 | AXI-1973 | `tests/cleanup_lib.bats` | `axiome_unregister_cleanup` is a safe no-op for an unregistered or empty path; does not disturb other registered paths. |
| UT-INFRA-543 | AXI-1973 | `tests/lock_override.bats` | Companion to UT-INFRA-391/392: `lock.sh override` succeeds with a reason whose WHOLE key differs from any sensitive name (`password_policy=...`, not `password=...`). |
| UT-INFRA-544 | AXI-1973 | `tests/report_secret_and_cleanup.bats` | Review bounce #1: `report_is_secret_value` refuses a sensitive key (matched WHOLE, never a substring) paired with a real-looking value, however the pair is spelled — `key=value`, `--flag value`, `--flag=value`, JSON `"key": "value"`, mid-sentence, spaces around `=`. |
| UT-INFRA-620 | AXI-1973 | `tests/power_down_backup.bats` | Review bounce #1: `power.sh down --skip-backup` refuses a `token=<realvalue>` reason before any stop; the offending value is never echoed on stdout/stderr or in the report file. |
| UT-INFRA-621 | AXI-1973 | `tests/lock_override.bats` | Review bounce #1: `lock.sh override` refuses a `token=<realvalue>` reason before any delete; nothing is written to the report and the value is never echoed. |
| UT-INFRA-624 | AXI-1973 | `tests/cleanup_lib.bats` | Review bounce #2: `axiome_create_tracked_tempfile` registers in the caller's shell, not a lost subshell — the registered path is visible in `_AXIOME_CLEANUP_PATHS` immediately after the call returns (no command substitution involved). |
| UT-INFRA-625 | AXI-1973 | `tests/cleanup_lib.bats` | Review bounce #2: the create-then-register TERM-signal race is closed by construction — 200-iteration old-vs-new loop; the pre-fix create-then-register shape leaks under a widened gap, `axiome_create_tracked_tempfile`'s register-before-create ordering never does. |
