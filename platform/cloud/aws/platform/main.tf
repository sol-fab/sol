terraform {
  required_version = ">= 1.6"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

module "platform" {
  kafka_credential = var.kafka_authority == null ? null : merge(var.kafka_authority, {
    password = data.aws_secretsmanager_secret_version.kafka[0].secret_string
  })
  source                                  = "../../modules/platform"
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
  gcp_provisioner_service_account         = var.gcp_provisioner_service_account
  install_postgresql                      = var.install_postgresql
  postgres_password                       = var.postgres_password
  postgres_persistent_storage             = var.postgres_persistent_storage
  grafana_admin_password                  = var.grafana_admin_password
  grafana_oidc_provider                   = var.grafana_oidc_provider
  grafana_oidc_client_id                  = var.grafana_oidc_client_id
  grafana_oidc_client_secret              = var.grafana_oidc_client_secret
  grafana_oidc_auth_url                   = var.grafana_oidc_auth_url
  grafana_oidc_token_url                  = var.grafana_oidc_token_url
  grafana_oidc_api_url                    = var.grafana_oidc_api_url
  grafana_oidc_name                       = var.grafana_oidc_name
  grafana_oidc_scopes                     = var.grafana_oidc_scopes
  grafana_oidc_allowed_groups             = var.grafana_oidc_allowed_groups
  grafana_oidc_role_attribute_path        = var.grafana_oidc_role_attribute_path
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
  aws_region                              = var.aws_region
  loki_s3_bucket                          = var.loki_s3_bucket
  loki_irsa_role_arn                      = var.loki_irsa_role_arn
  thanos_s3_bucket                        = var.thanos_s3_bucket
  thanos_irsa_role_arn                    = var.thanos_irsa_role_arn
  loki_gcs_bucket                         = var.loki_gcs_bucket
  loki_workload_identity_sa_email         = var.loki_workload_identity_sa_email
  thanos_gcs_bucket                       = var.thanos_gcs_bucket
  thanos_workload_identity_sa_email       = var.thanos_workload_identity_sa_email
  prometheus_raw_retention_days           = var.prometheus_raw_retention_days
  thanos_retention_5m_days                = var.thanos_retention_5m_days
  thanos_retention_1h_days                = var.thanos_retention_1h_days
  grafana_irsa_role_arn                   = var.grafana_irsa_role_arn
  managed_resource_dashboards             = var.managed_resource_dashboards
  alert_receiver_type                     = var.alert_receiver_type
  alert_receiver_url                      = var.alert_receiver_url
  alert_owner                             = var.alert_owner
  alert_runbook_url                       = var.alert_runbook_url
  letsencrypt_email                       = var.letsencrypt_email
  cert_manager_irsa_role_arn              = var.cert_manager_irsa_role_arn
  cert_manager_dns01_region               = var.cert_manager_dns01_region
  database_egress_cidrs                   = var.database_egress_cidrs
  cert_manager_dns01_project              = var.cert_manager_dns01_project
  cert_manager_workload_identity_sa_email = var.cert_manager_workload_identity_sa_email
}

moved {
  from = kubernetes_manifest.letsencrypt_staging
  to   = module.platform.kubernetes_manifest.letsencrypt_staging
}

moved {
  from = kubernetes_manifest.letsencrypt_prod
  to   = module.platform.kubernetes_manifest.letsencrypt_prod
}

moved {
  from = kubernetes_namespace.cert_manager
  to   = module.platform.kubernetes_namespace.cert_manager
}

moved {
  from = kubernetes_namespace.ingress_nginx
  to   = module.platform.kubernetes_namespace.ingress_nginx
}

moved {
  from = kubernetes_namespace.argocd
  to   = module.platform.kubernetes_namespace.argocd
}

moved {
  from = kubernetes_namespace.redpanda
  to   = module.platform.kubernetes_namespace.redpanda
}

moved {
  from = kubernetes_namespace.postgresql
  to   = module.platform.kubernetes_namespace.postgresql
}

moved {
  from = kubernetes_namespace.monitoring
  to   = module.platform.kubernetes_namespace.monitoring
}

moved {
  from = terraform_data.observability_backend_validation
  to   = module.platform.terraform_data.observability_backend_validation
}

moved {
  from = terraform_data.managed_resource_dashboards_validation
  to   = module.platform.terraform_data.managed_resource_dashboards_validation
}

moved {
  from = helm_release.cert_manager
  to   = module.platform.helm_release.cert_manager
}

moved {
  from = helm_release.ingress_nginx
  to   = module.platform.helm_release.ingress_nginx
}

moved {
  from = helm_release.argocd
  to   = module.platform.helm_release.argocd
}

moved {
  from = kubernetes_ingress_v1.argocd
  to   = module.platform.kubernetes_ingress_v1.argocd
}

moved {
  from = helm_release.redpanda
  to   = module.platform.helm_release.redpanda
}

moved {
  from = helm_release.postgresql
  to   = module.platform.helm_release.postgresql
}

moved {
  from = helm_release.loki
  to   = module.platform.helm_release.loki
}

moved {
  from = helm_release.grafana
  to   = module.platform.helm_release.grafana
}

moved {
  from = kubernetes_config_map.grafana_cloudwatch_datasource
  to   = module.platform.kubernetes_config_map.grafana_cloudwatch_datasource
}

moved {
  from = kubernetes_config_map.grafana_managed_resource_dashboards
  to   = module.platform.kubernetes_config_map.grafana_managed_resource_dashboards
}

moved {
  from = helm_release.alloy
  to   = module.platform.helm_release.alloy
}

moved {
  from = helm_release.tempo
  to   = module.platform.helm_release.tempo
}

moved {
  from = kubernetes_config_map.grafana_loki_datasource
  to   = module.platform.kubernetes_config_map.grafana_loki_datasource
}

moved {
  from = kubernetes_config_map.grafana_prometheus_datasource
  to   = module.platform.kubernetes_config_map.grafana_prometheus_datasource
}

moved {
  from = kubernetes_config_map.grafana_tempo_datasource
  to   = module.platform.kubernetes_config_map.grafana_tempo_datasource
}

moved {
  from = kubernetes_config_map.grafana_dashboards
  to   = module.platform.kubernetes_config_map.grafana_dashboards
}

moved {
  from = kubernetes_ingress_v1.grafana
  to   = module.platform.kubernetes_ingress_v1.grafana
}

moved {
  from = kubernetes_secret.thanos_objstore_config
  to   = module.platform.kubernetes_secret.thanos_objstore_config
}

moved {
  from = helm_release.prometheus
  to   = module.platform.helm_release.prometheus
}

moved {
  from = helm_release.thanos
  to   = module.platform.helm_release.thanos
}

moved {
  from = kubernetes_storage_class_v1.platform_default
  to   = module.platform.kubernetes_storage_class_v1.platform_default
}

moved {
  from = kubernetes_cluster_role.sol_deploy
  to   = module.platform.kubernetes_cluster_role.sol_deploy
}

moved {
  from = kubernetes_cluster_role.sol_deploy_bootstrap
  to   = module.platform.kubernetes_cluster_role.sol_deploy_bootstrap
}

moved {
  from = kubernetes_cluster_role_binding.sol_deploy_bootstrap
  to   = module.platform.kubernetes_cluster_role_binding.sol_deploy_bootstrap
}

moved {
  from = kubernetes_role.sol_boundary_lease
  to   = module.platform.kubernetes_role.sol_boundary_lease
}

moved {
  from = kubernetes_role_binding.sol_boundary_lease
  to   = module.platform.kubernetes_role_binding.sol_boundary_lease
}

moved {
  from = kubernetes_cluster_role.sol_operator_diagnostics
  to   = module.platform.kubernetes_cluster_role.sol_operator_diagnostics
}

moved {
  from = kubernetes_cluster_role.sol_operator_namespaces
  to   = module.platform.kubernetes_cluster_role.sol_operator_namespaces
}

moved {
  from = kubernetes_cluster_role_binding.sol_operator_namespaces
  to   = module.platform.kubernetes_cluster_role_binding.sol_operator_namespaces
}

moved {
  from = kubernetes_cluster_role.platform_provisioner_namespaced
  to   = module.platform.kubernetes_cluster_role.platform_provisioner_namespaced
}

moved {
  from = kubernetes_role_binding.platform_provisioner
  to   = module.platform.kubernetes_role_binding.platform_provisioner
}

moved {
  from = kubernetes_cluster_role.platform_provisioner_cluster
  to   = module.platform.kubernetes_cluster_role.platform_provisioner_cluster
}

moved {
  from = kubernetes_cluster_role_binding.platform_provisioner_cluster
  to   = module.platform.kubernetes_cluster_role_binding.platform_provisioner_cluster
}
