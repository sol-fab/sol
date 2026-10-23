variable "base_domain" {
  description = "Base domain for Ingress resources, e.g. mycompany.com. Subdomains argocd.*, grafana.* are created."
  type        = string
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer name for TLS certificates."
  type        = string
  default     = "letsencrypt-prod"
}

variable "ingress_service_type" {
  description = "Kubernetes Service type for the ingress-nginx controller. Use LoadBalancer for cloud clusters, NodePort for k3d/local."
  type        = string
  default     = "LoadBalancer"
}

variable "create_storage_class" {
  description = "Create Sol's own default StorageClass. Always false on GCP and only meaningful there as an input a shared tooling invocation may still pass: GKE ships `standard-rwo` as the cluster default, so the platform adopts it and creating a second default class would leave the cluster with two."
  type        = bool
  default     = false
}

variable "storage_class_name" {
  description = "Name of the default StorageClass the platform's durable volumes bind to. On GCP that is GKE's adopted `standard-rwo`; the definition creates its own only on AWS."
  type        = string
  default     = "standard-rwo"
}

variable "cloud_provider" {
  description = "Cloud provider for provider-specific Kubernetes integrations. This root is the GCP one, so it defaults to gcp; Sol always sets it explicitly."
  type        = string
  default     = "gcp"
  validation {
    condition     = contains(["aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be one of: aws, gcp."
  }
}

variable "redpanda_replicas" {
  description = "Number of Redpanda broker replicas."
  type        = number
  default     = 3
}

variable "redpanda_cpu_cores" {
  description = "CPU cores per Redpanda broker."
  type        = number
  default     = 2
}

variable "redpanda_memory" {
  description = "Memory limit per Redpanda broker (e.g. 4Gi)."
  type        = string
  default     = "4Gi"
}

variable "redpanda_persistent_storage" {
  description = "Enable persistent volumes for Redpanda. Disable for ephemeral dev clusters."
  type        = bool
  default     = true
}

variable "gcp_provisioner_service_account" {
  description = "Google service account that acts as the platform provisioner on GCP, bound to the same ClusterRoles the AWS provisioner's group receives. Empty on AWS."
  type        = string
  default     = ""
}

variable "database_egress_cidrs" {
  description = "The ranges a workload must reach to use this target's managed database, derived by the cluster root from the placement Sol provisioned. Rendered into the cluster as a fact the deploy reads, so an application author never declares a CIDR."
  type        = list(string)
  default     = []
}

variable "cert_manager_dns01_project" {
  description = "GCP project holding the Cloud DNS zone cert-manager writes challenge records into. Sol passes the cloud root's own project_id here so the solver names the zone's project explicitly rather than inferring it from whichever credentials the pod happens to hold."
  type        = string
  default     = ""
}

variable "cert_manager_workload_identity_sa_email" {
  description = "GCP service account cert-manager impersonates to write Cloud DNS challenge records. From platform/cloud/gcp/cluster's cert_manager_workload_identity_sa_email output; empty means an ACME challenge runs without credentials (FND-0067)."
  type        = string
  default     = ""
}

variable "install_postgresql" {
  description = "Install in-cluster PostgreSQL. Set false when using RDS or Cloud SQL."
  type        = bool
  default     = false
}

variable "postgres_password" {
  description = "PostgreSQL admin password. Ignored when install_postgresql=false."
  type        = string
  default     = "dev"
  sensitive   = true
}

variable "postgres_persistent_storage" {
  description = "Enable persistent volumes for PostgreSQL."
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Break-glass Grafana admin password. When null, Sol generates one; retrieve it from the chart's `grafana` Secret in the monitoring namespace. SSO is the normal login path."
  type        = string
  default     = null
  sensitive   = true
}

variable "grafana_oidc_provider" {
  description = "Grafana OIDC provider family: google or custom."
  type        = string
  default     = "google"
  validation {
    condition     = contains(["google", "custom"], var.grafana_oidc_provider)
    error_message = "grafana_oidc_provider must be one of: google, custom."
  }
}

variable "grafana_oidc_client_id" {
  description = "OIDC client ID for Grafana."
  type        = string
  default     = ""
}

variable "grafana_oidc_client_secret" {
  description = "OIDC client secret for Grafana; supply as TF_VAR_grafana_oidc_client_secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_oidc_auth_url" {
  description = "OIDC authorization endpoint; empty uses the Google default."
  type        = string
  default     = ""
}

variable "grafana_oidc_token_url" {
  description = "OIDC token endpoint; empty uses the Google default."
  type        = string
  default     = ""
}

variable "grafana_oidc_api_url" {
  description = "OIDC userinfo endpoint; empty uses the Google default."
  type        = string
  default     = ""
}

variable "grafana_oidc_name" {
  description = "Display name of the SSO button."
  type        = string
  default     = "Google"
}

variable "grafana_oidc_scopes" {
  description = "Space-separated OIDC scopes."
  type        = string
  default     = "openid email profile"
}

variable "grafana_oidc_allowed_groups" {
  description = "Optional OIDC group names allowed to sign in."
  type        = list(string)
  default     = []
}

variable "grafana_oidc_role_attribute_path" {
  description = "Grafana role mapping expression over the OIDC claims."
  type        = string
  default     = "contains(groups[*], 'sol-grafana-admins') && 'Admin' || 'Viewer'"
}


variable "loki_persistent_storage" {
  description = "Enable persistent volumes for Loki."
  type        = bool
  default     = true
}

variable "prometheus_persistent_storage" {
  description = "Enable persistent volumes for Prometheus."
  type        = bool
  default     = true
}

variable "observability_backend" {
  description = <<-EOT
    Observability backend profile:
      local                — in-cluster Loki + Grafana + Prometheus (default).
      external             — point Alloy/Prometheus remote_write at a
                              user-supplied endpoint; skip installing local
                              Loki + Grafana (Prometheus still runs to scrape
                              and forward, with minimal local retention).
      self_hosted_durable — same in-cluster components as "local", but backed
                              by durable storage provisioned in
                              platform/cloud/aws/cluster (see OBS-006/OBS-007).
  EOT
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "external", "self_hosted_durable"], var.observability_backend)
    error_message = "observability_backend must be one of: local, external, self_hosted_durable."
  }
}

variable "platform_profile" {
  description = <<-EOT
    The profile layer of platform/shared/components.json used for Sol's own
    platform components (Redpanda, PostgreSQL):

      local   — the dev/default shape; Redpanda stays plaintext.
      durable — the production shape; Redpanda serves TLS-encrypted Kafka and
                schema registry with SASL authentication.

    Sol sets this from the target's platform profile, independently of the
    observability backend: a production profile must get the production Kafka
    transport even when its telemetry goes to an external backend.
  EOT
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "durable"], var.platform_profile)
    error_message = "platform_profile must be one of: local, durable."
  }
}

variable "external_loki_url" {
  description = "Loki push URL for the \"external\" profile, e.g. https://logs-prod-000.grafana.net/loki/api/v1/push. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_loki_username" {
  description = "Basic auth username for external_loki_url (e.g. a Grafana Cloud tenant ID). Leave empty for an endpoint that doesn't require auth."
  type        = string
  default     = ""
}

variable "external_loki_password" {
  description = "Basic auth password/API key for external_loki_url."
  type        = string
  default     = ""
  sensitive   = true
}

variable "external_prometheus_remote_write_url" {
  description = "Prometheus remote_write URL for the \"external\" profile. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_prometheus_username" {
  description = "Basic auth username for external_prometheus_remote_write_url."
  type        = string
  default     = ""
}

variable "external_prometheus_password" {
  description = "Basic auth password/API key for external_prometheus_remote_write_url."
  type        = string
  default     = ""
  sensitive   = true
}

variable "loki_gcs_bucket" {
  description = "GCS bucket for durable Loki storage. From platform/cloud/gcp/cluster's loki_gcs_bucket output."
  type        = string
  default     = ""
}

variable "loki_workload_identity_sa_email" {
  description = "GCP service account email for Loki's GCS access (Workload Identity). From platform/cloud/gcp/cluster's loki_workload_identity_sa_email output."
  type        = string
  default     = ""
}

variable "thanos_gcs_bucket" {
  description = "GCS bucket for durable Prometheus/Thanos storage. From platform/cloud/gcp/cluster's thanos_gcs_bucket output."
  type        = string
  default     = ""
}

variable "thanos_workload_identity_sa_email" {
  description = "GCP service account email for Thanos's GCS access (Workload Identity). From platform/cloud/gcp/cluster's thanos_workload_identity_sa_email output."
  type        = string
  default     = ""
}

variable "prometheus_raw_retention_days" {
  description = "Retention in days for raw Prometheus samples in Thanos compactor."
  type        = number
  default     = 90
  validation {
    condition     = var.prometheus_raw_retention_days >= 1 && floor(var.prometheus_raw_retention_days) == var.prometheus_raw_retention_days
    error_message = "prometheus_raw_retention_days must be a whole number of days >= 1."
  }
}

variable "thanos_retention_5m_days" {
  description = "Retention in days for Thanos 5m downsampled blocks."
  type        = number
  default     = 90
  validation {
    condition     = var.thanos_retention_5m_days >= 1 && floor(var.thanos_retention_5m_days) == var.thanos_retention_5m_days
    error_message = "thanos_retention_5m_days must be a whole number of days >= 1."
  }
}

variable "thanos_retention_1h_days" {
  description = "Retention in days for Thanos 1h downsampled blocks."
  type        = number
  default     = 90
  validation {
    condition     = var.thanos_retention_1h_days >= 1 && floor(var.thanos_retention_1h_days) == var.thanos_retention_1h_days
    error_message = "thanos_retention_1h_days must be a whole number of days >= 1."
  }
}

variable "managed_resource_dashboards" {
  description = <<-EOT
    Managed-resource dashboards to provision in Grafana (OBS-044): a map of
    resource name -> {resource_type, cloudwatch_namespace, dimension_name,
    dimension_value, metrics}. From platform/cloud/aws/cluster's
    managed_resource_dashboards output (e.g. {"postgres" = {resource_type =
    "rds", cloudwatch_namespace = "AWS/RDS", dimension_name =
    "DBInstanceIdentifier", dimension_value = "acme-prod-postgres", metrics =
    ["CPUUtilization", "DatabaseConnections", ...]}}). One Grafana dashboard
    is provisioned per distinct resource_type (not per entry) from a shared
    template -- adding a future resource of an already-represented type
    needs no new dashboard, only a new map entry.
  EOT
  type = map(object({
    resource_type        = string
    cloudwatch_namespace = string
    dimension_name       = string
    dimension_value      = string
    metrics              = list(string)
  }))
  default = {}
}

variable "alert_receiver_type" {
  description = "Alert receiver adapter. \"webhook\" is the maturity-A reference mechanism; empty keeps the dev null receiver."
  type        = string
  default     = ""
  validation {
    condition     = contains(["", "webhook"], var.alert_receiver_type)
    error_message = "alert_receiver_type must be \"\" or \"webhook\" (the qualified maturity-A receiver adapter)."
  }
}

variable "alert_receiver_url" {
  description = "Endpoint the Alertmanager route delivers to when alert_receiver_type is set. Never a secret Sol stores; keep routing credentials in the receiver URL out of committed files."
  type        = string
  default     = ""
}

variable "alert_owner" {
  description = "Accountable owner attached to every required maturity-A alert."
  type        = string
  default     = ""
}

variable "alert_runbook_url" {
  description = "First-response runbook linked from every required maturity-A alert."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate notifications"
  type        = string
}
