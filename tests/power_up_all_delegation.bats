#!/usr/bin/env bats
# tests/power_up_all_delegation.bats — providers/aws/scripts/power-up-all.sh
# cannot bypass the FR42/FR43 mutual-exclusion rule (AXI-1967): it never
# mutates RDS/Redis/EC2 directly — every mutating action goes through
# power-data.sh or power.sh, both of which already enforce the rule
# (tests/power_data_down.bats, power_data_up.bats, power_down_backup.bats).
# This is a structural proof (grep), not an execution — see UT-INFRA-427.

load 'helpers/setup'

SCRIPT="${BATS_TEST_DIRNAME}/../providers/aws/scripts/power-up-all.sh"

setup() {
  stub_setup
}

# UT-INFRA-427: no `aws rds|ec2|elasticache <mutating-verb>` call appears in
# power-up-all.sh at all — its only two calls into those services
# (`aws elasticache describe-replication-groups`, `aws elasticache
# describe-snapshots`, `aws s3 ls/cp`) are read-only preflight checks; the
# actual RDS/Redis/EC2 start calls live exclusively in power-data.sh/power.sh
# (both already lock-guarded), and power-up-all.sh only ever calls `up`,
# never `down`, on either.
@test "UT-INFRA-427: power-up-all.sh contains no direct mutating RDS/EC2/Redis call, only delegation" {
  run grep -En "aws (rds (start|stop|create|delete|modify)|ec2 (start|stop|terminate)|elasticache (create|delete|modify))" "$SCRIPT"
  assert_failure

  run grep -c '"\${HERE}/power-data.sh" "\$ENV" up' "$SCRIPT"
  assert_output "1"
  run grep -c '"\${HERE}/power.sh" "\$ENV" up' "$SCRIPT"
  [ "$output" -ge 1 ]

  # power-up-all.sh must never itself call `down` on either script.
  run grep -c ' down' "$SCRIPT"
  assert_output "0"
}
