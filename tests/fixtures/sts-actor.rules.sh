# shellcheck shell=bash
# Fixture for the aws stub — `_report_actor`'s `aws sts get-caller-identity`
# call made by every report_init/log_event (tests/report.bats).
stub_respond() {
  case "$1" in
    *"sts get-caller-identity"*)
      echo "arn:aws:iam::123456789012:user/test-actor"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
