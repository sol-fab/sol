terraform {
  required_version = ">= 1.6"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

module "platform" {
  kafka_credential = var.kafka_authority == null ? null : merge(var.kafka_authority, {
    password = data.google_secret_manager_secret_version_access.kafka[0].secret_data
  })
  source = "../../modules/platform"

  base_domain                             = var.base_domain
  cluster_issuer                          = var.cluster_issuer
  ingress_service_type                    = var.ingress_service_type
  create_storage_class                    = var.create_storage_class
  storage_class_name                      = var.storage_class_name
  cloud_provider                          = var.cloud_provider
  redpanda_replicas                       = var.redpanda_replicas
  redpanda_cpu_cores                      = var.redpanda_cpu_cores
  redpanda_memory                         = var.redpanda_memory
  redpanda_persistent_storage             = var.redpanda_persistent_storage
  install_postgresql                      = var.install_postgresql
  gcp_provisioner_service_account         = var.gcp_provisioner_service_account
  postgres_password                       = var.postgres_password
  postgres_persistent_storage             = var.postgres_persistent_storage
  grafana_admin_password                  = var.grafana_admin_password
  loki_persistent_storage                 = var.loki_persistent_storage
  prometheus_persistent_storage           = var.prometheus_persistent_storage
  observability_backend                   = var.observability_backend
  platform_profile                        = var.platform_profile
  external_loki_url                       = var.external_loki_url
  external_loki_username                  = var.external_loki_username
  external_loki_password                  = var.external_loki_password
  external_prometheus_remote_write_url    = var.external_prometheus_remote_write_url
  external_prometheus_username            = var.external_prometheus_username
  external_prometheus_password            = var.external_prometheus_password
  loki_gcs_bucket                         = var.loki_gcs_bucket
  loki_workload_identity_sa_email         = var.loki_workload_identity_sa_email
  thanos_gcs_bucket                       = var.thanos_gcs_bucket
  thanos_workload_identity_sa_email       = var.thanos_workload_identity_sa_email
  prometheus_raw_retention_days           = var.prometheus_raw_retention_days
  thanos_retention_5m_days                = var.thanos_retention_5m_days
  thanos_retention_1h_days                = var.thanos_retention_1h_days
  managed_resource_dashboards             = var.managed_resource_dashboards
  alert_receiver_type                     = var.alert_receiver_type
  alert_receiver_url                      = var.alert_receiver_url
  alert_owner                             = var.alert_owner
  alert_runbook_url                       = var.alert_runbook_url
  letsencrypt_email                       = var.letsencrypt_email
  cert_manager_workload_identity_sa_email = var.cert_manager_workload_identity_sa_email
  database_egress_cidrs                   = var.database_egress_cidrs
  cert_manager_dns01_project              = var.cert_manager_dns01_project
}
