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
    # AXI-1977 Part 3: these three used to be left SCRIPT-ONLY because the
    # runbook genuinely didn't carry the quote verbatim yet (a case
    # mismatch for the first, missing entirely for the other two — see the
    # AXI-1977 edits to docs/platform-lifecycle-operations.md §4/§6). Now
    # real, dual-checked entries like everything else in this array.
    "scripts/lock.sh|has no automatic release by ANY route"
    "providers/aws/scripts/power.sh|ABORT: backup not verified; compute NOT stopped"
    "providers/aws/scripts/power-data.sh|ABORT: could not acquire the data-tier lock"
    # AXI-1977 Part 2 additions — every new verbatim message/exit code the
    # runbook now quotes, checked against its own script source.
    "providers/aws/scripts/power.sh|ABORT: the apply lock for \${ENV} is held — refusing to stop compute while a Terraform apply is in progress."
    "providers/aws/scripts/power-data.sh|ABORT: the apply lock is held — releasing the data-tier lock just acquired and refusing to park while a Terraform apply is in progress."
    "providers/aws/scripts/power-data.sh|ABORT: the apply lock for \${ENV} is held — refusing to start/recreate the data tier while a Terraform apply is in progress. Re-run '\$0 \${ENV} up' once the apply finishes."
    "providers/aws/scripts/power-data.sh|ABORT: the apply lock is held — refusing to unpark while a Terraform apply is in progress. The data-tier lock itself is untouched (it is this park's own lock)."
    "scripts/lock.sh|ERROR: acquire of '\${name}' REFUSED — the given --operation resembles a secret-shaped string"
    "scripts/lock.sh|ERROR: lock_mark_for_auto_release refuses 'data-tier' (FR29)"
    "providers/aws/onbox/mongo-backup.sh|ERROR: MONGO_ROOT_PASSWORD contains a newline, a carriage return, or another control character"
    "providers/aws/onbox/mongo-backup.sh|MONGO_BACKUP_OK key="
    "providers/aws/onbox/mongo-backup.sh|MONGO_BACKUP_FAILED"
    "scripts/deploy-prod.sh|The given value also looks secret-shaped, so it is not printed here"
    "scripts/deploy-prod.sh|expected exactly 8 lowercase hex characters, e.g. 'a1b2c3d4'"
    # §3's Locks table quotes this deploy-lock-acquisition refusal verbatim.
    "scripts/deploy-prod.sh|could not acquire the deploy lock for \${ENV}, or the data-tier/apply lock is held"
  )
  # The runbook's own text, markdown-stripped and whitespace-collapsed —
  # this, not a copy in this test, is what each dual-checked needle is
  # checked against.
  local runbook_text
  runbook_text="$(perl -0777 -pe 's/[`*]//g; s/\s+/ /g' "${INFRA_ROOT}/docs/platform-lifecycle-operations.md")"

  local e script needle missing_script="" missing_runbook=""
  for e in "${entries[@]}"; do
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

# UT-INFRA-633 — §10's consolidated
# exit-code table must agree with each script's own literal exit/return
# codes, mechanically, in both directions — every code the table lists for
# a script must exist in that script, and every distinct literal code the
# script uses must appear in the table. Derived straight from source
# (`grep -oE '(exit|return) [0-9]+'`, or lock.sh's own LOCK_RC_* constants)
# — never copied from the table, so this cannot drift silently again.
# `providers/aws/onbox/mongo-backup.sh` and `tests/run-shellcheck.sh` are
# deliberately NOT in this list (see the runbook's §10 note on why their
# codes cannot be mapped onto the table's per-column scheme mechanically).
@test "UT-INFRA-633: §10's exit-code table matches each script's own exit/return codes" {
  local doc="${INFRA_ROOT}/docs/platform-lifecycle-operations.md"

  # script-path-fragment-as-it-appears-in-the-table-row -> real script path
  local -A table_key_to_path=(
    ["scripts/asset-sync.sh"]="scripts/asset-sync.sh"
    ["scripts/ssm-exec.sh"]="scripts/ssm-exec.sh"
    ["scripts/deploy-prod.sh"]="scripts/deploy-prod.sh"
    ["scripts/lock.sh"]="scripts/lock.sh"
    ["scripts/seed-environment.sh"]="scripts/seed-environment.sh"
  )

  local key path table_codes script_codes mismatch=""
  for key in "${!table_key_to_path[@]}"; do
    path="${table_key_to_path[$key]}"

    # Table side: the one row starting with "| `<key>`" (allowing a
    # trailing " (...)" annotation before the next "|"), split on "|",
    # columns 2..9 are codes 0..7 — non "—" cells are codes this table
    # claims the script uses.
    run awk -F'|' -v key="$key" '
      /^## 10\. / { in_section = 1 }
      /^## 11\. / { in_section = 0 }
      in_section && $0 ~ "^\\| `" key "`" {
        for (i = 3; i <= 10; i++) {
          cell = $i; gsub(/^[ \t]+|[ \t]+$/, "", cell)
          if (cell != "" && cell != "\xe2\x80\x94") print (i - 3)
        }
        exit
      }
    ' "$doc"
    assert_success
    table_codes="$(printf '%s\n' "$output" | sort -un | tr '\n' ' ')"
    [ -n "$(printf '%s' "$output")" ] || fail "no §10 row found for ${key} — table row missing or key changed"

    # Script side: lock.sh's codes are its RC constants (it mostly
    # `return`s them from a sourced library; its CLI entry's own
    # `gnu_date_check || exit 1` is a documented, named exception, not part
    # of this set-equality check). Every other script's codes are its own
    # literal `exit N`/`return N` statements.
    if [ "$path" = "scripts/lock.sh" ]; then
      run grep -oE 'readonly LOCK_RC_[A-Z]+=[0-9]+' "${INFRA_ROOT}/${path}"
      assert_success
      script_codes="$(printf '%s\n' "$output" | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')"
    else
      run grep -oE '(exit|return) [0-9]+' "${INFRA_ROOT}/${path}"
      assert_success
      script_codes="$(printf '%s\n' "$output" | awk '{print $2}' | sort -un | tr '\n' ' ')"
    fi

    if [ "$table_codes" != "$script_codes" ]; then
      mismatch="${mismatch}\n  ${key}: table={${table_codes}} script={${script_codes}}"
    fi
  done
  [ -z "$mismatch" ] || fail "§10 exit-code table disagrees with script source:$(printf '%b' "$mismatch")"
}

# UT-INFRA-634 — every internal
# `](#anchor)` link in the runbook must resolve to a real `## N. Heading`
# in the same file. Anchors are computed with the same algorithm GitHub's
# own heading slugger uses (lowercase, strip anything that is not a word
# character/hyphen/space, spaces -> hyphens) — never hand-copied — so a
# heading rename that breaks a link fails here instead of silently 404ing.
@test "UT-INFRA-634: every internal anchor link in the runbook matches a real heading" {
  local doc="${INFRA_ROOT}/docs/platform-lifecycle-operations.md"
  run python3 -c "
import re, sys
doc = open('${doc}').read()
headings = re.findall(r'^## (.+)$', doc, re.MULTILINE)

def slug(h):
    s = h.lower()
    s = re.sub(r'[^\w\- ]', '', s)
    s = s.replace(' ', '-')
    return s

slugs = {slug(h) for h in headings}
anchors = re.findall(r'\]\(#([a-z0-9-]+)\)', doc)
missing = [a for a in anchors if a not in slugs]
if missing:
    print('missing: ' + ', '.join(sorted(set(missing))))
    sys.exit(1)
"
  assert_success
}

# UT-INFRA-635 — the same check, from every OTHER markdown file in the
# repo that links INTO platform-lifecycle-operations.md with an anchor
# (e.g. `docs/migration-authoring-guide.md`, `docs/deployment.md`,
# README files) — a heading rename in the runbook breaks these links too,
# and they are easy to miss because the broken half lives in a different
# file.
@test "UT-INFRA-635: every cross-file link into the runbook's anchors matches a real heading" {
  run python3 -c "
import re, sys, glob, os

infra_root = '${INFRA_ROOT}'
runbook = os.path.join(infra_root, 'docs/platform-lifecycle-operations.md')
runbook_text = open(runbook).read()
headings = re.findall(r'^## (.+)$', runbook_text, re.MULTILINE)

def slug(h):
    s = h.lower()
    s = re.sub(r'[^\w\- ]', '', s)
    s = s.replace(' ', '-')
    return s

slugs = {slug(h) for h in headings}

missing = []
for path in glob.glob(os.path.join(infra_root, '**/*.md'), recursive=True):
    if os.path.abspath(path) == os.path.abspath(runbook):
        continue
    text = open(path).read()
    # a markdown link whose target ends in platform-lifecycle-operations.md
    # (any relative path to it) followed by a #anchor fragment.
    for m in re.finditer(r'\]\(([^)]*platform-lifecycle-operations\.md)#([a-z0-9-]+)\)', text):
        anchor = m.group(2)
        if anchor not in slugs:
            missing.append('%s -> #%s' % (path, anchor))

if missing:
    print('missing: ' + ', '.join(sorted(set(missing))))
    sys.exit(1)
"
  assert_success
}
