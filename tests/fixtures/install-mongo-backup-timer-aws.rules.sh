# shellcheck shell=bash
# Fixture for the aws stub — install-mongo-backup-timer.sh's path through
# scripts/ssm-exec.sh: find the instance, send one command, poll it to
# Success immediately. Used only to prove the command TEXT sent is this
# story's own providers/aws/onbox/install-mongo-backup-timer-remote.sh
# file, not the old inline heredoc string.
stub_respond() {
  local argv="$1"
  case "$argv" in
    *"describe-instances"*)
      echo "i-0123456789abcdef0"
      return 0
      ;;
    *"ssm send-command"*)
      echo "cmd-install-timer"
      return 0
      ;;
    *"get-command-invocation"*"--query Status"*)
      echo "Success"
      return 0
      ;;
    *"get-command-invocation"*"--query StandardOutputContent"*)
      echo "mongo-backup.timer verified enabled and active; removed cron entry /etc/cron.d/mongo-backup."
      return 0
      ;;
    *"get-command-invocation"*"--query StandardErrorContent"*)
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}
