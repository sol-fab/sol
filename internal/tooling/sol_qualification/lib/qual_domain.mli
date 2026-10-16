(** Offline qualification domain. No released-candidate binding or release verdict
    API exists here. Fixture evidence is always MECHANISM evidence. *)
type run

type intent
type selection
type obligations
type instance

type scenario =
  | Aws
  | Gcp
  | Local

type kind =
  | Ca
  | Dml
  | No_master
  | Tls
  | Migration

type owner =
  | Legacy_matrix of string
  | Typed_family of string

val sha256 : string -> string
val canonical_json : Yojson.Safe.t -> (string, string) result
val run_json : run -> Yojson.Safe.t
val same_run : run -> run -> bool
val select : run -> intent -> (selection, string) result
val consumers : selection -> string list
val exclusions : selection -> (string * string) list
val bind_obligations : run -> scenario -> selection -> (obligations, string) result
val instances : obligations -> instance list
val applicability : obligations -> (string * string) list
val instance_key : instance -> string
val instance_kind : instance -> kind
val obligations_json : obligations -> Yojson.Safe.t

type ca_requirement
type dml_requirement
type no_master_requirement
type tls_requirement
type migration_requirement

type request =
  | Ca_delivery of ca_requirement
  | Dml_delivery of dml_requirement
  | No_master_copy of no_master_requirement
  | Tls_connectivity of tls_requirement
  | Migration_input of migration_requirement

val plan : instance -> request
val requested : request -> instance
val reconcile_plan : obligations -> request list -> (unit, string) result
val reconcile_keys : expected:string list -> actual:string list -> (unit, string) result

val check_ownership
  :  claims:string list
  -> assignments:(string * owner) list
  -> (unit, string) result

type ca_facts =
  { namespace : string
  ; workload : string
  ; configmap : string
  ; key : string
  ; mount_path : string
  ; nonempty : bool
  }

type dml_facts =
  { namespace : string
  ; workload : string
  ; credential_class : string
  ; key : string
  ; nonempty : bool
  }

(** Secret source references, never credential values or field-name heuristics.
    Unresolved source provenance must be Unreadable, not an empty reference list. *)
type secret_address =
  { namespace : string
  ; name : string
  }

type unit_secret_facts =
  { namespace : string
  ; workload : string
  ; references : secret_address list
  }

type tls_facts =
  { namespace : string
  ; workload : string
  ; verified : bool
  }

type migration_facts =
  { database : string
  ; key : string
  ; nonempty : bool
  }

type 'a state =
  | Present of 'a
  | Absent
  | Unreadable of string

type 'a observation

type recorded_check =
  | Ca_checked of ca_requirement * ca_facts observation
  | Dml_checked of dml_requirement * dml_facts observation
  | No_master_checked of no_master_requirement * unit_secret_facts observation
  | Tls_checked of tls_requirement * tls_facts observation
  | Migration_checked of migration_requirement * migration_facts observation

type decision =
  | Pass
  | Fail of string
  | Unknown of string
  | Not_run of string

type verdict = private
  { instance : instance
  ; decision : decision
  ; evidence : string list
  }

(** Pure semantic matching and predicates. No I/O, clock, subprocess or globals. *)
val evaluate : recorded_check -> verdict

val reconcile_outcomes : obligations -> verdict list -> (unit, string) result

val accept_mechanism
  :  obligations
  -> request list
  -> verdict list
  -> (unit, string) result

val verdict_json : verdict -> Yojson.Safe.t

module Fixture : sig
  val bind
    :  scenario:scenario
    -> attempt:string
    -> assessment:string
    -> candidate_revision:string
    -> specimen:string
    -> contract:Yojson.Safe.t
    -> (run, string) result

  val intent : Yojson.Safe.t -> (intent, string) result

  val observe
    :  run
    -> subject:string
    -> evidence:string list
    -> 'a state
    -> ('a observation, string) result

  val blocked : instance -> evidence:string list -> string -> (verdict, string) result
end
