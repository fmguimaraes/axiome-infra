#!/usr/bin/env bash
# power.sh — daily compute on/off for an Axiome AWS environment.
#
# SCOPE (deliberate — do not widen):
#   Stops/starts ONLY the EC2 compute instance. It NEVER touches storage:
#   RDS, ElastiCache, S3, and the Terraform state backend all stay up. The
#   instance's EBS root volume (Mongo / RabbitMQ / local-Redis docker volumes)
#   survives a stop, so no data moves and nothing is snapshotted. On a
#   low-traffic HDS environment the EC2 box is most of the bill; leaving the
#   data tier running keeps time-to-up short and the blast radius near zero.
#
# On start, the box brings itself back: cloud-init installed an enabled
#   `axiome.service` systemd unit (docker compose up -d) and every container is
#   restart: unless-stopped. Images already live on EBS, so there is no ECR
#   pull — start is boot + container warm-up only.
#
# Usage:  ./power.sh <dev|staging|production> <up|down|status>
# Env overrides: AWS_REGION, AXIOME_PROJECT, AXIOME_HEALTH_URL, REPORTS_DIR
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|production> <up|down|status>" >&2; exit 2; }
[ $# -eq 2 ] || usage
ENV="$1"; ACTION="$2"
case "$ENV" in dev|staging|production) ;; *) usage ;; esac

PROJECT="${AXIOME_PROJECT:-axiome}"
REGION="${AWS_REGION:-eu-west-3}"

# Reports live at the repo root of whatever checkout/worktree this script runs
# from, so the audit log is versioned alongside the code that produced it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../../..")"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports}"

# versioned audit log — one appended entry per change
log_event() { # <resource> <change>
  mkdir -p "$REPORTS_DIR"
  local ts who
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  who="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"
  printf '| %s | %s | %s | %s | %s |\n' "$ts" "$ENV" "$1" "$2" "$who" \
    >> "${REPORTS_DIR}/power-operations.md"
}

# Readiness endpoint = the app's liveness probe, reached through the public edge
# (CloudFront -> Caddy -> gateway). 200 means the stack is actually serving, not
# just that the instance reached "running".
case "$ENV" in
  production) FQDN="platform.axiomebio.com" ;;
  staging)    FQDN="staging.axiomebio.com" ;;
  dev)        FQDN="dev.axiomebio.com" ;;
esac
HEALTH_URL="${AXIOME_HEALTH_URL:-https://${FQDN}/api/v1/health/live}"

# --- resolve the single compute instance by tag (provider default_tags) --------
find_instance() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=tag:Environment,Values=${ENV}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

IID="$(find_instance)"
[ -n "$IID" ] || { echo "no EC2 instance for ${PROJECT}/${ENV} in ${REGION}" >&2; exit 1; }
[ "$(printf '%s' "$IID" | wc -w)" -eq 1 ] || {
  echo "expected exactly one instance, found: ${IID}" >&2
  echo "(a deploy may be replacing the VM — retry once it settles)" >&2
  exit 1
}

state() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[].Instances[].State.Name' --output text
}

case "$ACTION" in
  status)
    echo "${ENV} compute ${IID}: $(state)"
    ;;

  down)
    echo "stopping compute ${IID} (${ENV}) — RDS / ElastiCache / S3 / state untouched"
    aws ec2 stop-instances --region "$REGION" --instance-ids "$IID" >/dev/null
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$IID"
    log_event "EC2 ${IID}" "compute stopped"
    echo "stopped."
    ;;

  up)
    start_epoch="$(date +%s)"
    echo "starting compute ${IID} (${ENV})"
    aws ec2 start-instances --region "$REGION" --instance-ids "$IID" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
    echo "instance running; polling ${HEALTH_URL} for app readiness (timeout 10m)..."
    deadline=$(( start_epoch + 600 ))
    until curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL"; do
      [ "$(date +%s)" -lt "$deadline" ] || {
        echo "NOT READY after 10m — check the box: ssm-exec.sh ${ENV} 'docker compose -f /opt/axiome/docker-compose.yml ps'" >&2
        exit 1
      }
      sleep 5
    done
    ttu=$(( $(date +%s) - start_epoch ))
    log_event "EC2 ${IID}" "compute started, time-to-up ${ttu}s"
    echo "READY. time-to-up: ${ttu}s"
    ;;

  *) usage ;;
esac
