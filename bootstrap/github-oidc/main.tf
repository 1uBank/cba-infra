# Lets GitHub Actions deploy to ECS without long-lived AWS keys (OIDC).
# Apply this once per AWS account/environment, with its own state.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Use the same S3 backend bucket as envs/dev, with a different key.
  backend "s3" {
    bucket       = "cba-deployment-bucket"
    key          = "cba-core/github-oidc-dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type = string
}

variable "github_org" {
  type    = string
  default = "1uBank"
}

variable "github_repo" {
  type    = string
  default = "cba-core"
}

variable "allowed_subjects" {
  description = "OIDC 'sub' claims allowed to assume the role. Branch-based by default. For prod, use GitHub Environments: repo:ORG/REPO:environment:prod (and require approvals on that environment)."
  type        = list(string)
  default     = ["repo:1uBank/cba-core:ref:refs/heads/dev"]
}

variable "create_oidc_provider" {
  description = "An AWS account can have only one GitHub OIDC provider. Set false if it already exists."
  type        = bool
  default     = true
}

variable "prefix" {
  description = "<name>-<environment> used by the cba-core module (so ECR repo, cluster, service, family and role names line up)."
  type        = string
  default     = "cba-core-dev"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  ecr_repo_arn = "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.prefix}"
  ecs_svc_arn  = "arn:aws:ecs:${var.region}:${local.account_id}:service/${var.prefix}/${var.prefix}"
  pass_roles = [
    "arn:aws:iam::${local.account_id}:role/${var.prefix}-exec",
    "arn:aws:iam::${local.account_id}:role/${var.prefix}-task",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself and ignores this value,
  # but older provider versions still require it.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.allowed_subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.prefix}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [local.ecr_repo_arn]
  }

  statement {
    sid       = "EcsTaskDefinitions" # these two actions do not support resource-level permissions
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "EcsService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [local.ecs_svc_arn]
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = local.pass_roles

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-to-ecs"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "deploy_role_arn" {
  description = "Put this in the GitHub repo variable AWS_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}
