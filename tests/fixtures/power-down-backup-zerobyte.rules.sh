# shellcheck shell=bash
# Fixture for the aws stub — power.sh <env> down, backup OK line parses, but
# the object's own ContentLength is 0 (never trust a zero-byte object).
# stop-instances/wait are deliberately NOT matched — any call to either is
# itself the proof the freshness/integrity check was skipped.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"sts"*"get-caller-identity"*)
      echo "arn:aws:iam::111111111111:user/test-actor"
      return 0
      ;;
    *"describe-instances"*"InstanceId"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"describe-instances"*"State.Name"*)
      echo "running"
      return 0
      ;;
    *"ssm"*"send-command"*)
      echo "cmd-ok-1"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"Status"*)
      echo "Success"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardOutputContent"*)
      echo "MONGO_BACKUP_OK key=backups/mongo/20261010T020000Z.archive.gz sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      return 0
      ;;
    *"ssm"*"get-command-invocation"*"StandardErrorContent"*)
      return 0
      ;;
    *"s3api"*"head-object"*"backups/mongo/20261010T020000Z.archive.gz"*)
      echo '{"ContentLength":0,"LastModified":"2030-01-01T00:00:00+00:00","Metadata":{"sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}'
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
