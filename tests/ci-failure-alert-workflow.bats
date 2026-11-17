#!/usr/bin/env bats
# tests/ci-failure-alert-workflow.bats — .github/workflows/ci-failure-alert.yml
# (AXI-2282, epic AXI-2280 CI Robustness, FR8/AC5, SI-041).
#
# UT-INFRA-900..902 are structural (python3 + yaml, like
# tests/dev-auto-promote-workflow.bats). UT-INFRA-903..907 extract the real
# github-script `script:` body and EXECUTE it with node against a mocked
# issues API (tests/fixtures/ci-failure-alert-harness.js) — proving the
# per-workflow open/comment/close behaviour, not just that the YAML parses.
#
# UT-ID range: AXI-2282 takes UT-INFRA-900..919 (well clear of the 8xx block in
# use on main at the time of writing) — flagged in the story handback.

load 'helpers/setup'

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/ci-failure-alert.yml"
HARNESS="${BATS_TEST_DIRNAME}/fixtures/ci-failure-alert-harness.js"

setup() {
  stub_setup
  SCRIPT_FILE="${BATS_TEST_TMPDIR}/alert-script.js"
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d['jobs']['main-ci-status']['steps'][0]['with']['script'])
" "$WORKFLOW" > "$SCRIPT_FILE"
}

teardown() {
  stub_teardown
}

py() {
  python3 -c "$1" "$WORKFLOW"
}

# run_alert <workflow name> <conclusion> <open-issues-json>
run_alert() {
  local scenario="${BATS_TEST_TMPDIR}/scenario.json"
  printf '{"run":{"name":"%s","conclusion":"%s","head_sha":"abc123","html_url":"https://x/run/1"},"issues":%s}' \
    "$1" "$2" "$3" > "$scenario"
  run node "$HARNESS" "$SCRIPT_FILE" "$scenario"
}

@test "UT-INFRA-900 watches every push-on-main workflow of this repo by its exact name" {
  run py "
import sys, yaml, glob, os
d = yaml.safe_load(open(sys.argv[1]))
watched = set(d[True]['workflow_run']['workflows'])
wfdir = os.path.dirname(sys.argv[1])
names = set()
for f in glob.glob(os.path.join(wfdir, '*.yml')):
    w = yaml.safe_load(open(f))
    push = (w.get(True) or {}).get('push') or {}
    if 'main' in (push.get('branches') or []):
        names.add(w['name'])
assert watched == names, (watched, names)
assert d[True]['workflow_run']['types'] == ['completed']
"
  [ "$status" -eq 0 ]
}

@test "UT-INFRA-901 only reacts to main push runs (no PR / dispatch / branch runs)" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cond = d['jobs']['main-ci-status']['if']
assert \"head_branch == 'main'\" in cond and \"event == 'push'\" in cond, cond
"
  [ "$status" -eq 0 ]
}

@test "UT-INFRA-902 least privilege: issues write + contents read only" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['permissions'] == {'issues': 'write', 'contents': 'read'}, d['permissions']
"
  [ "$status" -eq 0 ]
}

@test "UT-INFRA-903 a red run with no open issue opens a per-workflow ci-failure issue" {
  run_alert "infra-tests" "failure" '[]'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
calls = json.load(sys.stdin)
assert [c['op'] for c in calls] == ['create'], calls
assert calls[0]['title'] == '🔴 main CI is failing: infra-tests' and calls[0]['labels'] == ['ci-failure']
"
}

@test "UT-INFRA-904 a red run with its own issue open comments instead of opening a second" {
  run_alert "infra-tests" "timed_out" '[{"number":7,"title":"🔴 main CI is failing: infra-tests"}]'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
calls = json.load(sys.stdin)
assert [c['op'] for c in calls] == ['createComment'] and calls[0]['issue_number'] == 7, calls
"
}

@test "UT-INFRA-905 a green run closes only ITS workflow's issue, never another workflow's" {
  run_alert "Secrets Check" "success" \
    '[{"number":7,"title":"🔴 main CI is failing: infra-tests"},{"number":8,"title":"🔴 main CI is failing: Secrets Check"}]'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
calls = json.load(sys.stdin)
assert {c.get('issue_number') for c in calls} == {8}, calls
assert any(c['op'] == 'update' and c['state'] == 'closed' for c in calls)
"
}

@test "UT-INFRA-906 startup_failure (e.g. Actions refusing jobs) counts as red" {
  run_alert "terraform-cd" "startup_failure" '[]'
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
assert [c['op'] for c in json.load(sys.stdin)] == ['create']
"
}

@test "UT-INFRA-907 a cancelled run neither opens nor closes anything" {
  run_alert "infra-tests" "cancelled" '[{"number":7,"title":"🔴 main CI is failing: infra-tests"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
