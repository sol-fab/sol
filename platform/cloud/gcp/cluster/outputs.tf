output "cluster_name" {
  value = google_container_cluster.main.name
}

output "project_id" {
  description = "GCP project the target was provisioned into; addresses every API call and the cluster credential."
  value       = var.project_id
}

output "region" {
  description = "GCP region the target's regional resources were placed in."
  value       = var.region
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.region} --project ${var.project_id}"
}

output "kube_context" {
  description = "Kubernetes context name written by kubeconfig_command"
  value       = "gke_${var.project_id}_${var.region}_${google_container_cluster.main.name}"
}

output "artifact_registry" {
  description = "Artifact Registry URL — pass as --registry to sol deploy"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.cluster_name}"
}

output "docker_auth_command" {
  description = "Command to authenticate Docker with Artifact Registry"
  value       = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
}

output "postgres_private_ip" {
  description = "Cloud SQL private IP (accessible from GKE pods)"
  value       = var.create_database ? google_sql_database_instance.postgres[0].private_ip_address : null
  sensitive   = true
}

output "postgres_url" {
  description = "POSTGRES_URL for Sol services"
  value       = var.create_database ? "postgresql://postgres:${replace(urlencode(var.db_password), "+", "%20")}@${google_sql_database_instance.postgres[0].private_ip_address}/app" : null
  sensitive   = true
}

output "postgres_ca_cert" {
  description = "The trust anchor a client needs to verify the Cloud SQL endpoint's certificate under sslmode=verify-full: the instance's server CA, which Cloud SQL derives per instance rather than publishing through a shared bundle. Null when no database is created."
  # The provider marks the instance's `server_ca_cert` sensitive, so a root output that
  # carries it must be marked too or Terraform refuses the root ("Output refers to sensitive
  # values") and the target can neither apply nor destroy — as `postgres_url` above does.
  # Sol reads the value from the outputs the same way it reads that one.
  value     = var.create_database ? google_sql_database_instance.postgres[0].server_ca_cert[0].cert : null
  sensitive = true
}

output "database_egress_cidrs" {
  description = "The network range a workload must reach to use this target's managed database: the private services access range Cloud SQL's private address is allocated from."
  value = [
    "${google_compute_global_address.sql_peering.address}/${google_compute_global_address.sql_peering.prefix_length}"
  ]
}

output "dns_nameservers" {
  description = "Nameservers to set at your domain registrar"
  value       = var.create_dns_zone ? google_dns_managed_zone.main[0].name_servers : null
}

output "provisioner_service_account" {
  description = "The platform provisioner identity Sol impersonates for cluster access; short-lived tokens, never a key file."
  value       = google_service_account.provisioner.email
}

output "loki_gcs_bucket" {
  description = "GCS bucket for durable Loki storage — set in platform/cloud/modules/platform as loki_gcs_bucket (INFRA-003, GCP counterpart to aws/'s loki_s3_bucket)"
  value       = var.enable_durable_observability ? google_storage_bucket.loki[0].name : null
}

output "loki_workload_identity_sa_email" {
  description = "GCP service account email for Loki's GCS access — set in platform/cloud/modules/platform as loki_workload_identity_sa_email (INFRA-003, GCP counterpart to aws/'s loki_irsa_arn)"
  value       = var.enable_durable_observability ? google_service_account.loki[0].email : null
}

output "thanos_gcs_bucket" {
  description = "GCS bucket for durable Prometheus/Thanos storage — set in platform/cloud/modules/platform as thanos_gcs_bucket (INFRA-003, GCP counterpart to aws/'s thanos_s3_bucket)"
  value       = var.enable_durable_observability ? google_storage_bucket.thanos[0].name : null
}

output "thanos_workload_identity_sa_email" {
  description = "GCP service account email for Thanos's GCS access — set in platform/cloud/modules/platform as thanos_workload_identity_sa_email (INFRA-003, GCP counterpart to aws/'s thanos_irsa_arn)"
  value       = var.enable_durable_observability ? google_service_account.thanos[0].email : null
}

output "dns_managed_zone" {
  description = "Cloud DNS managed zone cert-manager writes ACME challenge records into — the zone the DNS-01 solver's record permissions are scoped to (DEC-055)"
  value       = local.dns_managed_zone
}

output "cert_manager_workload_identity_sa_email" {
  description = "GCP service account email for cert-manager's Cloud DNS DNS-01 solver — set in platform/cloud/modules/platform as cert_manager_workload_identity_sa_email (DEC-055, GCP counterpart to aws/'s cert_manager_irsa_role_arn)"
  value       = google_service_account.cert_manager.email
}
