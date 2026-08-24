#!/usr/bin/env bash
# connect-prod-db.sh — open a READ-ONLY psql shell to the PRODUCTION database as
# `metabase_ro`, the prod analogue of the local `docker compose exec postgres psql`.
#
# The production RDS is PRIVATE (not internet-reachable), and the EC2 host has no
# SSH keypair — access is via AWS SSM, exactly like scripts/ssm-exec.sh. So this
# opens an SSM **port-forward** through the prod EC2 instance to the RDS endpoint,
# then runs psql against the forwarded local port. Only the least-privilege
# read-only role is used — never the master/app credentials.
#
# Prerequisites (all checked below, with a clear message for each):
#   * aws CLI + the Session Manager plugin (session-manager-plugin)
#   * psql, terraform
#   * providers/aws terraform state initialized to PRODUCTION (rds_endpoint resolves)
#   * metabase_ro provisioned on prod (run analytics/funnels/00_metabase_readonly_role.sql
#     against production once, with a real password)
#   * METABASE_RO_PROD_PASSWORD set (repo-root .env.local or the environment)
#
# The password is read on THIS machine and handed to psql via PGPASSWORD — it is
# never passed through SSM/CloudTrail (only the RDS host/port travel through SSM).
set -euo pipefail

INFRA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$INFRA_DIR"

ENVIRONMENT="${ANALYTICS_PROD_ENV:-production}"
REGION="${AWS_REGION:-eu-west-3}"
LOCAL_PORT="${ANALYTICS_LOCAL_PORT:-15432}"

# Optional credential overrides (repo-root .env.local — the .env.example copy target).
[ -f .env.local ] && { set -a; . ./.env.local; set +a; }
RO_USER="${METABASE_RO_PROD_USER:-${METABASE_RO_USER:-metabase_ro}}"
RO_PASS="${METABASE_RO_PROD_PASSWORD:-${METABASE_RO_PASSWORD:-}}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Prerequisite checks ──────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1                    || die "aws CLI not found on PATH"
command -v session-manager-plugin >/dev/null 2>&1 || die "session-manager-plugin not found — install the AWS Session Manager plugin"
command -v psql >/dev/null 2>&1                   || die "psql not found on PATH (install the postgresql client)"
command -v terraform >/dev/null 2>&1              || die "terraform not found on PATH"
[ -n "$RO_PASS" ] || die "METABASE_RO_PROD_PASSWORD not set — add it to the repo-root .env.local (the real prod read-only password)"

# ── Resolve the prod EC2 instance (SSM target) and the RDS coordinates ───────
echo "Resolving production EC2 instance (tag Name=axiome-${ENVIRONMENT}-ec2)…"
instance=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=axiome-${ENVIRONMENT}-ec2" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$instance" ] && [ "$instance" != "None" ] || die "no running instance tagged axiome-${ENVIRONMENT}-ec2 in ${REGION}"

host=$(terraform -chdir=providers/aws output -raw rds_endpoint 2>/dev/null) \
  || die "could not read rds_endpoint — is providers/aws initialized to the PRODUCTION state?"
conn=$(terraform -chdir=providers/aws output -raw rds_connection_string_admin 2>/dev/null) \
  || die "could not read rds_connection_string_admin from providers/aws"
port=$(printf '%s' "$conn" | sed -E 's#.*@[^:]+:([0-9]+)/.*#\1#')
db=$(printf   '%s' "$conn" | sed -E 's#.*/([^/?]+)(\?.*)?$#\1#')

# ── Open the SSM port-forward tunnel, tear it down on exit ───────────────────
echo "Opening SSM port-forward ${LOCAL_PORT} → ${host}:${port} via ${instance}…"
aws ssm start-session --region "$REGION" --target "$instance" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${host}\"],\"portNumber\":[\"${port}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  >/dev/null 2>&1 &
tunnel_pid=$!
trap 'kill "$tunnel_pid" 2>/dev/null || true' EXIT

# Wait for the local end of the tunnel to accept connections (no fixed sleep).
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  kill -0 "$tunnel_pid" 2>/dev/null || die "SSM tunnel exited before it was ready (check AWS auth / SSM permissions)"
  sleep 1
done

echo "Connecting to PRODUCTION ${host}:${port}/${db} as ${RO_USER} (read-only, via SSM tunnel)…"
PGPASSWORD="$RO_PASS" PGSSLMODE=require psql -h 127.0.0.1 -p "$LOCAL_PORT" -U "$RO_USER" -d "$db"
