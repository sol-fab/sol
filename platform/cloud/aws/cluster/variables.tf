variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name and resource name prefix (e.g. acme-prod)"
  type        = string
}

variable "workspace_name" {
  description = "Sol workspace name (the app's checkout directory basename, e.g. acme). Used to key ECR repository names so they match sol deploy's image references, which are workspace-scoped rather than cluster-scoped."
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster (e.g. acme.com). Subdomains are managed via Route53."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ha_nat_gateway" {
  description = "Deploy one NAT gateway per AZ (true) vs one shared gateway (false). Single gateway saves ~$100/month for dev clusters."
  type        = bool
  default     = false
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group. It must hold the platform's own largest request on ONE node: a redpanda broker asks 2 CPU and the loki chart's chunks cache 9.6 GiB, against about 3.9 CPU / 13 GiB allocatable on m6i.xlarge and 1.93 CPU / 5.88 GiB on m6i.large. internal/ci/check_node_shape_fits_platform.py holds that fit (FND-0066); the AWS half is inference from the platform's shared requests until an AWS run reaches a platform install."
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 10
}

variable "node_desired_size" {
  description = "Nodes the platform's node group runs. Four is the shape the profile recommends (Sol_cli_profile.recommended_node_shape): with one node held back for node-failure headroom, three of them still carry the platform's capacity envelope."
  type        = number
  default     = 4
}

variable "ecr_repositories" {
  description = "List of service names to create ECR repositories for, e.g. [\"charge-svc\", \"notify-worker\"]"
  type        = list(string)
  default     = []
}

variable "create_rds" {
  description = "Create an RDS PostgreSQL instance. Disable for low-cost substrate smoke tests."
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.small"
}

variable "rds_storage_gb" {
  description = "Allocated storage in GB for RDS"
  type        = number
  default     = 20
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "rds_deletion_protection" {
  description = "Enable RDS deletion protection. Set false to allow terraform destroy."
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "Skip the final snapshot when destroying the instance. Leave false in production: production database destruction takes a final snapshot unless explicitly governed otherwise."
  type        = bool
  default     = false
}

variable "rds_final_snapshot_identifier" {
  description = "Name for the snapshot Terraform takes when destroying the instance. Must be unique per snapshot; leave empty for the cluster-name default."
  type        = string
  default     = ""
}

variable "rds_multi_az" {
  description = "Run RDS with a synchronous standby in another availability zone."
  type        = bool
  default     = false
}

variable "create_route53_zone" {
  description = "Create a new Route53 hosted zone for base_domain. Set false if the zone already exists."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_durable_observability" {
  description = "Provision S3 buckets + IRSA roles for durable Loki (OBS-006) and Thanos-backed Prometheus (OBS-007) storage. Pair with platform/cloud/modules/platform's observability_backend = \"self_hosted_durable\"."
  type        = bool
  default     = false
}

variable "loki_retention_days" {
  description = "S3 lifecycle retention for durable Loki logs."
  type        = number
  default     = 90
  validation {
    condition     = var.loki_retention_days >= 1 && floor(var.loki_retention_days) == var.loki_retention_days
    error_message = "loki_retention_days must be a whole number of days >= 1."
  }
}

variable "alert_receiver_type" {
  type    = string
  default = ""
}

variable "alert_receiver_url" {
  type    = string
  default = ""
}

variable "alert_owner" {
  type    = string
  default = ""
}

variable "alert_runbook_url" {
  type    = string
  default = ""
}

variable "cluster_endpoint_cidr" {
  description = "The single CIDR allowed to reach the public Kubernetes API endpoint. Empty leaves the module default (0.0.0.0/0) for non-production clusters; a production-single-region target must set a specific value (enforced by sol deploy's preflight)."
  type        = string
  default     = ""

  validation {
    condition = (
      var.cluster_endpoint_cidr == ""
      || (can(cidrhost(var.cluster_endpoint_cidr, 0))
      && var.cluster_endpoint_cidr != "0.0.0.0/0")
    )
    error_message = "cluster_endpoint_cidr must be empty or a valid, non-world CIDR; an explicit 0.0.0.0/0 is never accepted."
  }
}

variable "enable_cluster_creator_admin" {
  description = "Grant the cluster-creator identity standing EKS admin. Default false: the normal production path uses the named identities from the target file, and bootstrapping/break-glass is a documented, scoped exception (AUDIT-072)."
  type        = bool
  default     = false
}

variable "provisioner_role_arn" {
  description = "Named AWS cloud-provisioning principal. This identity reconciles the cloud substrate and bootstrap access association; it is not used for steady-state Kubernetes access."
  type        = string
  default     = ""
}

variable "cluster_access_role_arn" {
  description = "Named AWS steady-state cluster-access principal authenticated to EKS for the scoped platform lifecycle. Its IAM policy must not grant access-entry, policy-association, or IAM mutation."
  type        = string
  default     = ""
}

variable "provisioner_bootstrap_admin" {
  description = "Temporarily associate EKS cluster-admin while Sol installs the narrower platform-provisioner RBAC. Sol must remove this before applying the remaining platform."
  type        = bool
  default     = false
}

variable "deploy_role_arn" {
  description = "Named AWS deploy principal authenticated to EKS for application workload mutation (AUDIT-072). Grants only Kubernetes group membership here; the namespace-scoped RoleBinding is applied per application namespace by Sol_cli_substrate.ensure, not by Terraform, because application namespaces are created dynamically."
  type        = string
  default     = ""
}

variable "operator_role_arn" {
  description = "Named AWS operator principal authenticated to EKS for production observation and diagnosis (DEC-038). The generated AWS-side contract (bootstrap: eks:DescribeCluster/ListClusters + state read) lets it obtain a kubeconfig; this variable is what makes it usable once there, by granting Kubernetes group membership. The read-only cluster role it receives is platform/cloud/modules/platform/platform_operator_rbac.tf, bound per application namespace by Sol_cli_substrate.ensure for the same reason deploy's is: application namespaces are created dynamically. Without this, the identity Sol documents cannot reach the cluster at all."
  type        = string
  default     = ""
}
