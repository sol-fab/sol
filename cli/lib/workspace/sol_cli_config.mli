type target =
  { name : string
  ; env : string
  ; provider : Sol_cli_provider.t
  ; region : string
  ; registry : string option
  ; base_domain : string option
  ; cluster_issuer : string option
  ; letsencrypt_email : string option
  ; cluster_name : string option
  ; kube_context : string option
  ; kubeconfig : string option
  ; terraform_var_file : string option
  ; observability_backend : string option
  ; destroy_retention : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; state_bucket : string option
  ; cluster_endpoint_cidr : string option
  ; dns_zone_ownership : string option
  ; node_failure_headroom_nodes : int option
  ; profile : Sol_cli_profile.t option
  ; provider_fields : (string * (string * string) list) list
  ; secret_authorities : (string * (string * secret_authority) list) list
  }

and secret_authority =
  | Sol_managed
  | External of
      { store : string
      ; key : string
      }

type unit_secret_resolution =
  { resolved : (string * secret_authority) list
  ; missing : string list
  ; additional : string list
  }

val destination_of_target : target -> (Sol_cli_kube_destination.t, string) result

type index =
  { index_name : string
  ; partition_key : string option
  ; sort_key : string option
  }

type resource_ownership =
  | Ownership_sol
  | Ownership_external

type resource_binding =
  { ownership : resource_ownership
  ; store : string option
  ; keys : (string * string) list
  ; connection : (string * string) list
  ; (* Class name -> remote path, for a contract whose credential classes resolve one
       contract key to different remote paths. The class is the outer dimension. *)
    credentials : (string * string) list
  }

type resource =
  { name : string
  ; typ : string option
  ; partition_key : string option
  ; sort_key : string option
  ; indexes : index list
  ; size : string option
  ; omit : bool
  ; binding : resource_binding option
  }

type service =
  { name : string
  ; typ : string option
  ; path : string option
  ; uses : string list
  ; scale_min : int option
  ; scale_max : int option
  ; language : Sol_cli_compat.language option
  ; omit : bool
  }

type t =
  { project : string option
  ; target : target
  ; resources : resource list
  ; services : service list
  }

type error =
  { path : string
  ; line : int
  ; message : string
  }

val error_to_string : error -> string
val sol_yml_services_of_string : path:string -> string -> (service list, error) result
val load_for_target : target:string -> (t, error) result

type declared =
  { services : service list
  ; resources : resource list
  ; profile : Sol_cli_profile.t option
  }

val declared_of_config : t -> declared
val load_declared : root:string -> (declared, error) result
val parse_target : string -> (target, error) result
val target_declared : target -> bool
val target_source : target -> string
val discover_target_paths : ?root:string -> unit -> (string list, error) result
val resources : t -> resource list
val services : t -> service list
val format_use_ref : string -> string
val sol_yml_services : root:string -> (service list, error) result
val is_omitted_service : t -> name:string -> bool
val provider_field : target -> string -> string option

val secret_authority
  :  target
  -> unit_address:string
  -> key:string
  -> secret_authority option

val secret_authorities_for_unit : target -> string -> (string * secret_authority) list

val resolve_secret_authorities
  :  target
  -> unit_address:string
  -> required_keys:string list
  -> unit_secret_resolution

val vars_with_profile_precedence
  :  has_profile:bool
  -> cli_vars:string list
  -> config_vars:string list
  -> string list

val local_infra : root:string -> (Sol_cli_workspace.infra_requirements, error) result
