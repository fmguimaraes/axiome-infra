# Provider Portability

## Current State

**Primary provider**: Scaleway (EU — fr-par region)
**Secondary provider**: AWS (planned, not yet implemented)

## Scaleway Services Used

| Module | Scaleway Service | AWS Equivalent |
|--------|-----------------|----------------|
| Network | VPC Private Network | VPC + Subnets |
| Compute | Serverless Containers | ECS Fargate |
| Database (Postgres) | Managed Database for PostgreSQL | RDS PostgreSQL |
| Database (MongoDB) | Managed MongoDB | DocumentDB |
| Storage | Object Storage (S3-compatible) | S3 |
| Registry | Container Registry | ECR |
| Secrets | Secret Manager | Secrets Manager |

## Switching to AWS

The module interface is designed for portability. To switch:

1. Create AWS module implementations in `providers/aws/<module>/` matching the same variable/output interface
2. Update `main.tf` to use `source = "./providers/aws/<module>"` instead of `./modules/<module>`
3. Update `versions.tf` to require the AWS provider
4. Create AWS-specific environment tfvars (update region, node types, etc.)
5. Initialize and apply

### Known Differences

- **MongoDB**: Scaleway offers managed MongoDB; AWS equivalent is DocumentDB (not fully compatible) or self-hosted MongoDB on EC2/ECS
- **Serverless Containers**: Scaleway Serverless Containers vs AWS ECS Fargate — different scaling and cold-start behavior
- **Networking**: Scaleway Private Networks are simpler than AWS VPC (no subnet/route table management required)
- **Region naming**: Scaleway uses `fr-par`, AWS uses `eu-west-3` (Paris)

## Design Principle

Optimize for topology portability, not naive one-to-one resource mapping. The same architectural pattern (private network, isolated containers, managed databases, S3-compatible storage) works on both providers even if the specific resource types differ.
