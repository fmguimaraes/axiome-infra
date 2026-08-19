# These outputs are the Tenant Registry (FR2) pointers for this tenant. Phase 2
# (Design A, FR19) writes them onto the registry row as a Terraform resource;
# Phase 1 surfaces them so the app / registry can be populated against a known
# contract without this module having to know about the registry table.

output "bucket_name" {
  description = "Per-tenant bucket name — the registry `bucket_ref` (FR2)."
  value       = aws_s3_bucket.tenant.id
}

output "bucket_arn" {
  description = "Per-tenant bucket ARN."
  value       = aws_s3_bucket.tenant.arn
}

output "role_arn" {
  description = "Per-tenant IAM role ARN — the registry `credential_ref` (FR2); the role AXI-1299 assumes for per-job, tenant-scoped credentials (FR12)."
  value       = aws_iam_role.tenant.arn
}

output "role_name" {
  description = "Per-tenant IAM role name."
  value       = aws_iam_role.tenant.name
}

output "residency" {
  description = "Recorded data-residency region for this tenant (NFR1); empty = provider region."
  value       = var.residency
}
