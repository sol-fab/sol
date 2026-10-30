resource "kubernetes_service_account_v1" "sol_deploy" {
  metadata {
    name      = "sol-deploy"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { "app.kubernetes.io/managed-by" = "sol" }
  }

  automount_service_account_token = false
}

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
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.sol_deploy.metadata[0].name
    namespace = kubernetes_service_account_v1.sol_deploy.metadata[0].namespace
    api_group = ""
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
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.sol_deploy.metadata[0].name
    namespace = kubernetes_service_account_v1.sol_deploy.metadata[0].namespace
    api_group = ""
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
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.sol_deploy.metadata[0].name
    namespace = kubernetes_service_account_v1.sol_deploy.metadata[0].namespace
    api_group = ""
  }
}

# The deploy identity needs to create a RoleBinding in each workload namespace before it
# can operate there. A cluster-wide `rolebindings` grant would also let it bind its broad
# ClusterRole in monitoring/cert-manager/argocd/redpanda, reaching platform Secrets and
# workloads. Keep that power but confine it to namespaces Sol itself labelled as workload
# namespaces, and only for the two ClusterRoles the deployment contract owns.
resource "kubernetes_manifest" "deploy_rolebinding_boundary" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata = {
      name = "sol-deploy-rolebinding-boundary"
    }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["rbac.authorization.k8s.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["rolebindings"]
        }]
      }
      validations = [{
        expression = <<-CEL
          !request.userInfo.groups.exists(g, g == "sol:deployers") ||
          (has(namespaceObject.metadata.labels) &&
           namespaceObject.metadata.labels["sol.io/workload-namespace"] == "true" &&
           object.roleRef.apiGroup == "rbac.authorization.k8s.io" &&
           object.roleRef.kind == "ClusterRole" &&
           (object.roleRef.name == "sol-deploy" ||
            object.roleRef.name == "sol-operator-diagnostics"))
        CEL
        message    = "the deploy identity may create only Sol workload RoleBindings in a namespace labelled sol.io/workload-namespace=true"
      }]
    }
  }
}

resource "kubernetes_manifest" "deploy_rolebinding_boundary_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata = {
      name = "sol-deploy-rolebinding-boundary"
    }
    spec = {
      policyName        = "sol-deploy-rolebinding-boundary"
      validationActions = ["Deny"]
    }
  }
  depends_on = [kubernetes_manifest.deploy_rolebinding_boundary]
}
