(** The concrete generated Kafka authority. No credential values are serialized by
    these references; generation and broker projection decisions fail closed. *)
type reference =
  { resource : string
  ; reference : string
  ; username : string
  ; mechanism : string
  }

val reference_of_json : string -> (reference, string) result
val reference_output : string -> (string option, string) result
val check_reference : resource:string -> string -> (reference, string) result

type generation =
  | Reuse
  | Initialize

(** The Terraform addresses of the durable provider authority. Kept here so the
    generation decision and the recovery inventory read one declaration. *)
type authority_resources =
  { secret : string
  ; version : string
  }

(** A plan may establish that a generation resource exists; only a provider read
    establishes that the authority is usable. [Reuse] therefore needs this. *)
type authority_state =
  | Authority_current
  | Authority_missing of string
  | Authority_unobservable of string

val generation
  :  resources:authority_resources
  -> managed:bool
  -> Sol_cli_terraform_plan.change list
  -> (generation, string) result

val check_reuse_authority : authority_state -> (unit, string) result

type initialization_evidence =
  { broker : Sol_cli_absence.observation
  ; storage : Sol_cli_absence.observation
  ; authority : Sol_cli_absence.observation
  }

val check_initial_absence : initialization_evidence -> (unit, string) result

(** Only creation or a refreshed no-op may establish broker delivery. An update,
    replacement or deletion must not silently change an existing broker credential. *)
val broker_projection_policy : Sol_cli_terraform_plan.policy

val platform_policy : Sol_cli_terraform_plan.policy

val observe_broker
  :  env:(string * string) list
  -> namespace:string
  -> Sol_cli_absence.observation

val scope_storage
  :  Sol_cli_absence.observation
  -> is_kafka:(string -> (bool, string) result)
  -> Sol_cli_absence.observation

val check_plan_inputs
  :  kafka:Sol_cli_resource_binding.kafka
  -> cluster_name:string option
  -> string
  -> (unit, string) result
