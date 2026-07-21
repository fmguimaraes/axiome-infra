# Compute DR: EBS snapshot lifecycle policy (FR4, NFR4, NFR6).
#
# Uses AWS Data Lifecycle Manager (DLM) to automate encrypted snapshots of the
# production EC2 root volume. Together with the rebuild-from-IaC drill runbook
# (axiome-docs/reports/infra/FR4-Rebuild-Drill.md), this satisfies AC4:
#   "The production host is rebuilt from IaC + restored volumes in a drill within RTO."

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# DLM needs an IAM role to call EC2 CreateSnapshot / DeleteSnapshot and to use
# the data-at-rest CMK for encryption. This role is NOT the instance profile; it
# is assumed by the DLM service itself.
resource "aws_iam_role" "dlm" {
  name = "${var.naming_prefix}-dlm-lifecycle"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "dlm" {
  role = aws_iam_role.dlm.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SnapshotVolume"
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:DeleteSnapshot",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
      {
        Sid      = "EncryptWithCmk"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [var.data_cmk_arn]
      },
      {
        Sid    = "TagSnapshot"
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}::snapshot/*",
        ]
      },
      {
        Sid      = "ManageOwnTagsOnCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = ["arn:aws:ec2:${data.aws_region.current.name}::snapshot/*"]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSnapshot"
          }
        }
      },
    ]
  })
}

# DLM lifecycle policy — targets the EC2 instance by the DlmPolicy tag. Every
# EBS volume attached to the matching instance is snapshotted. Using a tag
# instead of a volume-id means the policy survives an instance recreate.
resource "aws_dlm_lifecycle_policy" "root_volume" {
  description        = "${var.naming_prefix} EBS root-volume daily snapshots (FR4)"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    policy_type = "EBS_SNAPSHOT_MANAGEMENT"

    resource_types = ["INSTANCE"]

    target_tags = {
      DlmPolicy = var.dlm_target_tag_value
    }

    schedule {
      name = "${var.naming_prefix}-daily"

      # Copy instance/volume tags onto each snapshot for discoverability during
      # the rebuild drill (FR4 runbook).
      copy_tags = var.copy_tags

      create_rule {
        cron_expression = var.snapshot_schedule
      }

      retain_rule {
        count = var.snapshot_retain_count
      }
    }
  }

  tags = merge(var.tags, { Purpose = "compute-dr-ebs-snapshots" })
}
