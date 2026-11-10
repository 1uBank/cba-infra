# ---------------------------------------------------------------------------
# Deploy roles for cba-auth and cba-banking-api (one role per repo, least privilege).
# The existing role in main.tf (cba-core) is unchanged.
#
# Names line up with modules/cba-core (prefix = var.prefix, e.g. cba-core-dev):
#   ECR repos:      <prefix>-auth-api, <prefix>-auth-realm-loader, <prefix>-banking-api
#   ECS services:   <prefix>-auth, <prefix>-banking-api   (cluster: <prefix>)
#   Task families:  <prefix>-auth, <prefix>-auth-realm-loader, <prefix>-banking-api
#   Task roles:     <prefix>-auth-task, <prefix>-banking-api-task, plus <prefix>-exec
#
# allowed_subjects must match the 'sub' claim GitHub actually sends. Your cba-core
# subject in oidc.auto.tfvars uses the ID form (repo:ORG@<org id>/REPO@<repo id>:...).
# Use the same form here if that is what your organization emits; to check, print the
# decoded token's sub in a debug step of the workflow.
# ---------------------------------------------------------------------------

variable "service_deployments" {
  description = "GitHub repos that deploy to ECS through OIDC, keyed by a short name."
  type = map(object({
    allowed_subjects = list(string)
    ecr_repos        = list(string) # repository names
    service          = string       # ECS service name
    task_families    = list(string) # task definition families the pipeline registers
    pass_roles       = list(string) # IAM role names ECS passes to the tasks
    run_task_family  = optional(string)
  }))

  default = {
    "cba-auth" = {
      allowed_subjects = ["repo:1uBank/cba-auth:ref:refs/heads/dev"]
      ecr_repos        = ["cba-core-dev-auth-api", "cba-core-dev-auth-realm-loader"]
      service          = "cba-core-dev-auth"
      task_families    = ["cba-core-dev-auth", "cba-core-dev-auth-realm-loader"]
      pass_roles       = ["cba-core-dev-exec", "cba-core-dev-auth-task"]
      run_task_family  = "cba-core-dev-auth-realm-loader"
    }
    "cba-banking-api" = {
      allowed_subjects = ["repo:1uBank/cba-banking-api:ref:refs/heads/dev"]
      ecr_repos        = ["cba-core-dev-banking-api"]
      service          = "cba-core-dev-banking-api"
      task_families    = ["cba-core-dev-banking-api"]
      pass_roles       = ["cba-core-dev-exec", "cba-core-dev-banking-api-task"]
    }
  }
}

data "aws_iam_policy_document" "service_trust" {
  for_each = var.service_deployments

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
      values   = each.value.allowed_subjects
    }
  }
}

resource "aws_iam_role" "service_deploy" {
  for_each = var.service_deployments

  name                 = "${var.prefix}-gha-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.service_trust[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "service_deploy" {
  for_each = var.service_deployments

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
    resources = [for r in each.value.ecr_repos : "arn:aws:ecr:${var.region}:${local.account_id}:repository/${r}"]
  }

  statement {
    sid       = "EcsTaskDefinitions" # these two actions do not support resource-level permissions
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "EcsService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["arn:aws:ecs:${var.region}:${local.account_id}:service/${var.prefix}/${each.value.service}"]
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [for r in each.value.pass_roles : "arn:aws:iam::${local.account_id}:role/${r}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Only the realm loader repo (cba-auth) runs a one-off task and waits for it.
  dynamic "statement" {
    for_each = each.value.run_task_family != null ? [each.value.run_task_family] : []

    content {
      sid       = "RunOneOffTask"
      actions   = ["ecs:RunTask"]
      resources = ["arn:aws:ecs:${var.region}:${local.account_id}:task-definition/${statement.value}:*"]

      condition {
        test     = "ArnEquals"
        variable = "ecs:cluster"
        values   = ["arn:aws:ecs:${var.region}:${local.account_id}:cluster/${var.prefix}"]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.run_task_family != null ? [1] : []

    content {
      sid       = "WatchOneOffTask"
      actions   = ["ecs:DescribeTasks"]
      resources = ["arn:aws:ecs:${var.region}:${local.account_id}:task/${var.prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "service_deploy" {
  for_each = var.service_deployments

  name   = "deploy-to-ecs"
  role   = aws_iam_role.service_deploy[each.key].id
  policy = data.aws_iam_policy_document.service_deploy[each.key].json
}

output "service_deploy_role_arns" {
  description = "Put each ARN in the AWS_ROLE_ARN variable of the matching GitHub repo."
  value       = { for k, r in aws_iam_role.service_deploy : k => r.arn }
}
