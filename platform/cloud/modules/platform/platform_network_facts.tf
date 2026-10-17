variable "database_egress_cidrs" {
  description = "Ranges a unit that declares this target's managed database must reach to use it, derived by the cluster root from the placement Sol provisioned. Published to the cluster so the deploy can render the egress a consumer needs without an author declaring a CIDR. Empty means this target has no managed database, and no allowance is published. The deploy applies it only to the units that declared the database; no other workload is widened."
  type        = list(string)
  default     = []
}

resource "kubernetes_config_map" "network_facts" {
  metadata {
    name      = "sol-platform-network"
    namespace = "kube-system"
  }

  data = {
    "database-egress-cidrs" = join(",", var.database_egress_cidrs)
    "database-port"         = "5432"
  }
}

resource "kubernetes_role" "network_facts" {
  metadata {
    name      = "sol-platform-network-facts"
    namespace = "kube-system"
  }

  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map.network_facts.metadata[0].name]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "network_facts" {
  metadata {
    name      = "sol-platform-network-facts"
    namespace = "kube-system"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.network_facts.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }

  dynamic "subject" {
    for_each = var.gcp_provisioner_service_account == "" ? [] : [var.gcp_provisioner_service_account]

    content {
      kind      = "User"
      name      = subject.value
      api_group = "rbac.authorization.k8s.io"
    }
  }
}
