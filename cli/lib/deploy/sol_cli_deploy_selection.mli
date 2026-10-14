type selection =
  { resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
  }

val select
  :  image_refs:(string option * string) list
  -> Sol_cli_manifest.service list
  -> (selection, string) result

type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

(** The one ownership decision: which inputs a unit must carry, and who owns each. Both the
    plan gate and `sol secret set` resolve through it. *)
type input_owner =
  | Unit_secret
  | External_secret of
      { store : string
      ; key : string
      }
  | Target_database
  | Unmapped

val unit_input_owners
  :  config:Sol_cli_config.t
  -> unit_address:string
  -> transport:Sol_cli_manifest.kafka_transport
  -> db_uses_target:bool
  -> declared:string list
  -> (string * input_owner) list

(** Whether the unit declared it consumes the target's database, by
    [Sol_cli_deployment_plan.db_uses_target] — the function the plan itself uses to fill
    [spec.db_uses_target]. Reads the workspace's `uses:` edge, not the unit's secret keys. *)
val unit_consumes_target_database
  :  config:Sol_cli_config.t
  -> unit_name:string
  -> (bool, string) result

(** The `sol secret set` decision for one key, on the resolved input ownership. [declared]
    is the unit's application secret keys — the same list the plan builds [spec.secrets]
    from — so both callers reach {!unit_input_owners} with the same input. *)
val check_unit_secret_write
  :  config:Sol_cli_config.t
  -> unit_address:string
  -> unit_name:string
  -> declared:string list
  -> key:string
  -> (unit, string) result

val apply_target
  :  target:string
  -> config:Sol_cli_config.t
  -> selection
  -> (deployed, string) result

val secret_authorities_for_plan
  :  config:Sol_cli_config.t
  -> Sol_cli_deployment_plan.t
  -> ((string * string * Sol_cli_config.secret_authority) list, string) result

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

module Planning_input : sig
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; requested_scope : string
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan_input : sig
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan : sig
  type t

  val profile : t -> Sol_cli_deployment_plan.profile_claim option
  val to_deployment_plan : t -> Sol_cli_deployment_plan.t
end

val plan : Planning_input.t -> (Sol_cli_deployment_plan.t, plan_error) result
val target_plan : Target_plan_input.t -> (Target_plan.t, plan_error) result
