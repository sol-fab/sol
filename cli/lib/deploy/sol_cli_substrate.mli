val namespaces : Sol_cli_deployment_plan.t -> string list
val docs_for_namespaces : string list -> Sol_cli_yaml.document list

(** Establish the namespaces and their scoped RBAC, and apply the managed-database egress
    allowance the cluster's published fact carries. [manages_database] is whether the target
    provisions a Sol-managed database: when it does and the fact is absent, the substrate is
    refused rather than silently deployed with no route to the database. It is consulted only
    when [workloads] is non-empty, because that is when an allowance would be applied. *)
val ensure
  :  workloads:(string * string) list
  -> ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> manages_database:bool
  -> (unit, string) result

val established
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> (unit, string) result

val operator_binding_docs
  :  workspace:string
  -> Sol_cli_manifest.service list
  -> Sol_cli_yaml.document list

val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> services:Sol_cli_manifest.service list
  -> (unit, string) result
