val backend_config
  :  Sol_cli_config.target
  -> root:[ `Cloud | `Platform | `Authorization ]
  -> (string list, string) result

val authorization_backend : Sol_cli_config.target -> (string list, string) result

type cloud_target =
  { target : Sol_cli_config.target
  ; platform_shape : Sol_cli_profile.platform_shape
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; cluster_access_role_arn : string option
  }

val cloud_target
  :  platform_shape:Sol_cli_profile.platform_shape
  -> Sol_cli_config.target
  -> (cloud_target, string) result

val target : cloud_target -> Sol_cli_config.target
val cloud_backend : cloud_target -> string list
val platform_backend : cloud_target -> string list
val platform_address : string -> string

type platform_credential =
  { namespace : string
  ; secret : string
  }

val redpanda_namespace : string
val profile_of_platform_vars : string list -> string option

val platform_credentials_of_components
  :  platform_profile:string
  -> Yojson.Safe.t
  -> platform_credential list

(** The refusal an operator sees when the platform install stops for a credential
    Sol must not hold. [?deploy_handoff] is the target's already-computed
    (kubeconfig command, context) for the identity that deploys to it, so the
    operator who has to create the Secret is told how to reach the cluster
    instead of having to find a context themselves. *)
val missing_platform_credential_message
  :  ?deploy_handoff:string * string
  -> platform_credential
  -> string

type credential_presence =
  | Credential_present
  | Credential_absent
  | Credential_unverifiable of string

val credential_presence : exit_code:int -> output:string -> credential_presence
val unverifiable_platform_credential_message : platform_credential -> string -> string

type platform_inputs

val platform_inputs
  :  cloud_target
  -> Sol_cli_cluster.t
  -> (platform_inputs, string) result

type platform_vars_context = Sol_cli_cluster.platform_vars_context =
  | Install
  | Destruction

val platform_terraform_vars
  :  ?context:platform_vars_context
  -> platform_inputs
  -> (string list, string) result

type failure_policy =
  | Continue_to_destroy
  | Block_destroy

type 'a preparation_outcome =
  | Nothing_to_prepare
  | Prepared of 'a
  | Preparation_failed of
      { reason : string
      ; policy : failure_policy
      }

val preparation_failure : 'a preparation_outcome -> string option
val destruction_blocked : 'a preparation_outcome -> string option
val preparations_eligible : state:string list -> desired:string list -> string list
val preparations_unrepresented : state:string list -> desired:string list -> string list

type plan_phase =
  | Plannable
  | Deferred of string

val platform_plan_phases
  :  cluster_exists:bool
  -> rbac_established:bool
  -> install_window_open:bool
  -> crds_established:bool
  -> plan_phase * plan_phase

type authorization =
  | Required
  | Forbidden

val provisioner_authorization_checks : (authorization * string list) list
val provisioner_authorization_established : can_i:(string list -> bool) -> bool
val install_window_authorization_checks : (authorization * string list) list
val install_window_open : can_i:(string list -> bool) -> bool

type readiness =
  | Established
  | Unmet of string
  | Unobservable of string

type platform_storage = Sol_cli_provider_capabilities.platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

val platform_storage : Sol_cli_provider.t -> platform_storage

val readiness
  :  provider:Sol_cli_provider.t
  -> run:(string list -> (string, string) result)
  -> (string * readiness) list

val readiness_invocations : provider:Sol_cli_provider.t -> (string * string list) list
val readiness_summary : (string * readiness) list -> string
val readiness_decision : (string * readiness) list -> (unit, string) result

type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

val policy_of_phase : phase -> phase_policy
val transition_allowed : from:phase -> to_:phase -> bool
val destruction_available : phase -> bool
val enter_destruction : from:phase -> phase
val ready_policy_applies : phase -> bool

type destroy_retention =
  | Retain_final_snapshot
  | Retain_nothing

val default_destroy_retention : destroy_retention
val destroy_retention_to_string : destroy_retention -> string
val destroy_retention_of_string : string -> (destroy_retention, string) result

val policy_vars
  :  provider:Sol_cli_provider.t
  -> phase:phase
  -> destroy_snapshot_id:string
  -> retention:destroy_retention
  -> (string * string) list

val phase_to_string : phase -> string
val observed_phase : cloud_exists:bool -> platform_installed:bool -> phase

type deescalation_principal = Sol_cli_capability.deescalation_principal =
  | Principal_confirmed of string
  | Principal_refused_by_cluster of string
  | Principal_probe_failed of string
  | Principal_unexpected of string

type deescalation_verdict = Sol_cli_capability.deescalation_verdict =
  | Deescalated
  | Still_elevated of string list
  | Undetermined of string

type capability_answer = Sol_cli_capability.capability_answer =
  | Permitted
  | Denied
  | Indeterminate of string

type capability = Sol_cli_capability.capability =
  { verb : string
  ; resource : string
  }

val capability_label : capability -> string
val answer_is_permitted : capability_answer -> bool

val capability_answer_of_can_i_output
  :  exit_code:int
  -> stdout:string
  -> stderr:string
  -> capability_answer

val indeterminate_reason : capability * capability_answer -> (string * string) option

val deescalation_verdict
  :  principal:deescalation_principal
  -> (capability * capability_answer) list
  -> deescalation_verdict

val successor_authority : (capability * capability_answer) list -> (unit, string) result

val deescalation_transition
  :  before:(capability * capability_answer) list
  -> after_principal:deescalation_principal
  -> after:(capability * capability_answer) list
  -> deescalation_verdict

val deescalation_verdict_to_string : deescalation_verdict -> string
val enter : from:phase -> to_:phase -> (phase, string) result
