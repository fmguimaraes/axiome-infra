# Platform Lifecycle Operations Runbook (FR41, NFR9, AC33)

Operator-facing runbook for everything epic AXI-1944 shipped: the migration
gate, deploy, roll, box conversion, baselining, locks, park/unpark, local
stack safety, and what the next Terraform apply will change. Every command,
flag, exit code and refusal message below is copied or paraphrased from the
actual script on `origin/main` as of this writing, not guessed — where a
refusal string is quoted it is verbatim; where it is paraphrased that is
called out. **Nothing in this runbook has been run against live AWS** — see
[Known gaps](#11-known-gaps) at the end.

For the migration-authoring rules (what makes a migration the gate accepts),
see [`migration-authoring-guide.md`](migration-authoring-guide.md).

---

## 0. Pre-flight — before touching any of this

- **AWS CLI version.** `scripts/lock.sh` needs **≥ 2.17.34** for atomic lock
  acquisition (`s3api put-object --if-none-match '*'`) — below that, `acquire`
  refuses with `ERROR: aws CLI … is older than the minimum 2.17.34 …`. It
  needs **≥ 2.22.3** for a conditional `release`/`override` delete
  (`--if-match <etag>`); below that, release/override WARN and fall back to
  an unconditional delete (a narrow, documented race window — see
  [§4 Locks](#4-locks)). If the version cannot be determined at all, `acquire`
  prints a WARNING and still tries the call — an old CLI that gets past the
  warning still cannot silently overwrite (it hits the "unsupported option"
  branch and fails, never falls back to an unconditional create).
- **Bash 3.2 (macOS's shipped `/bin/bash`) — what is and is not verified.**
  `scripts/lib/report.sh` and `scripts/lib/cleanup.sh` are written to avoid
  bash-4-only constructs (e.g. `${var,,}` case-conversion — `tr` is used
  instead) so they parse and run on bash 3.2. This has been verified by
  reading the source for bash-4-only syntax and by the normal bats suite
  running under whatever bash is on this machine; it has **not** been
  verified by actually executing these libraries under a real bash 3.2
  interpreter (none is available in this environment) — treat
  "bash 3.2 safe" as "reviewed for known bash-4-isms", not "run on bash
  3.2 and observed to pass".
- **GNU `date` is required** on whatever machine runs `power-data.sh` /
  `scripts/lock.sh` (age/duration calculations use `date -u -d <iso>`). A
  non-GNU `date` (e.g. macOS's BSD `date` without `coreutils`) makes those
  calculations come back empty and the affected function reports "unknown"
  rather than guessing — it fails safe, it does not silently miscompute.
- **`jq` is required** by `ssm-exec.sh`, `lock.sh`, and `power.sh`'s backup
  verification — each refuses immediately with a plain `ERROR: jq is
  required` if it is missing.
- **Shellcheck is pinned, not skewed, as of AXI-1972 (FR62).** The older text
  here claimed CI ran 0.9.0 while a contributor's machine might run a newer
  0.11.0 — that is now **false**: `tests/run-shellcheck.sh` downloads and
  **verifies** a pinned shellcheck binary (version/URL/tarball checksum
  baked into the script as `SHELLCHECK_VERSION`/`SHELLCHECK_URL`/
  `SHELLCHECK_TARBALL_SHA256`) and runs that exact binary, local or CI,
  rather than whatever `shellcheck` happens to be on `$PATH`. Cached under
  `${TESTS_DIR}/vendor/shellcheck` (overridable via `SHELLCHECK_CACHE_DIR`);
  AXI-1977 close-out hardened the cache itself (see below) to re-verify a
  SHA-256 sidecar on every cache hit, failing closed (`exit 2`) on a missing
  or mismatched sidecar rather than trusting whatever is sitting in the
  cache directory.
  **To move the pin forward** (e.g. a new shellcheck release): update
  `SHELLCHECK_VERSION`, `SHELLCHECK_URL`, and `SHELLCHECK_TARBALL_SHA256` in
  `tests/run-shellcheck.sh` together, delete `${SHELLCHECK_CACHE_DIR}` (or
  run once with a fresh `SHELLCHECK_CACHE_DIR`) so the next run fetches and
  re-verifies against the new checksum, then run `tests/run.sh` once to
  confirm the whole repo is still clean against the new version before
  committing the bump — a version bump that introduces a new finding is the
  bump author's finding to fix, never a baseline/disable-directive escape
  hatch (`tests/shellcheck-baseline.json` only ever shrinks, it is not a
  place to park a new, real finding).

---

## 1. One-time box conversion (AXI-1950)

**An existing box does not get the migration gate from a Terraform apply or a
reboot alone.** Its systemd unit (`axiome.service`) keeps running a bare
`docker compose up -d` — no asset sync, no `.env` refresh, no `migrate`
one-shot — until this one-time conversion is done, once, per box:

```bash
# 1. Pull the on-box asset bundle (compose file + boot.sh + asset-sync.sh +
#    refresh-env.sh + manifest) from the published S3 prefix into /opt/axiome:
scripts/asset-sync.sh pull s3://<project>-<env>-system/onbox /opt/axiome

# 2. Point the systemd unit at the new boot wrapper instead of a bare
#    `docker compose up -d` (do this on the box, over SSM/SSH). boot.sh
#    exits immediately without ONBOX_S3_PREFIX, and refresh-env.sh needs
#    SSM_PARAMETER_PREFIX, so the unit needs these lines, not ExecStart alone
#    (same unit cloud-init writes on a new box, cloud-init/init.sh.tftpl):
#    Environment=AXIOME_DIR=/opt/axiome
#    Environment=ONBOX_S3_PREFIX=s3://<project>-<env>-system/onbox
#    Environment=SSM_PARAMETER_PREFIX=<parameter prefix>
#    ExecStart=/opt/axiome/scripts/boot.sh
# 3. Reload the unit:
systemctl daemon-reload
```

This has **never been run against a real box** — it is the documented,
reviewed path, not a verified one. `scripts/deploy-prod.sh`'s own preflight
names exactly this command when it detects an unconverted box (see
[§3 Deploy](#3-deploy-scriptsdeploy-prodsh--make-deploy-prod)).

**What refuses until this is done, and why:**

| Operation | Refusal | Why |
|---|---|---|
| `scripts/roll-service.sh` (backend) | `REFUSE: <compose-file> has no 'migrate' service under services: — this box predates the migration gate. Run: scripts/asset-sync.sh pull <s3-prefix> <dir> on this box, then retry the roll.` | No `migrate` service in the box's compose file means `up -d` cannot run the gate at all before swapping backend containers — the script refuses rather than start backend containers unguarded. |
| `scripts/deploy-prod.sh` | `REFUSE: <env> box has no 'migrate' service in its compose definition — it predates the AXI-1950 asset-sync conversion. Run the one-time conversion: scripts/asset-sync.sh pull s3://<project>-<env>-system/onbox /opt/axiome on the box, point axiome.service at scripts/boot.sh, systemctl daemon-reload, then retry this deploy.` | Same check, read-only, at preflight time — before any snapshot or roll. |

`asset-sync.sh pull` itself — the full exit-code contract (from the
script's own header, `scripts/asset-sync.sh`):

| Exit | Meaning |
|---|---|
| `0` | installed, confirmed already current, or repaired a stale manifest bookkeeping copy only |
| `1` | usage error |
| `2` | manifest or a listed file could not be fetched — existing assets kept |
| `3` | a downloaded file's checksum does not match the manifest — nothing installed |
| `4` | `docker-compose.yml` failed `docker compose config -q` validation — nothing installed |
| `5` | a manifest entry's path is absolute, empty, or contains a `..` segment (FR48) — nothing installed, that entry is never even fetched |
| `6` | install failed partway through — every file already replaced in this install run was restored to its own previous copy (FR49); nothing is left mixed |
| `7` | could not create a staging directory at all (20 name collisions in a row — in practice should never happen; AXI-1972 follow-up) |

Every non-zero exit leaves the destination directory untouched (`5`/`7`) or
restored to a consistent pre-install state (`6`) — a failed pull never
leaves a half-installed box. **`publish`'s own staging-directory-creation
failure returns `1`, not `7`** — the two modes were never unified onto one
exit code for this specific failure; `publish` is operator/CI-only (never
run against a real bucket by anything in this repo) and nothing branches on
its exit code today, so this is documented rather than changed (see the
AXI-1977 close-out comment in the script itself, `scripts/asset-sync.sh`
near the exit-code block).

Once converted, `boot.sh` runs on every boot: asset sync → `.env` refresh
(both **non-fatal** — a box with assets/`.env` already on disk still comes
up even if S3/SSM is unreachable) → `docker compose up -d` (this step's exit
code **is** `boot.sh`'s own exit code — the migrate-gate one-shot inside it
is never bypassed or swallowed).

---

## 2. Baselining — `migrate-gate baseline <service>`

**When it is the right action:** a service has real tables in its database
but **no Prisma migration ledger at all** (or an empty one) — e.g. a database
that was `db push`ed into existence once, long before the gate existed, or a
genuinely fresh schema that was never run through `migrate deploy`.
`migrate-gate apply`'s own classification step is what actually detects this
and prints the line that names it:

```
REFUSE <service>: tables exist with no migration ledger. Run: migrate-gate baseline <service>
```

Baselining then runs `prisma migrate resolve --applied <name>` once per
already-shipped migration directory, confirming **zero drift** before
recording each one as applied — per the AXI-1946 learnings log (the gate's
own source, `axiome-back docker/migrate-gate/`, is a different repo from
this one — these lines are not independently verifiable from
`axiome-infra` alone) it prints `Checking drift for <service> against its
configured datasource`, then one `resolve --applied <name>` line per
migration, then `Baseline complete for <service>: <n> migration(s) recorded
as applied (zero drift confirmed).` Measured once (throwaway
Postgres, built image): **organization-service ≈ 5–6.5 minutes** for 227+13
migrations (resumable if interrupted) — this is a several-minute, one-off
operator act, never put in a boot or deploy path.

**When it is NOT the right action — do not baseline a connectivity/config
failure.** `migrate-gate status` exits non-zero for exactly three reasons,
and only one of the three is remotely baseline-shaped:

- `not_configured` — a service listed in `MIGRATE_GATE_SERVICES` has no
  database URL set (`ORGANIZATION_DATABASE_URL` / `USER_DATABASE_URL`).
- `missing_migration_files` — the image's own migrations directory could not
  be read.
- `status_undetermined` — the status query itself threw (e.g. the database is
  unreachable right now).

**None of these three is "tables exist with no ledger"** — that classification
only exists in `apply`'s own classify step, which a read-only `status` call
never runs (running `apply` to find out would mutate any OTHER
already-ready service). `scripts/deploy-prod.sh`'s preflight therefore
distinguishes the two cases explicitly: if its own read of `migrate-gate
status`'s output happens to carry a literal `REFUSE <svc>: tables exist with
no migration ledger` line, it names that service's `baseline` command; for
every OTHER non-zero `status` exit it prints:

```
REFUSE: migrate-gate status could not be determined on the <env> box (exit <n>)
— this is a configuration or connectivity problem (e.g. a service's database
URL not set, or the database unreachable from inside the migrate container),
NOT evidence that any service needs baselining. Do NOT run migrate-gate
baseline unless the raw output below explicitly names a service with tables
and no ledger. Check both database URLs are present and reachable from the
migrate container, then retry.
```

Baselining a service that is merely unreachable right now would record
migrations as "applied" against a ledger the operator never actually
verified against — silently diverging the production ledger from reality.
**Read the raw output before ever running `baseline`.**

**A ledger-less service passes deploy preflight and is refused by `apply` at
roll time instead (AXI-1954 known gap).** `status`'s own exit-0 contract
folds a missing ledger into "every shipped migration is pending" — it does
not surface the `REFUSE … tables exist with no migration ledger` line unless
`apply`'s classify step produced it, which a read-only preflight never runs.
So a production deploy's preflight can show `PENDING_COUNT=<n>` and proceed
to snapshot + roll, and only the roll's own `migrate-gate apply` (inside the
`migrate` one-shot, with the OLD containers still serving) actually hits the
REFUSE and fails closed — the deploy then restores the previous tag per
§5's failure handling. **If you know a service is ledger-less, baseline it
BEFORE scheduling a deploy** — do not rely on preflight to catch it.

---

## 3. Deploy (`scripts/deploy-prod.sh` / `make deploy-prod`)

```bash
make deploy-prod ENV=production TAG=<8-char-sha>                      # backend (default)
make deploy-prod ENV=production TAG=<sha> SERVICE=frontend|biocompute
make deploy-prod ENV=production TAG=<sha> DRY_RUN=1                   # plan only, no mutation
# equivalently: scripts/deploy-prod.sh --tag <sha> [--env production] [--service backend] [--dry-run]
```

**Sequence (`AXI-1954`, re-ordered from the earlier AXI-1349 flow to close
H2/H6/H7 from the feature doc):**

1. Confirm the `data-tier` lock is free (`lock_require_free … data-tier`);
   refuse closed if held or UNKNOWN.
2. Acquire the `deploy` lock (auto-released on exit, even on Ctrl-C).
3. Preflight: verify the source tag exists in ECR and resolve its digest;
   read-only on-box check of `.env`'s prior tag, compose `migrate:` service
   presence, and `migrate-gate status` (§2 above governs how its result is
   read). The ONLY non-zero SSM exit here (box unreachable) is itself a
   refusal — nothing has mutated yet.
4. **Re-check** the `data-tier` lock, now that `deploy` (step 2) is held: a
   park acquires `data-tier` and only then checks `deploy`/`apply`, so this
   re-check (on top of step 1's earlier, pre-acquisition check) is what
   guarantees a park starting anywhere up to this point is caught — not a
   race left open (see [§4](#4-locks)).
5. **Pre-deploy RDS snapshot** — backend, pending migrations, production
   only. Named `<project>-<env>-predeploy-<UTC timestamp>`; waits for
   `available` before continuing; pruned to the newest `SNAPSHOT_RETENTION`
   (default 5, manual snapshots with that prefix only) afterward. **Not
   taken** for frontend/biocompute (no schema, EC13) or when nothing is
   pending or off production.
6. **Roll** to the new tag via `roll-service.sh` over `ssm-exec.sh` — the OLD
   containers keep serving while the gate runs against the NEW image (the
   compose `migrate:` dependency, §1). This run's `MIGRATION_FACTS`/
   `MIGRATION_FACTS_OVERRIDE` lines are captured into the deploy report; an
   unavailable-facts result is a **warning only** here (the containers are
   already proven serving by the NEXT step), not a deploy failure.
7. **Readiness poll** — backend polls `/api/v1/health/ready` (JSON body,
   `services[].reason`); frontend/biocompute poll their own 2xx path.
8. **Advance `:stable`** — the LAST mutation, and only on readiness PASS. Also
   re-resolves the tag's digest right before retagging and refuses if it
   moved during the deploy (see "`:stable` not advanced" below).
9. **Read-only baseline verification** (`seed-environment.sh --check`,
   backend only) — warning only, **never** rolls back.
10. Release the `deploy` lock.

**Every refusal and what it means:**

| Stage | Refusal (paraphrased — see the note below the table for which rows are verbatim) | Meaning |
|---|---|---|
| Locks | data-tier lock held/UNKNOWN | refuse before any mutation — a park may be in progress |
| Locks | `FAIL-CLOSED: could not acquire the deploy lock for ${ENV}, or the data-tier/apply lock is held — refusing to deploy. See above for which lock is held.` (**verbatim**, `scripts/deploy-prod.sh`) | another deploy running, or the data-tier/apply lock is held |
| Preflight (box) | `FAIL-CLOSED: could not reach <env> over SSM to preflight-check (INDETERMINATE) — the box may be stopped. Nothing has been changed.` | SSM wait expired (exit 2) — nothing mutated |
| Preflight (box) | `FAIL-CLOSED: /opt/axiome/.env does not exist on the <env> box — has cloud-init finished?` | box never finished first boot |
| Preflight (gate) | §1's box-conversion REFUSE, or §2's ledger/connectivity REFUSE | see §1/§2 |
| Post-preflight re-check | `FAIL-CLOSED: the data-tier lock for <env> is now held (parked during preflight) — refusing to snapshot/roll against it.` | a park started mid-preflight; caught by the already-safe acquire-then-check pattern (§4), not a race |
| Snapshot | `FAIL-CLOSED: could not create pre-deploy snapshot … — stopping before any migration.` / did not become available | RDS snapshot API failure or timeout — stop before migrating |
| Roll (indeterminate, exit 2) | `FAIL-CLOSED: the roll result is INDETERMINATE … :stable was NOT advanced.` | SSM wait expired on the roll itself; box state truly unknown — **no blind restore attempted** (see below) |
| Roll (failed, exit 1) | `FAIL-CLOSED: <env>/<service> roll failed — migration gate did not pass. :stable was never advanced.` | gate refused on the new image; previous tag is restored (see below) |
| Readiness | `FAIL-CLOSED: <env>/<service> did not become ready after <n> attempts.` + per-service reasons | readiness never reached 200; previous tag is restored |
| `:stable` advance | `FAIL-CLOSED: … advancing ECR :stable FAILED. Production is serving a build that :stable does NOT point at — retry … by hand with the digest …` | the box IS healthy on the new image, but the retag call itself failed — manual retag needed |
| `:stable` not advanced (digest moved) | `<repo>:<tag> moved during this deploy — it now points at <digest>, not the <digest> this deploy rolled out and verified ready. Refusing to advance :stable to a digest this deploy never proved healthy.` | someone re-pushed the mutable tag mid-deploy; the roll itself already succeeded and is healthy — only the `:stable` pointer is withheld |

**Verbatim vs paraphrase:** every backtick-quoted message in this runbook
is one of two things.
**Dual-checked verbatim** against both this file and its script by
`tests/doc-truth.bats`'s `UT-INFRA-388` — the deploy-lock row above, the
§1 box-conversion `REFUSE` lines, the §4 lock-table
rows, the §4 `acquire --operation`/`lock_mark_for_auto_release` refusals,
and the `mongo-backup.sh` `MONGO_BACKUP_OK`/`MONGO_BACKUP_FAILED`/
control-character lines — are all checked this way (grep `UT-INFRA-388` in
that file for the exact substring list). **Explicitly paraphrased**
otherwise: every OTHER row in the table above (placeholders like
`<env>`/`<n>`/`<service>`/`<digest>` stand in for the script's own
`${ENV}`/etc. shell interpolation, and `…` elides boilerplate) — these are
paraphrases for operator readability, not exact script output, and are not
asserted against script source by any test. The §0 AWS-CLI-version-error
line (`ERROR: aws CLI … is older than the minimum 2.17.34 …`) is likewise
an explicit paraphrase (its own `…` marks the elision).

**Restore behaviour (previous-tag restore):** on a roll failure (exit 1) or a
readiness failure, `deploy-prod.sh` re-rolls the box to `PRIOR_TAG` (captured
at preflight) via the SAME `roll-service.sh`, then polls health again to
confirm the restore itself worked, before reporting `failed-roll-restored` /
`failed-readiness-restored`. If the restore ALSO fails, it says so plainly
and names the manual recovery command
(`KEY=<key> IMAGE_TAG=<prior> SERVICE=<service> scripts/roll-service.sh`
by hand on the box) — `:stable` is untouched either way.

**On an INDETERMINATE roll (exit 2), there is deliberately NO automatic
restore** — the remote command was cancelled after its wait expired and its
true final state is unknown; blindly re-rolling an unknown state is not
safer than leaving it alone. The operator is told to check `docker compose
ps`, `docker compose logs migrate`, and the `.env` tag by hand before
retrying anything.

**"Schema may be ahead of the restored image" / "snapshot is the rollback
point":** every restore path above reports one of two statements, because a
restore re-points the BOX but never reverts the DATABASE SCHEMA the gate
already wrote:

- *Confirmed ahead:* "The migration gate completed successfully before this
  failure — the schema is now fully migrated, and the restored (older)
  image's own schema expectations predate this migration; restoring the box
  does NOT undo the schema change." (readiness-failure path — the gate had
  already passed).
- *Unknown:* "Migrations may have PARTIALLY applied before this failure (the
  gate stops at the first failing migration within a service, not before
  it) — the schema's true state relative to the restored (older) image is
  UNKNOWN." (roll-failure / indeterminate paths).

Either way, if a pre-deploy snapshot was taken, the message names it as "the
point-in-time rollback path if the schema needs to be reverted — this script
does NOT restore it automatically" — restoring a snapshot is always a human
decision, never automated here. If no snapshot was taken (frontend/
biocompute, or nothing was pending), the message says plainly there is no
automatic rollback path available.

**`:stable` not advanced, summarised — every case:** roll failed; roll
indeterminate; readiness failed; the retag call itself failed (box IS
healthy, pointer is stuck — needs a manual retag); the tag's digest moved
mid-deploy (box IS healthy, pointer deliberately withheld). In every one of
these, the thing that actually serves traffic and the thing `:stable` names
can disagree — check both independently (`docker compose ps` on the box vs.
`aws ecr describe-images --image-ids imageTag=stable`) before assuming either.

**`Baseline verification: NOT PERFORMED`:** `seed-environment.sh --check`
exits `3` (distinct from `0` match / nonzero mismatch) specifically when
expected counts cannot be derived. Since AXI-1968 (FR45/AC37),
`deploy-production.yml` checks out `axiome-back` beside `axiome-infra` and
exports `AXIOME_BACK_PATH`, so this is no longer the structural, every-time
result there — it now only fires if that checkout genuinely failed or its
rule-pack/template files are unreadable. This is reported as
`Baseline verification: NOT PERFORMED`, never as a mismatch — treating
"could not check" as "checked and it's wrong" would be a false alarm.
Either way this step is warning-only and never rolls back.

**Diagnostic output is scrubbed before it is ever printed (AXI-1968,
FR63):** both the preflight's captured `migrate-gate status` output (when
it REFUSEs with a connectivity/configuration error, §3's "Every refusal"
table) and the baseline check's own printed output go through
`report_is_secret_value` (`scripts/lib/report.sh`, AXI-1973) one line at a
time before `deploy-prod.sh` prints them. A line that matches a secret
shape is replaced with `[<check name> output line withheld — matched a
secret shape (NFR3); content not printed]`; every other line in the same
block still prints verbatim — this is a per-line scrub, not an
all-or-nothing withholding of the whole diagnostic block. The production
deploy workflow's own "Resolve deployed commit" step applies the same
scrub (sourcing `axiome-infra/scripts/lib/report.sh`, already checked out
by that point) to the GitHub API response it prints on a resolution
failure, bounded to 2000 bytes either way.

**The `deploy-production.yml` GitHub Actions workflow — one level above
`deploy-prod.sh`.** The script above is what runs; this workflow is what
calls it and prepares its inputs:

- **`--tag`/`TAG` must be exactly 8 lowercase hex characters** — the short
  git SHA `reusable-build.yml` publishes — validated before it is written
  into any lock or report. Two refusal messages, chosen by whether the bad
  value ALSO looks secret-shaped:
  `ERROR: --tag/TAG is not shaped like an image tag this pipeline produces
  (expected exactly 8 lowercase hex characters, the short git SHA
  reusable-build.yml publishes). The given value also looks secret-shaped,
  so it is not printed here. Refusing before it is written into any lock or
  report. Nothing was changed.` or, when it is merely malformed (and safe to
  print): `ERROR: --tag/TAG is not shaped like an image tag this pipeline
  produces (expected exactly 8 lowercase hex characters, e.g. 'a1b2c3d4');
  got '${TAG}'. Refusing before it is written into any lock or report.
  Nothing was changed.`
- **`GH_PAT` is required**, not optional, to check out `axiome-back`,
  `axiome-bio-compute`, and `axiome-front` for this deploy's baseline check
  and deployed-commit checkout — enforced with
  `: "${GH_PAT:?GH_PAT secret is required to check out axiome-back,
  axiome-bio-compute and axiome-front for this deploy's baseline check and
  deployed-commit checkout — missing. Add it as a repo secret (same PAT
  reusable-build.yml and terraform-cd.yml already use).}"`.
- **Each of those three repos is checked out twice** in the same workflow
  run: once at the commit the deploy is actually rolling out (resolved from
  `<repo>@<tag>` via the GitHub API), and once at that repo's own default
  branch (used by the baseline check, §3's "Baseline verification" above,
  which needs the LATEST rule-pack/template files, not the deployed
  commit's possibly-older copy).
- **Commit-resolution failure** (the GitHub API call that turns
  `<repo>@<tag>` into a commit SHA comes back non-2xx) refuses the checkout
  outright, with the response scrubbed and truncated before printing:
  `::error::Could not resolve ${REPO}@${TAG} to a commit via the GitHub API
  (HTTP ${http_code}) — refusing to check out an unresolved commit for the
  service being deployed. Nothing was changed. Response (truncated to 2000
  bytes, scrubbed): $(scrubbed_response)` — nothing is checked out at an
  unverified ref.

**Seeding production directly (`scripts/seed-environment.sh -e production`,
outside `deploy-prod.sh`):** since AXI-1968 (FR46/AC39), the WRITE path (no
`--check`) against `-e production` refuses unless the operator also passes
`--confirm production` (the literal word, typed exactly — no prompt, no
piped `yes`/empty stdin satisfies it). The refusal happens before any
connection or Compose call runs:
`SEED REFUSED: seeding production requires an explicit confirmation — pass
--confirm production (typed exactly) to proceed. There is no prompt; a
piped 'yes' or empty stdin can never satisfy this. Nothing was connected
to, and nothing was written.` `-e dev`/`-e staging`/`--local`/`--check`
(any environment) are all unaffected — only a production WRITE needs it.
**`make seed-env ENV=production` hits this same refusal** — the Makefile
target is `scripts/seed-environment.sh -e $(ENV)` with no `--confirm` flag
of its own, so it always refuses for `ENV=production`; the Makefile's own
`seed-env` help line and comment say so. To actually seed production, call
the script directly: `scripts/seed-environment.sh -e production --confirm
production`.

---

## 4. Locks

**There are four lock names: `deploy`, `data-tier`, `apply`, and `compute`**
(`LOCK_NAMES="deploy data-tier apply compute"`, `scripts/lock.sh`). `apply` is
held across a `terraform-cd` apply run (acquired/released by the workflow
itself, AXI-1967/FR42/AC34 — see `.github/workflows/terraform-cd.yml`'s
`lock_acquire_exclusive production apply "terraform apply run=${{
github.run_id }}" deploy data-tier compute` step, released `if: always()` via
`scripts/lock.sh production release apply --token "${APPLY_LOCK_TOKEN}"`).
`compute` is held for the duration of a `providers/aws/scripts/power.sh`
`down`/`up` run (AXI-1981/FR43) — acquired first, released on every exit path
via `lock_mark_for_auto_release` + `lock_install_exit_trap`, the same pattern
`deploy` uses. Together these make deploy/apply/park/compute mutually
exclusive:

| Caller | Check | Exact message | Effect |
|---|---|---|---|
| `providers/aws/scripts/power.sh` (`down`) | deploy or apply lock held? | `ABORT: could not acquire the compute lock for ${ENV}, or the deploy/apply lock is held — refusing to stop compute. See above for which lock is held.` | releases the just-acquired `compute` lock, refuses before any SSM/backup/stop call |
| `providers/aws/scripts/power.sh` (`up`) | deploy or apply lock held? | `ABORT: could not acquire the compute lock for ${ENV}, or the deploy/apply lock is held — refusing to start compute. See above for which lock is held.` | releases the just-acquired `compute` lock, refuses before any start call |
| `providers/aws/scripts/power-data.sh` (`down`, after acquiring data-tier) | compute lock held? | `ABORT: the compute lock is held — releasing the data-tier lock just acquired and refusing to park while a compute power operation is in progress.` | releases the data-tier lock it just took, then refuses — never leaves data-tier held on this path |
| `power-data.sh` (`up`) | compute lock held? | **stderr:** `ABORT: the compute lock for ${ENV} is held — refusing to start/recreate the data tier while a compute power operation is in progress. Re-run '$0 ${ENV} up' once it finishes.` **report line:** `ABORT: the compute lock is held — refusing to unpark while a compute power operation is in progress. The data-tier lock itself is untouched (it is this park's own lock).` | refuses before starting/recreating RDS/ElastiCache; the park's own data-tier lock is left held (it is not released on this path) |
| `power-data.sh` (`down`, acquiring data-tier) | could not acquire data-tier at all | `ABORT: could not acquire the data-tier lock (rc=${LOCK_RC}) — refusing to park. Another park, deploy, or terraform-cd apply may be in progress; see '$0 ${ENV} status'.` | refuses before any AWS mutation |
| `scripts/deploy-prod.sh` (initial acquire) | data-tier, apply, or compute lock held? | `FAIL-CLOSED: could not acquire the deploy lock for ${ENV}, or the data-tier/apply/compute lock is held — refusing to deploy. See above for which lock is held.` | releases the just-acquired `deploy` lock, refuses before any build/push/roll call |
| `scripts/deploy-prod.sh` (post-preflight re-check) | compute lock held? | `FAIL-CLOSED: the compute lock for ${ENV} is now held (a compute power operation started during preflight) — refusing to snapshot/roll against it.` | refuses before the snapshot/roll step; the `deploy` lock it holds is released on this exit path like any other |

Every refusal in the table above (and the pre-existing data-tier/apply
re-checks it mirrors) also prints a second, remedy line pointing the
operator at the right next step without inviting a reckless override —
e.g. `power.sh`'s exact wording: `  If the lock named above is stale (its
holder is confirmed dead): scripts/lock.sh ${ENV} status <name>, then
scripts/lock.sh ${ENV} override <name> --reason "<text>" --confirm. Never
override a lock that is still legitimately held.` A script that already
knows the specific lock name (power-data.sh/deploy-prod.sh's per-lock
checks) prints that name directly instead of `<name>`, e.g. `  If the
compute lock is stale (its holder is confirmed dead): scripts/lock.sh
${ENV} status compute, then scripts/lock.sh ${ENV} override compute
--reason "<text>" --confirm. Never override a lock that is still
legitimately held.` — the exact CLI forms from §4's own "Inspect"/
"Override" examples above.

`terraform-cd` itself acquires `apply` naming `deploy`, `data-tier` and
`compute` as the locks it conflicts with — so a deploy, a park, or a compute
power operation already in progress blocks a new `apply` from starting in
the first place, symmetric with the table above. `scripts/deploy-prod.sh`
likewise names `data-tier`, `apply` and `compute` as the locks it conflicts
with (see below). See below for why this makes deploy/apply/park/compute
mutually exclusive, and the one deliberately one-directional pair
(`compute`/`data-tier`).

**Inspect:**

```bash
scripts/lock.sh <dev|staging|production> status              # both locks
scripts/lock.sh <dev|staging|production> status deploy        # one lock
```

Output is `<name>: FREE` or `<name>: HELD by <actor> running <operation>
since <iso> (age <n>s) host=<host>`, or `<name>: UNKNOWN (<reason>)` — UNKNOWN
is never treated as free (fail-closed).

**Override (the only way to remove a lock you do not hold):**

```bash
scripts/lock.sh <env> override <deploy|data-tier|apply|compute> --reason "<text>" --confirm
```

Requires both `--reason` and `--confirm`; refuses if the lock is already
free; **writes a dated audit report BEFORE deleting** — if the reason text
looks secret-shaped (`password=`, `token=`, a bearer token, an AWS-style
access key, a `user:pass@` URL, …) or the report cannot be written for any
other reason, the override is **ABORTED and the lock is NOT deleted** — there
is no path that deletes a lock without a written audit trail. The report
names the previous holder, their operation, the lock's age, and the given
reason.

**`data-tier` has no automatic release by ANY route** — not on process exit,
not on a crash, not on Ctrl-C/SIGTERM. `lock_mark_for_auto_release` (the
auto-release registration used by `deploy`) **refuses to register
`data-tier` at all**. Only an explicit `lock_release` (after the operator
verifies the data tier is actually available again) or `override` (with the
audit trail above) ever removes it. This is deliberate: a crash between
"park started" and "verified unparked" must leave the lock held, never
silently free.

**No TTL, no auto-steal.** A stale lock is only ever surfaced by `status`
(with its age) and removed by the explicit, audited `override` — nothing
times it out automatically.

**`acquire --operation <text>` is secret-checked too, not just `override
--reason`.** The same secret-shape guard runs on the `--operation` string
before a lock is written:
`ERROR: acquire of '${name}' REFUSED — the given --operation resembles a
secret-shaped string (e.g. contains 'password=' or similar). Rephrase
--operation and retry. The lock was NOT acquired.` — the lock is **not**
acquired at all on this path (contrast `override`, where the audit report
write itself is what is refused). `lock_mark_for_auto_release`'s own refusal
for `data-tier` is verbatim:
`ERROR: lock_mark_for_auto_release refuses 'data-tier' (FR29) — the
data-tier lock must be removed only after the data tier is verified
available again, never automatically on exit/crash/signal. Call
lock_release explicitly after verification.`

**Apply, deploy, and data-tier park cannot run at the same time.** Every
mutating operation acquires its OWN lock with an atomic S3 conditional
create (`s3api put-object --if-none-match '*'`, strongly read-after-write
consistent) **before** it ever checks the other two — never the other
order:

- `terraform-cd`'s apply job: `lock_acquire_exclusive production apply
  "terraform apply run=${{ github.run_id }}" deploy data-tier` — this calls
  `scripts/lock.sh`'s `lock_acquire_exclusive()`, which acquires `apply`
  (its own lock) first, THEN loops checking `deploy`/`data-tier` are free,
  releasing `apply` and refusing if either is held.
- `scripts/deploy-prod.sh`: `lock_acquire_exclusive "${ENV}" deploy
  "deploy service=... tag=..." data-tier apply` (line ~606) — acquires
  `deploy` first, then checks `data-tier`/`apply` are free; it re-checks
  both again after preflight (lines ~636-664), which only re-runs the same
  already-safe check closer to the snapshot/roll calls — it is not a
  second chance to be unsafe.
- `providers/aws/scripts/power-data.sh down`: acquires `data-tier` first
  (`lock_acquire`), then checks `deploy`/`apply` are free, releasing
  `data-tier` and refusing if either is held.

Because S3's conditional create is atomic and immediately visible,
whichever side's own acquire happens later in real time is guaranteed, by
its own strictly-subsequent check of the other lock, to observe the
earlier acquisition and back out. **At most one of {apply, deploy, park}
ever proceeds to its actual mutation — two of them can never both run.**
The remaining effects are not a safety race; they are:

- **(a) Mutual back-out.** If two of them start within the same narrow
  window, both own-acquires can succeed (different lock names), but each
  side's very next check then finds the OTHER's lock held — both refuse,
  each releasing the lock it just took, and neither proceeds. The operator
  sees two refusals naming each other's operation and must retry one of
  them (never both at once).
- **(b) A failed release leaves the lock stuck.** A refusal releases the
  lock the refusing side just took; if that release call itself fails
  (`scripts/lock.sh`'s own wording: `WARNING: releasing '${name}' failed
  (rc=${release_rc}) — it may still be HELD.`), the lock is left HELD and
  every later operation refuses — fail-closed — until an operator runs
  `scripts/lock.sh <env> status <name>`, confirms it is this run's own
  stale lock, then `scripts/lock.sh <env> override <name> --reason
  "<text>" --confirm` to remove it.
- **(c) Cannot determine the other lock's state.** A check that fails to
  determine whether the other lock is free (network/access/CLI error,
  `LOCK_RC_UNKNOWN=2`) is refused by `lock_require_free` exactly like a
  held lock — never treated as free.

**`providers/aws/scripts/power.sh`'s compute park (`down`)/unpark (`up`)
follow the same acquire-then-check pattern as `deploy`/`apply`.** Each
acquires its own `compute` lock first (`lock_acquire_exclusive`), then
verifies `deploy` and `apply` are free; on either being held it releases
`compute` and refuses before any backup/stop/start call. This makes
`compute` mutually exclusive with `deploy` and `apply` in both directions —
a `deploy-prod.sh` run or a `terraform-cd` apply that starts after
`power.sh` has already acquired `compute` is refused by their own
`compute` check (see the Locks table in §3), and a `power.sh` run that
starts after either of those already holds its lock is refused by
`power.sh`'s own check. `compute` is deliberately checked one-directionally
against `data-tier`: `power-data.sh`'s `down`/`up` check `compute` is free,
but `power.sh` does not check `data-tier` — `data-tier` is held for the
entire parked window (potentially days), and making `compute` wait on it
would make compute power operations unusable for that whole window. This
one-directional check only stops a park/unpark operation from STARTING
while `compute` is held; it does not stop a compute power operation from
starting while a park/unpark operation (or the parked state after it) is
already under way. That is acceptable because `power.sh` only stops/
starts the EC2 instance and triggers an on-box Mongo backup over SSM — it
never writes RDS, ElastiCache, or Terraform state, so there is nothing for
it to corrupt by overlapping with a data-tier operation. In practice: a
`power.sh up` started during a park, or while already parked, starts the
instance but then fails its own readiness poll (the app cannot reach a
stopped/deleted RDS/Redis) and exits non-zero, releasing `compute` on the
way out — a failed, retriable `up`, not a corrupted state.

---

## 5. Roll (`scripts/roll-service.sh`) and `ssm-exec.sh` exit codes

`roll-service.sh` is the mechanism `deploy-prod.sh` calls; it can also be run
directly (e.g. from `dev-auto-promote.yml`) with `KEY=<env-key>
IMAGE_TAG=<tag> SERVICE=backend|frontend|biocompute scripts/roll-service.sh`.
For a backend roll it NEVER passes `--no-deps` — a plain `docker compose up
-d <targets>` runs the compose `migrate:` dependency first and refuses to
start the backend containers if the gate fails, leaving the previous
containers serving untouched. See §1 for the box-conversion refusal.

**`ssm-exec.sh` exit codes — the contract every caller branches on:**

| Exit | Meaning | What a caller must do |
|---|---|---|
| `0` | Success — the remote command reached a terminal `Success` state before the wait expired | proceed |
| `1` | A terminal `Failed`/`Cancelled`/`TimedOut` state reached before the wait expired — a **real, known** remote failure | treat as a definite failure |
| `2` | **INDETERMINATE** — the wait expired before any terminal state; the script cancels the command (`aws ssm cancel-command`) and prints `status: INDETERMINATE` rather than guessing | **never advance `:stable`**; do not blindly retry/restore — the remote state is unknown, not known-bad. Check the box by hand. |

**Manual checks for an INDETERMINATE (exit 2) result** — do these before
retrying anything:

```bash
scripts/ssm-exec.sh -e <env> 'docker compose -f /opt/axiome/docker-compose.yml ps'
scripts/ssm-exec.sh -e <env> 'docker compose -f /opt/axiome/docker-compose.yml logs --no-log-prefix migrate'
scripts/ssm-exec.sh -e <env> 'cat /opt/axiome/.env | grep _IMAGE_TAG='   # never do this with a real secret-bearing file — .env here carries only tags
```
Confirm which image tag is ACTUALLY running (`docker compose ps` image column)
before trusting the `_IMAGE_TAG` value recorded in `.env` — a roll writes
that value BEFORE the gate runs, so on a gate failure it can briefly name a
tag that never actually started serving.

---

## 6. Park / unpark (`power.sh`, `power-data.sh`, `power-up-all.sh`)

**Compute (daily, safe) — `power.sh <env> <up|down|status>`:**

- `down` runs the on-box Mongo backup over SSM FIRST, then independently
  **verifies** it (not just trusts the on-box script's own claim): the
  verification requires a `head-object` that shows `ContentLength > 0`,
  `LastModified` not earlier than when the backup was issued, and the
  object's `sha256` metadata matching the backup script's own reported
  checksum. Only then does it stop the instance. Any `ssm-exec.sh` non-zero
  result (including the INDETERMINATE 2) refuses the stop, as does a
  verification that fails: `ABORT: backup not verified; compute NOT
  stopped. Use --skip-backup "<reason>" to override.`
- **The on-box backup script (`providers/aws/onbox/mongo-backup.sh`) never
  puts the Mongo password on argv.** It delivers `MONGO_ROOT_PASSWORD` to
  `mongodump` via a generated `--config=/dev/stdin` YAML document instead —
  argv is visible to any other user on the box (`ps`), a config file read
  from stdin is not. Before building that YAML it refuses on any control
  character in the password:
  `ERROR: MONGO_ROOT_PASSWORD contains a newline, a carriage return, or
  another control character, which a mongodump YAML config file cannot
  represent without corrupting it (YAML folds a newline/carriage return
  inside a single-quoted scalar into a space) — refusing rather than
  silently using the wrong password.` Its own stdout contract on completion
  is one of exactly two lines: `MONGO_BACKUP_OK key=<s3-key>
  sha256=<hex>` or `MONGO_BACKUP_FAILED <reason>` (non-zero exit) — this is
  what `power.sh down`'s independent verification (below) checks against.
- `--skip-backup "<reason>"` overrides the backup requirement — the reason
  must be non-empty and must not look secret-shaped (same guard family as
  lock override's `--reason`); it is written to the audit report before the
  stop proceeds.
- `up` polls `/api/v1/health/ready` (through the public edge) and prints the
  last response body on a timeout.
- Env knobs: `AXIOME_HEALTH_URL`, `BACKUP_SSM_WAIT` (default 180s),
  `POWER_UP_HEALTH_TIMEOUT_SECONDS` (default 600s),
  `POWER_UP_HEALTH_POLL_INTERVAL` (default 5s).

**What holds the data-tier lock, and when it is released — `power-data.sh
<env> <down|up|status>`:**

- `down` **acquires** the `data-tier` lock before touching anything, writes
  the acquired token to `s3://<system-bucket>/power-data/park-state.env`
  immediately (before any stop/delete — if THAT write itself fails, the lock
  is released and nothing is touched), then stops RDS and — only after a
  verified config capture — snapshots and deletes the ElastiCache
  replication group, waiting for the final snapshot to be confirmed
  `available` before ever reporting success. **`down` never releases the
  lock.**
- `up` starts/recreates both tiers, waits (bounded) for BOTH to report
  `available`, and **releases the lock only then** — never from a
  trap/finally. If the wait times out, the lock stays held and the operator
  is told to investigate and re-run `up`.
- A second `down` while already parked is refused at the lock, with no AWS
  mutation at all.
- `up` with nothing parked makes no lock call at all (nothing to release).
- `up` after an `override` (lock removed out-of-band): the recorded park
  token is gone, so the release is cleanly skipped with a warning naming
  `scripts/lock.sh <env> status data-tier` — the stale `park-state.env` is
  left for the operator (not auto-cleared on this path).

**One-call turn-on (validated superset) — `power-up-all.sh <env> [--yes]`
(or `make turn-on ENV=<env> [YES=1]` from `providers/aws/`):** read-only
preflight (AWS identity, current state, and — if Redis is `absent` — that
BOTH the `redis-state.env` file and its referenced final snapshot exist and
are `available`, since that snapshot is the only copy) ALWAYS runs first and
aborts before any mutation on a missing input. The mutating run needs
`--yes` (or `POWER_CONFIRM=1`); without it, the command is a safe dry run.
Order: data tier up and verified healthy FIRST, then compute — the app must
never start against a cold DB/Redis. Keep `terraform-cd` gated for the whole
window (Redis is recreated outside Terraform); confirm `terraform plan`
shows no changes before un-gating it.

**Installing the Mongo backup timer — `install-mongo-backup-timer.sh <env>`
— this has never been run.** It is a one-time operator conversion (same
category as §1's box conversion): moves a box from cron-only Mongo backup
(no catch-up if a run is missed) to a systemd timer
(`OnCalendar=daily, Persistent=true` — the mechanism that actually satisfies
"catches up a missed run on box start"). Precondition: the box must already
be on the asset-sync channel (§1) and have pulled at least once since
`mongo-backup.timer`/`.service` were published — the script refuses with a
clear message if those files are not yet on disk, rather than silently doing
nothing. It has never been run by CI or against any real box.

---

## 7. Local stack safety (AXI-1952, hardened AXI-1971)

- **Compose v2 is required, resolved through ONE shared resolver** —
  `scripts/lib/compose-resolve.sh` (AXI-1971, FR54). The root `Makefile` and
  every LOCAL-dev-stack script that runs Compose (`wt-up.sh`, `wt-down.sh`,
  `wt-migrate.sh`, `ensure-shared-infra.sh`, `enable-llm-planner.sh`,
  `sync-event-store-indexes.sh`, `analytics/test/e2e-analytics.sh`) call it
  instead of each hardcoding `docker compose` independently (verified
  repo-wide, not just this list — `tests/compose-call-sites.bats`'s
  UT-INFRA-519/606 scan EVERY tracked shell script and Makefile via
  `git ls-files`, with an explicit, one-line-reasoned exclusion list rather
  than an inclusion list, so a brand-new file is checked by default).
  Resolution refuses — printing one line naming what was found and the
  remedy, running nothing — whenever:
  - no usable `docker compose` (v2) is found at all;
  - a `DOCKER_COMPOSE` override is not literally shaped like a Compose v2
    command — an **allow-shape** (basename `docker`, immediately followed
    by the literal word `compose`, then optional arguments), not a
    deny-list: a deny-list only ever covers forms someone already thought
    of, which is exactly how `DOCKER_COMPOSE=/usr/bin/docker-compose` and
    `DOCKER_COMPOSE="docker-compose -f x"` (AXI-1955 follow-up) and, later,
    leading/trailing whitespace, a `sudo`/`env VAR=…` prefix, and any other
    non-Compose override all slipped an earlier, narrower check.

  **Scripts that invoke Compose but are deliberately NOT resolver-routed**
  (excluded from the UT-INFRA-519/606 scan, each for a stated reason — see
  `tests/compose-call-sites.bats`'s header comment for the authoritative,
  one-line-per-file list): scripts that run on the PRODUCTION box over
  SSM/SSH or ship a literal command string to one (`asset-sync.sh`,
  `deploy-prod.sh`, `roll-service.sh`, `reset-admin-password.sh`,
  `pull-on-vm.sh`, `platform-debug.sh`, `ssm-exec.sh`,
  `providers/aws/onbox/boot.sh`, `providers/aws/scripts/power.sh` /
  `power-up-all.sh`); `providers/onprem/scripts/install.sh` (installs onto a
  customer's target machine, never run against this repo's own dev stack).
  `scripts/seed-environment.sh` was a known, flagged exception at the time
  this paragraph was written (hardcoded `docker compose` literally, not yet
  resolver-routed) — AXI-1968 closed it: both of its local Compose call
  sites now route through `scripts/lib/compose-resolve.sh` like every other
  local script, and the exclusion entry has been removed from
  `tests/compose-call-sites.bats`.

  The Makefile's own guard still only fires **for a goal that actually
  touches Docker Compose** (AXI-1955 fix (a) — `make help` and every
  Terraform/seed/deploy-prod target need no Docker at all and work without
  it); it now forwards `DOCKER_COMPOSE` into the resolver explicitly (a
  command-line `make … DOCKER_COMPOSE=…` is not part of `make`'s own process
  environment otherwise) and `override`s the result back, normalizing
  whatever it resolved to for every Compose macro below it in the file.
  **Requires GNU Make >= 4.2** (the `.SHELLSTATUS` automatic variable this
  guard reads). On an older `make`, any Compose-touching goal fails closed
  with a message naming that version requirement explicitly, rather than a
  misleading "Compose v2 not found".
- **`make local-ps` / `make local-health` now inspect `axiome-demo`** — the
  project `local-up`/`demo-up` actually start — not the unrelated
  `axiome-$(LEGACY_SLUG)` project no `local-*` target starts (FR55/AC48;
  epic AXI-1944 debt, named in the AXI-1955 follow-up list).
- **Purge guard** (`wt_purge_guard` in `scripts/wt-common.sh`): `wt-down.sh
  --purge` only proceeds if every target resource name contains the
  worktree's own slug, no resource equals a known SHARED name, the slug
  itself matches `[a-z0-9][a-z0-9-]*` (no glob/regex metacharacters), and the
  Redis index is not the shared index (0 or 1). All violations are listed
  before refusing — nothing is deleted on a partial pass.
- **`wt-down.sh --purge-shared --confirm DELETE-ALL-LOCAL-DATA`** — the
  literal, case-exact token is the ONLY accepted confirmation; there is no
  interactive prompt, so a piped "yes" or a closed/empty stdin can never
  satisfy it. A verified Postgres backup is taken FIRST; a failed or empty
  backup refuses the purge (same via `make shared-down PURGE=1
  CONFIRM=DELETE-ALL-LOCAL-DATA`).
- **Backup-before-migrate:** `wt-migrate.sh apply` (used by both `wt-up.sh
  --migrate` and `make demo-up`) takes a verified `pg_dump` of the shared DB
  BEFORE running `migrate-gate apply` — a failed or empty dump refuses the
  migration outright, forward-only, no schema-push fallback of any kind. A
  second concurrent `wt-migrate.sh apply` from another worktree waits on a
  machine-local lock and then refuses rather than running concurrently.
- **`make demo-up MIGRATE=0`** skips the migration and instead prints the
  pending migrations (`wt-migrate.sh status`, read-only) before starting the
  stack anyway — useful to inspect drift without committing to a migration.
- **`scripts/sync-event-store-indexes.sh --compose-project <p>
  --compose-file <f> [--env-file <f>] [--service backend]`** — the ONE
  explicit, opt-in way to sync the local event-store (MongoDB) indexes
  (AXI-1971, FR56/AC49). Invokes the application's OWN index definitions —
  `npx prisma db push` against axiome-back's own
  `apps/event-service/src/prisma/schema.prisma` (`@@index([...])`), inside
  the running backend container — rather than duplicating that list here.
  No start, up, migrate or seed path calls it (structurally checked,
  `tests/sync-event-store-indexes.bats`): it is an operator act, run by
  hand, e.g. `scripts/sync-event-store-indexes.sh --compose-project
  axiome-demo --compose-file docker-compose.demo.yml`. It refuses before
  touching anything if: the MongoDB address THIS COMMAND was told about is
  not local (loopback, or the `mongodb` compose-network container alias —
  never a remote event store); a `--mongodb-url` argument carries embedded
  credentials (secrets never belong on argv); or — checked separately,
  right before the push — the running backend container's OWN
  `$MONGODB_URL` (read from inside the container, host only, never the
  full URL, so nothing credential-bearing ever reaches this process's own
  argv/stdout/logs) is missing, unreadable, or not local either. The two
  checks are independent on purpose: the address this command was told
  about and the address the container will actually use when `prisma db
  push` runs inside it can legitimately differ. It never passes
  `--accept-data-loss` or any other data-loss-accepting flag — if Prisma
  itself judges a change destructive it refuses non-interactively rather
  than forcing it through, and it is idempotent (a no-op re-run is a
  no-op).

---

## 8. Health checks (AXI-1974, FR60)

Three routes exist on both the gateway and organization-service for
different purposes — do not point a liveness probe at a readiness route or
vice versa:

| Route | What it does | Touches the database? | Status codes |
|---|---|---|---|
| `GET /health` | general health — same shape as `/health/ready` today | yes | 200 healthy / 503 degraded |
| `GET /health/live` | pure process liveness — "is the process alive enough to answer HTTP at all" | **no** — zero-cost, no RPC, no DB round trip | always 200 `{status:'ok'}` |
| `GET /health/ready` | readiness — are this service's real dependencies (DB reachable, schema at the expected migration) actually OK right now | yes | 200 ready / 503 not ready |

- **Gateway** (`apps/gateway/src/health/health.controller.ts`): `@SkipThrottle()`
  on the whole controller (health checks must never be rate-limited).
  `/health` and `/health/ready` fan out over RPC to `USER_SERVICE`,
  `EVENT_SERVICE`, `ORGANIZATION_SERVICE`, and (only if
  `controlPlane.healthEnabled` is configured on, off by default — "no SQL
  database the gate migrates and no place it is deployed today"; production
  compose has no `CONTROL_PLANE_*` wiring) `CONTROL_PLANE_SERVICE`.
- **Organization-service** (`apps/organization-service/src/health/health.controller.ts`):
  `/health` and `/health/ready` both run a real check — a trivial Postgres
  query under a `SET LOCAL statement_timeout`, plus a schema-version check
  against the applied migration ledger — coalesced per-process via a
  single-flight query so concurrent health polls do not multiply database
  load. `/health/live` deliberately makes **no** database call at all —
  exactly the liveness/readiness split FR60 asks for. The same `evaluate()`
  backs an RPC `@MessagePattern` the gateway calls.
- **`resolveServiceHealth()`** (`apps/gateway/src/health/resolve-service-health.ts`)
  is the one place an RPC-reported `<service>.health` payload becomes the
  gateway's own readiness fact. Only two reasons a service may self-report
  are trusted: `database_unreachable`, `schema_behind`. Anything the gateway
  cannot trust is synthesized by the gateway itself, never passed through:
  `unreachable` (malformed/untrusted payload) or `unexpected_responder`
  (the payload named a different service than the one asked) — never `ok`
  on a shape the gateway did not ask for.

## 9. What the next approved `terraform apply` will change

(From the AXI-1950/1951 learnings — **described, never run** by this epic.)

- `aws_s3_object` publishing of the on-box asset bundle in both
  `compute-ec2` and `compute` (Lightsail) modules, including three new
  objects for the Mongo backup timer unit (`mongo-backup.service`,
  `.timer`, plus the script itself) — the Lightsail module gains the
  `mongo_backup_script` object it was previously missing.
- `aws_db_event_subscription.rds_auto_restart` (new, `modules/alerting`) —
  an alert on AWS's own 7-day auto-restart of a stopped RDS instance.
- The rendered `user_data` on the EC2 compute module changes (the systemd
  `ExecStart` now points at `/opt/axiome/scripts/boot.sh`, cloud-init
  bootstraps the on-box layout). **Production is configured for the EC2
  module** (`environments/production/terraform.tfvars`: `use_ec2_compute =
  true`, `use_legacy_stack = false`), which sets
  `user_data_replace_on_change = false`: the instance is not replaced, and
  an existing box does not re-run cloud-init, which is why §1's one-time
  conversion is manual. In the Lightsail module (`use_legacy_stack = true`,
  the variable's default, not used by production) ANY cloud-init change
  destroys and recreates the instance. After this one change, on-box file
  updates happen entirely through `aws_s3_object` + `asset-sync.sh pull` —
  no further `user_data` changes are expected from future on-box file
  additions.
- `terraform-cd` is currently **red at `terraform fmt -check`** on
  `modules/compute/main.tf` (alignment of `NODE_ENV`/`PORT`), independent of
  this epic (confirmed red before any AXI-1944 commit) — no production plan
  or apply has run since. **No story in this epic may fix that formatting as
  a side effect** — doing so re-arms the production plan and queues an apply
  for the owner's (`fmguimaraes`) approval; that is the owner's call, not an
  incidental fix.

---

## 10. Consolidated exit codes, every operator script

A quick-reference table, gathered from each script's own header/contract
(detailed meanings and refusal text are in the sections above — this is
the "what number did I just get" lookup):

Each row is read from the script's own `exit`/`return N` statements, not
from memory. `tests/doc-truth.bats`'s `UT-INFRA-633` derives each script's codes
mechanically (`grep -oE "(exit|return) [0-9]+"`, or the `LOCK_RC_*`
constants for `lock.sh`) and cross-checks them against this table's
columns for `scripts/asset-sync.sh`, `scripts/ssm-exec.sh`,
`scripts/deploy-prod.sh`, `scripts/lock.sh`, and
`scripts/seed-environment.sh`, so those five cannot drift silently again.
`providers/aws/onbox/mongo-backup.sh` and `tests/run-shellcheck.sh` are
excluded from that mechanical check: `mongo-backup.sh` documents an
OK/any-failure contract, not per-numeric-code columns — it also exits
`130`/`143` on signals, still just "failed", nothing branches on which
nonzero code — so a column-equality check would be forcing a mapping the
script itself doesn't make; `run-shellcheck.sh`'s success path never calls
a literal `exit 0`/`return 0` (it falls through normally), so "0" cannot
be found by the same grep that finds its "2".

| Script | `0` | `1` | `2` | `3` | `4` | `5` | `6` | `7` |
|---|---|---|---|---|---|---|---|---|
| `scripts/asset-sync.sh` (pull) | installed/current/repaired | usage error | fetch failure | checksum mismatch | compose validation failure | unsafe manifest path (FR48) | install failed partway, restored (FR49) | staging-dir creation failure |
| `scripts/ssm-exec.sh` | success (terminal `Success`) | real failure (`Failed`/`Cancelled`/`TimedOut`) | INDETERMINATE (wait expired, command cancelled) | — | — | — | — | — |
| `scripts/deploy-prod.sh` | success, or a dry run | every FAIL-CLOSED refusal (SSM/box/snapshot/roll/readiness/`:stable`-advance failures) | usage/argument error, including the `--tag` shape refusal (not shaped like an 8-lowercase-hex image tag) | — | — | — | — | — |
| `scripts/lock.sh` | success (`FREE`/acquired/released/overridden) | HELD (status, or acquire found it already held) | UNKNOWN — could not be determined (network/access/bad input/CLI too old/missing jq/unparseable lock body); never treated as acquired or free (fail-closed) | REFUSED — release/override refused (not the holder, lock already free, missing `--reason`/`--confirm`, unwritable audit report, or a secret-shaped `--operation`/`--reason`) | — | — | — | — |
| `scripts/seed-environment.sh` (`--check`) | counts match (`BASELINE CHECK OK`) | usage error, OR a mismatch (`BASELINE CHECK MISMATCH`) — both exit `1`, there is no separate exit `2` | — | expected counts could not be derived — `BASELINE CHECK NOT PERFORMED` (not a mismatch; check mode only) | — | — | — | — |
| `providers/aws/onbox/mongo-backup.sh` | `MONGO_BACKUP_OK` | `MONGO_BACKUP_FAILED` (any failure reason, including the control-character refusal) | — | — | — | — | — | — |
| `tests/run-shellcheck.sh` (`_ensure_pinned_shellcheck`, AXI-1977) | cache verified / freshly fetched and verified | — | cached binary missing or mismatched its recorded checksum, or any other fetch/verify/preflight failure — refuses closed | — | — | — | — | — |

**Source lines for each code above** (so this table can be re-verified
against the script, not against this table):
- `scripts/lock.sh`: `readonly LOCK_RC_OK=0`, `LOCK_RC_HELD=1`,
  `LOCK_RC_UNKNOWN=2`, `LOCK_RC_REFUSED=3` (header comment + constants,
  `scripts/lock.sh`). Its CLI entry point's own preflight
  (`gnu_date_check || exit 1`) is a literal `exit 1` unrelated to any lock
  state — the one place this script exits `1` for something that is not
  "HELD" (noted so a reader does not assume `1` always means HELD at the
  CLI layer).
- `scripts/deploy-prod.sh`: exit `0` at the dry-run/help/final-success
  lines; exit `1` at every `FAIL-CLOSED`/restore-failure line (SSM
  preflight, `.env` missing, snapshot, roll INDETERMINATE/failed,
  readiness, `:stable` advance, lock-acquire failure); exit `2` at the
  unknown-argument, bad `--env`/`--service`/`--tag` value branches
  (the `--tag` shape check is one of these — confirmed via Read of its
  `case "${TAG}" in` block, whose first arm is the bash glob pattern
  `[0-9a-f]` repeated eight times, i.e. eight lowercase hex characters;
  `{8}` is a regex-quantifier shorthand that does not apply to a bash
  `case` glob and is not how the source is written).
- `scripts/seed-environment.sh`: exit `0` only at `-h|--help`; exit `1` at
  the unknown-argument/bad-`-e`-value/`compose_resolve`-failure branches
  AND at the mismatch branch (`if [ "${FAILED}" -ne 0 ]; then ... exit 1;
  fi`, both check and non-check mode); exit `3` only in check mode, only
  when expected counts could not be derived (`BASELINE CHECK NOT
  PERFORMED`). There is no exit `2` anywhere in this script.
- `tests/run-shellcheck.sh`: `_ensure_pinned_shellcheck`'s every failure
  branch (missing/mismatched sidecar, unsupported platform, missing
  `curl`, tarball checksum mismatch) uses `exit 2`; the caller's normal
  gate failure (a new shellcheck finding) is a separate, later exit path
  not part of this function's contract and not tabulated here.

`scripts/migrate-gate` (the gate binary itself, from `axiome-back` —
documented here because every caller above branches on it) uses `0` for a
clean/already-applied result and non-zero for every refusal shape in §2;
its exact per-reason codes are that other repo's contract, not
independently re-specified here.

## 11. Known gaps

- AXI-1968 added `axiome-back`/`axiome-bio-compute`/`axiome-front` checkouts
  and `AXIOME_BACK_PATH` to `deploy-production.yml` (FR45/AC37), so
  `seed-environment.sh --check`'s baseline verification now has a real
  `axiome-back` checkout to read expected counts from in that workflow —
  "Baseline verification: NOT PERFORMED" is no longer the routine,
  structural result there; it should now show `OK`/`MISMATCH` like a local
  run. It remains the correct, honest result whenever `AXIOME_BACK_PATH`
  genuinely isn't available (e.g. a caller that only checks out
  `axiome-infra`), per FR46/AC38.
- `install-mongo-backup-timer.sh` has never been run against a real box.
- Nothing in this runbook — box conversion, baselining, deploy, roll,
  park/unpark, locks — has been exercised against live AWS. Every behaviour
  above is proven by the shell scripts' own logic and this repo's offline,
  stubbed bats suite (`tests/run.sh`), never a real `terraform apply`, SSM
  command, or AWS mutation. Treat every exit code / refusal message above as
  "what the code says it does", not as field-verified.
- Shellcheck is now **pinned** (§0), so the old "local vs CI version skew"
  gap this bullet used to name no longer applies — the remaining risk is
  narrower: a corrupted or stale/foreign cached binary is caught
  (fail-closed, §0) — this is a corruption/integrity check, not a security
  control against someone who can write to the cache directory — but a
  contributor who deletes `${SHELLCHECK_CACHE_DIR}` and is offline cannot
  run the check at all until connectivity returns (fails closed to "cannot
  determine", not to "assume clean").

## 12. Not yet done / operator acts before first live use (AXI-1977)

Facts only — this section states what has and has not actually happened,
not what the code is capable of:

- **Nothing in this epic has been run against real AWS or a real GitHub
  Actions deploy.** Every refusal message, exit code,
  and sequence described in this runbook is verified by reading the
  current script source and by this repo's own offline stubbed bats suite
  — never by a live `terraform apply`, SSM command, deploy run, or AWS
  mutation.
- **Box conversion (§1) and the user-service baseline (§2's baselining
  procedure, for whichever service still lacks a migration ledger) are both
  owed, operator acts, not yet done against any real box.**
- **The Mongo backup systemd timer is not installed anywhere**
  (`install-mongo-backup-timer.sh`, §6) — backups today happen only via
  `power.sh down`'s pre-stop backup-and-verify step and whatever cron
  already exists on the box; the "catches up a missed run" guarantee only
  starts once an operator runs the installer against a real box.
- **The next approved `terraform apply` changes the production EC2
  `user_data` but should not replace the instance.** Production's tfvars
  select the EC2 compute module (`use_ec2_compute = true`,
  `use_legacy_stack = false`), which sets `user_data_replace_on_change =
  false`. An earlier version of this section said the apply would recreate
  a Lightsail instance; that is true only of the Lightsail module
  (`aws_lightsail_instance.main` carries `replace_triggered_by =
  [terraform_data.user_data_hash]`), which production does not use. Neither
  statement has been checked against the AWS account or a real plan: read
  the plan before approving, and do not approve one that replaces the
  instance.
- **Control-plane health checks are skipped in production until wired.**
  The gateway only calls `CONTROL_PLANE_SERVICE` for `/health`/`/health/ready`
  when `controlPlane.healthEnabled` is configured on (§8); it is off by
  default and production's compose configuration carries no
  `CONTROL_PLANE_*` wiring today, so this is a dormant, not-yet-enabled
  check, not a live gap in an existing check.
- **Cloud-init writes `.env` in plaintext on the box** (§1's conversion,
  `providers/aws/cloud-init/init.sh.tftpl`): it fetches runtime config from
  SSM Parameter Store into `/opt/axiome/.env`, then `chmod 600`s it
  (root-only). The weakness this records: the secret material lives on disk
  in plaintext (not just in SSM) for as long as the box exists, readable by
  anything running as root on that box (including a compromised container
  with a host mount, or an operator debugging session) — `chmod 600`
  narrows who can read the file but does not change that it is unencrypted
  at rest. This is the same pattern already named for Scaleway/on-prem in
  `providers.md`'s secrets row (`.env` file, root-only) — it is not unique
  to AWS; it is recorded here as a fact an operator should know before
  relying on this box.
- **What triggers a backend image build/promotion:** a fully green
  `CI — Backend` run on `axiome-back` main — `test`,
  `migrate-from-scratch` (per service), and `livedb-constraints`
  (organization-service) must ALL pass before `Build, Push & Notify` /
  `Scan Image & Resolve Digest` / `Promote backend to staging/production`
  run.
  - **Unmerged branch `AXI-1976-livedb-harness`** (`axiome-back`, head
    `8b1f6a18`, not merged — verified `git -C axiome-back merge-base
    --is-ancestor origin/AXI-1976-livedb-harness origin/main` exits
    non-zero) fixes `livedb-constraints`'s missing `?schema=organization_svc`
    query parameter. Left unmerged on purpose, so this epic's stories could
    not themselves trigger a backend build/promotion — merging is the
    owner's decision.
  - **Dated observation (2026-10-11, run `38088676928`, headSha
    `161239b3`):** the `test` job failed on `user-service`'s
    `admin-bootstrap.service.spec.ts` (5000ms Jest timeout — not
    investigated further; `axiome-back` is outside `axiome-infra`'s repo
    boundary). The same
    run's `livedb-constraints` job failed exactly the way
    `AXI-1976-livedb-harness` fixes.
  - **Before merging:** confirm `test` is independently green (the harness
    fix alone does not fix `test`), rule out the Jest timeout as a genuine
    regression, then merge and confirm `livedb-constraints` goes green —
    re-check `CI — Backend` on `axiome-back` main directly
    (`gh run list -R <org>/axiome-back`) before trusting any of this as
    current.
- **`terraform fmt -check` on `providers/aws/modules/compute/main.tf` is
  left failing on purpose (§9)** — fixing it re-arms a production Terraform
  plan/apply that no story in this epic is authorized to trigger; this is
  the owner's (`fmguimaraes`) decision to make, not a formatting fix to
  slip in. **Not fixed**, per the same instruction that
  scoped it out of every debt-closure story in this epic.

## 13. Manual validation scenarios (not run — the runbook text itself is the deliverable here, not a live exercise of it)

Every scenario below is **manual/deferred** — none has been run against a
real box or real AWS (see §12). Each names the exact command
and the documented message/exit code an operator should see, so a future
operator or QA pass can walk this list against a real environment and
confirm the runbook is still true:

1. **A blocked operation under each lock holder** (apply vs deploy vs
   park) — manual/deferred: (a) with `apply` held, run `power.sh <env>
   down` and confirm the verbatim `ABORT: the apply lock for ${ENV} is
   held…` message (§4); (b) with `apply` held, run `power-data.sh <env>
   down` and confirm it releases the data-tier lock it just took and
   prints the matching ABORT; (c) with `deploy` held, start a second
   `deploy-prod.sh` and confirm the `FAIL-CLOSED: could not acquire the
   deploy lock…` refusal (§3); (d) with `data-tier` held (parked), run
   `deploy-prod.sh` and confirm it refuses before any mutation (§3 step 1).
2. **Stale-lock inspection and override** — manual/deferred: `scripts/lock.sh
   <env> status` to see a `HELD by … (age …s)` line, then `scripts/lock.sh
   <env> override <name> --reason "<text>" --confirm` and confirm the
   dated audit report is written before deletion (§4); separately confirm
   `override --reason "password=x"` is ABORTED and the lock is NOT deleted.
3. **Index-sync refusal on a non-local host** — manual/deferred:
   `scripts/sync-event-store-indexes.sh --mongodb-url
   mongodb://some-remote-host/db …` and confirm it refuses before touching
   anything (§7).
4. **`--tag` refusal** — manual/deferred: run the `deploy-production.yml`
   workflow (or `deploy-prod.sh` directly) with a malformed `--tag` (e.g.
   `not-a-sha`) and confirm the exact 8-lowercase-hex refusal message (§3);
   separately with a secret-shaped value and confirm the value is withheld.
5. **Seed refusal without `--confirm production`** — manual/deferred:
   `make seed-env ENV=production` and `scripts/seed-environment.sh -e
   production` (no `--confirm`) and confirm the `SEED REFUSED` message,
   then `scripts/seed-environment.sh -e production --confirm production`
   to confirm the write path actually proceeds (§3).
6. **Baseline verification `NOT PERFORMED`** — manual/deferred: run
   `deploy-prod.sh`/`deploy-production.yml` in a context where
   `AXIOME_BACK_PATH`/the `axiome-back` checkout is unavailable and confirm
   `Baseline verification: NOT PERFORMED` (not a mismatch) is reported (§3).
7. **Backup timer install and a backup run** — manual/deferred:
   `install-mongo-backup-timer.sh <env>` against a real, asset-sync-converted
   box, then confirm `mongo-backup.timer`'s `OnCalendar=daily,
   Persistent=true` catches up a missed run on box start, and that a
   manual/triggered run emits `MONGO_BACKUP_OK key=… sha256=…` (§6) —
   never done against a real box as of this writing.
8. **`asset-sync.sh` exit 6 and 7** — manual/deferred: exit `6` (install
   failed partway, restored) needs an injected failure mid-install (e.g. a
   permission-denied on one target file) and a check that every already-
   replaced file in that run was restored to its previous copy; exit `7`
   (could not create a staging directory) needs forcing 20 consecutive
   name collisions against a real filesystem — both are described from the
   script's own logic and this repo's stubbed bats suite, never exercised
   against a real filesystem failure mode (§1/§10).
9. **A retired-docs link check** — manual/deferred: click/curl every
   relative link in the retired-provider banners (e.g.
   `README.md` → `docs/platform-lifecycle-operations.md`,
   `docs/providers.md#retired--not-yet-deployed-providers`,
   `providers/scaleway/README.md` → `../aws/README.md`) and confirm each
   resolves to the intended anchor/file in a rendered (GitHub) view, not
   just a path that exists on disk (UT-INFRA-387 only checks the latter).
10. **The `compute` lock (FR43, AXI-1981)** — manual/deferred:
    (a) with `deploy` held, run `power.sh <env> down` and confirm it
    acquires then releases `compute` and refuses, naming `deploy`; repeat
    for `power.sh <env> up`; (b) with `apply` held, repeat (a) for both
    `down` and `up`, naming `apply`; (c) with `compute` held (a `power.sh`
    run in progress), start `deploy-prod.sh` and confirm it refuses at the
    initial lock acquire, naming `compute`; (d) with `compute` held,
    separately start a `terraform-cd` apply and confirm the "Acquire apply
    lock" step refuses, naming `compute`; (e) with `compute` held, run
    `power-data.sh <env> down` and confirm it releases the data-tier lock
    it just took and refuses, naming `compute`; (f) start `power.sh <env>
    up` while a `power-data.sh <env> down` (park) is genuinely in progress,
    or while already parked, and confirm the EXPECTED, ACCEPTABLE overlap
    from §4: the instance starts but the readiness poll fails (the app
    cannot reach a stopped/deleted RDS/Redis), exiting non-zero with
    `compute` released — not a corrupted state; (g) with a `compute` lock
    stale from a dead run, confirm `scripts/lock.sh <env> status compute`
    shows `HELD by … (age …s)`, then (only once the holder is confirmed
    dead) `scripts/lock.sh <env> override compute --reason "<text>"
    --confirm` clears it and a subsequent `power.sh <env> up` proceeds;
    (h) run `power-up-all.sh <env> --yes` end to end against a real
    environment and confirm each lock (`data-tier`, then `compute`) is
    acquired and released in turn, never both held at once, per §4/§6.
