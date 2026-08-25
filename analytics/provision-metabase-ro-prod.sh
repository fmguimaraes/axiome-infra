#!/usr/bin/env bash
# One-time: provision the read-only `metabase_ro` role on the PRODUCTION database
# (pilot-grade — password `change_me_readonly`, the funnels/00 SQL default).
#
# Prod RDS is private and the box has no SSH, so this tunnels over AWS SSM (same
# path as scripts/ssm-exec.sh), applies analytics/funnels/00_metabase_readonly_role.sql
# with the MASTER credentials (from terraform, used only for this one setup), then
# verifies metabase_ro can log in and read the analytics feed. Idempotent — safe
# to re-run. Tears the tunnel down on exit.
#
# Run from a machine with: aws CLI + session-manager-plugin, psql, terraform, and
# providers/aws initialized to the PRODUCTION state.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> axiome-infra

REGION="${AWS_REGION:-eu-west-3}"
LOCAL_PORT="${LOCAL_PORT:-15434}"
RO_PASS="change_me_readonly"             # pilot-grade, matches funnels/00 default + local

echo "== resolving prod EC2 + RDS =="
instance=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=axiome-production-ec2" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$instance" ] && [ "$instance" != "None" ] || { echo "no running prod EC2"; exit 1; }

host=$(terraform -chdir=providers/aws output -raw rds_endpoint)
conn=$(terraform -chdir=providers/aws output -raw rds_connection_string_admin 2>/dev/null || true)
if [ -n "$conn" ]; then
  rest=${conn#postgresql://}; userpass=${rest%@*}; hostportdb=${rest##*@}
  muser=${userpass%%:*}; mpass=${userpass#*:}
  hostport=${hostportdb%%/*}; port=${hostport##*:}
  db=${hostportdb##*/}; db=${db%%\?*}
else
  # The rds_connection_string_admin output isn't in the deployed state (added to
  # config after the last apply, and a refresh-only apply is blocked by an
  # unrelated alerting-module count bug). Read the master creds straight from the
  # existing resources in state instead — no apply needed.
  # `state show` redacts sensitive attrs as "(sensitive value)"; the raw state
  # (state pull) carries them in plaintext. jq extracts them from the database_rds
  # module's resources. Nothing is echoed.
  echo "(rds_connection_string_admin output absent — reading master creds from raw terraform state)"
  command -v jq >/dev/null 2>&1 || { echo "jq required for the state fallback"; exit 1; }
  state=$(terraform -chdir=providers/aws state pull)
  sel='.resources[] | select((.module//"")|test("database_rds"))'
  muser=$(printf '%s' "$state" | jq -r "$sel | select(.type==\"aws_db_instance\")  | .instances[0].attributes.username" | head -1)
  port=$( printf '%s' "$state" | jq -r "$sel | select(.type==\"aws_db_instance\")  | .instances[0].attributes.port"     | head -1)
  db=$(   printf '%s' "$state" | jq -r "$sel | select(.type==\"aws_db_instance\")  | .instances[0].attributes.db_name"  | head -1)
  mpass=$(printf '%s' "$state" | jq -r "$sel | select(.type==\"random_password\" and .name==\"db\") | .instances[0].attributes.result" | head -1)
fi
: "${port:=5432}"
[ -n "$muser" ] && [ -n "$mpass" ] && [ -n "$db" ] || { echo "could not resolve master creds (user='$muser' db='$db' pass=${mpass:+set})"; exit 1; }
echo "instance=$instance rds=$host:$port/$db master_user=$muser"

echo "== opening SSM tunnel $LOCAL_PORT -> $host:$port =="
aws ssm start-session --region "$REGION" --target "$instance" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${host}\"],\"portNumber\":[\"${port}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  >/dev/null 2>&1 &
tpid=$!; trap 'kill "$tpid" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  kill -0 "$tpid" 2>/dev/null || { echo "tunnel died early (SSM auth/permission?)"; exit 1; }
  sleep 1
done
echo "tunnel up"

export PGSSLMODE=require
MASTER=(psql -h 127.0.0.1 -p "$LOCAL_PORT" -U "$muser" -d "$db")
q() { PGPASSWORD="$mpass" "${MASTER[@]}" -tAc "$1"; }

echo "== inspection =="
role_before=$(q "select count(*) from pg_roles where rolname='metabase_ro';")
ae_exists=$(q "select (to_regclass('organization_svc.analytics_events') is not null);")
ev_exists=$(q "select (to_regclass('organization_svc.events') is not null);")
echo "metabase_ro role present:                       $role_before"
echo "organization_svc.analytics_events present:      $ae_exists"
echo "organization_svc.events (pre-rename) present:   $ev_exists"

echo "== ensuring read-only role (pilot-grade) — idempotent =="
PGPASSWORD="$mpass" "${MASTER[@]}" -v ON_ERROR_STOP=1 <<SQL
DO \$do\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='metabase_ro') THEN
    CREATE ROLE metabase_ro LOGIN PASSWORD '${RO_PASS}';
  END IF;
END \$do\$;
GRANT CONNECT ON DATABASE "${db}" TO metabase_ro;
GRANT USAGE ON SCHEMA organization_svc TO metabase_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA organization_svc GRANT SELECT ON TABLES TO metabase_ro;
SQL

if [ "$ae_exists" = "t" ]; then
  echo "== granting SELECT on analytics_events + verifying =="
  PGPASSWORD="$mpass" "${MASTER[@]}" -v ON_ERROR_STOP=1 \
    -c "GRANT SELECT ON organization_svc.analytics_events TO metabase_ro;"
  PGPASSWORD="$RO_PASS" psql -h 127.0.0.1 -p "$LOCAL_PORT" -U metabase_ro -d "$db" -tAc \
    "select 'metabase_ro reads analytics_events, rows='||count(*) from organization_svc.analytics_events;"
  echo "== DONE — metabase_ro provisioned + verified on prod (pilot-grade). =="
  echo "Set METABASE_RO_PROD_PASSWORD=change_me_readonly in axiome-infra/.env.local, then: make analytics-connect-prod"
else
  echo
  echo "!! organization_svc.analytics_events does NOT exist on production."
  echo "   Behavior-tracking migrations are not deployed to prod yet"
  echo "   (pre-rename 'events' table present: ${ev_exists})."
  echo "   metabase_ro now has CONNECT + USAGE + default-privilege SELECT on future"
  echo "   tables, but there is nothing to read until the backend carrying migration"
  echo "   20260720000000_baseline_behavior_events (+ the AXI-1155 reconcile) is"
  echo "   deployed to production and 'prisma migrate deploy' creates the table."
  echo "   Re-run this script after that deploy to complete + verify the grant."
  exit 3
fi
