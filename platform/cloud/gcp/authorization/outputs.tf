output "reconciler_service_account_email" {
  description = "The fenced reconciler service account the gated authorization job impersonates."
  value       = var.reconciler_trust_principal == "" ? null : google_service_account.reconciler[0].email
}

output "reconciler_role_id" {
  description = "The resource-scoped custom role carrying secret-grant authority."
  value       = var.reconciler_trust_principal == "" ? null : google_project_iam_custom_role.authorization[0].id
}

output "secret_prefix" {
  description = "Name prefix every secret this environment owns must carry."
  value       = local.secret_prefix
}

output "established_grants" {
  description = "The safe grant set this root established; Sol reads it back to compute the next plan (DEC-062 rule 4)."
  value       = local.realized_grants
}

output "serverless_service_accounts" {
  description = "Per-unit serverless runtime identities this target owns."
  value       = { for unit, account in google_service_account.serverless : unit => account.email }
}
