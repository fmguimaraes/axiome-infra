# `knowledge-store` — Knowledge content bucket + IAM (AXI-2798, epic AXI-2796)

A dedicated module — **not** an instance of `../storage` — so no production app
role can ever gain access to licensed full text by reuse (FR66/FR67/NFR12).
Instantiated once, account-shared, from `providers/aws/shared/main.tf` (the
existing account-shared tfstate — see `../../shared/README` pattern for ECR). It is
never instantiated per environment (dev/staging/production).

## What it creates

| Resource | Name (with `naming_prefix = "axiome"`) | Notes |
|---|---|---|
| S3 bucket | `axiome-knowledge-store` | private, `eu-west-3` (region comes from the `aws` provider the `shared` root configures) |
| IAM user | `axiome-knowledge-tooling` | the **one** dedicated principal (O18) |

No `aws_iam_access_key` resource exists in this module — Terraform never creates
or holds a key. After `apply`, create one by hand:

```bash
aws iam create-access-key --user-name axiome-knowledge-tooling
# then put the pair into a named AWS CLI profile, e.g. ~/.aws/credentials:
#   [axiome-knowledge]
#   aws_access_key_id = ...
#   aws_secret_access_key = ...
```

The sync tooling (`axiome-knowledge/tools/datastore.py push|pull|check --remote`)
resolves credentials through the standard AWS SDK/boto3 credential chain
(`AWS_PROFILE=axiome-knowledge` or environment variables) — never a literal key in
`data-store.json` or any committed file (FR67).

## Bucket configuration (FR66, AC31)

- Private, region `eu-west-3`.
- All four S3 Block Public Access settings on.
- Default server-side encryption (SSE-S3/AES256, or SSE-KMS if `kms_key_arn` is
  supplied).
- Versioning enabled.
- Bucket policy denies any request without `aws:SecureTransport` (TLS-only,
  NFR12).
- Lifecycle:
  - noncurrent object versions (any prefix) expire after 90 days;
  - `backup/` objects expire 180 days after creation;
  - `sha256/` content objects never expire;
  - storage class stays S3 Standard throughout (no transition rule).

## IAM (O18 ruled; FR66, FR67, NFR12, AC31)

Exactly one principal, `axiome-knowledge-tooling`, granted `s3:ListBucket` +
`s3:GetBucketLocation` on the bucket and `s3:GetObject` / `s3:PutObject` /
`s3:AbortMultipartUpload` / `s3:ListMultipartUploadParts` on its objects — scoped
to this bucket's ARN only, nothing else. No delete permission (the sync
tooling never deletes or overwrites a bucket object, FR62). No CI principal is
granted access (CI needs no content, FR65).

## What the sync tooling (`data-store.json`) needs from here

| Field | Output | Value today |
|---|---|---|
| `bucket` | `module.knowledge_store.bucket_name` | `axiome-knowledge-store` |
| `region` | `module.knowledge_store.bucket_region` | `eu-west-3` |
| `key_scheme` | not a Terraform output — fixed convention | `sha256/<first 2 hex chars>/<sha256>`, plus the `backup/` prefix |

## Variables

- `naming_prefix` (string, required) — bare project name, e.g. `"axiome"`.
- `kms_key_arn` (string, default `""`) — empty falls back to SSE-S3.
- `tags` (map, default `{}`).

## Outputs

`bucket_name`, `bucket_arn`, `bucket_region`, `iam_user_name`, `iam_user_arn`.
