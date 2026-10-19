variable "kafka_authority" {
  description = "Reference-only credential authority published by the cluster root."
  type        = object({ reference = string, resource = string, username = string, mechanism = string })
  default     = null
}

data "google_secret_manager_secret_version_access" "kafka" {
  count   = var.kafka_authority == null ? 0 : 1
  secret  = var.kafka_authority.reference
  version = "latest"
}
