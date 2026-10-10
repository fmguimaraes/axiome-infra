#!/usr/bin/env bats
# tests/pull-on-vm.bats — scripts/pull-on-vm.sh (AXI-1953, epic AXI-1944,
# FR13/AC27). UT-INFRA-301..305.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pull-on-vm.sh"

setup() {
  stub_setup
  export INSTANCE_IP="203.0.113.10"
  export LIGHTSAIL_SSH_KEY="${BATS_TEST_TMPDIR}/key.pem"
  : > "$LIGHTSAIL_SSH_KEY"
  chmod 600 "$LIGHTSAIL_SSH_KEY"
  stub_use_rules ssh "${TESTS_DIR}/fixtures/pull-on-vm-ssh.rules.sh"
}

# UT-INFRA-301 — `pull-on-vm.sh production` refuses and never calls ssh
# (FR13/AC27 — no ungated start path for production).
@test "UT-INFRA-301: pull-on-vm.sh refuses production" {
  run "$SCRIPT" production
  assert_failure
  assert_output --partial "REFUSE"
  assert_output --partial "roll-service.sh"
  assert_stub_not_called ssh
}

# UT-INFRA-302 — `pull-on-vm.sh staging` refuses the same way.
@test "UT-INFRA-302: pull-on-vm.sh refuses staging" {
  run "$SCRIPT" staging
  assert_failure
  assert_output --partial "REFUSE"
  assert_stub_not_called ssh
}

# UT-INFRA-303 — `pull-on-vm.sh dev` proceeds and connects over ssh.
@test "UT-INFRA-303: pull-on-vm.sh dev proceeds over ssh" {
  run "$SCRIPT" dev
  assert_success
  assert_output --partial "Connecting to"
  assert_stub_called ssh "${INSTANCE_IP}"
}

# UT-INFRA-304 — an unknown environment name is still rejected.
@test "UT-INFRA-304: pull-on-vm.sh rejects an unknown environment" {
  run "$SCRIPT" nonsense
  assert_failure
  assert_output --partial "must be dev"
  assert_stub_not_called ssh
}

# UT-INFRA-305 — no argument is a usage error, no ssh call.
@test "UT-INFRA-305: pull-on-vm.sh with no argument is a usage error" {
  run "$SCRIPT"
  assert_failure
  assert_output --partial "Usage:"
  assert_stub_not_called ssh
}
