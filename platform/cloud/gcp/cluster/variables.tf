variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "cluster_endpoint_cidr" {
  description = "The single CIDR allowed to reach the public GKE control-plane endpoint. Empty leaves the endpoint unrestricted; a production profile requires a value and refuses 0.0.0.0/0."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "GKE cluster name and resource name prefix (e.g. acme-prod)"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster (e.g. acme.com)"
  type        = string
}

variable "nodes_cidr" {
  type    = string
  default = "10.0.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.2.0.0/20"
}

variable "master_cidr" {
  description = "CIDR for the GKE control plane (must be /28, cannot overlap other ranges)"
  type        = string
  default     = "172.16.0.0/28"
}

variable "sql_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-g1-small"
}

variable "sql_disk_gb" {
  type    = number
  default = 20
}

variable "sql_high_availability" {
  description = "Enable Cloud SQL high availability (REGIONAL). Doubles cost."
  type        = bool
  default     = false
}

variable "gke_deletion_protection" {
  description = "Enable the GKE provider's deletion protection on the cluster. Default true (a direct destroy fails rather than deleting a cluster); `sol destroy` sets it false for the Destroy phase."
  type        = bool
  default     = true
}

variable "sql_deletion_protection" {
  description = "Enable both Terraform's destroy guard and Cloud SQL API deletion protection."
  type        = bool
  default     = true
}

variable "publisher_service_account" {
  description = "Optional Google service account email used by CI to push images. Sol grants it roles/artifactregistry.writer on this cluster's repository only; it gets no Kubernetes API authority."
  type        = string
  default     = ""
}

variable "provisioner_impersonators" {
  description = "IAM members (for example `user:ops@example.com`, or a service account) allowed to impersonate the platform provisioner and enter the install window. Each receives roles/iam.serviceAccountTokenCreator on that one identity."
  type        = list(string)
  default     = []
}

variable "provisioner_bootstrap_admin" {
  description = "Temporarily grant the platform provisioner the in-cluster authority the install needs. Sol opens this for the install window and closes it before Ready."
  type        = bool
  default     = false
}

variable "db_password" {
  description = "PostgreSQL admin password. Required when create_database is true; unused otherwise."
  type        = string
  sensitive   = true
  default     = ""
}

variable "create_database" {
  description = "Create a Cloud SQL PostgreSQL instance. Mirrors AWS's create_rds so both providers derive provisioning from the same resolved ownership decision."

  type    = bool
  default = true
}

variable "create_dns_zone" {
  description = "Create a new Cloud DNS managed zone for base_domain."
  type        = bool
  default     = true
}

variable "enable_durable_observability" {
  description = "Provision GCS buckets + Workload Identity service accounts for durable Loki (OBS-006) and Thanos-backed Prometheus (OBS-007) storage. Pair with platform/cloud/modules/platform's observability_backend = \"self_hosted_durable\". Mirrors platform/cloud/aws/cluster's enable_durable_observability."
  type        = bool
  default     = false
}

variable "loki_retention_days" {
  description = "GCS lifecycle retention (days) for durable Loki logs."
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

variable "gcs_soft_delete_retention_seconds" {
  description = "Soft-delete retention for the observability buckets, in seconds: 0 (disabled) or 7-90 days."
  type        = number
  default     = 604800

  validation {
    condition     = var.gcs_soft_delete_retention_seconds == 0 || (var.gcs_soft_delete_retention_seconds >= 604800 && var.gcs_soft_delete_retention_seconds <= 7776000)
    error_message = "gcs_soft_delete_retention_seconds must be 0 (disabled) or between 604800 (7 days) and 7776000 (90 days)."
  }
}


variable "node_count" {
  description = "Nodes in the platform's node pool. Four is the shape the profile recommends (Sol_cli_profile.recommended_node_shape): with one node held back for node-failure headroom, three of them still carry the platform's capacity envelope. The node footprint stays well inside the project's disk quota at this size too."
  type        = number
  default     = 4
}

variable "node_machine_type" {
  description = "Machine type for the platform's nodes. It must hold the platform's own largest request on ONE node: a redpanda broker asks 2 CPU and the loki chart's chunks cache 9.6 GiB, against about 3.9 CPU / 13 GiB allocatable on e2-standard-4 and 1.93 CPU / 5.88 GiB on e2-standard-2. internal/ci/check_node_shape_fits_platform.py holds that fit (FND-0066)."
  type        = string
  default     = "e2-standard-4"
}

variable "node_zones" {
  description = "Optional explicit zone list for the GKE control plane/node pool. Empty uses the first UP zone the provider reports for the region, so regions without an -a zone are valid; the pool keeps one zone and the four-node count."
  type        = list(string)
  default     = []
}

variable "node_disk_gb" {
  description = "Boot disk size for each node, in GiB. pd-balanced disks count against the region's SSD_TOTAL_GB quota, which the lifecycle checks before the platform asks for a volume."
  type        = number
  default     = 100
}
