# Connecting to a Deployed Host & Debugging

How to get onto a deployed platform host and inspect the running stack. The current
production host is **EC2 + SSM** (the HDS data stack), not the Lightsail flow still
described in [providers/aws/README.md](../providers/aws/README.md).

> For *what to do once you suspect a specific problem*, see
> [troubleshooting.md](troubleshooting.md).

---

## 1. Access model — no SSH key, use SSM

The production EC2 instance has **no SSH keypair** attached (`KeyName=None`) and does
not expose port 22. Access is via **AWS Systems Manager** (Session Manager / Run
Command). This is deliberate:

- No key to distribute, rotate, or leak.
- Every action is authenticated by your **AWS IAM identity** and recorded in
  **CloudTrail** — there is an audit trail of who ran what.
- The SSM agent runs commands **as root** on the host.

Prerequisites:

- AWS CLI v2 configured with credentials for account `225201317100`
  (`aws sts get-caller-identity` should succeed).
- `jq` installed (the helper scripts use it to escape commands safely).
- Region `eu-west-3` (Paris).
- For an *interactive* shell (humans): the
  [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
  The scripts below use Run Command and do **not** need it.

---

## 2. Find the instance

```bash
aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Name,Values=axiome-production-ec2" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,IP:PublicIpAddress}' --output table

# Confirm the SSM agent is online (must say "Online"):
aws ssm describe-instance-information --region eu-west-3 \
  --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}' --output table
```

The Name tag pattern is `axiome-<env>-ec2` (`axiome-production-ec2`,
`axiome-staging-ec2`, ...).

---

## 3. Run commands on the host

### The easy way — helper scripts

```bash
# Arbitrary command (headless Run Command, prints stdout/stderr):
scripts/ssm-exec.sh 'docker compose -f /opt/axiome/docker-compose.yml ps'
scripts/ssm-exec.sh -e production 'uptime'
scripts/ssm-exec.sh -f scripts/some-onbox-script.sh    # run a local file on the box

# Common debugging shortcuts:
scripts/platform-debug.sh status                 # all containers (flags the healthcheck quirk)
scripts/platform-debug.sh health                 # gateway /api/v1/health → {"status":"ok"}
scripts/platform-debug.sh logs gateway 120       # tail 120 lines of a service
scripts/platform-debug.sh login-test EMAIL       # POST /auth/login with the SSM admin pw → 200?
scripts/platform-debug.sh env                    # .env KEY names only (never values)
```

### Interactive shell (humans, requires the SSM plugin)

```bash
aws ssm start-session --region eu-west-3 --target <instance-id>
# then on the box:
sudo -i ; cd /opt/axiome ; docker compose ps
```

### Raw Run Command (no helper)

```bash
CID=$(aws ssm send-command --region eu-west-3 \
  --instance-ids <instance-id> --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/axiome && docker compose ps"]' \
  --query Command.CommandId --output text)
aws ssm get-command-invocation --region eu-west-3 \
  --command-id "$CID" --instance-id <instance-id> --query StandardOutputContent --output text
```

---

## 4. The host layout

Everything lives in **`/opt/axiome`**:

| Path | What |
|---|---|
| `/opt/axiome/docker-compose.yml` | The full stack (gateway, user/org/event services, biocompute, frontend, caddy, redis, rabbitmq) |
| `/opt/axiome/.env` | Runtime config + secrets, rendered from SSM at boot (mode `600`) |
| `/opt/axiome/Caddyfile` | TLS / reverse proxy |

Secrets are in **SSM Parameter Store** under `/<env>/axiome-<env>/` (e.g.
`/production/axiome-production/DATABASE_URL`). The host's runtime IAM role can
**Get** parameters but not **Describe** them, so always reference a parameter by its
full known path:

```bash
scripts/ssm-exec.sh 'aws ssm get-parameter --region eu-west-3 \
  --name /production/axiome-production/DATABASE_URL --with-decryption \
  --query Parameter.Value --output text'
```

---

## 5. Connect to the databases

```bash
# Postgres (Neon) — connection string is in SSM:
PG=$(scripts/ssm-exec.sh 'aws ssm get-parameter --region eu-west-3 \
  --name /production/axiome-production/DATABASE_URL --with-decryption \
  --query Parameter.Value --output text' | sed '/^==>/d')
psql "$PG"

# MongoDB (event/audit store) — Atlas-managed, not a host container (FR3). Connection
# string is in SSM:
MONGO=$(scripts/ssm-exec.sh 'aws ssm get-parameter --region eu-west-3 \
  --name /production/axiome-production/MONGODB_URL --with-decryption \
  --query Parameter.Value --output text' | sed '/^==>/d')
mongosh "$MONGO" --eval 'db.adminCommand({ping:1})'
```

### 5.1 Private RDS (Postgres) via SSM port-forward — connect from your laptop

> **First documented:** 2026-06-23, production. Use this when you need a real SQL
> session against the production Postgres from your own machine — running a
> migration, inspecting schema drift, or one-off DDL — rather than via Run Command
> on the box.

The user/org services do **not** use the Neon `DATABASE_URL` shown above. They point
at a **private Amazon RDS** instance, `axiome-production-pg`
(`...rds.amazonaws.com:5432`), referenced by SSM params
`/production/axiome-production/ORGANIZATION_DATABASE_URL` and `…/USER_DATABASE_URL`.

That instance is **not reachable directly**, and the reasons matter so you don't
waste time trying:

- `PubliclyAccessible = false`, and its DB subnets have **no internet-gateway
  route** — a private data tier. A direct `psql`/TCP connect from anywhere outside
  the VPC returns `No route to host`. Credentials do not change this.
- It is **standard RDS Postgres, not Aurora**, so there is **no** `aws rds-data
  execute-statement` Data-API path. There is no pure-CLI way to run SQL against it.
- Making it reachable "directly" would require adding an IGW route to the prod DB
  subnets + flipping public access + opening the SG — i.e. putting the production
  database on the internet. **Don't.**

The supported path is an **SSM port-forward through the prod EC2 box** (already in
the VPC, already talks to this RDS). No SSH, no inbound ports, no network changes —
just an `aws ssm` tunnel:

```bash
# 0. One-time: install the session-manager-plugin (needed for port-forwarding).
#    No root? Extract the .deb into a local prefix and symlink it onto PATH:
curl -s -o smp.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
dpkg-deb -x smp.deb smp && export PATH="$PWD/smp/usr/local/sessionmanagerplugin/bin:$PATH"
session-manager-plugin --version   # sanity check

# 1. Find the SSM-managed prod instance (must be "Online"):
INSTANCE=$(aws ssm describe-instance-information --region eu-west-3 \
  --query 'InstanceInformationList[0].InstanceId' --output text)

# 2. Open the tunnel: localhost:55432 -> RDS:5432, through the EC2 box. Leave running.
aws ssm start-session --region eu-west-3 --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["axiome-production-pg.cfmqsmeou4ci.eu-west-3.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["55432"]}'
```

Then connect to `127.0.0.1:55432`. **Use `sslmode=require`** (RDS forces TLS; the
cert CN won't match `localhost`, and `require` encrypts without verifying the host,
so it works through the tunnel). Reuse the SSM connection string but swap host/port:

```bash
# Fetch the URL, keep its credentials + ?schema=, point it at the tunnel:
URL=$(aws ssm get-parameter --region eu-west-3 \
  --name /production/axiome-production/ORGANIZATION_DATABASE_URL \
  --with-decryption --query Parameter.Value --output text)
LOCAL_URL=$(echo "$URL" | sed -E 's#@[^/]+/#@127.0.0.1:55432/#')   # -> ...@127.0.0.1:55432/axiome?sslmode=require&schema=organization_svc
psql "$LOCAL_URL"
```

**No `psql`?** Each backend service ships a generated Prisma client you can drive
with a throwaway Node script — run it from inside `axiome-back/` so `node_modules`
resolves. Note the per-service client output paths (the root `@prisma/client` is the
**MongoDB** event-service client; importing it for a Postgres URL fails with
*"the URL must start with the protocol `mongo`"*):

| Service | Generated client (import path under `axiome-back/`) | SSM param |
|---|---|---|
| organization | `./node_modules/.prisma/organization-client/index.js` | `ORGANIZATION_DATABASE_URL` |
| user | `./node_modules/.prisma/user-client/index.js` *(verify name in its schema's `output`)* | `USER_DATABASE_URL` |

```js
// axiome-back/probe.mjs  — run: node probe.mjs   (PROBE_URL = the LOCAL_URL above)
import { PrismaClient } from './node_modules/.prisma/organization-client/index.js';
const prisma = new PrismaClient({ datasources: { db: { url: process.env.PROBE_URL } } });
console.log(await prisma.$queryRawUnsafe(
  `SELECT column_name FROM information_schema.columns
   WHERE table_schema='organization_svc' AND table_name='workspace_members'`));
// $executeRawUnsafe for idempotent DDL — see troubleshooting.md "column ... does not exist".
await prisma.$disconnect();
```

**Tear down** the tunnel when finished (`Ctrl-C` the `start-session`, or kill it) —
don't leave a path to prod open.

---

## 6. Safety rules

- **Never pass a secret as a literal** to `ssm-exec`/`send-command` — the command
  text is stored in SSM history + CloudTrail. Fetch secrets **on the box** from SSM
  (as shown above) so only the *reference* travels through the tool.
- **Read-only first.** `platform-debug.sh` subcommands are read-only. Mutating
  actions (recreating containers, rotating passwords) belong in named scripts like
  `reset-admin-password.sh`, which are reviewable and verified.
- **`.env` edits are fragile** — prefer a script over hand-editing. See the `printf`
  warning in [troubleshooting.md](troubleshooting.md#fix--rotate-the-admin-password-authoritative).
