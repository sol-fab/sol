val validate_key_format : string -> (unit, string) result
val validate_key : string -> (unit, string) result

val unit_secret_manifest
  :  namespace:string
  -> secret_name:string
  -> (string * string) list
  -> string

val apply_unit_values
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> (string * string) list
  -> (bool, string) result

(** [hint] overrides the guidance appended when the Secret is missing keys, so a caller whose
    Secret is written by something other than the operator does not tell the reader to write
    it by hand. *)
val verify_required_keys
  :  ?hint:string
  -> ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> required_keys:string list
  -> unit
  -> (unit, string) result

val verify_workload_secret
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val verify_external_secret_ready
  :  ?timeout_s:float
  -> ?poll_s:float
  -> ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

(** Wait for an ExternalSecret to report Ready/SecretSynced, then check the Secret it wrote
    holds [required_keys]. [external_name] names both the ExternalSecret and the Secret it
    targets — this is the class-Secret shape, where the target is named for the target rather
    than a unit. [hint] overrides the key-check guidance. *)
val verify_external_secret_materialized
  :  ?timeout_s:float
  -> ?poll_s:float
  -> ?hint:string
  -> ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> external_name:string
  -> required_keys:string list
  -> unit
  -> (unit, string) result

val external_secret_status
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> unit_name:string
  -> expected_keys:string list
  -> (string, string) result

(** The declared ExternalSecret's uid, or [None] when it does not exist yet — the value its
    output Secret must name in [ownerReferences]. See {!verify_external_secret_output}. *)
val external_secret_uid
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> external_secret_name:string
  -> (string option, string) result

(** **The ESO output's ownership**, the predicate "[assert_destination_is_sol] answers a
    different question": for a declared ExternalSecret, the Secret ESO writes must be absent
    or owned by *that* ExternalSecret ([ownerReferences] names [external_uid]). Sol does not
    write these Secrets, so the managed-by label rule cannot answer for them.
    [external_uid] is [None] when no ExternalSecret is declared yet, and a pre-existing Secret
    is then refused (nothing declares it). Both the unit path and the class path use this
    check. *)
val verify_external_secret_output
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> external_uid:string option
  -> secret_name:string
  -> (unit, string) result

val verify_external_secret_destination
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val verify_runtime_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> required_keys:string list
  -> (unit, string) result

val set_unit_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> key:string
  -> value:string
  -> (bool, string) result

(** Read one decoded key from a Secret the caller has already established is the
    authority's projection. *)
val read_secret_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> key:string
  -> (string, string) result

(** Write a target-delivered key to a named Secret in each namespace, refusing any
    destination Sol does not own. Used for resource-owned projections such as
    `<target>-kafka-creds`. *)
val set_target_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> secret_name:string
  -> key:string
  -> value:string
  -> (string list, string) result

val platform_secret_keys : string list

(** The guard a delivered object passes before Sol writes it: what is already there must be
    absent or Sol's. A Secret is also refused where an ExternalSecret already targets it. *)
val assert_destination_is_sol
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> namespace:string
  -> name:string
  -> (unit, string) result

val verify_platform_secret_destinations
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> (unit, string) result

val set_platform_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> key:string
  -> value:string
  -> (string list, string) result

val delete_platform_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> key:string
  -> (string list, string) result

val delete_unit_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> key:string
  -> (bool, string) result

val unit_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> (string list, string) result

val runtime_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> (string list, string) result
