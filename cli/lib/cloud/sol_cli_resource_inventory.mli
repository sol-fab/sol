(** Read-only resource inventory. Classifies recorded state, independent provider
    observation, and recovery disposition; never mutates. *)

type layer =
  | Installation
  | Cloud
  | Platform
  | Authorization
  | Serverless
  | Workload

type root_role =
  | Installation_root
  | Cluster_root
  | Platform_root
  | Authorization_root

type status =
  | Owned
  | Recorded
  | Missing
  | Unrecorded
  | External
  | In_cluster
  | Synthetic
  | Uid_mismatch of string
  | Absent
  | Unknown of string

type recovery =
  | Not_applicable
  | Recoverable of
      { address : string
      ; import_identity : string
      }
  | Unrecoverable of string
  | Unmapped of string

type observation =
  | Observed
  | Unobserved
  | By_contract
  | Failed of string

type action =
  | No_action
  | Adopt
  | Investigate
  | Retain
  | Uninstall

type row =
  { layer : layer
  ; root : string
  ; address : string option
  ; resource_class : string
  ; name : string option
  ; identity : string option
  ; observed_as : string option
  ; ownership_kind : string option
  ; uid : string option
  ; uid_status : [ `Match | `Mismatch | `No_record | `Not_applicable ]
  ; import_identity : string option
  ; status : status
  ; recovery : recovery
  ; observation : observation
  ; action : action
  ; reason : string option
  ; checked_with : string option
  ; lifetime : [ `Installation | `Target | `Workload ]
  ; deletion_protection : bool option
  }

type root =
  { role : root_role
  ; layer : layer
  ; durable : bool
  ; state : Sol_cli_cloud_destroy.state_read
  ; last_operation : Sol_cli_supervised.status
  ; errored_state : bool
  }

type verdict =
  | Reconciled
  | Incomplete
  | Attention_required
  | Unknown_verdict
  | Unverified

type coverage =
  { inventory_complete : bool
  ; verification_complete : bool
  ; required_classes : string list
  ; observed_classes : string list
  ; by_contract_classes : string list
  ; unobserved_classes : string list
  ; failed_classes : string list
  ; recorded_unverified : string list
  }

type summary =
  { owned : int
  ; recorded : int
  ; missing : int
  ; unrecorded : int
  ; external_resources : int
  ; in_cluster : int
  ; synthetic : int
  ; uid_mismatch : int
  ; unknown : int
  }

type inventory =
  { target : Sol_cli_config.target
  ; roots : root list
  ; rows : row list
  ; coverage : coverage
  ; summary : summary
  ; verdict : verdict
  ; unknowns : string list
  }

val layer_to_string : layer -> string
val root_role_to_string : root_role -> string
val status_to_string : status -> string
val recovery_to_string : recovery -> string
val observation_to_string : observation -> string
val action_to_string : action -> string
val verdict_to_string : verdict -> string

val root_of_state
  :  role:root_role
  -> layer:layer
  -> durable:bool
  -> chdir:string
  -> backend_config:string list
  -> Sol_cli_cloud_destroy.state_read
  -> root

val read_root
  :  role:root_role
  -> layer:layer
  -> durable:bool
  -> chdir:string
  -> backend_config:string list
  -> root

val unreadable_root
  :  role:root_role
  -> layer:layer
  -> durable:bool
  -> chdir:string
  -> backend_config:string list
  -> string
  -> root

val collect
  :  Sol_cli_config.target
  -> roots:root list
  -> cloud:Sol_cli_cloud_wiring.cloud_collection option
  -> state_only:bool
  -> inventory

val filter_inventory
  :  all:bool
  -> classes:string list
  -> statuses:string list
  -> inventory
  -> inventory

val filter_rows
  :  all:bool
  -> classes:string list
  -> statuses:string list
  -> row list
  -> row list

val render
  :  ?all:bool
  -> ?classes:string list
  -> ?statuses:string list
  -> explain:bool
  -> inventory
  -> string

val to_json : inventory -> Yojson.Safe.t
