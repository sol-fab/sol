resource "kubernetes_cluster_role" "platform_provisioner_namespaced" {
  metadata { name = "sol-platform-provisioner-namespaced" }
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
}

locals {
  platform_namespaces = toset(concat(
    ["cert-manager", "ingress-nginx", "argocd", "redpanda", "monitoring"],
    var.install_postgresql ? ["postgresql"] : [],
  ))
}

resource "kubernetes_role_binding" "platform_provisioner" {
  for_each = local.platform_namespaces
  metadata {
    name      = "sol-platform-provisioner"
    namespace = each.key
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_namespaced.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
  dynamic "subject" {
    for_each = local.gcp_provisioner == "" ? [] : [local.gcp_provisioner]
    content {
      kind      = "User"
      name      = subject.value
      api_group = "rbac.authorization.k8s.io"
    }
  }
  depends_on = [
    kubernetes_namespace.cert_manager, kubernetes_namespace.ingress_nginx,
    kubernetes_namespace.argocd, kubernetes_namespace.redpanda,
    kubernetes_namespace.postgresql, kubernetes_namespace.monitoring,
  ]
}

resource "kubernetes_cluster_role" "platform_provisioner_cluster" {
  metadata { name = "sol-platform-provisioner-cluster" }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "csidrivers", "csinodes"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["clusterissuers"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["scheduling.k8s.io", "apiregistration.k8s.io"]
    resources  = ["priorityclasses", "apiservices"]
    verbs      = ["get", "list", "watch"]
  }
}

locals {
  gcp_provisioner = var.gcp_provisioner_service_account
}

resource "kubernetes_cluster_role_binding" "platform_provisioner_cluster" {
  metadata { name = "sol-platform-provisioner-cluster" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_cluster.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
  dynamic "subject" {
    for_each = local.gcp_provisioner == "" ? [] : [local.gcp_provisioner]
    content {
      kind      = "User"
      name      = subject.value
      api_group = "rbac.authorization.k8s.io"
    }
  }
}
