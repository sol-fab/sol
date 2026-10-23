terraform {
  required_version = ">= 1.6"
  required_providers {
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

resource "kubernetes_namespace" "cert_manager" {
  metadata { name = "cert-manager" }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata { name = "ingress-nginx" }
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "kubernetes_namespace" "redpanda" {
  metadata { name = "redpanda" }
}

resource "kubernetes_namespace" "postgresql" {
  metadata { name = "postgresql" }
  count = var.install_postgresql ? 1 : 0
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "terraform_data" "observability_backend_validation" {
  input = var.observability_backend

  lifecycle {
    precondition {
      condition = var.observability_backend != "external" || (
        trimspace(var.external_loki_url) != "" &&
        trimspace(var.external_prometheus_remote_write_url) != ""
      )
      error_message = "observability_backend = \"external\" requires external_loki_url and external_prometheus_remote_write_url."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_loki_username) == "" && trimspace(var.external_loki_password) == "") ||
        (trimspace(var.external_loki_username) != "" && trimspace(var.external_loki_password) != "")
      )
      error_message = "external_loki_username and external_loki_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_prometheus_username) == "" && trimspace(var.external_prometheus_password) == "") ||
        (trimspace(var.external_prometheus_username) != "" && trimspace(var.external_prometheus_password) != "")
      )
      error_message = "external_prometheus_username and external_prometheus_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "self_hosted_durable" || var.cloud_provider != "aws" || (
        trimspace(var.loki_s3_bucket) != "" &&
        trimspace(var.loki_irsa_role_arn) != "" &&
        trimspace(var.thanos_s3_bucket) != "" &&
        trimspace(var.thanos_irsa_role_arn) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" on AWS requires loki_s3_bucket, loki_irsa_role_arn, thanos_s3_bucket, and thanos_irsa_role_arn."
    }

    precondition {
      condition = var.observability_backend != "self_hosted_durable" || var.cloud_provider != "gcp" || (
        trimspace(var.loki_gcs_bucket) != "" &&
        trimspace(var.loki_workload_identity_sa_email) != "" &&
        trimspace(var.thanos_gcs_bucket) != "" &&
        trimspace(var.thanos_workload_identity_sa_email) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" on GCP requires loki_gcs_bucket, loki_workload_identity_sa_email, thanos_gcs_bucket, and thanos_workload_identity_sa_email."
    }

    precondition {
      condition     = var.observability_backend != "self_hosted_durable" || var.cloud_provider == "aws"
      error_message = "observability_backend = \"self_hosted_durable\" is currently supported only on AWS/EKS: the GCP Workload Identity path is wired but not yet validated against a live GKE cluster (INFRA-005)."
    }
  }
}

resource "terraform_data" "managed_resource_dashboards_validation" {
  input = var.managed_resource_dashboards

  lifecycle {
    precondition {
      condition     = length(var.managed_resource_dashboards) == 0 || var.cloud_provider == "aws"
      error_message = "managed_resource_dashboards is currently supported only on AWS/EKS (CloudWatch-backed, requires IRSA)."
    }

    precondition {
      condition     = length(var.managed_resource_dashboards) == 0 || trimspace(var.grafana_irsa_role_arn) != ""
      error_message = "managed_resource_dashboards requires grafana_irsa_role_arn (from platform/cloud/aws/cluster's grafana_irsa_arn output) so Grafana's CloudWatch datasource can authenticate."
    }
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.4"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }

  set {
    name  = "startupapicheck.timeout"
    value = "10m"
  }

  set {
    name  = "startupapicheck.backoffLimit"
    value = "1"
  }

  values = [
    yamlencode({
      serviceAccount = {
        annotations = {
          (local.cert_manager_identity_annotation) = local.cert_manager_identity
        }
      }
    })
  ]

  timeout = 1800

  wait = true
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = local.platform_components.versions["ingress-nginx"]
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  set {
    name  = "controller.service.type"
    value = var.ingress_service_type
  }

  depends_on = [helm_release.cert_manager]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.3"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "server.insecure"
    value = "true"
  }
}

resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["argocd.${var.base_domain}"]
      secret_name = "argocd-tls"
    }

    rule {
      host = "argocd.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd, helm_release.ingress_nginx]
}

# The broker bootstrap projection has one writer: platform Terraform. Provider
# authority survives cluster replacement; this Kubernetes object does not own it.
resource "kubernetes_secret_v1" "redpanda_users" {
  # Only presence is declassified; the credential value remains sensitive.
  count = var.platform_profile == "durable" && nonsensitive(var.kafka_credential != null) ? 1 : 0
  metadata {
    name        = local.platform_components.redpanda.durable.auth.sasl.secretRef
    namespace   = kubernetes_namespace.redpanda.metadata[0].name
    labels      = { "app.kubernetes.io/managed-by" = "sol" }
    annotations = { "sol.io/credential-authority" = nonsensitive(var.kafka_credential.reference) }
  }
  data = {
    "users.txt" = "${var.kafka_credential.username}:${var.kafka_credential.password}:${var.kafka_credential.mechanism}"
  }
}

resource "helm_release" "redpanda" {
  name       = "redpanda"
  repository = "https://charts.redpanda.com"
  chart      = "redpanda"
  version    = local.platform_components.versions.redpanda
  namespace  = kubernetes_namespace.redpanda.metadata[0].name
  timeout    = 600

  values = concat(
    local.redpanda_component_values,
    [yamlencode({
      statefulset = { replicas = var.redpanda_replicas }
      config      = { cluster = { write_caching_default = false } }
      resources = {
        cpu    = { cores = var.redpanda_cpu_cores }
        memory = { container = { max = var.redpanda_memory } }
      }
      storage = {
        persistentVolume = { enabled = var.redpanda_persistent_storage }
      }
    })]
  )

  depends_on = [kubernetes_storage_class_v1.platform_default, kubernetes_secret_v1.redpanda_users]
}

resource "helm_release" "postgresql" {
  count      = var.install_postgresql ? 1 : 0
  name       = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = local.platform_components.versions.postgresql
  namespace  = kubernetes_namespace.postgresql[0].metadata[0].name

  set {
    name  = "auth.postgresPassword"
    value = var.postgres_password
  }
  set {
    name  = "primary.persistence.enabled"
    value = tostring(var.postgres_persistent_storage)
  }

  values = local.postgresql_component_values

  depends_on = [kubernetes_storage_class_v1.platform_default]
}

locals {
  loki_install_local = var.observability_backend != "external"

  managed_resource_dashboards_enabled = (
    local.loki_install_local &&
    var.cloud_provider == "aws" &&
    length(var.managed_resource_dashboards) > 0
  )

  managed_resource_types = toset([for r in values(var.managed_resource_dashboards) : r.resource_type])

  managed_resource_by_type = {
    for t in local.managed_resource_types :
    t => [for r in values(var.managed_resource_dashboards) : r if r.resource_type == t][0]
  }

  platform_components   = jsondecode(file("${path.module}/../../../shared/components.json"))
  observability_dir     = "${path.module}/../../../shared/observability"
  observability_profile = var.observability_backend == "self_hosted_durable" ? "durable" : "local"
  platform_profile      = var.platform_profile

  loki_component_values = [
    jsonencode(local.platform_components.loki.common),
    jsonencode(local.platform_components.loki[local.observability_profile]),
  ]
  grafana_component_values = [
    jsonencode(local.platform_components.grafana.common),
    jsonencode(local.platform_components.grafana[local.observability_profile]),
  ]

  grafana_oauth_auth_url = (
    var.grafana_oidc_auth_url != ""
    ? var.grafana_oidc_auth_url
    : var.grafana_oidc_provider == "google" ? "https://accounts.google.com/o/oauth2/v2/auth" : ""
  )
  grafana_oauth_token_url = (
    var.grafana_oidc_token_url != ""
    ? var.grafana_oidc_token_url
    : var.grafana_oidc_provider == "google" ? "https://oauth2.googleapis.com/token" : ""
  )
  grafana_oauth_api_url = (
    var.grafana_oidc_api_url != ""
    ? var.grafana_oidc_api_url
    : var.grafana_oidc_provider == "google" ? "https://openidconnect.googleapis.com/v1/userinfo" : ""
  )
  grafana_admin_password = (
    var.grafana_admin_password != null
    ? var.grafana_admin_password
    : try(random_password.grafana_admin[0].result, "")
  )
  tempo_component_values = [
    jsonencode(local.platform_components.tempo.common),
    jsonencode(local.platform_components.tempo[local.observability_profile]),
  ]
  prometheus_component_values = [
    jsonencode(local.platform_components.prometheus.common),
    jsonencode(local.platform_components.prometheus[local.observability_profile]),
  ]
  redpanda_component_values = [
    jsonencode(local.platform_components.redpanda.common),
    jsonencode(local.platform_components.redpanda[local.platform_profile]),
  ]
  postgresql_component_values = [
    jsonencode(local.platform_components.postgresql.common),
    jsonencode(local.platform_components.postgresql[local.platform_profile]),
  ]

  loki_push_url                 = var.observability_backend == "external" ? var.external_loki_url : "http://loki:3100/loki/api/v1/push"
  loki_push_basic_auth_username = var.observability_backend == "external" ? var.external_loki_username : ""
  loki_push_basic_auth_password = var.observability_backend == "external" ? var.external_loki_password : ""

  observability_taxonomy_labels = ["workspace", "env", "domain", "service", "primitive", "release"]

  loki_infra_bindings_gcs_yaml = yamlencode({
    loki = {
      storage = {
        type = "gcs"
        bucketNames = {
          chunks = var.loki_gcs_bucket
          ruler  = var.loki_gcs_bucket
        }
        gcs = {}
      }
      schemaConfig = {
        configs = [
          {
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "gcs"
            schema       = "v13"
            index        = { prefix = "index_", period = "24h" }
          }
        ]
      }
    }
    serviceAccount = {
      annotations = {
        "iam.gke.io/gcp-service-account" = var.loki_workload_identity_sa_email
      }
    }
  })

  loki_infra_bindings_s3_yaml = yamlencode({
    loki = {
      storage = {
        bucketNames = {
          chunks = var.loki_s3_bucket
          ruler  = var.loki_s3_bucket
        }
        s3 = {
          region           = var.aws_region
          s3ForcePathStyle = false
        }
      }
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.loki_irsa_role_arn
      }
    }
  })

  loki_infra_bindings = var.cloud_provider == "gcp" ? local.loki_infra_bindings_gcs_yaml : local.loki_infra_bindings_s3_yaml
}

resource "helm_release" "loki" {
  count = local.loki_install_local ? 1 : 0

  name       = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = local.platform_components.versions.loki
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "singleBinary.persistence.enabled"
    value = tostring(var.loki_persistent_storage)
  }

  values = concat(
    local.loki_component_values,
    var.observability_backend == "self_hosted_durable" ? [local.loki_infra_bindings] : []
  )

  depends_on = [
    kubernetes_storage_class_v1.platform_default,
    terraform_data.observability_backend_validation
  ]
}

resource "terraform_data" "grafana_sso_validation" {
  count = local.loki_install_local ? 1 : 0

  lifecycle {
    precondition {
      condition = (
        var.grafana_oidc_client_id != ""
        && var.grafana_oidc_client_secret != ""
        && local.grafana_oauth_auth_url != ""
        && local.grafana_oauth_token_url != ""
        && local.grafana_oauth_api_url != ""
      )
      error_message = "Grafana SSO is required. Set TF_VAR_grafana_oidc_client_id and TF_VAR_grafana_oidc_client_secret (and, for a custom provider, the issuer/auth/token/userinfo URLs). Google endpoints are defaulted when grafana_oidc_provider=google. The client secret must come from TF_VAR_*, never the command line."
    }
  }
}

resource "random_password" "grafana_admin" {
  count   = local.loki_install_local ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "grafana_secret_key" {
  count   = local.loki_install_local ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "grafana_oidc" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { "app.kubernetes.io/managed-by" = "sol" }
  }

  type = "Opaque"
  data = { "client-secret" = var.grafana_oidc_client_secret }
}

resource "kubernetes_secret_v1" "grafana_security" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-security"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { "app.kubernetes.io/managed-by" = "sol" }
  }

  type = "Opaque"
  data = { "secret-key" = try(random_password.grafana_secret_key[0].result, "") }
}

resource "helm_release" "grafana" {
  count = local.loki_install_local ? 1 : 0

  name       = "grafana"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = local.platform_components.versions.grafana
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "adminPassword"
    value = local.grafana_admin_password
  }

  values = concat(
    local.grafana_component_values,
    [yamlencode({
      "grafana.ini" = {
        server = {
          root_url = "https://grafana.${var.base_domain}"
        }
        auth = {
          anonymous = {
            enabled = false
          }
          generic_oauth = {
            enabled              = true
            name                 = var.grafana_oidc_name
            client_id            = var.grafana_oidc_client_id
            scopes               = var.grafana_oidc_scopes
            auth_url             = local.grafana_oauth_auth_url
            token_url            = local.grafana_oauth_token_url
            api_url              = local.grafana_oauth_api_url
            allowed_groups       = join(" ", var.grafana_oidc_allowed_groups)
            role_attribute_path  = var.grafana_oidc_role_attribute_path
            allow_sign_up        = false
            auto_assign_org      = true
            auto_assign_org_role = "Viewer"
          }
        }
      }
      envValueFrom = {
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = {
          secretKeyRef = {
            name = "grafana-oidc"
            key  = "client-secret"
          }
        }
        GF_SECURITY_SECRET_KEY = {
          secretKeyRef = {
            name = "grafana-security"
            key  = "secret-key"
          }
        }
      }
    })],
    local.managed_resource_dashboards_enabled ? [yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.grafana_irsa_role_arn
        }
      }
    })] : []
  )

  depends_on = [
    terraform_data.observability_backend_validation,
    terraform_data.managed_resource_dashboards_validation,
    terraform_data.grafana_sso_validation,
    kubernetes_secret_v1.grafana_oidc,
    kubernetes_secret_v1.grafana_security,
  ]
}

resource "kubernetes_config_map" "grafana_cloudwatch_datasource" {
  count = local.managed_resource_dashboards_enabled ? 1 : 0

  metadata {
    name      = "grafana-cloudwatch-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "cloudwatch.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "CloudWatch"
        type   = "cloudwatch"
        access = "proxy"
        jsonData = {
          authType      = "default"
          defaultRegion = var.aws_region
        }
      }]
    })
  }

  depends_on = [helm_release.grafana, terraform_data.managed_resource_dashboards_validation]
}

resource "kubernetes_config_map" "grafana_managed_resource_dashboards" {
  for_each = local.managed_resource_dashboards_enabled ? local.managed_resource_by_type : {}

  metadata {
    name      = "sol-grafana-dashboard-managed-resource-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "managed-resource-${each.key}.json" = templatefile("${local.observability_dir}/dashboards/managed-resource.json.tftpl", {
      resource_type        = each.key
      cloudwatch_namespace = each.value.cloudwatch_namespace
      dimension_name       = each.value.dimension_name
      metrics              = each.value.metrics
      region               = var.aws_region
    })
  }

  depends_on = [helm_release.grafana, terraform_data.managed_resource_dashboards_validation]
}

resource "helm_release" "alloy" {
  name      = "alloy"
  chart     = "https://github.com/grafana/helm-charts/releases/download/alloy-${local.platform_components.versions.alloy}/alloy-${local.platform_components.versions.alloy}.tgz"
  namespace = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    alloy = {
      configMap = {
        content = templatefile("${local.observability_dir}/alloy/logs.alloy.tftpl", {
          loki_push_url                 = local.loki_push_url
          loki_push_basic_auth_username = local.loki_push_basic_auth_username
          loki_push_basic_auth_password = local.loki_push_basic_auth_password
          taxonomy_labels               = local.observability_taxonomy_labels
        })
      }
    }
  })]

  depends_on = [terraform_data.observability_backend_validation]
}

resource "helm_release" "tempo" {
  count = local.loki_install_local ? 1 : 0

  name       = "tempo"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "tempo"
  version    = local.platform_components.versions.tempo
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = local.tempo_component_values

  depends_on = [terraform_data.observability_backend_validation]
}

resource "kubernetes_config_map" "grafana_loki_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "loki.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki:3100"
        isDefault = false
        jsonData = {
          derivedFields = [{
            datasourceUid = "tempo"
            matcherRegex  = "trace_id=([0-9a-f]{32})"
            name          = "TraceID"
            url           = "$${__value.raw}"
          }]
        }
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

resource "kubernetes_config_map" "grafana_prometheus_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-prometheus-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "prometheus.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:80"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

resource "kubernetes_config_map" "grafana_tempo_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-tempo-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "tempo.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Tempo"
        type      = "tempo"
        access    = "proxy"
        uid       = "tempo"
        url       = "http://tempo.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:3200"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana, helm_release.tempo]
}

resource "kubernetes_config_map" "grafana_dashboards" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "sol-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "workspace-overview.json"    = file("${local.observability_dir}/dashboards/workspace-overview.json")
    "service-template.json"      = file("${local.observability_dir}/dashboards/service-template.json")
    "domain-overview.json"       = file("${local.observability_dir}/dashboards/domain-overview.json")
    "release-timeline.json"      = file("${local.observability_dir}/dashboards/release-timeline.json")
    "target-infrastructure.json" = file("${local.observability_dir}/dashboards/target-infrastructure.json")
  }

  depends_on = [helm_release.grafana]
}

resource "kubernetes_ingress_v1" "grafana" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["grafana.${var.base_domain}"]
      secret_name = "grafana-tls"
    }

    rule {
      host = "grafana.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.grafana, helm_release.ingress_nginx]
}

locals {
  prometheus_thanos_enabled = var.observability_backend == "self_hosted_durable"

  prometheus_remote_write = var.observability_backend == "external" ? [
    merge(
      { url = var.external_prometheus_remote_write_url },
      var.external_prometheus_username != "" ? {
        basic_auth = { username = var.external_prometheus_username, password = var.external_prometheus_password }
      } : {}
    )
  ] : []

  prometheus_thanos_server_fields = {
    server = {
      serviceAccount = {
        annotations = {
          (var.cloud_provider == "gcp" ? "iam.gke.io/gcp-service-account" : "eks.amazonaws.com/role-arn") = (
            var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
          )
        }
      }
      service = {
        gRPC = { enabled = true, servicePort = 10901 }
      }
      extraSecretMounts = [{
        name       = "thanos-objstore-config"
        mountPath  = "/etc/thanos"
        subPath    = ""
        secretName = "thanos-objstore-config"
        readOnly   = true
      }]
      sidecarContainers = {
        thanos-sidecar = {
          image = "thanosio/thanos:v0.35.1"
          args = [
            "sidecar",
            "--tsdb.path=/data",
            "--prometheus.url=http://127.0.0.1:9090",
            "--objstore.config-file=/etc/thanos/objstore.yml",
            "--http-address=0.0.0.0:10902",
            "--grpc-address=0.0.0.0:10901",
          ]
          volumeMounts = [
            { name = "storage-volume", mountPath = "/data" },
            { name = "thanos-objstore-config", mountPath = "/etc/thanos", readOnly = true }
          ]
          ports = [
            { containerPort = 10902, name = "http-sidecar" },
            { containerPort = 10901, name = "grpc" }
          ]
        }
      }
    }
  }
}

locals {
  alerting_configured = var.alert_receiver_type == "webhook" && var.alert_receiver_url != ""

  alert_annotations = {
    owner       = var.alert_owner
    runbook_url = var.alert_runbook_url
  }

  prometheus_alerting_rules = {
    groups = [
      {
        name = "sol-starter-alerts"
        rules = [
          {
            alert = "SolHighErrorRate"
            expr = join(" ", [
              "(sum by (workspace, env, domain, service) (rate(sol_svc_requests_total{status_class=\"5xx\"}[5m]))",
              "/",
              "sum by (workspace, env, domain, service) (rate(sol_svc_requests_total[5m]))) > 0.05"
            ])
            for = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "High 5xx error rate for {{ $labels.service }} ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) has served a 5xx rate of {{ $value | humanizePercentage }} over the last 5 minutes."
            }, local.alert_annotations)
          },
          {
            alert = "SolPodRestartLoop"
            expr  = "increase(kube_pod_container_status_restarts_total[15m]) > 3"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Pod {{ $labels.pod }} restarting repeatedly"
              description = "Container {{ $labels.container }} in pod {{ $labels.pod }} (namespace {{ $labels.namespace }}) restarted {{ $value }} times in the last 15 minutes. Namespace is `<workspace>-<domain>`; join with `kube_pod_labels` for an exact workspace/domain/service breakdown."
            }, local.alert_annotations)
          },
          {
            alert = "SolRolloutFailed"
            expr  = "kube_deployment_status_replicas_available / clamp_min(kube_deployment_spec_replicas, 1) < 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Rollout stuck for {{ $labels.namespace }}/{{ $labels.deployment }}"
              description = "Deployment {{ $labels.deployment }} in namespace {{ $labels.namespace }} has had fewer available replicas than desired for 10 minutes."
            }, local.alert_annotations)
          },
          {
            alert = "SolNodeNotReady"
            expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Node {{ $labels.node }} not ready"
              description = "Node {{ $labels.node }} has reported Ready=false for 5 minutes. Confirm the `node-failure-tolerant` workloads' headroom is absorbing the loss."
            }, local.alert_annotations)
          },
          {
            alert = "SolTelemetryTargetDown"
            expr  = "up{namespace=\"monitoring\"} == 0"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Telemetry target down in monitoring"
              description = "Scrape target {{ $labels.job }} ({{ $labels.instance }}) in the monitoring namespace has been down for 10 minutes. Diagnostics are degraded; business-data durability is unaffected (DEC-026 §5)."
            }, local.alert_annotations)
          },
          {
            alert = "SolPostgresUnavailable"
            expr  = "pg_up == 0"
            for   = "5m"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "Postgres dependency unavailable"
              description = "The monitored Postgres target has been down for 5 minutes. Restore/failover runbook applies; application writes may be failing."
            }, local.alert_annotations)
          },
          {
            alert = "SolKafkaConsumerLagHigh"
            expr  = "-sum by (redpanda_group, redpanda_topic) (max by (redpanda_group, redpanda_topic, redpanda_partition) (redpanda_kafka_consumer_group_committed_offset) - on (redpanda_topic, redpanda_partition) group_left() max by (redpanda_topic, redpanda_partition) (redpanda_kafka_max_offset)) > 10000"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Kafka consumer lag high for group {{ $labels.redpanda_group }}"
              description = "Consumer group {{ $labels.redpanda_group }} on topic {{ $labels.redpanda_topic }} has been more than 10000 messages behind for 10 minutes."
            }, local.alert_annotations)
          },
          {
            alert = "SolWorkerDecodeDrops"
            expr  = "sum by (workspace, env, domain, service) (increase(sol_worker_decode_errors_total[5m])) > 0"
            for   = "0s"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "{{ $labels.service }} could not decode messages ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} in domain {{ $labels.domain }} (workspace {{ $labels.workspace }}, env {{ $labels.env }}) could not decode about {{ $value | humanize }} message(s) in the last 5 minutes. By default they are parked on the group's DLQ; under an explicit Ack_and_drop they are discarded. Usually a producer deployed an incompatible schema."
            }, local.alert_annotations)
          },
          {
            alert = "SolOutboxPublicationLag"
            expr  = "max by (workspace, env, domain, service, kind) (sol_outbox_oldest_pending_seconds) > 300"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = merge({
              summary     = "Outbox publication is lagging for kind {{ $labels.kind }} ({{ $labels.domain }}/{{ $labels.workspace }})"
              description = "{{ $labels.service }} has held the oldest {{ $labels.kind }} outbox event unpublished for over 5 minutes ({{ $value | humanize }}s). Nothing is lost - the intent is committed - but that key's later events are held back behind it. The broker, an incompatible schema, or a stopped relay is the usual cause."
            }, local.alert_annotations)
          },
          {
            alert = "SolKafkaBrokerDown"
            expr  = "up{job=~\".*redpanda.*\"} == 0"
            for   = "5m"
            labels = {
              severity = "critical"
            }
            annotations = merge({
              summary     = "Kafka broker scrape target down"
              description = "A Redpanda broker scrape target ({{ $labels.instance }}) has been down for 5 minutes. The `single-broker-loss` durability contract tolerates one broker; more than one is outside the profile."
            }, local.alert_annotations)
          }
        ]
      }
    ]
  }

  prometheus_alertmanager_config = local.alerting_configured ? {
    route = {
      receiver        = "sol-receiver"
      group_by        = ["alertname", "workspace", "domain", "service"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [
      {
        name = "sol-receiver"
        webhook_configs = [{
          url           = var.alert_receiver_url
          send_resolved = true
        }]
      }
    ]
    } : {
    route = {
      receiver        = "null"
      group_by        = ["alertname", "workspace", "domain", "service"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
    }
    receivers = [
      { name = "null", webhook_configs = [] }
    ]
  }
}

resource "kubernetes_secret" "thanos_objstore_config" {
  count = local.prometheus_thanos_enabled ? 1 : 0

  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = var.cloud_provider == "gcp" ? yamlencode({
      type = "GCS"
      config = {
        bucket = var.thanos_gcs_bucket
      }
      }) : yamlencode({
      type = "S3"
      config = {
        bucket   = var.thanos_s3_bucket
        endpoint = "s3.${var.aws_region}.amazonaws.com"
        region   = var.aws_region
      }
    })
  }
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = local.platform_components.versions.prometheus
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "server.persistentVolume.enabled"
    value = tostring(var.observability_backend == "external" ? false : var.prometheus_persistent_storage)
  }
  set {
    name  = "server.retention"
    value = var.observability_backend == "external" ? "2h" : "15d"
  }

  values = concat(
    local.prometheus_component_values,
    [yamlencode({ server = { remoteWrite = local.prometheus_remote_write } })],
    local.prometheus_thanos_enabled ? [yamlencode(local.prometheus_thanos_server_fields)] : [],
    [yamlencode({ serverFiles = { "alerting_rules.yml" = local.prometheus_alerting_rules } })],
    [yamlencode({ alertmanager = { config = local.prometheus_alertmanager_config } })]
  )

  depends_on = [
    kubernetes_storage_class_v1.platform_default,
    kubernetes_secret.thanos_objstore_config,
    terraform_data.observability_backend_validation
  ]
}

resource "helm_release" "thanos" {
  count      = local.prometheus_thanos_enabled ? 1 : 0
  name       = "thanos"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "thanos"
  version    = "17.3.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "query.enabled"
    value = "true"
  }
  set {
    name  = "query.dnsDiscovery.enabled"
    value = "false"
  }
  set {
    name  = "query.stores[0]"
    value = "prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "query.stores[1]"
    value = "thanos-storegateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "existingObjstoreSecret"
    value = kubernetes_secret.thanos_objstore_config[0].metadata[0].name
  }
  set {
    name  = "storegateway.enabled"
    value = "true"
  }
  set {
    name  = "compactor.enabled"
    value = "true"
  }
  set {
    name  = "compactor.retentionResolutionRaw"
    value = "${var.prometheus_raw_retention_days}d"
  }
  set {
    name  = "compactor.retentionResolution5m"
    value = "${var.thanos_retention_5m_days}d"
  }
  set {
    name  = "compactor.retentionResolution1h"
    value = "${var.thanos_retention_1h_days}d"
  }
  set {
    name = (
      var.cloud_provider == "gcp"
      ? "storegateway.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
      : "storegateway.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    )
    value = var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
  }
  set {
    name = (
      var.cloud_provider == "gcp"
      ? "compactor.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
      : "compactor.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    )
    value = var.cloud_provider == "gcp" ? var.thanos_workload_identity_sa_email : var.thanos_irsa_role_arn
  }
  set {
    name  = "receive.enabled"
    value = "false"
  }
  set {
    name  = "ruler.enabled"
    value = "false"
  }
  set {
    name  = "bucketweb.enabled"
    value = "false"
  }
  set {
    name  = "queryFrontend.enabled"
    value = "false"
  }

  depends_on = [
    helm_release.prometheus,
    terraform_data.observability_backend_validation
  ]
}

resource "kubernetes_storage_class_v1" "platform_default" {
  count = var.create_storage_class && var.cloud_provider == "aws" ? 1 : 0

  metadata {
    name        = var.storage_class_name
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }
}
