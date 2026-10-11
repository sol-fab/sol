type secret_source = Sol_cli_secret_source.t =
  | Sol_managed
  | External of
      { store : string
      ; key : string
      }

type primitive =
  | Svc
  | Worker
  | Fn

type service =
  { domain : string
  ; name : string
  ; primitive : primitive
  ; dir : string
  }

type workload_fact = service * bool
type unexpected = string * string * string

type workspace_scan =
  { workloads : workload_fact list
  ; unexpected : unexpected list
  }

type discover_error =
  | Missing_app_dir
  | Workspace_error of Sol_cli_workspace.workspace_error

val workload_fact_to_service : workload_fact -> service
val scan_workspace : ?root:string -> unit -> (workspace_scan, discover_error) result
val primitive_of_suffix : string -> primitive option
val primitive_label : primitive -> string
val observability_identity : (string * string) list

val identity_env
  :  ?env:string
  -> ?release:Sol_cli_release_id.t
  -> workspace:string
  -> domain:string
  -> service:string
  -> primitive:string
  -> unit
  -> (string * string) list

val discover_error_to_string : discover_error -> string
val discover_services : ?root:string -> unit -> (service list, discover_error) result

type kafka_transport =
  | Plaintext
  | Sasl_ssl

val kafka_transport : Sol_cli_profile.platform_shape -> kafka_transport
val kafka_tls : kafka_transport -> bool
val kafka_transport_of_config : (string * string) list -> kafka_transport
val cluster_env : kafka_transport -> (string * string) list
val production_kafka_config : (string * string) list
val default_cluster_env : (string * string) list
val monitoring_namespace : string
val loki_service : string
val loki_service_port : int
val loki_host_port : int
val grafana_service : string
val grafana_service_port : int
val grafana_host_port : int
val prometheus_service : string
val prometheus_service_port : int
val prometheus_host_port : int
val pushgateway_service : string
val pushgateway_service_port : int
val pushgateway_host_port : int
val tempo_service : string
val tempo_query_port : int
val tempo_query_host_port : int
val tempo_otlp_port : int
val tempo_otlp_host_port : int
val service_host : namespace:string -> name:string -> string
val service_url : scheme:string -> namespace:string -> name:string -> port:int -> string
val local_url : int -> string
val default_secrets : (string * string) list
val runtime_secret_name : string
val workload_secret_name : string -> string
val external_secret_name : string -> string
val required_secret_keys : ?transport:kafka_transport -> string list -> string list
val config_hash : (string * string) list -> (string * string) list -> string
val sanitize_label_value : string -> string
val namespace_doc : ns:string -> Sol_cli_yaml.document
val deploy_role_binding_doc : ns:string -> Sol_cli_yaml.document
val operator_role_binding_doc : ns:string -> Sol_cli_yaml.document
val service_account_doc : ns:string -> name:string -> Sol_cli_yaml.document
val pdb_doc : ns:string -> name:string -> replicas:int -> Sol_cli_yaml.document

val configmap_doc
  :  ?cluster_env:(string * string) list
  -> ?extra_env:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val secret_doc
  :  ?base_secrets:(string * string) list
  -> ?extra_secrets:(string * string) list
  -> ?labels:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val external_secret_doc
  :  secret_refs:(string * string * string) list
  -> ns:string
  -> name:string
  -> Sol_cli_yaml.document

type workload_shape =
  | Http_service
  | Background_worker

module Workload_spec : sig
  type t =
    { extra_labels : (string * string) list
    ; secret_keys : string list
    ; secret_sources : (string * secret_source) list
    ; volumes : Sol_cli_toml.volume list
    ; projected_identities : Sol_cli_identity_projection.t list
    ; env : string option
    ; config_hash : string
    ; availability : Sol_cli_availability.t
    ; consumes_kafka : bool
    ; kafka_tls : bool
    ; readiness_path : string
    ; shape : workload_shape
    ; replicas : int
    ; cpu : string
    ; memory : string
    ; ns : string
    ; name : string
    ; image : string
    ; workspace : string
    ; domain : string
    ; primitive : string
    ; release_id : Sol_cli_release_id.t
    ; (* 2d: the CA ConfigMap to mount when this unit consumes a Sol-provisioned database.
         Prep: see {!Sol_cli_manifest_yaml.Workload_spec}. *)
      db_ca_configmap : string option
    }
end

val deployment_doc
  :  ?rollout_strategy:Sol_cli_toml.rollout_strategy
  -> workload:Workload_spec.t
  -> unit
  -> Sol_cli_yaml.document

val rollout_doc
  :  workload:Workload_spec.t
  -> pd:Sol_cli_toml.progressive_delivery
  -> unit
  -> Sol_cli_yaml.document

val pvc_docs
  :  ns:string
  -> name:string
  -> Sol_cli_toml.volume list
  -> Sol_cli_yaml.document list

val blue_green_service_docs : ns:string -> name:string -> Sol_cli_yaml.document list
val service_doc : ns:string -> name:string -> Sol_cli_yaml.document

val ingress_doc
  :  ?ingress_host:string
  -> ?ingress_path:string
  -> ?cluster_issuer:string
  -> ?tls_secret_name:string
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val managed_database_egress_doc
  :  cidrs:string list
  -> port:int
  -> ns:string
  -> name:string
  -> Sol_cli_yaml.document

val network_policy_doc
  :  ?egress_to:(string * string) list
  -> ?ingress_from:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

module Scheduled_workload_spec : sig
  type t =
    { ns : string
    ; name : string
    ; image : string
    ; secret_keys : string list
    ; secret_sources : (string * secret_source) list
    ; projected_identities : Sol_cli_identity_projection.t list
    ; env : string option
    ; schedule : string
    ; concurrency_policy : string
    ; backoff_limit : int
    ; cpu : string
    ; memory : string
    ; kafka_tls : bool
    ; workspace : string
    ; domain : string
    ; release_id : Sol_cli_release_id.t
    ; (* 2d: see {!Workload_spec.t}. *)
      db_ca_configmap : string option
    }
end

val cronjob_doc : Scheduled_workload_spec.t -> Sol_cli_yaml.document

val migration_configmap_doc
  :  name:string
  -> namespace:string
  -> (string * string) list
  -> Sol_cli_yaml.document

val migration_job_doc
  :  name:string
  -> namespace:string
  -> image:string
  -> args:string list
  -> configmap_name:string
  -> Sol_cli_yaml.document

val contract_job_doc
  :  cluster_env:(string * string) list
  -> name:string
  -> namespace:string
  -> image:string
  -> command:string list
  -> args:string list
  -> Sol_cli_yaml.document

val create_idempotent
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

type bundle =
  { namespace_yaml : string
  ; prerequisites_yaml : string
  ; workload_yaml : string
  }

val apply_bundle_namespace
  :  ctx:Sol_cli_kube_destination.context
  -> bundle
  -> (unit, string) result

val apply_bundle_prerequisites
  :  ctx:Sol_cli_kube_destination.context
  -> bundle
  -> (unit, string) result

val apply_bundle_workload
  :  ctx:Sol_cli_kube_destination.context
  -> bundle
  -> (unit, string) result

val print_bundle : bundle -> unit
val emit_to_dir : string -> bundle -> ns:string -> name:string -> (string, string) result
