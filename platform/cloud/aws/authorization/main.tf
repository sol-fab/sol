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
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  path        = "/"
  description = "Maximum authority any Sol workload role for ${var.environment} may hold (DEC-062)."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

data "aws_iam_policy_document" "reconciler_trust" {
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
  name                 = local.reconciler
  path                 = "/sol/authorization/"
  assume_role_policy   = data.aws_iam_policy_document.reconciler_trust.json
  description          = "Fenced reconciler for ${var.environment}'s Sol workload roles and grants (DEC-062)."
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "reconciler" {
  name   = "sol-${var.environment}-authorization"
  role   = aws_iam_role.reconciler.id
  policy = data.aws_iam_policy_document.reconciler.json
}

locals {
  capability_actions = {
    secret = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
  }

  realized_grants = [
    for grant in var.grants : grant
    if contains(keys(local.capability_actions), grant.capability)
  ]

  grant_units = toset([for grant in local.realized_grants : grant.unit])

  grants_by_unit = {
    for unit in local.grant_units : unit => [
      for grant in local.realized_grants : grant if grant.unit == unit
    ]
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
          : ["*"]
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
      # EKS Pod Identity association ARNs omit the service and region segments:
      # arn:aws::<account>:podidentityassociation/<cluster>/<association-id>.
      values = ["arn:aws::${local.account_id}:podidentityassociation/${var.cluster_name}/*"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each             = local.grant_units
  name                 = "sol-${var.environment}-${each.value}"
  path                 = "/${local.role_path}"
  permissions_boundary = aws_iam_policy.workload_boundary.arn
  assume_role_policy   = data.aws_iam_policy_document.workload_trust.json
  description          = "Sol workload identity for ${each.value} in ${var.environment} (DEC-062)."
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.grant_units
  name     = "sol-${var.environment}-${each.value}"
  role     = aws_iam_role.workload[each.value].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.grant_statements[each.value]
  })
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each        = var.cluster_name == "" ? toset([]) : local.grant_units
  cluster_name    = var.cluster_name
  namespace       = local.grants_by_unit[each.value][0].namespace
  service_account = each.value
  role_arn        = aws_iam_role.workload[each.value].arn
}
