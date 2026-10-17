val namespaces : Sol_cli_deployment_plan.t -> string list

(** The units that declared the database this target provisions. [db_ca_target] is the plan's
    single "consumes the managed database" signal; a unit that consumes no database is not
    included, so no allowance is widened to it. A unit bound to an external database is also
    not included: Sol owns no destination fact for it, and this contract does not infer one. *)
val managed_database_workloads : Sol_cli_deployment_plan.t -> (string * string) list

val docs_for_namespaces : string list -> Sol_cli_yaml.document list

(** Establish the namespaces and their scoped RBAC, and apply the managed-database egress
    allowance the cluster's published fact carries. [workloads] are the units that declared
    the database this target provisions; when it is non-empty, a missing, unreadable, empty or
    malformed fact refuses the substrate rather than deploying those workloads with no route
    to the database. When it is empty no fact is read and no allowance is applied. *)
val ensure
  :  workloads:(string * string) list
  -> ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
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
