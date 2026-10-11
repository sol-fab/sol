terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.7"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]

  enable_nat_gateway   = true
  single_nat_gateway   = !var.ha_nat_gateway
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  cluster_endpoint_public_access_cidrs = (
    var.cluster_endpoint_cidr == "" ? null : [var.cluster_endpoint_cidr]
  )

  cluster_addons = {
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    general = {
      iam_role_name = "${var.cluster_name}-node-group"

      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      disk_size = 50

      labels = { role = "general" }
    }
  }

  enable_irsa = true

  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin

  access_entries = merge(
    var.cluster_access_role_arn == "" ? {} : {
      platform_cluster_access = {
        principal_arn     = var.cluster_access_role_arn
        kubernetes_groups = ["sol:platform-provisioners"]
        policy_associations = var.provisioner_bootstrap_admin ? {
          bootstrap = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        } : {}
      }
    },
    var.deploy_role_arn == "" ? {} : {
      deploy = {
        principal_arn     = var.deploy_role_arn
        kubernetes_groups = ["sol:deployers"]
      }
    },
    var.operator_role_arn == "" ? {} : {
      operator = {
        principal_arn     = var.operator_role_arn
        kubernetes_groups = ["sol:operators"]
      }
    },
  )

  tags = var.tags
}

resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.workspace_name}/${each.value}"
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_db_subnet_group" "main" {
  count      = var.create_rds ? 1 : 0
  name       = "${var.cluster_name}-postgres"
  subnet_ids = module.vpc.private_subnets
  tags       = var.tags
}

resource "aws_security_group" "rds" {
  count  = var.create_rds ? 1 : 0
  name   = "${var.cluster_name}-rds"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  tags = var.tags
}

resource "aws_db_instance" "postgres" {
  count             = var.create_rds ? 1 : 0
  identifier        = "${var.cluster_name}-postgres"
  engine            = "postgres"
  engine_version    = "16.15"
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_storage_gb
  storage_encrypted = true

  # Pinned, not left to the account/region default. RDS presents a leaf signed by the CA
  # this names, and `postgres_ca_cert` below carries the bundle that must contain it: the
  # two are coupled and live here together, updated together when AWS retires a CA. Unless
  # this is pinned, `sslmode=verify-full` verifies against a moving target.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_name  = "app"
  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  backup_retention_period = 7
  multi_az                = var.rds_multi_az
  deletion_protection     = var.rds_deletion_protection
  skip_final_snapshot     = var.rds_skip_final_snapshot
  final_snapshot_identifier = (
    var.rds_skip_final_snapshot
    ? null
    : (
      var.rds_final_snapshot_identifier != ""
      ? var.rds_final_snapshot_identifier
      : "${var.cluster_name}-postgres-final"
    )
  )

  tags = var.tags

  lifecycle {
    precondition {
      condition = (
        length(var.db_password) >= 8
        && !strcontains(var.db_password, "/")
        && !strcontains(var.db_password, "@")
        && !strcontains(var.db_password, "\"")
      )
      error_message = "db_password must be at least 8 characters and must not contain /, @ or a double quote (RDS master-password rules) when create_rds = true. Supply it out of band from your secret store, e.g. TF_VAR_db_password=... -- never with -var, because Sol records the terraform command line in its run log."
    }
  }
}

locals {
  managed_resources = var.create_rds ? {
    postgres = {
      resource_type        = "rds"
      cloudwatch_namespace = "AWS/RDS"
      dimension_name       = "DBInstanceIdentifier"
      dimension_value      = aws_db_instance.postgres[0].identifier
      metrics              = ["CPUUtilization", "DatabaseConnections", "FreeStorageSpace", "ReadIOPS", "WriteIOPS"]
    }
  } : {}
}

resource "aws_cloudwatch_dashboard" "managed_resource" {
  for_each       = local.managed_resources
  dashboard_name = "${var.cluster_name}-${each.key}"

  dashboard_body = jsonencode({
    widgets = [
      for i, metric in each.value.metrics : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = metric
          region  = var.region
          stat    = "Average"
          period  = 300
          metrics = [[each.value.cloudwatch_namespace, metric, each.value.dimension_name, each.value.dimension_value]]
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "grafana_cloudwatch" {
  count = length(local.managed_resources) > 0 ? 1 : 0

  statement {
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarmsForMetric",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana_cloudwatch" {
  count  = length(local.managed_resources) > 0 ? 1 : 0
  name   = "${var.cluster_name}-grafana-cloudwatch"
  policy = data.aws_iam_policy_document.grafana_cloudwatch[0].json
}

module "grafana_irsa" {
  count   = length(local.managed_resources) > 0 ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-grafana"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:grafana"]
    }
  }

  role_policy_arns = {
    grafana_cloudwatch = aws_iam_policy.grafana_cloudwatch[0].arn
  }
}

resource "aws_route53_zone" "main" {
  name  = var.base_domain
  count = var.create_route53_zone ? 1 : 0
  tags  = var.tags
}

data "aws_route53_zone" "existing" {
  count = var.create_route53_zone ? 0 : 1

  name         = var.base_domain
  private_zone = false
}

locals {
  route53_zone_arn = var.create_route53_zone ? aws_route53_zone.main[0].arn : data.aws_route53_zone.existing[0].arn
}

data "aws_iam_policy_document" "cert_manager" {
  statement {
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = [local.route53_zone_arn]
  }
  statement {
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cert_manager" {
  name   = "${var.cluster_name}-cert-manager"
  policy = data.aws_iam_policy_document.cert_manager.json
}

module "cert_manager_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-cert-manager"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  role_policy_arns = {
    cert_manager = aws_iam_policy.cert_manager.arn
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  policy_name_prefix = "${var.cluster_name}-"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn

  depends_on = [module.eks]
}

resource "aws_s3_bucket" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = "${var.cluster_name}-loki-logs"
  tags   = var.tags

  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = aws_s3_bucket.loki[0].id

  rule {
    id     = "expire-old-chunks"
    status = "Enabled"
    filter {}
    expiration {
      days = var.loki_retention_days
    }
  }
}

data "aws_iam_policy_document" "loki_s3" {
  count = var.enable_durable_observability ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki[0].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki[0].arn}/*"]
  }
}

resource "aws_iam_policy" "loki_s3" {
  count  = var.enable_durable_observability ? 1 : 0
  name   = "${var.cluster_name}-loki-s3"
  policy = data.aws_iam_policy_document.loki_s3[0].json
}

module "loki_irsa" {
  count   = var.enable_durable_observability ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-loki"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:loki"]
    }
  }

  role_policy_arns = {
    loki_s3 = aws_iam_policy.loki_s3[0].arn
  }
}

resource "aws_s3_bucket" "thanos" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = "${var.cluster_name}-thanos-metrics"
  tags   = var.tags

  force_destroy = true
}

data "aws_iam_policy_document" "thanos_s3" {
  count = var.enable_durable_observability ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.thanos[0].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.thanos[0].arn}/*"]
  }
}

resource "aws_iam_policy" "thanos_s3" {
  count  = var.enable_durable_observability ? 1 : 0
  name   = "${var.cluster_name}-thanos-s3"
  policy = data.aws_iam_policy_document.thanos_s3[0].json
}

module "thanos_irsa" {
  count   = var.enable_durable_observability ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-thanos"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "monitoring:prometheus-server",
        "monitoring:thanos-storegateway",
        "monitoring:thanos-compactor",
      ]
    }
  }

  role_policy_arns = {
    thanos_s3 = aws_iam_policy.thanos_s3[0].arn
  }
}
