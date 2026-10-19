resource "kubernetes_cluster_role" "sol_deploy" {
  metadata { name = "sol-deploy" }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets", "serviceaccounts", "services"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role" "sol_deploy_bootstrap" {
  metadata { name = "sol-deploy-bootstrap" }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch", "create"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["rolebindings"]
    verbs      = ["get", "list", "watch", "create"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles"]
    resource_names = [
      kubernetes_cluster_role.sol_deploy.metadata[0].name,
      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,
    ]
    verbs = ["bind"]
  }
}

resource "kubernetes_cluster_role_binding" "sol_deploy_bootstrap" {
  metadata { name = "sol-deploy-bootstrap" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.sol_deploy_bootstrap.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}

# The Redpanda chart owns the broker CA (`redpanda-default-cert`); the deploy
# projects it into the declared consumer namespaces (ADR 0008). Read that one
# Secret, in the namespace that holds it, rather than binding the whole
# `sol-deploy` role in the platform's namespace.
resource "kubernetes_role" "sol_kafka_ca_reader" {
  metadata {
    name      = "sol-kafka-ca-reader"
    namespace = kubernetes_namespace.redpanda.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["redpanda-default-cert"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "sol_kafka_ca_reader" {
  metadata {
    name      = "sol-kafka-ca-reader"
    namespace = kubernetes_namespace.redpanda.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.sol_kafka_ca_reader.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role" "sol_boundary_lease" {
  metadata {
    name      = "sol-boundary-lease"
    namespace = "default"
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "update", "delete"]
  }
}

resource "kubernetes_role_binding" "sol_boundary_lease" {
  metadata {
    name      = "sol-boundary-lease"
    namespace = "default"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.sol_boundary_lease.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
