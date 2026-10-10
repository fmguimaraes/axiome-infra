# shellcheck shell=bash
# Fixture: aws CLI below lock.sh's minimum (2.17.34, the version that
# shipped conditional writes for PutObject — see aws-cli's CHANGELOG.rst).
# Deliberately has NO put-object arm — if acquire proceeds to call
# put-object anyway, that call is unconfigured and fails the test
# (UT-INFRA-103).
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"--version"*)
      echo "aws-cli/2.9.0 Python/3.9.2 Linux/5.10 exe/x86_64"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
