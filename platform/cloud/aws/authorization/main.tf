terraform {
  required_version = ">= 1.6"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  role_path     = "sol/${var.environment}/"
  boundary_name = "sol-${var.environment}-workload-boundary"
  reconciler    = "sol-${var.environment}-authorization"
}

data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "InvokeEnvironmentFunctions"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.region}:${local.account_id}:function:*"]
  }

  statement {
    sid    = "ReadEnvironmentSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:sol/${var.environment}/*"]
  }

  statement {
    sid       = "ConnectToEnvironmentDatabase"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.region}:${local.account_id}:dbuser:*/*"]
  }

  statement {
    sid    = "UseEnvironmentKafka"
    effect = "Allow"
    actions = [
      "kafka-cluster:Connect",
      "kafka-cluster:AlterGroup",
      "kafka-cluster:DescribeGroup",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:ReadData",
      "kafka-cluster:WriteData",
    ]
    resources = ["arn:aws:kafka:${var.region}:${local.account_id}:cluster/sol-${var.environment}/*"]
  }

  statement {
    sid    = "WriteEnvironmentObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::sol-${var.environment}-*",
      "arn:aws:s3:::sol-${var.environment}-*/*",
    ]
  }

  dynamic "statement" {
    for_each = {
      for grant in local.boundary_external_grants :
      "${grant.capability}/${grant.resource}" => grant
      if can(regex("^message\\.", grant.capability))
    }
    content {
      sid       = "ExternalQueue${substr(sha1(statement.key), 0, 8)}"
      effect    = "Allow"
      actions   = local.capability_actions[statement.value.capability]
      resources = [statement.value.resource]
    }
  }

  dynamic "statement" {
    for_each = {
      for grant in local.boundary_external_grants :
      "${grant.capability}/${grant.resource}" => grant
      if grant.capability == "object.read" || grant.capability == "object.write"
    }
    content {
      sid       = "ExternalObject${substr(sha1(statement.key), 0, 8)}"
      effect    = "Allow"
      actions   = local.capability_actions[statement.value.capability]
      resources = [statement.value.resource]
    }
  }

}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  path        = "/"
  description = "Maximum authority any Sol workload role for ${var.environment} may hold (DEC-062)."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

data "aws_iam_policy_document" "reconciler_trust" {
  count = var.reconciler_trust_principal_arn == "" ? 0 : 1
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.reconciler_trust_principal_arn]
    }
  }
}

data "aws_iam_policy_document" "reconciler" {
  count = var.reconciler_trust_principal_arn == "" ? 0 : 1
  statement {
    sid       = "CreateWorkloadRolesOnlyUnderTheEnvironmentPathWithTheBoundary"
    effect    = "Allow"
    actions   = ["iam:CreateRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.role_path}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid    = "ManageTheWorkloadRolesItOwns"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.role_path}*"]
  }

  statement {
    sid    = "AssociateEnvironmentPodsWithTheirWorkloadRoles"
    effect = "Allow"
    actions = [
      "eks:CreatePodIdentityAssociation",
      "eks:DeletePodIdentityAssociation",
      "eks:DescribePodIdentityAssociation",
      "eks:ListPodIdentityAssociations",
    ]
    resources = ["arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name == "" ? "*" : var.cluster_name}"]
  }

  statement {
    sid       = "ReadTheBoundary"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [aws_iam_policy.workload_boundary.arn]
  }

  statement {
    sid    = "NeverReplaceOrRemoveTheBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.role_path}*"]
  }

  statement {
    sid    = "NeverMutateIdentitiesOutsideTheEnvironment"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateGroup",
      "iam:CreatePolicy",
      "iam:CreateSAMLProvider",
      "iam:CreateOpenIDConnectProvider",
      "iam:UpdateAssumeRolePolicy",
      "iam:AddUserToGroup",
      "iam:AttachUserPolicy",
      "iam:AttachGroupPolicy",
      "iam:PutUserPolicy",
      "iam:PutGroupPolicy",
      "organizations:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "reconciler" {
  count                = var.reconciler_trust_principal_arn == "" ? 0 : 1
  name                 = local.reconciler
  path                 = "/sol/authorization/"
  assume_role_policy   = data.aws_iam_policy_document.reconciler_trust[0].json
  description          = "Fenced reconciler for ${var.environment}'s Sol workload roles and grants (DEC-062)."
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "reconciler" {
  count  = var.reconciler_trust_principal_arn == "" ? 0 : 1
  name   = "sol-${var.environment}-authorization"
  role   = aws_iam_role.reconciler[0].id
  policy = data.aws_iam_policy_document.reconciler[0].json
}

locals {
  capability_actions = {
    secret = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    "message.publish" = ["sqs:SendMessage"]
    "message.subscribe" = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
    ]
    "object.read"  = ["s3:GetObject"]
    "object.write" = ["s3:PutObject"]
  }

  realized_grants = [
    for grant in var.grants : grant
    if contains(keys(local.capability_actions), grant.capability)
  ]

  grant_units = toset([for grant in local.realized_grants : grant.unit])

  boundary_external_grants = concat(
    [
      for grant in var.grants : {
        capability = grant.capability
        resource   = grant.resource
      }
    ],
    flatten([
      for unit in var.serverless_units : [
        for requirement in unit.requirements : {
          capability = requirement.capability
          resource   = requirement.resource
        }
      ]
    ])
  )

  serverless_units = toset([for unit in var.serverless_units : unit.unit])

  scheduler_units = { for unit in var.scheduler_units : unit.unit => unit }

  role_units = setunion(local.grant_units, local.serverless_units)

  serverless_requirements_by_unit = {
    for unit in var.serverless_units : unit.unit => unit.requirements
  }

  grants_by_unit = {
    for unit in local.grant_units : unit => [
      for grant in local.realized_grants : grant if grant.unit == unit
    ]
  }

  serverless_statements = {
    for unit in local.serverless_units : unit => concat(
      [
        for i, requirement in local.serverless_requirements_by_unit[unit] : {
          Sid    = "SolSecret${i}"
          Effect = "Allow"
          Action = local.capability_actions[requirement.capability]
          Resource = [
            "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:sol/${var.environment}/${requirement.resource}*"
          ]
        } if requirement.capability == "secret"
      ],
      [
        for i, requirement in local.serverless_requirements_by_unit[unit] : {
          Sid      = "SolCapability${i}"
          Effect   = "Allow"
          Action   = local.capability_actions[requirement.capability]
          Resource = [requirement.resource]
        } if contains(keys(local.capability_actions), requirement.capability) && requirement.capability != "secret"
      ],
      [
        {
          Sid    = "SolLambdaLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = [
            "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/*"
          ]
        }
      ]
    )
  }

  grant_statements = {
    for unit in local.grant_units : unit => [
      for i, grant in local.grants_by_unit[unit] : {
        Sid    = "Sol${i}"
        Effect = "Allow"
        Action = local.capability_actions[grant.capability]
        Resource = (
          grant.capability == "secret"
          ? ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:sol/${var.environment}/${grant.resource}*"]
          : [grant.resource]
        )
      }
    ]
  }
}

data "aws_iam_policy_document" "workload_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      # EKS Pod Identity association ARNs use the standard EKS service/region segments:
      # arn:aws:eks:<region>:<account>:podidentityassociation/<cluster>/<association-id>.
      values = [
        "arn:aws:eks:${var.region}:${local.account_id}:podidentityassociation/${var.cluster_name}/*",
      ]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each             = local.role_units
  name                 = "sol-${var.environment}-${replace(each.value, "/", "-")}"
  path                 = "/${local.role_path}"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.workload_trust.json
  description          = "Sol workload identity for ${each.value} in ${var.environment} (DEC-062)."
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.role_units
  name     = "sol-${var.environment}-${each.value}"
  role     = aws_iam_role.workload[each.value].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      lookup(local.grant_statements, each.value, []),
      lookup(local.serverless_statements, each.value, [])
    )
  })
}

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  for_each             = local.scheduler_units
  name                 = "sol-${var.environment}-sched-${substr(sha1(each.key), 0, 8)}"
  path                 = "/${local.role_path}"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.scheduler_trust.json
  description          = "Dedicated scheduler identity for ${each.key} in ${var.environment}."
}

resource "aws_iam_role_policy" "scheduler" {
  for_each = local.scheduler_units
  name     = "sol-scheduler"
  role     = aws_iam_role.scheduler[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          "arn:aws:lambda:${var.region}:${local.account_id}:function:${each.value.function_name}:live"
        ]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each        = var.cluster_name == "" ? toset([]) : local.grant_units
  cluster_name    = var.cluster_name
  namespace       = local.grants_by_unit[each.value][0].namespace
  service_account = each.value
  role_arn        = aws_iam_role.workload[each.value].arn
}
