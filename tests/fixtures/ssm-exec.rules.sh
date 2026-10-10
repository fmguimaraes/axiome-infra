# shellcheck shell=bash
# Fixture for the aws stub — scripts/ssm-exec.sh (AXI-1953, FR20).
#
# Env knobs:
#   SSM_EXEC_FIXTURE_INSTANCE_ID       (default i-fakeinstance)
#   SSM_EXEC_FIXTURE_COMMAND_ID        (default cmd-fake)
#   SSM_EXEC_FIXTURE_STATUS_SEQUENCE   comma-separated Status values returned
#                                      on successive polls (default "Pending";
#                                      the last value repeats once exhausted)
#   SSM_EXEC_FIXTURE_COUNTER_FILE      a per-test scratch file tracking which
#                                      poll we are on (required to use a
#                                      sequence of more than one value)
#   SSM_EXEC_FIXTURE_CANCEL_RC         exit code for `ssm cancel-command` (0)
#   SSM_EXEC_FIXTURE_STDOUT/_STDERR    invocation output content
stub_respond() {
  case "$1" in
    *"ec2 describe-instances"*)
      printf '%s' "${SSM_EXEC_FIXTURE_INSTANCE_ID:-i-fakeinstance}"
      return 0
      ;;
    *"ssm send-command"*)
      printf '%s' "${SSM_EXEC_FIXTURE_COMMAND_ID:-cmd-fake}"
      return 0
      ;;
    *"ssm cancel-command"*)
      return "${SSM_EXEC_FIXTURE_CANCEL_RC:-0}"
      ;;
    *"--query Status"*)
      next_status
      return 0
      ;;
    *"--query StandardOutputContent"*)
      printf '%s' "${SSM_EXEC_FIXTURE_STDOUT:-}"
      return 0
      ;;
    *"--query StandardErrorContent"*)
      printf '%s' "${SSM_EXEC_FIXTURE_STDERR:-}"
      return 0
      ;;
    *)
      return 99
      ;;
  esac
}

next_status() {
  local counter_file="${SSM_EXEC_FIXTURE_COUNTER_FILE:-}" n=0 seq status
  seq="${SSM_EXEC_FIXTURE_STATUS_SEQUENCE:-Pending}"
  IFS=',' read -r -a arr <<< "$seq"
  if [ -n "$counter_file" ] && [ -f "$counter_file" ]; then
    n="$(cat "$counter_file")"
  fi
  if [ "$n" -lt "${#arr[@]}" ]; then
    status="${arr[$n]}"
  else
    status="${arr[$((${#arr[@]} - 1))]}"
  fi
  [ -n "$counter_file" ] && printf '%s' "$((n + 1))" > "$counter_file"
  printf '%s' "$status"
}
