variable "kafka_authority" {
  description = "Reference-only credential authority published by the cluster root."
  type        = object({ reference = string, resource = string, username = string, mechanism = string })
  default     = null
}

provider "aws" { region = var.aws_region }

data "aws_secretsmanager_secret_version" "kafka" {
  count     = var.kafka_authority == null ? 0 : 1
  secret_id = var.kafka_authority.reference
}
