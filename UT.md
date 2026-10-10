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
