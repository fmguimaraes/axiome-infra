#!/usr/bin/env bats
# tests/compose-structure.bats — structural assertions on
# providers/aws/onbox/docker-compose.yml (AXI-1950, epic AXI-1944 decision
# 4, FR10/FR27/AC7/AC18). UT-INFRA-154..158.
#
# Parsed with `python3 -c 'import yaml'` (pyyaml) — this host has no `yq`,
# and asserting structure needs no running docker engine, so the real YAML
# parse is used instead of the (stubbed-only-in-tests) docker binary.

load 'helpers/setup'

COMPOSE="${BATS_TEST_DIRNAME}/../providers/aws/onbox/docker-compose.yml"

setup() {
  stub_setup
}

py() {
  python3 -c "$1" "$COMPOSE"
}

# UT-INFRA-154 — the `migrate` service exists, runs the gate, and never
# restart-loops on failure (FR10).
@test "UT-INFRA-154: docker-compose.yml declares a migrate service with restart no" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
m = d['services']['migrate']
assert m['restart'] == 'no', m['restart']
assert m['command'] == ['migrate-gate', 'apply'], m['command']
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-155 — every backend service container (gateway, user-service,
# organization-service, event-service) depends on migrate completing
# successfully before it starts (FR10/AC7).
@test "UT-INFRA-155: every backend service depends on migrate completing successfully" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for svc in ('gateway', 'user-service', 'organization-service', 'event-service'):
    dep = d['services'][svc]['depends_on']['migrate']
    assert dep['condition'] == 'service_completed_successfully', (svc, dep)
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-156 — biocompute (a different schema/database) is NOT gated on
# migrate — only organization-service/user-service's schemas are in scope.
@test "UT-INFRA-156: biocompute does not depend on migrate" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
deps = d['services']['biocompute'].get('depends_on', {})
assert 'migrate' not in deps, deps
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-157 — every backend service container declares a healthcheck
# (FR27/AC18).
@test "UT-INFRA-157: every backend service declares a healthcheck" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for svc in ('gateway', 'user-service', 'organization-service', 'event-service'):
    hc = d['services'][svc].get('healthcheck')
    assert hc and hc.get('test'), (svc, hc)
print('OK')
"
  assert_success
  assert_output --partial "OK"
}

# UT-INFRA-158 — the gateway's container healthcheck still targets
# /health/live (AXI-1949 learning: /health or /health/ready would turn a
# degraded backing service into a gateway restart loop).
@test "UT-INFRA-158: the gateway healthcheck targets /health/live" {
  run py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
test = ' '.join(d['services']['gateway']['healthcheck']['test'])
assert '/health/live' in test, test
assert '/health/ready' not in test and not test.rstrip('/').endswith('/health')
print('OK')
"
  assert_success
  assert_output --partial "OK"
}
