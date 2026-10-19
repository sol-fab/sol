# State and historical state versions contain the generated password.
variable "kafka_connection" {
  description = "Resolved native Kafka identity/posture. Null for absent, external or local plaintext Kafka. Sol supplies references and metadata, never a password."
  type        = object({ secret_name = string, resource = string, username = string, mechanism = string })
  default     = null
}

resource "random_password" "kafka" {
  count   = var.kafka_connection == null ? 0 : 1
  length  = 48
  special = false
  # No changing keepers: ordinary reconciliation must never rotate a broker.
}

variable "kafka_reader_members" {
  description = "Explicit deployment principals allowed to retrieve this target's Kafka credential; never inferred from workloads."
  type        = set(string)
  default     = []
}

resource "google_secret_manager_secret" "kafka" {
  count     = var.kafka_connection == null ? 0 : 1
  secret_id = var.kafka_connection.secret_name
  replication {
    auto {}
  }
  lifecycle {
    precondition {
      condition     = length(var.kafka_reader_members) > 0
      error_message = "Managed Kafka requires explicit kafka_reader_members for deployment; workload readers are not inferred."
    }
  }
  labels = {
    "sol-cluster" = var.cluster_name
    "sol-role"    = "kafka-credential"
  }
}

resource "google_secret_manager_secret_version" "kafka" {
  count       = var.kafka_connection == null ? 0 : 1
  secret      = google_secret_manager_secret.kafka[0].id
  secret_data = random_password.kafka[0].result
}

resource "google_secret_manager_secret_iam_member" "kafka_reader" {
  for_each  = var.kafka_connection == null ? toset([]) : var.kafka_reader_members
  secret_id = google_secret_manager_secret.kafka[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

output "kafka_authority" {
  description = "Authoritative identity and posture; never a credential value."
  value = var.kafka_connection == null ? null : merge(var.kafka_connection, {
    reference = google_secret_manager_secret.kafka[0].id
  })
}
