(** Refuse historical resource requirements whose current target authority is
    absent or omitted, before applying any restored workloads. *)
val validate_resource_requirements
  :  config:Sol_cli_config.t
  -> Sol_cli_release.t
  -> (unit, string) result

val service_specs_of_release
  :  ?database:string * Sol_cli_resource_binding.postgres
  -> Sol_cli_release.t
  -> ((Sol_cli_deployment_plan.service_spec * string) list, string) result

type migration_check_error =
  | Contracting_migration of
      { release_id : string
      ; migration : string
      }
  | Undeclared_disposition of
      { release_id : string
      ; migration : string
      ; reason : string
      }
  | Applied_migration_absent of
      { release_id : string
      ; version : int
      }
  | Applied_state_unavailable of
      { release_id : string
      ; reason : string
      }

val migration_check_error_to_string : migration_check_error -> string

val check_migration_boundary
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> applied:(unit -> (int list, string) result)
  -> (unit, migration_check_error) result

type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

val live_kind_of_service : Sol_cli_deployment_plan.service_spec -> live_kind
val live_resource_and_jsonpath : live_kind -> string * string

type apply_mode_check_error = Gitops_owned of { release_id : string }

val apply_mode_check_error_to_string : apply_mode_check_error -> string
val check_apply_mode : release:Sol_cli_release.t -> (unit, apply_mode_check_error) result

type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

val identity_of_spec : Sol_cli_deployment_plan.service_spec -> workload_identity

(** The namespaces a plan deploys into. *)
val namespaces_of_plan : Sol_cli_deployment_plan.t -> string list

(** The namespaces the recorded apply wrote into. Pruning observes these as well as the
    plan's: a workload the plan no longer declares lives in a namespace the plan may no
    longer name. *)
val namespaces_of_evidence : Sol_cli_release_id.owned_object list -> string list

(** Live workloads for [workspace], listed per namespace in [namespaces]. The target's
    deploy identity is namespace-scoped by design (ADR 0002, SEC-011), so this never lists
    cluster-wide. *)
val live_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> namespaces:string list
  -> ((workload_identity * string) list, string) result

val workload_rows_of_payload
  :  kind:live_kind
  -> workspace:string
  -> Yojson.Safe.t
  -> ((workload_identity * string) list, string) result

type live_object =
  { id : Sol_cli_workload_ownership.identity
  ; uid : string
  }

type workspace_listing =
  { objects : live_object list
  ; unobservable : (string * string) list
  }

val observe_workspace_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> workspace_listing

type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string
  }

type workload_report =
  { mismatched : workload_mismatch list
  ; missing : workload_identity list
  ; unexpected : (workload_identity * string) list
  }

val workload_report_ok : workload_report -> bool

val unexpected_workloads
  :  expected:Sol_cli_deployment_plan.service_spec list
  -> live:(workload_identity * string) list
  -> (workload_identity * string) list

val verify_workloads
  :  expected:(Sol_cli_deployment_plan.service_spec * string) list
  -> live:(workload_identity * string) list
  -> workload_report

val workload_report_to_string : release:Sol_cli_release.t -> workload_report -> string
val kind_resource : live_kind -> string

val capture_owned
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.t
  -> Sol_cli_release_id.owned_object list

type prune_target =
  { resource : string
  ; namespace : string
  ; name : string
  }

type unowned_reason =
  | No_recorded_uid
  | Live_uid_differs
  | Live_absent
  | Live_unobservable of string

type unowned_workload =
  { identity : workload_identity
  ; reason : unowned_reason
  }

val unowned_reason_to_string : unowned_reason -> string

type prune_report =
  { removed : prune_target list
  ; retained : prune_target list
  ; unowned : unowned_workload list
  }

val plan_prune
  :  removable:workload_identity list
  -> unowned:unowned_workload list
  -> live_names:string list
  -> claims:(workload_identity -> string list)
  -> prune_report

val prune_workloads
  :  ctx:Sol_cli_kube_destination.context
  -> evidence:Sol_cli_release_id.owned_object list
  -> live:(workload_identity * string) list
  -> surplus:(workload_identity * string) list
  -> (prune_report, string) result

val external_secret_of_spec
  :  Sol_cli_deployment_plan.service_spec
  -> Sol_cli_workload_ownership.identity option

val declared_external_secrets
  :  Sol_cli_deployment_plan.t
  -> Sol_cli_workload_ownership.identity list

type external_secret_prune_report =
  { removed_external_secrets : prune_target list
  ; unowned_external_secrets : (prune_target * unowned_reason) list
  }

val orphaned_external_secret_evidence
  :  evidence:Sol_cli_release_id.owned_object list
  -> declared:Sol_cli_workload_ownership.identity list
  -> Sol_cli_release_id.owned_object list

val prune_external_secrets
  :  ctx:Sol_cli_kube_destination.context
  -> evidence:Sol_cli_release_id.owned_object list
  -> declared:Sol_cli_workload_ownership.identity list
  -> (external_secret_prune_report, string) result

type pointer_report =
  | Pointer_confirmed
  | Pointer_names of string
  | Pointer_unreadable of string

val verify_pointer
  :  ctx:Sol_cli_kube_destination.context
  -> release:Sol_cli_release.t
  -> pointer_report

val pointer_report_ok : pointer_report -> bool
val pointer_report_to_string : release:Sol_cli_release.t -> pointer_report -> string

type transaction_deps =
  { (* 2b: the target's already resolved **current** database selection, from which
       restored workloads' delivery is derived (historical requirements, current bindings). [None] for a local
       rollback, where delivery stays unit-scoped. *)
    database : (string * Sol_cli_resource_binding.postgres) option
  ; ensure_held : unit -> (unit, string) result
  ; applied_migrations : unit -> (int list, string) result
  ; apply : (Sol_cli_deployment_plan.service_spec * string) list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune :
      live:(workload_identity * string) list
      -> surplus:(workload_identity * string) list
      -> (prune_report, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  ; record_consumer_groups : string list -> (unit, string) result
  }

val consumer_groups_of_release : Sol_cli_release.t -> string list

val execute
  :  release:Sol_cli_release.t
  -> migrations_dir:string
  -> current_migrations:string list
  -> deps:transaction_deps
  -> (unit, string) result
