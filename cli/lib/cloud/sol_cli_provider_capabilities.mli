type root_status =
  | Root_present
  | Root_not_applicable
  | Root_not_implemented

type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

type identity_contract =
  { identity : Sol_cli_installation.prerequisite
  ; policy_output : string
  ; declared_as : string
  }

type authority =
  | No_authority_required
  | Mechanism of
      { matchers : Sol_cli_terraform_plan.matcher list
      ; scope : Sol_cli_terraform.scope
      ; reconciliation_scope : string list -> Sol_cli_terraform.scope
      }

type authorization_reconciler =
  | Reconciler_role of string
  | Reconciler_service_account of string

type authorization_workload =
  { unit : string
  ; namespace : string
  ; secrets : string list
  }

type t =
  { root_status : root_status
  ; workload_identity_issuer : Sol_cli_config.target -> (string, string) result
    (** DEC-051/DEC-063: the single Kubernetes service-account OIDC issuer the
        target's cluster is trusted to have issued workload tokens with.

        It is target/infrastructure truth: discovered through the driver and
        never application configuration, and never taken from the [iss] claim
        of an incoming token. [Ok issuer] is that trusted issuer; [Error reason]
        means the target establishes none (so a workload-identity consumer must
        fail closed). *)
  ; backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
  ; platform_storage : platform_storage
  ; cluster_substrate :
      (outputs_json:string
       -> region:string
       -> cluster_name:string
       -> (Sol_cli_cluster_substrate.t, string) result)
        option
  ; installation_prerequisites : Sol_cli_installation.prerequisite list
  ; installation_probes :
      Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  ; installation_backend :
      Sol_cli_installation.installation_config -> (string list, string) result
  ; installation_vars :
      manage_dns_zone:bool
      -> ?parent_zone_id:string
      -> Sol_cli_installation.installation_config
      -> (string * string) list
  ; installation_zone_address : string
  ; installation_zone_import_address : string
  ; installation_zone_lookup : string -> string list
  ; installation_zone_candidates : string -> ((string * string) list, string) result
    (** Parse the lookup's stdout into [(identity, dns name)] candidates. The
        provider's list is a superset -- Route53 answers a prefix query with the
        next zone when there is no exact match -- so callers must select the one
        whose name is exactly the requested domain (see
        {!Sol_cli_installation.select_zone_identity}). *)
  ; installation_nameservers_output : string
  ; installation_failure_means_absent : string -> bool
  ; installation_identity_contracts : identity_contract list
  ; installation_created_prerequisites : Sol_cli_installation.prerequisite list
  ; installation_state_backend_address : string
  ; installation_retire_state_backend :
      run:(string list -> Sol_cli_installation.observation)
      -> Sol_cli_installation.installation_config
      -> (unit, string) result
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
  ; guarded_removals : string list
  ; root_declared_vars :
      has_postgres:bool
      -> kafka_connection:Yojson.Safe.t option
      -> production_postgres:bool
      -> ecr_repositories:(unit -> (string, string) result)
      -> ((string * string) list, string) result
  ; destroy_guard_vars : final_snapshot:string option -> (string * string) list
  ; authority : authority
  ; guarded_addresses : string list
  ; cloud_ready_expectation : string
  ; production_qualified : bool
  ; state_locking : string option
  ; scoped_identities : string list
  ; authorization_reconciler_field : string
  ; authorization_trust_field : string
  ; authorization_destroy_trust_placeholder : string
  ; authorization_root_vars :
      Sol_cli_config.target -> ((string * string) list, string) result
  ; authorization_fence_addresses : string list
  ; authorization_reconciler :
      Sol_cli_config.target -> (authorization_reconciler, string) result
  ; authorization_assumption :
      authorization_reconciler -> ((string * string) list, string) result
  ; authorization_principal_matches :
      authorization_reconciler -> principal:string -> (unit, string) result
  ; authorization_effective_access :
      Sol_cli_config.target -> authorization_workload list -> (unit, string) result
  }

val aws_effective_access
  :  run:(string list -> (string, string) result)
  -> Sol_cli_config.target
  -> authorization_workload list
  -> (unit, string) result

val gcp_effective_access
  :  run:(string list -> (string, string) result)
  -> Sol_cli_config.target
  -> authorization_workload list
  -> (unit, string) result

(** The provider-specific half of {!workload_identity_issuer}: discover the
    target cluster's trusted Kubernetes service-account OIDC issuer from the
    provider, failing closed when it cannot be read. [run] is injected so the
    mechanics can be tested without the real CLIs. *)
val aws_workload_identity_issuer
  :  run:(string list -> (string, string) result)
  -> Sol_cli_config.target
  -> (string, string) result

(** GKE's issuer is read from the cluster's public OIDC discovery document (the
    Google API `well-known.getOpenid-configuration` endpoint), whose reported
    [issuer] must be on the GKE API host. The document is fetched without an
    operator credential because the callee fetches it, and the advertised JWKS,
    without Google credentials at runtime. *)
val gcp_workload_identity_issuer
  :  run:(string list -> (string, string) result)
  -> Sol_cli_config.target
  -> (string, string) result

val required : string -> string option -> (string, string) result
val aws : t
val gcp : t
val byo : t
val capabilities_of : Sol_cli_provider.t -> t
val authorization_trust : Sol_cli_config.target -> string option
val validate_target : Sol_cli_provider.t -> Sol_cli_config.target -> (unit, string) result
val owns_root : Sol_cli_provider.t -> bool
val provider_console_url : Sol_cli_config.target -> string option
val installation_nameservers_output : Sol_cli_provider.t -> string
val installation_identity_contracts : Sol_cli_provider.t -> identity_contract list

val installation_prerequisites
  :  Sol_cli_provider.t
  -> Sol_cli_installation.prerequisite list

val installation_created_prerequisites
  :  Sol_cli_provider.t
  -> Sol_cli_installation.prerequisite list

val installation_probes
  :  Sol_cli_provider.t
  -> Sol_cli_installation.installation_config
  -> Sol_cli_installation.probe list

val installation_backend
  :  Sol_cli_provider.t
  -> Sol_cli_installation.installation_config
  -> (string list, string) result

val installation_vars
  :  Sol_cli_provider.t
  -> manage_dns_zone:bool
  -> ?parent_zone_id:string
  -> Sol_cli_installation.installation_config
  -> (string * string) list

val installation_observation
  :  provider:Sol_cli_provider.t
  -> string list
  -> Sol_cli_installation.observation

val observe_installation
  :  Sol_cli_config.target
  -> ( Sol_cli_installation.installation_config
       * (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
       , string )
       result
