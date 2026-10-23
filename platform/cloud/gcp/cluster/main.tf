terraform {
  required_version = ">= 1.6"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.25"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_compute_network" "main" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.cluster_name}-nodes"
  ip_cidr_range = var.nodes_cidr
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

resource "google_compute_router" "main" {
  name    = "${var.cluster_name}-router"
  network = google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "main" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.region

  deletion_protection = var.gke_deletion_protection

  remove_default_node_pool = true
  initial_node_count       = 1

  node_locations = ["${var.region}-a"]

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  dynamic "master_authorized_networks_config" {
    for_each = var.cluster_endpoint_cidr == "" ? [] : [var.cluster_endpoint_cidr]
    content {
      cidr_blocks {
        cidr_block   = master_authorized_networks_config.value
        display_name = "sol-deploy"
      }
    }
  }
  release_channel {
    channel = "REGULAR"
  }
}

resource "google_container_node_pool" "main" {
  name     = "${var.cluster_name}-nodes"
  cluster  = google_container_cluster.main.id
  location = var.region

  node_locations = ["${var.region}-a"]
  node_count     = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = var.cluster_name
  format        = "DOCKER"
  description   = "Container images for ${var.cluster_name} Sol workspace"
}

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

locals {
  gke_node_service_account = (
    google_container_node_pool.main.node_config[0].service_account == "default"
    ? data.google_compute_default_service_account.default.email
    : google_container_node_pool.main.node_config[0].service_account
  )
}

resource "google_artifact_registry_repository_iam_member" "gke_pull" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.gke_node_service_account}"
}

resource "google_artifact_registry_repository_iam_member" "publisher" {
  count      = var.publisher_service_account == "" ? 0 : 1
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.publisher_service_account}"
}

resource "google_sql_database_instance" "postgres" {
  count               = var.create_database ? 1 : 0
  name                = "${var.cluster_name}-postgres"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    availability_type           = var.sql_high_availability ? "REGIONAL" : "ZONAL"
    deletion_protection_enabled = var.sql_deletion_protection
    disk_autoresize             = true
    disk_size                   = var.sql_disk_gb

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "app" {
  count    = var.create_database ? 1 : 0
  name     = "app"
  instance = google_sql_database_instance.postgres[0].name

  depends_on = [google_sql_user.postgres]
}

resource "google_sql_user" "postgres" {
  count    = var.create_database ? 1 : 0
  name     = "postgres"
  instance = google_sql_database_instance.postgres[0].name
  password = var.db_password
}

resource "google_compute_global_address" "sql_peering" {
  name          = "${var.cluster_name}-sql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_peering.name]

  deletion_policy = "ABANDON"
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.main.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
}

resource "kubernetes_cluster_role_binding" "provisioner_bootstrap_admin" {
  count = var.provisioner_bootstrap_admin ? 1 : 0

  metadata { name = "sol-platform-provisioner-bootstrap-admin" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = google_service_account.provisioner.email
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "google_service_account" "provisioner" {
  account_id   = "${var.cluster_name}-provisioner"
  display_name = "Sol platform provisioner for ${var.cluster_name}"
  project      = var.project_id
}

resource "google_project_iam_custom_role" "provisioner_cluster_access" {
  project     = var.project_id
  role_id     = "sol_${replace(var.cluster_name, "-", "_")}_cluster_access"
  title       = "Sol provisioner cluster access"
  description = "Discover and obtain credentials for GKE clusters; Kubernetes object authority is supplied only by RBAC."
  permissions = [
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.getCredentials",
    "container.clusters.connect",
  ]
}

resource "google_project_iam_member" "provisioner_cluster_access" {
  project = var.project_id
  role    = google_project_iam_custom_role.provisioner_cluster_access.name
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

resource "google_service_account_iam_member" "provisioner_impersonators" {
  for_each = toset(var.provisioner_impersonators)

  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}

resource "google_dns_managed_zone" "main" {
  count       = var.create_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "Sol workspace zone for ${var.cluster_name}"
}

resource "google_storage_bucket" "loki" {
  count                       = var.enable_durable_observability ? 1 : 0
  name                        = "${var.cluster_name}-loki-logs"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  soft_delete_policy {
    retention_duration_seconds = var.gcs_soft_delete_retention_seconds
  }

  lifecycle_rule {
    condition {
      age = var.loki_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "loki" {
  count        = var.enable_durable_observability ? 1 : 0
  project      = var.project_id
  account_id   = "${var.cluster_name}-loki"
  display_name = "Loki durable storage (Workload Identity) for ${var.cluster_name}"
}

resource "google_storage_bucket_iam_member" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = google_storage_bucket.loki[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loki[0].email}"
}

resource "google_service_account_iam_member" "loki_workload_identity" {
  count              = var.enable_durable_observability ? 1 : 0
  service_account_id = google_service_account.loki[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/loki]"
}

resource "google_storage_bucket" "thanos" {
  count                       = var.enable_durable_observability ? 1 : 0
  name                        = "${var.cluster_name}-thanos-metrics"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  soft_delete_policy {
    retention_duration_seconds = var.gcs_soft_delete_retention_seconds
  }
}

resource "google_service_account" "thanos" {
  count        = var.enable_durable_observability ? 1 : 0
  project      = var.project_id
  account_id   = "${var.cluster_name}-thanos"
  display_name = "Thanos durable storage (Workload Identity) for ${var.cluster_name}"
}

resource "google_storage_bucket_iam_member" "thanos" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = google_storage_bucket.thanos[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.thanos[0].email}"
}

data "google_dns_managed_zone" "existing" {
  count = var.create_dns_zone ? 0 : 1

  name    = replace(var.base_domain, ".", "-")
  project = var.project_id
}

locals {
  dns_managed_zone = var.create_dns_zone ? google_dns_managed_zone.main[0].name : data.google_dns_managed_zone.existing[0].name
}

resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-cert-manager"
  display_name = "cert-manager ACME DNS-01 (Workload Identity) for ${var.cluster_name}"
}

resource "google_project_iam_custom_role" "cert_manager_dns_records" {
  project     = var.project_id
  role_id     = "sol_${replace(var.cluster_name, "-", "_")}_cert_manager_dns_records"
  title       = "Sol cert-manager ACME challenge records"
  description = "Create, read and remove resource record sets for ACME DNS-01 challenges in the workspace's own zone, and nothing else."
  permissions = [
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
  ]
}

resource "google_project_iam_custom_role" "cert_manager_dns_discovery" {
  project     = var.project_id
  role_id     = "sol_${replace(var.cluster_name, "-", "_")}_cert_manager_dns_discovery"
  title       = "Sol cert-manager zone discovery"
  description = "Read which managed zones exist, so cert-manager can resolve the zone a challenge belongs to. Record authority is granted separately, and only on the workspace's zone."
  permissions = ["dns.managedZones.get", "dns.managedZones.list"]
}

resource "google_dns_managed_zone_iam_member" "cert_manager_dns_records" {
  project      = var.project_id
  managed_zone = local.dns_managed_zone
  role         = google_project_iam_custom_role.cert_manager_dns_records.name
  member       = "serviceAccount:${google_service_account.cert_manager.email}"
}

resource "google_project_iam_member" "cert_manager_dns_discovery" {
  project = var.project_id
  role    = google_project_iam_custom_role.cert_manager_dns_discovery.name
  member  = "serviceAccount:${google_service_account.cert_manager.email}"
}

resource "google_service_account_iam_member" "cert_manager_workload_identity" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[cert-manager/cert-manager]"
}

resource "google_service_account_iam_member" "thanos_workload_identity" {
  for_each = var.enable_durable_observability ? toset([
    "monitoring/prometheus-server",
    "monitoring/thanos-storegateway",
    "monitoring/thanos-compactor",
  ]) : []

  service_account_id = google_service_account.thanos[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value}]"
}
