# axiome-infra test harness (AXI-1945)

Offline, stubbed tests for the ~3,000 lines of lifecycle shell under
`scripts/` and `providers/aws/scripts/`. Nothing here ever reaches real AWS,
a real box, or the shared local docker stack (NFR5). Run everything with:

```bash
tests/run.sh
```

CI (`.github/workflows/infra-tests.yml`) runs exactly this script — never a
different command — so a green `tests/run.sh` locally means a green CI job.

## Adding a test for your script

1. Create `tests/<your-script>.bats` (one file per script is the convention;
   see `tests/power_status.bats` for a worked example against an existing,
   untouched script).
2. Start every file with:
   ```bash
   load 'helpers/setup'

   setup() {
     stub_setup
   }
   ```
   `stub_setup` (from `tests/helpers/setup.bash`) creates a fresh per-test log
   at `$STUB_LOG` (and a fresh unconfigured-call marker at `$STUB_FAIL_LOG` —
   see "Unconfigured calls" below), puts `tests/stubs/` first on `$PATH`, and
   blanks every AWS credential/identity env var. After this, any
   `aws`/`docker`/`psql`/`curl`/`ssh`/`terraform`/`git` call your script makes
   resolves to a stub, never the real binary.

   **Do not rely on `teardown()` doing nothing by default.** `helpers/setup.bash`
   defines a default `teardown()` that calls `stub_teardown` (the check that
   makes the unconfigured-call guarantee below hold). If your `*.bats` file
   needs its own `teardown()` for other cleanup, it OVERRIDES that default —
   you MUST call `stub_teardown` inside it yourself, or the guard is silently
   gone for that file. `tests/check-teardown-contract.sh` (run by `tests/run.sh`)
   statically greps every `*.bats` file for this and fails the gate if a
   file defines `teardown()` without calling `stub_teardown`.
3. **Give each stub you need a rules fixture** — a tiny bash file that
   defines `stub_respond "<joined argv>"`, matched with a `case` statement,
   returning via `echo` (stdout) and `return <code>`. `return 99` (or no
   match at all) means "unconfigured". See `tests/fixtures/power-status.rules.sh`.
   ```bash
   stub_use_rules aws "${TESTS_DIR}/fixtures/my-fixture.rules.sh"
   ```
   `stub_use_rules <name> <file>` just sets `<NAME>_STUB_RULES` (e.g.
   `AWS_STUB_RULES`) — you can also set that env var directly.

   **Unconfigured calls are caught independently of the exit code (NFR2).**
   An unconfigured call both exits 99 AND writes a line to `$STUB_FAIL_LOG` —
   a fact recorded in a separate file, not just an exit status. The default
   `teardown()` reads that file and fails the test if it is non-empty,
   **regardless of what the script under test did with the stub's exit
   code** — `cmd 2>/dev/null || true`, `x="$(cmd)"`, a pipeline without
   `pipefail`, `set +e`, a subshell, or `cmd &` all still get caught. See
   `tests/stub_detection.bats` (UT-INFRA-007..009) for the proof, and note
   that some EXISTING scripts resolve things like `REPO_ROOT` via a git call
   guarded exactly this way (`_power_lib.sh`'s
   `git rev-parse ... 2>/dev/null || echo fallback`) — if your script under
   test does this, either stub the call or, if the script supports it (most
   of these resolution helpers do, by design), pre-set the env var it checks
   first (e.g. `export REPO_ROOT=...`) so the real call never happens — see
   `tests/power_status.bats`'s `setup()` for a worked example. Don't silently
   re-introduce the swallowing bug you're trying to avoid by papering over a
   fixture instead.
4. Run your script with bats' `run`, then assert on `$status`/`$output`
   (via the vendored `bats-assert` — `assert_success`, `assert_output
   --partial "…"`, etc.) and on what was/was not called:
   ```bash
   run "${INFRA_ROOT}/providers/aws/scripts/power.sh" dev status
   assert_success
   assert_stub_called aws "describe-instances"
   assert_stub_not_called terraform
   ```
5. Every bats test name carries a `UT-INFRA-<seq>` ID (see `UT.md`). Ask the
   lead for your range before claiming one — AXI-1945 owns `UT-INFRA-001`–
   `UT-INFRA-099`.

## Stub log format

Each call appends to `$STUB_LOG`:
```
### CALL: aws
ec2
describe-instances
--region
eu-west-3
### END
```
One argv element per line, so a test can `grep`/`awk` either the whole
invocation or a single argument without worrying about embedded spaces.

## Ownership (do not edit without asking the lead)

`tests/stubs/**`, `tests/helpers/**`, `tests/run.sh`, `tests/run-shellcheck.sh`
and `scripts/lib/report.sh` are **AXI-1945's shared infrastructure** — every
other story adds its own `tests/<script>.bats` + fixture files but does not
modify the stub engine. If a stub needs a new behaviour, message the lead
rather than patching it in your branch.

## shellcheck baseline (NFR8 — "no new findings")

`axiome-infra` was not shellcheck-clean before this story. Rather than fix
~3,000 untouched lines, `tests/shellcheck-baseline.json` records every
finding that existed when this story landed. `tests/run-shellcheck.sh`:

- re-runs `shellcheck -S warning` over every tracked `*.sh` file (excluding
  `tests/vendor/`, which is third-party and untouched by us),
- diffs the current findings against the baseline by `(file, line, code)`,
- **fails only on a finding not in the baseline** — i.e. any new finding in
  a file you touch, or ANY finding at all in a file that didn't exist when
  the baseline was written (new files must be fully clean, full stop).

If your story legitimately needs to update the baseline (e.g. you finally
fixed a pre-existing finding, shrinking it), regenerate it:
```bash
tests/run-shellcheck.sh --write-baseline
```
and commit the updated `tests/shellcheck-baseline.json`. Do **not** add new
findings to the baseline to make a red gate pass — fix the shellcheck issue
in your own new/touched lines instead.

**Line-shift caveat:** the baseline keys on `(file, line, code)`. If you add
or remove lines ABOVE a pre-existing, still-unfixed finding in a file you
touch, that finding's line number shifts and the gate reports it as "new"
even though it's the same old issue. If that happens: confirm with
`git diff` that you didn't actually introduce a new problem at that
location, then re-run `tests/run-shellcheck.sh --write-baseline` to re-key
it and commit the refreshed baseline alongside your change (don't do this
silently in an unrelated commit — call it out in your PR/handback).

## Vendored bats (no network/package manager required)

`tests/vendor/bats-core`, `bats-support`, `bats-assert` are vendored source
(git history stripped) pinned at `v1.11.0` / `v0.3.0` / `v2.1.0`. They are
committed so CI and local runs need nothing beyond `bash`, `shellcheck` and
`jq` — no `npm install`/`apt install bats` step, no network access required
at test time. `tests/run-shellcheck.sh` checks both tools are on `PATH`
with a clear error before running, rather than failing deep inside a
cryptic `shellcheck: command not found`.

## Un-stubbed tools (documented debt)

Only `aws`, `docker`, `psql`, `curl`, `ssh`, `terraform`, `git` have a stub
today (the set this story's scripts actually call). `scp`, `rsync`, `nc`,
`wget`, `mongosh`, and any absolute-path invocation (e.g. `/usr/bin/foo`)
are **not** shimmed — a script under test that calls one of these directly
will hit the real binary, uncaught by anything here. If a sibling story's
script under test needs one of these, add a stub following the exact
pattern in `tests/stubs/aws` (one line, `stub_main "<name>" "$@"`) plus a
line in `stub_setup`'s `PATH` comment — message the lead first, since
`tests/stubs/**` is AXI-1945's shared ownership (see above).
