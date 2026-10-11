# Disaster Recovery

> **AXI-1977 correction:** this page describes the retired, not-deployed
> Scaleway path (see [providers.md](providers.md)). Production's actual
> backups: **Postgres** is Neon (its own managed snapshots). **MongoDB** is a
> self-hosted container on the production box, backed up by `power.sh down`'s
> pre-stop backup-and-verify step and (once an operator runs
> `install-mongo-backup-timer.sh`, never done against a real box so far) a
> daily systemd timer — see
> [platform-lifecycle-operations.md](platform-lifecycle-operations.md) §6/§9
> for the verified current behaviour. The gated, not-yet-deployed AWS
> EC2/RDS/ElastiCache stack (`providers/RUNBOOK.md`) would instead use RDS
> manual snapshots (see `deploy-prod.sh`'s pre-deploy snapshot step) — that
> stack is off (`use_hds_data_stack = false`) and does not describe the live
> platform today.

## Backup Strategy

### Databases

| Database | Backup Type | Frequency | Retention |
|----------|-------------|-----------|-----------|
| Postgres (production, actual) | Neon managed snapshots | Continuous/managed | Per Neon plan |
| MongoDB (production, actual) | `power.sh down`'s verified SSM backup-to-S3 + (owed) systemd timer | On every compute power-down; daily once the timer is installed | Not yet defined — timer not installed |
| Postgres | ~~Scaleway automatic backups~~ — retired, not deployed | — | — |
| MongoDB | ~~Scaleway automatic backups~~ — retired, not deployed | — | — |

### Object Storage

- Versioning enabled on artifact buckets — previous versions are preserved
- Uploads and system buckets are not versioned (can be enabled if needed)
- Cross-region replication not configured for Phase 1

### Infrastructure State

- Terraform state stored in S3-compatible object storage
- State bucket should have versioning enabled
- State contains sensitive values — access must be restricted

## Recovery Procedures

### Service failure — single service down

1. Check health endpoint and container logs
2. Redeploy the same version via the promote workflow
3. If the image is corrupted, redeploy the previous known-good version

### Database failure — Postgres or MongoDB

1. Contact Scaleway support for managed database incidents
2. For data corruption, restore from automatic backup via Scaleway console
3. Verify application connectivity after restore
4. Run any pending migrations if needed

### Complete environment rebuild

1. Ensure Terraform state is intact
2. Run `make plan ENV=<env>` to verify state
3. If state is lost, import existing resources or recreate from scratch
4. Redeploy applications via CI/CD pipeline

### Secret compromise

1. Rotate all compromised secrets immediately
2. Update Scaleway Secret Manager and GitHub Actions
3. Redeploy all affected services
4. Review access logs for unauthorized activity
5. Document the incident

## RTO / RPO Targets (Phase 1)

| Metric | Dev | Staging | Production |
|--------|-----|---------|------------|
| RTO (Recovery Time Objective) | 4h | 2h | 1h |
| RPO (Recovery Point Objective) | 24h | 24h | 24h |

These are Phase 1 targets appropriate for a pilot system. Production targets should be tightened as the platform matures.
