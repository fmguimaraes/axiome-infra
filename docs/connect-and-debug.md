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
| `/opt/axiome/docker-compose.yml` | The full stack (gateway, user/org/event services, biocompute, frontend, caddy, mongo, redis, rabbitmq) |
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

# MongoDB — runs as a container on the host:
scripts/ssm-exec.sh "docker exec axiome-mongo mongosh --quiet --eval 'db.adminCommand({ping:1})'"
```

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
