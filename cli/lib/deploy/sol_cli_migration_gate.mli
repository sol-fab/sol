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
  -> dir:string
  -> table:string
  -> namespace:string
  -> ddl_creds_name:string
  -> ?ca_configmap:string
  -> unit
  -> (int list, string) result

(** [read_applied] and [verify] run their Job in [namespace]. A *target* computes it from the
    database identity ({!Sol_cli_database_setup_render.database_namespace} of
    {!Sol_cli_database_setup_run.identity}), so no caller derives it from the selected
    services (#1424). The local path has no target and passes the release's own namespace, where
    its runtime credential lives. *)

val verify
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> dir:string
  -> namespace:string
  -> ddl_creds_name:string
  -> ?ca_configmap:string
  -> unit
  -> verification

(** Shared decision for host-read local status and in-cluster target status. *)
val verify_status
  :  required:Sol_cli_migration.prerequisite list
  -> Sol_cli_migration.applied_status
  -> verification
