# Secrets Management

## Principles

- No plaintext secrets in the repository
- Secrets are injected at runtime via environment variables
- Each environment has isolated secrets
- CI pipeline checks for accidental secret commits

## Secret Categories

| Category | Examples | Storage |
|----------|----------|---------|
| Database credentials | Postgres password, MongoDB password | Scaleway Secret Manager + GitHub Secrets |
| API secrets | JWT secret, session secret | Scaleway Secret Manager + GitHub Secrets |
| Storage credentials | S3 access key, S3 secret key | Scaleway Secret Manager + GitHub Secrets |
| Provider credentials | Scaleway API key | GitHub Secrets only |
| Registry credentials | Registry login | GitHub Secrets only |
| Observability keys | Sentry DSN, monitoring API keys | GitHub Secrets only |

## Local Development

1. Copy `.env.example` to `.env.local`
2. Update values as needed (defaults work out of the box)
3. `.env.local` is gitignored and never committed

## Cloud Environments

### Scaleway Secret Manager

Secrets are provisioned via the `modules/secrets` Terraform module:
- `<prefix>-database-credentials` — Postgres and MongoDB credentials
- `<prefix>-api-secrets` — JWT and session secrets
- `<prefix>-storage-credentials` — Object storage access keys

### GitHub Actions

Secrets for CI/CD are configured in GitHub repository settings:
- Settings → Secrets and variables → Actions
- Use environment-specific secrets (dev, staging, production)

## Adding a New Secret

1. Add the secret to Scaleway Secret Manager (via Terraform or console)
2. Add the secret to GitHub Actions environment secrets
3. Reference it in the workflow YAML: `${{ secrets.SECRET_NAME }}`
4. Update `.env.example` with a placeholder for local development
5. Update this documentation

## Rotating Secrets

1. Generate new secret value
2. Update in Scaleway Secret Manager
3. Update in GitHub Actions secrets
4. Redeploy affected services
5. Verify services start correctly with new credentials

## Security Controls

- `.gitignore` excludes `.env.local` and secret files
- `secrets-check.yml` CI workflow scans for plaintext secrets on every PR
- Terraform state contains sensitive values — state backend (S3) must be access-controlled
- Secrets are never logged — application code must not print secret values
