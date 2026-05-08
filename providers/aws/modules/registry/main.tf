# ECR repositories are AWS-account-shared. Only one environment (production) creates
# them; dev and staging look them up via data sources.

locals {
  repos = ["backend", "biocompute", "frontend"]
}

resource "aws_ecr_repository" "axiome" {
  for_each = var.create_repositories ? toset(local.repos) : toset([])

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "axiome" {
  for_each = var.create_repositories ? aws_ecr_repository.axiome : {}

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 production tags"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
    ]
  })
}

# IAM role used by the Lightsail VM to pull images from ECR.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "ecr_pull" {
  name = "${var.project_name}-${terraform.workspace}-ecr-pull"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ecr_pull" {
  role = aws_iam_role.ecr_pull.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
    ]
  })
}
