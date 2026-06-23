# HDS-in-scope EC2 compute (FR1) — replaces Lightsail. Runs the same containerized
# stack via the shared cloud-init templates, in the VPC, with an Elastic IP that the
# Microsoft 365 A record for platform.axiomebio.com points at (FR7). TLS via Caddy/LE.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Scoped runtime IAM user (SSM read + ECR pull + S3 rw on axiome-* buckets),
# injected via cloud-init — mirrors the Lightsail module so the proven init.sh
# template is reused unchanged.
resource "aws_iam_user" "runtime" {
  name = "${var.naming_prefix}-ec2-runtime"
  tags = var.tags
}

resource "aws_iam_user_policy" "runtime" {
  user = aws_iam_user.runtime.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${var.naming_prefix}-*", "arn:aws:s3:::${var.naming_prefix}-*/*"]
      },
      # CloudWatch Logs ingestion (FR9 / NFR8). The amazon-cloudwatch-agent on the box
      # runs under these [default] creds, so the log-shipping grant lives here, scoped
      # to the single in-region log group it writes to.
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:CreateLogGroup"]
        Resource = ["${aws_cloudwatch_log_group.ec2.arn}", "${aws_cloudwatch_log_group.ec2.arn}:*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "runtime" {
  user = aws_iam_user.runtime.name
}

# SSM Session Manager — keyless, auditable shell + run-command (no SSH key on this
# box). Needed for HDS ops (migrations, debugging) without opening port 22 to SSH.
resource "aws_iam_role" "ssm" {
  name = "${var.naming_prefix}-ec2-ssm"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 read/write on the platform buckets, granted to the *instance profile role*
# (not only the runtime IAM user). Application containers have no static AWS
# credentials; they obtain temporary credentials from IMDS via this role, which
# requires metadata_options.http_put_response_hop_limit = 2 on the instance so
# the Docker bridge network can reach the metadata endpoint.
resource "aws_iam_role_policy" "s3" {
  role = aws_iam_role.ssm.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = ["arn:aws:s3:::${var.naming_prefix}-*", "arn:aws:s3:::${var.naming_prefix}-*/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.naming_prefix}-ec2-ssm"
  role = aws_iam_role.ssm.name
}

# ---------------- CloudWatch Logs sink (FR9 / NFR8) ----------------
# Container stdout/stderr (json-file) + host bootstrap logs are shipped here by the
# amazon-cloudwatch-agent (see cloud-init step 13). The json-file driver is kept so
# `docker compose logs` still works for SSM debugging; the agent only tails the files.
#
# Dedicated CMK (not the shared data CMK, whose default key policy can't be granted to
# the logs service without an invasive rewrite). Encryption at rest per CONTRACT §6;
# the group lives in ${data.aws_region.current.name} only, per CONTRACT §1.
locals {
  log_group_name = "/axiome/${var.environment}/ec2"
}

resource "aws_kms_key" "logs" {
  description             = "${var.naming_prefix} CloudWatch Logs CMK"
  deletion_window_in_days = var.environment == "production" ? 30 : 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Purpose = "cloudwatch-logs-cmk" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.naming_prefix}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

resource "aws_cloudwatch_log_group" "ec2" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = var.tags
}

locals {
  caddyfile = templatefile("${path.module}/../../cloud-init/Caddyfile.tftpl", {
    fqdn         = var.fqdn
    behind_proxy = false
  })

  docker_compose_yml = file("${path.module}/../../cloud-init/docker-compose.yml")

  legacy_image_tag_env = var.use_ssm_image_tags ? "" : <<-EOT
    BACKEND_IMAGE_TAG=${var.backend_image_tag}
    BIOCOMPUTE_IMAGE_TAG=${var.biocompute_image_tag}
    FRONTEND_IMAGE_TAG=${var.frontend_image_tag}
  EOT

  cloud_init = templatefile("${path.module}/../../cloud-init/init.sh.tftpl", {
    aws_region            = var.aws_region
    aws_access_key_id     = aws_iam_access_key.runtime.id
    aws_secret_access_key = aws_iam_access_key.runtime.secret
    ssm_parameter_prefix  = var.ssm_parameter_prefix
    ecr_registry          = var.ecr_registry
    fqdn                  = var.fqdn
    environment           = var.environment
    project_name          = var.naming_prefix
    docker_compose_yml    = local.docker_compose_yml
    caddyfile             = local.caddyfile
    legacy_image_tag_env  = local.legacy_image_tag_env
    cloudwatch_log_group  = local.log_group_name
  })
}

# Public edge SG for the single-VM: 22 (SSH), 80 (ACME), 443 (HTTPS).
resource "aws_security_group" "instance" {
  name        = "${var.naming_prefix}-ec2"
  description = "EC2 compute (Caddy edge + app stack)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.naming_prefix}-ec2" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instance.id, var.app_security_group_id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  user_data              = local.cloud_init

  # Do NOT replace the instance when cloud-init changes. This is the single live
  # platform with in-VM state (mongo_data); a cloud-init edit (e.g. adding the
  # CloudWatch agent) must not trigger a destroy/recreate. The new user_data applies
  # on the next natural boot; to roll it onto the running box immediately, push the
  # change via SSM (scripts/ssm-exec.sh) instead of rebuilding.
  user_data_replace_on_change = false

  # IMDSv2 required; hop limit 2 so containers on the Docker bridge network can
  # reach the metadata endpoint to assume the instance role (S3 access).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.naming_prefix}-ec2" })

  # Pin the AMI: data.aws_ami.ubuntu uses most_recent, so each new Canonical
  # release would otherwise force-replace this stateful VM (wiping the in-VM
  # mongo_data volume + causing downtime). OS patching happens in-place via apt.
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "main" {
  instance = aws_instance.main.id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.naming_prefix}-eip" })
}
