output "reconciler_role_arn" {
  description = "The fenced reconciler role the gated authorization job assumes."
  value       = var.reconciler_trust_principal_arn == "" ? null : aws_iam_role.reconciler[0].arn
}

output "workload_role_path" {
  description = "IAM path every workload role for this environment must live under."
  value       = "/${local.role_path}"
}

output "permissions_boundary_arn" {
  description = "Boundary that must be attached to every workload role at creation."
  value       = aws_iam_policy.workload_boundary.arn
}

output "established_grants" {
  description = "The safe grant set this root established; Sol reads it back to compute the next plan (DEC-062 rule 4)."
  value       = local.realized_grants
}

output "serverless_role_arns" {
  description = "Per-unit Lambda runtime roles this target owns."
  value = {
    for unit, role in aws_iam_role.workload : unit => role.arn
    if contains(local.serverless_units, unit)
  }
}
