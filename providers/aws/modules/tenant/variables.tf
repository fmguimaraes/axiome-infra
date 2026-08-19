variable "naming_prefix" {
  description = "Environment naming prefix, e.g. axiome-production. The per-tenant bucket is named <naming_prefix>-tenant-<tenant_id>."
  type        = string
}

variable "tenant_id" {
  description = <<-EOT
    Stable tenant identifier (the Tenant Registry `tenant_id`, FR2). Used as the
    per-tenant bucket suffix and the IAM role name, so it must be a valid S3
    bucket-name fragment: lowercase letters, digits and hyphens only. The MIPP
    pilot tenant is org `f371ce3f-86ca-40de-9242-5b2aeed7d068` (D1 §A/FR4).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.tenant_id))
    error_message = "tenant_id must be 3-63 lowercase alphanumeric/hyphen characters (S3 bucket-name safe)."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    ARN of the CMK that encrypts this tenant's bucket at rest (NFR2/AC1). The
    per-tenant IAM role is granted GenerateDataKey/Decrypt on ONLY this key.
    Empty falls back to SSE-S3 (AES256) and no KMS grant — dev/local only.

    This module does NOT create the key — it encrypts with whatever ARN it is
    handed. The caller decides whether that is a genuinely per-tenant CMK or the
    shared platform CMK: pass a per-tenant key ARN (root var.tenant_kms_key_arns)
    to realize NFR2's per-tenant-key posture; otherwise the shared platform CMK is
    used and bucket-scoped isolation still holds. Per-tenant CMK *creation* is
    FR18/Phase-2 (AXI-1292).
  EOT
  type        = string
  default     = ""
}

variable "assume_role_principal_arns" {
  description = <<-EOT
    Principal ARNs allowed to sts:AssumeRole the per-tenant role — the seam
    AXI-1299 (per-job, tenant-scoped STS credentials, FR12/FR13) plugs into: the
    compute/instance role assumes this role to obtain short-lived, bucket-scoped
    credentials for a job. Empty falls back to the account root, leaving the
    delegation to be governed by the caller's own IAM policy (still bounded — no
    principal can assume it without an explicit sts:AssumeRole grant).
  EOT
  type        = list(string)
  default     = []
}

variable "residency" {
  description = <<-EOT
    Tenant data-residency region (NFR1/AC1). Phase 1 provisions every tenant in
    the provider region (eu-west-3); a differing residency is recorded on the
    registry row and realized by a regional provider in a later phase (§9.4), not
    here. Kept as an input so the module contract already carries the field.
  EOT
  type        = string
  default     = ""
}

variable "cors_allowed_origins" {
  description = "Browser origins allowed to PUT/GET this tenant's bucket via presigned URLs. Empty disables CORS (non-browser-facing envs)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
