# Disaster Recovery

## Backup Strategy

### Databases

| Database | Backup Type | Frequency | Retention |
|----------|-------------|-----------|-----------|
| Postgres | Scaleway automatic backups | Daily | 7 days (dev), 30 days (production) |
| MongoDB | Scaleway automatic backups | Daily | 7 days (dev), 30 days (production) |

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
