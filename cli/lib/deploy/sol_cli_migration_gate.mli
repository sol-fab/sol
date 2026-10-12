val migration_files : string -> ((string * string) list, string) result

val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> services:Sol_cli_manifest.service list
  -> unit

type verification =
  | No_migrations
  | Satisfied of int list
  | Unsatisfied of Sol_cli_migration.prerequisite list
  | Drifted of Sol_cli_migration.drift list
  | Unavailable of string

val read_applied
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> dir:string
  -> table:string
  -> services:Sol_cli_manifest.service list
  -> ddl_creds_name:string
  -> ?ca_configmap:string
  -> unit
  -> (int list, string) result

val verify
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> dir:string
  -> services:Sol_cli_manifest.service list
  -> ddl_creds_name:string
  -> ?ca_configmap:string
  -> unit
  -> verification
