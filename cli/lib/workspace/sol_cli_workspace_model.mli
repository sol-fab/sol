type workload =
  { service : Sol_cli_manifest.service
  ; has_dockerfile : bool
  ; language : Sol_cli_compat.language option
  ; config : (Sol_cli_toml.t, Sol_cli_toml.parse_error) result
  }

type migration =
  { file : Sol_cli_plan_ids.Migration_file.t
  ; version : int option
  ; name : string option
  ; disposition : (Sol_cli_migration_disposition.t, string) result
  }

type t =
  { root : string
  ; app_dir : string option
  ; workloads : workload list
  ; unexpected : Sol_cli_manifest.unexpected list
  ; declared : Sol_cli_config.service list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; migrations : migration list
  ; events : (string * Sol_cli_toml.event_decl) list
  ; targets : string list
  }

type declaration_issue =
  { service_name : string
  ; domain : string option
  ; path : string
  ; severity : [ `Error | `Warning ]
  ; message : string
  }

val services : t -> Sol_cli_manifest.service list
val workloads : t -> workload list
val migration_files : t -> Sol_cli_plan_ids.Migration_file.t list
val count_unapplied_migrations : t -> int

val declaration_issues
  :  scan:Sol_cli_manifest.workspace_scan
  -> Sol_cli_config.service list
  -> declaration_issue list

(** Pure scan view reused by target-specific declaration checks. *)
val scan_of : t -> Sol_cli_manifest.workspace_scan

val declaration_issues_of : t -> declaration_issue list
val load : root:string -> (t, string) result
val load_cwd : unit -> (t, string) result
