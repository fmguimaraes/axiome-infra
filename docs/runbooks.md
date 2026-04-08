# Operational Runbooks

## Common Operations

### Scale a service

Backend and biocompute scaling is controlled via Terraform variables:

```bash
# Edit the environment tfvars
# e.g., environments/production/terraform.tfvars
# Change backend_max_scale or biocompute_max_scale

make plan ENV=production
make apply ENV=production
```

### Rotate database credentials

1. Generate new password
2. Update in Scaleway Secret Manager (console or CLI)
3. Update in GitHub Actions secrets for the affected environment
4. Redeploy backend and biocompute via promote workflow
5. Verify connectivity

### Rotate API/JWT secrets

1. Generate new secret value
2. Update in GitHub Actions secrets
3. Redeploy backend via promote workflow
4. Existing sessions will be invalidated — users will need to re-authenticate

### Debug a failed deployment

1. Check GitHub Actions workflow run for error messages
2. Check container logs:
   ```bash
   scw container container logs <container-id>
   ```
3. Check health endpoints manually:
   ```bash
   curl -v https://<backend-url>/health
   ```
4. If the container failed to start, check for:
   - Missing environment variables
   - Database connectivity issues
   - Port binding conflicts
5. Rollback to previous version if needed

### Add a new environment variable

1. Add to `.env.example` with a descriptive comment
2. Add to `docker-compose.yml` for local development
3. Add to GitHub Actions secrets for cloud environments
4. Add to container environment_variables in `modules/compute/main.tf` if it's an infra concern
5. Update `docs/secrets.md`

### Provision a new environment

1. Create `environments/<new-env>/terraform.tfvars` (copy from dev and adjust)
2. Create `environments/<new-env>/backend.hcl` (use a new state bucket)
3. Create the state bucket manually in Scaleway console
4. Run:
   ```bash
   make init ENV=<new-env>
   make plan ENV=<new-env>
   make apply ENV=<new-env>
   ```
5. Configure GitHub Actions environment secrets
6. Deploy applications via promote workflow

### View application logs

```bash
# Scaleway CLI
scw container container logs <container-id>

# Or via Scaleway Cockpit (Grafana/Loki) if monitoring is enabled
```

### Check Terraform state

```bash
make init ENV=<env>
terraform state list
terraform state show <resource>
```

## Troubleshooting

### Container won't start

- Check image exists in registry: `scw registry image list`
- Verify environment variables are set
- Check resource limits (CPU/memory may be too low)
- Review container logs for startup errors

### Database connection refused

- Verify private network connectivity
- Check database instance status in Scaleway console
- Verify credentials are correct
- Check if database is in maintenance window

### Object storage access denied

- Verify S3 credentials are correct
- Check bucket policy/ACL
- Verify the bucket name matches the environment
- Check if the bucket exists

### Health check failing

- Service may still be starting — wait for cold start
- Check if dependent services (database, storage) are healthy
- Review application logs for errors
- Verify the health endpoint is implemented correctly
