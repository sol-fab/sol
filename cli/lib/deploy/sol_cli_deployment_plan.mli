type deployment_mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type env_config =
  { name : string
  ; mode : deployment_mode
  ; registry : string
  ; image_tag : string
  ; env : string option
  ; region : string option
  ; base_domain : string option
  ; cluster_issuer : string
  }

type primitive =
  | Svc
  | Worker
  | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sol_cli_kubernetes_name.k8s_name
type namespace = Sol_cli_kubernetes_name.namespace

type service_call =
  { env_var : string
  ; unit_id : string
    (* the referenced unit's canonical identity, [<domain>/<k8s name>]; for a
       callee this is the projected-token audience, for a caller it is the
       identity the callee authorizes. Both forms are derived from the committed
       declarations, so a release can reconstruct them for rollback. *)
  ; url : string
  ; target_domain : string
  ; target_name : k8s_name
  ; target_namespace : namespace
  }

val identity_projections : service_call list -> Sol_cli_identity_projection.t list
val identity_env : service_call -> string * string

type service_spec =
  { domain : string
  ; source_name : string
  ; k8s_name : k8s_name
  ; namespace : namespace
  ; primitive : primitive
  ; source_dir : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; secret_sources : (string * Sol_cli_secret_source.t) list
  ; build_secret_keys : string list
  ; volumes : Sol_cli_toml.volume list
  ; schedule : string option
  ; scheduled_concurrency : Sol_cli_toml.scheduled_concurrency
  ; backoff_limit : int
  ; replicas : int
  ; availability : Sol_cli_availability.t
  ; consumes_kafka : bool
  ; language : Sol_cli_compat.language option
  ; cpu : Sol_cli_toml.cpu_quantity
  ; memory : Sol_cli_toml.memory_quantity
  ; rollout_strategy : Sol_cli_toml.rollout_strategy option
  ; ingress_host : Sol_cli_toml.hostname option
  ; ingress_path : Sol_cli_toml.ingress_path option
  ; cluster_issuer : string
  ; calls : service_call list
  ; called_by : service_call list
  ; extra_labels : (string * string) list
  ; progressive_delivery : Sol_cli_toml.progressive_delivery option
  ; (* 2b: the target whose postgres resource this unit consumes, whatever its ownership.
       Routes the unit's `POSTGRES_URL` to `<target>-dml-creds`; see the implementation
       comment. [None] when the unit consumes no database. *)
    db_uses_target : string option
    (** What this unit **declared** it uses ([uses: [app_db]]) -- the requirement, not its
        resolution. The release record carries it so a rollback re-resolves it against the
        *current* target's authorities and bindings (#1422). *)
  ; uses : string list
  ; (* 2d: the target whose *Sol-provisioned* database this unit consumes, if any; gates the
       CA ConfigMap mount, which exists only where Sol's setup step writes it. *)
    db_ca_target : string option
  }

type profile_claim =
  { profile : Sol_cli_profile.t
  ; requirements : Sol_cli_profile.capability list
  ; application_findings : (Sol_cli_profile.capability * string) list
  }

type contract_change =
  | Added of
      { subject : string
      ; topic : string
      ; partitions : int
      }
  | Removed of
      { subject : string
      ; topic : string
      }
  | Partitions of
      { subject : string
      ; observed : int
      ; desired : int
      }
  | Key of
      { subject : string
      ; observed : string option
      ; desired : string option
      }
  | Topic of
      { subject : string
      ; observed : string
      ; desired : string
      }
  | Schema of
      { subject : string
      ; observed : string
      ; desired : string
      }

type t =
  { workspace : string
  ; release_id : Sol_cli_release_id.t
  ; environment : env_config
  ; services : service_spec list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; migrations : Sol_cli_plan_ids.Migration_file.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; consumer_groups : Sol_cli_plan_ids.Consumer_group.t list
  ; requested_scope : string
  ; platform_shape : Sol_cli_profile.platform_shape
  ; profile : profile_claim option
  ; contract : Sol_cli_release_id.contract_fact list
  ; contract_changes : contract_change list
  }

type plan_error =
  | Toml_error of Sol_cli_toml.parse_error
  | Invalid_persistence of
      { workload : string
      ; message : string
      }
  | Unsupported_availability of
      { workload : string
      ; message : string
      }
  | Invalid_service_call of
      { service : string
      ; ref : string
      ; message : string
      }
  | Invalid_kubernetes_name of
      { field : string
      ; value : string
      ; message : string
      }
  | Incompatible_contract_change of
      { subject : string
      ; reason : string
      }

val contract_change_to_string : contract_change -> string

val contract_of_facts
  :  (string * Sol_cli_toml.event_decl) list
  -> Sol_cli_release_id.contract_fact list

val contract_changes_between
  :  observed:Sol_cli_release_id.contract_fact list
  -> desired:Sol_cli_release_id.contract_fact list
  -> contract_change list

val incompatible_contract_change : contract_change -> string option

val with_observed_contract
  :  observed:Sol_cli_release_id.contract_fact list
  -> t
  -> (t, plan_error) result

val derive_consumer_groups
  :  ?declared:Sol_cli_config.declared
  -> string
  -> service_spec list
  -> Sol_cli_plan_ids.Consumer_group.t list

val mode_to_string : deployment_mode -> string
val primitive_to_string : primitive -> string
val primitive_of_string : string -> (primitive, string) result
val effective_rollout_strategy : service_spec -> effective_rollout_strategy
val effective_rollout_strategy_to_string : effective_rollout_strategy -> string

(** Whether a declared service uses a resource of [typ], read from its [uses]
    declaration. Already asked for kafka; the database setup step asks it for postgres to
    find the namespaces that receive the DML credential. *)
val service_uses_resource_type
  :  Sol_cli_config.declared option
  -> string
  -> string
  -> bool

(** Whether a declared service's [uses] names one specific resource. The database setup
    step asks this, rather than the type form, so an externally bound database's consumers
    are not written a Sol credential: only the Sol-provisioned resource's consumers are. *)
val service_uses_resource : Sol_cli_config.declared option -> string -> string -> bool

(** The target whose database the service consumes, by the one rule both the plan and
    `sol secret set` use. [None] when it declares no use of the resource the target resolved
    as its database. *)
val db_uses_target
  :  Sol_cli_config.declared option
  -> target:string option
  -> target_database:string option
  -> string
  -> string option

(** A `uses:` ref's resource name, when the ref names a resource at all. *)
val resource_name_of_ref : string -> string option

(** What a unit **declared** it uses -- the requirement, not its resolution (#1422). The
    declaration's *order* is not semantic: the release content id is order-insensitive under a
    `uses:` reordering, so two releases that declared the same requirements in a different order
    are the same boundary. *)
val declared_uses : Sol_cli_config.declared option -> string -> string list

val resource_of_spec : service_spec -> string
val external_secret_of_spec : service_spec -> (string * string) option
val release_workload_of_spec : service_spec -> Sol_cli_release_id.workload

val workload_release_id
  :  workspace:string
  -> environment:string option
  -> service_spec
  -> Sol_cli_release_id.t

val to_json : t -> Yojson.Safe.t
val pp_summary : Format.formatter -> t -> unit
val is_whole_workspace : t -> bool
val plan_error_to_string : plan_error -> string
val validate_persistence : service_spec -> (unit, plan_error) result
val validate_availability : service_spec -> (unit, plan_error) result
val k8s_name_result : string -> (k8s_name, plan_error) result
val k8s_name_to_string : k8s_name -> string
val namespace_result : workspace:string -> domain:string -> (namespace, plan_error) result
val namespace_to_string : namespace -> string
val namespace_name : workspace:string -> domain:string -> (string, string) result
val k8s_name : string -> (string, string) result

val image_ref
  :  registry:string
  -> workspace:string
  -> k8s_name:k8s_name
  -> tag:string
  -> string

val of_services_result
  :  workspace:string
  -> env:env_config
  -> facts:Sol_cli_workspace_model.t
  -> ?requested_scope:string
  -> ?declared:Sol_cli_config.declared
  -> ?image_refs:(string * string) list
  -> ?inventory:Sol_cli_manifest.service list
  -> ?target:string
  -> ?target_database:string
  -> ?provisioned_database:string
  -> Sol_cli_manifest.service list
  -> (t, plan_error) result
