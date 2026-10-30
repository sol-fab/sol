variable "project_id" {
  description = "Project the target's environment runs in; scopes every grant the reconciler may set."
  type        = string
}

variable "region" {
  description = "Region the target's environment runs in."
  type        = string
}

variable "environment" {
  description = "Environment whose secret grants this reconciler owns and whose name scopes them."
  type        = string
}

variable "reconciler_trust_principal" {
  description = "Principal permitted to impersonate the reconciler service account: the gated CI authorization job's own identity, never the deploy identity. Empty establishes only serverless runtime identities."
  type        = string
  default     = ""
}

variable "grants" {
  description = "The safe grant set Sol computed: only grants DEC-062 rule 4 permits the reconciler to establish. This is the generated input the reconciler feeds Terraform."
  type = list(object({
    unit       = string
    capability = string
    resource   = string
    namespace  = string
  }))
  default = []
}

variable "serverless_units" {
  description = "Serverless units whose runtime identities and capability grants this target owns."
  type = list(object({
    unit = string
    requirements = list(object({
      capability = string
      resource   = string
    }))
  }))
  default = []
}
