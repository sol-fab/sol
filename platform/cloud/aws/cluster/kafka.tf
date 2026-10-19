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

resource "aws_secretsmanager_secret" "kafka" {
  count = var.kafka_connection == null ? 0 : 1
  name  = var.kafka_connection.secret_name
  # Intentional full target teardown is destructive. The asynchronous response
  # does not establish absence; independent observation must still do so.
  recovery_window_in_days = 0
  tags = merge(var.tags, {
    "sol-cluster"  = var.cluster_name
    "sol-resource" = var.kafka_connection.resource
    "sol-role"     = "kafka-credential"
  })
}

resource "aws_secretsmanager_secret_version" "kafka" {
  count         = var.kafka_connection == null ? 0 : 1
  secret_id     = aws_secretsmanager_secret.kafka[0].id
  secret_string = random_password.kafka[0].result
}

# Runtime applications receive only their Kubernetes delivery Secret. The deploy
# principal reads this target's durable authority; it receives no write authority.
data "aws_iam_policy_document" "kafka_reader" {
  count = var.kafka_connection == null ? 0 : 1
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.kafka[0].arn]
    principals {
      type        = "AWS"
      identifiers = [var.deploy_role_arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "kafka_reader" {
  count               = var.kafka_connection == null ? 0 : 1
  secret_arn          = aws_secretsmanager_secret.kafka[0].arn
  policy              = data.aws_iam_policy_document.kafka_reader[0].json
  block_public_policy = true
  lifecycle {
    precondition {
      condition     = var.deploy_role_arn != ""
      error_message = "Managed Kafka requires an explicit deploy_role_arn for its scoped credential reader."
    }
  }
}

output "kafka_authority" {
  description = "Authoritative identity and posture; never a credential value."
  value = var.kafka_connection == null ? null : merge(var.kafka_connection, {
    reference = aws_secretsmanager_secret.kafka[0].arn
  })
}
