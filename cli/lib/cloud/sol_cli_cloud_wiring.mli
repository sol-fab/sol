type terraform_inputs =
  { var_files : string list
  ; vars : string list
  }

type terraform_layout =
  { provider : Sol_cli_provider.t
  ; pname : string
  ; infra_dir : string
  ; platform_dir : string
  ; cloud_backend : string list
  ; platform_backend : string list
  }

val terraform_layout
  :  cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> terraform_layout

val confirm_guarded_removal_flag : string

val init
  :  assets:Sol_cli_platform_assets.t
  -> Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> string list
  -> (unit, Sol_cli_cloud_apply.failure) result

type reconciliation =
  { observations : Sol_cli_absence.observation list
  ; dispositions : Sol_cli_ownership_reconciliation.disposition list
  ; restored : Sol_cli_ownership_reconciliation.candidate list
  }

val reconcile_ownership
  :  provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> cluster_name:string
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> act:bool
  -> (reconciliation, string) result

type state_cluster_identity =
  | Cluster_not_in_state
  | Cluster_named of string
  | Cluster_unnamed
  | Cluster_ambiguous of string list

(** The identity the cloud-root state represents for the substrate. Selection requires the
    provider's substrate address prefix *and* Terraform type, so a similarly-prefixed
    object is not mistaken for the cluster. More than one matching substrate resource is
    [Cluster_ambiguous], even when those resources record the same name: distinct
    Terraform resources still represent distinct ownership. *)
val state_cluster_identity
  :  provider:Sol_cli_provider.t
  -> Sol_cli_cloud_destroy.state_read
  -> state_cluster_identity

(** Forget cloud-root and platform-root state only when the substrate is positively absent
    at the provider, and only when the cluster identity in that state agrees with the
    target. Exposed so the destroy path's no-unsafe-[state rm] property is exercised
    directly; it is not a second entry point. *)
val provable_absence_reconciliation
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> platform_dir:string
  -> platform_backend:string list
  -> var_files:string list
  -> vars:string list
  -> state:Sol_cli_cloud_destroy.state_read
  -> (Sol_cli_cloud_destroy.reconciliation, string) result

val credentials_result
  :  provider:Sol_cli_provider.t
  -> operation:string
  -> leaves_target_standing:bool
  -> (unit, string) result

val init_result
  :  assets:Sol_cli_platform_assets.t
  -> Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> string list
  -> (unit, string) result

val plan
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> inputs:terraform_inputs
  -> (unit, Sol_cli_cloud_apply.failure) result

val apply_deps
  :  kafka:Sol_cli_resource_binding.kafka
  -> assets:Sol_cli_platform_assets.t
  -> confirm_ecr_removal:bool
  -> run_log:Sol_cli_run_log.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> inputs:terraform_inputs
  -> ( (Sol_cli_cluster.t, (string * string) list, unit) Sol_cli_cloud_apply.deps
       , Sol_cli_cloud_apply.failure )
       result

val destroy_preview
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> inputs:terraform_inputs
  -> (unit, string) result

val destruction
  :  run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> Sol_cli_destruction.t

val destroy_deps
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> inputs:terraform_inputs
  -> retention:Sol_cli_cloud_lifecycle.destroy_retention
  -> workload_namespaces:string list
  -> accept_unreleased:bool
  -> recorded_evidence:Sol_cli_release_id.owned_object list
  -> destruction:Sol_cli_destruction.t
  -> Sol_cli_cloud_destroy.deps
