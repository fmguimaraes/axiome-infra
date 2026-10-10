data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Lightsail does not natively support IAM instance profiles; we issue
# short-lived credentials at boot via an instance role that the cloud-init
# script assumes through `aws sts assume-role` using credentials baked
# from a service IAM user (chicken-and-egg) — OR we use an EC2-style
# attached IAM role via `aws_iam_instance_profile` not supported on
# Lightsail. Practical solution: pass an AWS access key for a scoped IAM
# user via cloud-init user_data (via SSM put-parameter at runtime is
# preferred but bootstraps need a primer).
#
# Cleanest path: create a dedicated IAM user with read-only SSM + ECR pull
# permissions, generate access keys via Terraform, inject via user_data.
# Keys can be rotated via `terraform apply -replace=...iam_access_key`.

resource "aws_iam_user" "lightsail_runtime" {
  name = "${var.naming_prefix}-lightsail-runtime"
  tags = var.tags
}

resource "aws_iam_user_policy" "lightsail_runtime" {
  user = aws_iam_user.lightsail_runtime.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        # GetParametersByPath authorizes against the path resource itself (no trailing /*),
        # while GetParameter/GetParameters authorize against each child. Grant both.
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "arn:aws:s3:::${var.naming_prefix}-*",
          "arn:aws:s3:::${var.naming_prefix}-*/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "lightsail_runtime" {
  user = aws_iam_user.lightsail_runtime.name
}

# On-box asset channel (AXI-1950, epic AXI-1944 decision 8, FR11/AC9) — same
# declarative publish pattern as modules/compute-ec2. init.sh.tftpl is shared
# by both modules (see its own header comment), so the Lightsail path's
# cloud-init bootstrap (step 7) needs these objects to exist too, or a fresh
# Lightsail dev box would fail its first boot the moment this story's
# init.sh.tftpl change lands. The existing `s3:::${naming_prefix}-*` wildcard
# grant below already covers reading `onbox/*` from the system bucket.
locals {
  onbox_compose_path     = "${path.module}/../../onbox/docker-compose.yml"
  onbox_boot_sh_path     = "${path.module}/../../onbox/boot.sh"
  onbox_asset_sync_path  = "${path.module}/../../scripts/asset-sync.sh"
  onbox_refresh_env_path = "${path.module}/../../scripts/refresh-env.sh"
}

resource "aws_s3_object" "onbox_compose" {
  bucket      = "${var.naming_prefix}-system"
  key         = "onbox/docker-compose.yml"
  source      = local.onbox_compose_path
  source_hash = filemd5(local.onbox_compose_path)
}

resource "aws_s3_object" "onbox_boot_sh" {
  bucket      = "${var.naming_prefix}-system"
  key         = "onbox/scripts/boot.sh"
  source      = local.onbox_boot_sh_path
  source_hash = filemd5(local.onbox_boot_sh_path)
}

resource "aws_s3_object" "onbox_asset_sync" {
  bucket      = "${var.naming_prefix}-system"
  key         = "onbox/scripts/asset-sync.sh"
  source      = local.onbox_asset_sync_path
  source_hash = filemd5(local.onbox_asset_sync_path)
}

resource "aws_s3_object" "onbox_refresh_env" {
  bucket      = "${var.naming_prefix}-system"
  key         = "onbox/scripts/refresh-env.sh"
  source      = local.onbox_refresh_env_path
  source_hash = filemd5(local.onbox_refresh_env_path)
}

resource "aws_s3_object" "onbox_manifest" {
  bucket = "${var.naming_prefix}-system"
  key    = "onbox/manifest.sha256"
  content = join("\n", [
    "${filesha256(local.onbox_compose_path)}  docker-compose.yml",
    "${filesha256(local.onbox_boot_sh_path)}  scripts/boot.sh",
    "${filesha256(local.onbox_asset_sync_path)}  scripts/asset-sync.sh",
    "${filesha256(local.onbox_refresh_env_path)}  scripts/refresh-env.sh",
    "",
  ])
}

# Cloud-init user_data renders the deploy stack onto the VM at first boot.
locals {
  caddyfile = templatefile("${path.module}/../../cloud-init/Caddyfile.tftpl", {
    fqdn         = var.fqdn
    behind_proxy = var.behind_proxy
  })

  docker_compose_yml = file(local.onbox_compose_path)

  # Per-image-tag env lines baked into cloud-init when `var.use_ssm_image_tags`
  # is false (legacy). When true, these lines are omitted and the tags come
  # from SSM via the get-parameters-by-path step in init.sh.
  legacy_image_tag_env = var.use_ssm_image_tags ? "" : <<-EOT
    BACKEND_IMAGE_TAG=${var.backend_image_tag}
    BIOCOMPUTE_IMAGE_TAG=${var.biocompute_image_tag}
    FRONTEND_IMAGE_TAG=${var.frontend_image_tag}
  EOT

  # docker-compose.yml is deliberately NOT a template var (AXI-1950,
  # decision 8) — it reaches the box via the on-box asset sync above.
  cloud_init = templatefile("${path.module}/../../cloud-init/init.sh.tftpl", {
    aws_region            = var.aws_region
    aws_access_key_id     = aws_iam_access_key.lightsail_runtime.id
    aws_secret_access_key = aws_iam_access_key.lightsail_runtime.secret
    ssm_parameter_prefix  = var.ssm_parameter_prefix
    ecr_registry          = var.ecr_registry
    fqdn                  = var.fqdn
    environment           = var.environment
    project_name          = var.naming_prefix
    caddyfile             = local.caddyfile
    legacy_image_tag_env  = local.legacy_image_tag_env
    # Legacy Lightsail path has no CloudWatch sink; empty value skips the agent block.
    cloudwatch_log_group = ""
  })
}

# Image tags live in SSM Parameter Store (when var.use_ssm_image_tags is true),
# not baked into user_data.
#
# WHY: when image tags are templated into user_data, every tag bump changes
# the rendered cloud-init -> changes user_data_hash -> replaces the Lightsail
# instance -> ~10 minutes of downtime per deploy. Storing the tags in SSM
# lets the deploy workflow mutate them out-of-band: write to SSM, then
# `docker compose pull && up -d` over SSH on the existing VM. No recreate.
#
# `ignore_changes = [value]` is required so subsequent SSM bumps (made by the
# deploy workflow) aren't reverted on the next `terraform apply`. The
# terraform-managed value is therefore only the *seed* used at first boot —
# `var.*_image_tag` (sourced from `images.tfvars`) is the initial floor;
# after that SSM is the source of truth.

resource "aws_ssm_parameter" "backend_image_tag" {
  count = var.use_ssm_image_tags ? 1 : 0

  name  = "${var.ssm_parameter_prefix}/BACKEND_IMAGE_TAG"
  type  = "String"
  value = var.backend_image_tag
  tags  = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "biocompute_image_tag" {
  count = var.use_ssm_image_tags ? 1 : 0

  name  = "${var.ssm_parameter_prefix}/BIOCOMPUTE_IMAGE_TAG"
  type  = "String"
  value = var.biocompute_image_tag
  tags  = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "frontend_image_tag" {
  count = var.use_ssm_image_tags ? 1 : 0

  name  = "${var.ssm_parameter_prefix}/FRONTEND_IMAGE_TAG"
  type  = "String"
  value = var.frontend_image_tag
  tags  = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_lightsail_static_ip" "main" {
  name = "${var.naming_prefix}-ip"
}

resource "terraform_data" "user_data_hash" {
  input = sha256(local.cloud_init)
}

resource "aws_lightsail_instance" "main" {
  # cloud-init's bootstrap (init.sh.tftpl step 7) fetches the on-box asset
  # channel from S3 at first boot — it must already exist (AXI-1950).
  depends_on = [
    aws_s3_object.onbox_compose,
    aws_s3_object.onbox_boot_sh,
    aws_s3_object.onbox_asset_sync,
    aws_s3_object.onbox_refresh_env,
    aws_s3_object.onbox_manifest,
  ]

  name              = "${var.naming_prefix}-vm"
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = var.key_pair_name
  user_data         = local.cloud_init

  tags = var.tags

  # The aws_lightsail_instance provider sometimes fails to detect user_data
  # diffs, leaving instances on stale cloud-init. Hash the rendered
  # cloud-init explicitly and use it as a replacement trigger.
  lifecycle {
    replace_triggered_by = [terraform_data.user_data_hash]
  }
}

resource "aws_lightsail_static_ip_attachment" "main" {
  static_ip_name = aws_lightsail_static_ip.main.name
  instance_name  = aws_lightsail_instance.main.name

  # When the Lightsail instance is replaced (e.g. user_data changes), the
  # attachment must be re-created — otherwise the static IP stays detached
  # and DNS keeps resolving to a now-unowned address. The terraform-provider
  # doesn't infer this dependency from instance_name alone, so force it.
  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.main]
  }
}

# Open ports: 22 (SSH), 80 (HTTP for ACME challenge), 443 (HTTPS).
resource "aws_lightsail_instance_public_ports" "main" {
  instance_name = aws_lightsail_instance.main.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
}
