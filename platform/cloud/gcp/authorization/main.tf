terraform {
  required_version = ">= 1.6"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  secret_prefix = "sol-${var.environment}-"
  role_id       = "sol_${replace(var.environment, "-", "_")}_authorization"
}

resource "google_service_account" "reconciler" {
  count        = var.reconciler_trust_principal == "" ? 0 : 1
  account_id   = "sol-${var.environment}-authorization"
  display_name = "Sol ${var.environment} authorization reconciler"
  description  = "Fenced reconciler for ${var.environment}'s Sol secret grants (DEC-062)."
}

resource "google_project_iam_custom_role" "authorization" {
  count       = var.reconciler_trust_principal == "" ? 0 : 1
  role_id     = local.role_id
  title       = "Sol ${var.environment} authorization reconciler"
  description = "Resource-scoped secret grant authority for ${var.environment}; it creates no service accounts and mutates no project IAM."
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "reconciler_authorization" {
  count   = var.reconciler_trust_principal == "" ? 0 : 1
  project = var.project_id
  role    = google_project_iam_custom_role.authorization[0].id
  member  = "serviceAccount:${google_service_account.reconciler[0].email}"

  condition {
    title       = "sol-managed-secrets-only"
    description = "The reconciler may set grants only on secrets this environment owns."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/secrets/${local.secret_prefix}\")"
  }
}

resource "google_service_account_iam_member" "reconciler_impersonation" {
  count              = var.reconciler_trust_principal == "" ? 0 : 1
  service_account_id = google_service_account.reconciler[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.reconciler_trust_principal
}

locals {
  realized_grants = [
    for grant in var.grants : grant
    if grant.capability == "secret"
  ]
}

resource "google_secret_manager_secret_iam_member" "workload" {
  for_each = {
    for grant in local.realized_grants : "${grant.unit}/${grant.resource}" => grant
  }

  project   = var.project_id
  secret_id = "sol-${var.environment}-${each.value.resource}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.namespace}/${each.value.unit}]"
}

locals {
  serverless_units = toset([for unit in var.serverless_units : unit.unit])

  serverless_secret_grants = flatten([
    for unit in var.serverless_units : [
      for requirement in unit.requirements : {
        unit       = unit.unit
        capability = requirement.capability
        resource   = requirement.resource
      } if requirement.capability == "secret"
    ]
  ])
}

locals {
  scheduler_units = { for unit in var.scheduler_units : unit.unit => unit }
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_service_account" "scheduler" {
  for_each     = local.scheduler_units
  account_id   = "sol-${var.environment}-sched-${substr(sha1(each.key), 0, 8)}"
  display_name = "Sol ${var.environment} scheduler ${each.key}"
  description  = "Dedicated scheduler identity for ${each.key}."
}

resource "google_service_account_iam_member" "scheduler_act_as" {
  for_each           = local.scheduler_units
  service_account_id = google_service_account.scheduler[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler" {
  for_each = local.scheduler_units
  project  = var.project_id
  location = var.region
  name     = each.value.function_name
  role     = "roles/run.jobsExecutor"
  member   = "serviceAccount:${google_service_account.scheduler[each.key].email}"
}

resource "google_service_account" "serverless" {
  for_each     = local.serverless_units
  account_id   = "sol-${var.environment}-rt-${substr(sha1(each.value), 0, 8)}"
  display_name = "Sol ${var.environment} serverless runtime ${each.value}"
  description  = "Per-unit runtime identity for serverless unit ${each.value}."
}

resource "google_secret_manager_secret_iam_member" "serverless" {
  for_each = {
    for grant in local.serverless_secret_grants :
    "${grant.unit}/${grant.resource}" => grant
  }

  project   = var.project_id
  secret_id = "sol-${var.environment}-${each.value.resource}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.serverless[each.value.unit].email}"
}
