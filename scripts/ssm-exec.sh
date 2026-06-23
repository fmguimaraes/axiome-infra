#!/usr/bin/env bash
# ssm-exec.sh — run a shell command on a platform EC2 host via SSM Run Command.
#
# This is the headless equivalent of "SSH into the box". The production EC2
# instance has NO SSH keypair attached (KeyName=None) — access is via AWS
# Systems Manager Session Manager / Run Command. That means:
#   * no port 22 exposed, no key to manage
#   * every call is authenticated by your AWS IAM identity and logged in CloudTrail
#   * commands run as root inside the SSM agent context
#
# Usage:
#   scripts/ssm-exec.sh 'docker compose -f /opt/axiome/docker-compose.yml ps'
#   scripts/ssm-exec.sh -e production 'uptime'
#   scripts/ssm-exec.sh -f scripts/some-onbox-script.sh        # run a local file on the box
#   echo 'hostname' | scripts/ssm-exec.sh -                    # read command from stdin
#
# Options:
#   -e ENV       Environment (production|staging|dev). Default: production.
#   -r REGION    AWS region. Default: eu-west-3 (or $AWS_REGION).
#   -f FILE      Run the contents of a local script FILE on the host.
#   -i ID        Target a specific instance id (skips Name-tag lookup).
#   -t SECONDS   Max seconds to wait for completion. Default: 120.
#
# The target instance is found by its Name tag `axiome-<env>-ec2` unless -i is given.
# Exits with the remote command's effective status (non-zero on Failed/TimedOut).
#
# SECURITY: the command text is stored in SSM command history + CloudTrail. Do NOT
# pass secrets as literals. To use a secret on the box, fetch it there from SSM
# (e.g. `aws ssm get-parameter --with-decryption ...`) so only the *reference*
# travels through this tool, never the value.

set -euo pipefail

ENVIRONMENT="production"
REGION="${AWS_REGION:-eu-west-3}"
INSTANCE_ID=""
SCRIPT_FILE=""
WAIT_SECONDS=120

while getopts "e:r:f:i:t:h" opt; do
  case "${opt}" in
    e) ENVIRONMENT="${OPTARG}" ;;
    r) REGION="${OPTARG}" ;;
    f) SCRIPT_FILE="${OPTARG}" ;;
    i) INSTANCE_ID="${OPTARG}" ;;
    t) WAIT_SECONDS="${OPTARG}" ;;
    h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option. Run: $0 -h" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew/apt install jq)." >&2; exit 1; }

# Resolve the command to run: -f file, positional arg, or '-' for stdin.
if [ -n "${SCRIPT_FILE}" ]; then
  [ -r "${SCRIPT_FILE}" ] || { echo "ERROR: cannot read ${SCRIPT_FILE}" >&2; exit 1; }
  REMOTE_CMD="$(cat "${SCRIPT_FILE}")"
elif [ "${1:-}" = "-" ]; then
  REMOTE_CMD="$(cat)"
elif [ -n "${1:-}" ]; then
  REMOTE_CMD="$1"
else
  echo "ERROR: no command given. Run: $0 -h" >&2
  exit 2
fi

# Find the instance by Name tag unless one was supplied.
if [ -z "${INSTANCE_ID}" ]; then
  INSTANCE_ID=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=axiome-${ENVIRONMENT}-ec2" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[0].InstanceId' --output text)
  if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "None" ]; then
    echo "ERROR: no running instance tagged axiome-${ENVIRONMENT}-ec2 in ${REGION}." >&2
    exit 1
  fi
fi

echo "==> ${ENVIRONMENT} (${INSTANCE_ID}, ${REGION})" >&2

# Build the parameters JSON via jq so the command is escaped safely.
PARAMS=$(jq -n --arg c "${REMOTE_CMD}" '{commands: [$c]}')

COMMAND_ID=$(aws ssm send-command --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters "${PARAMS}" \
  --query 'Command.CommandId' --output text)

# Poll until the invocation reaches a terminal state (or we time out).
DEADLINE=$((SECONDS + WAIT_SECONDS))
STATUS="Pending"
while [ ${SECONDS} -lt ${DEADLINE} ]; do
  sleep 2
  STATUS=$(aws ssm get-command-invocation --region "${REGION}" \
    --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "${STATUS}" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
done

OUT=$(aws ssm get-command-invocation --region "${REGION}" \
  --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}" \
  --query 'StandardOutputContent' --output text 2>/dev/null || true)
ERR=$(aws ssm get-command-invocation --region "${REGION}" \
  --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}" \
  --query 'StandardErrorContent' --output text 2>/dev/null || true)

[ -n "${OUT}" ] && printf '%s\n' "${OUT}"
[ -n "${ERR}" ] && printf '%s\n' "${ERR}" >&2

echo "==> status: ${STATUS}" >&2
[ "${STATUS}" = "Success" ] && exit 0 || exit 1
