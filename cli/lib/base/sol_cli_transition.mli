(** A target's intended state transition, derived from Sol's own ownership state.

    This is display and confirmation input, not a second apply path: deployment still
    executes the same reconciliation, and the plan is computed from the declarations and
    the records that reconciliation reads. A caller must treat an unreadable prior state
    as [unknown] and refuse a destructive operation rather than guessing. *)

type workload =
  { name : string
  ; kind : string
  ; image : string option
  ; schedule : string option
  ; http : (string * string) option
    (** [(path, exposure)] for a public/internal HTTP function. *)
  ; config_digest : string option
    (** Digest of the runtime configuration the desired unit carries. *)
  }

type action =
  | Add
  | Update
  | Delete
  | Preserve

type resource_kind =
  | Workload
  | Http_route
  | Gateway
  | Schedule
  | Runtime_identity
  | Permission

type change =
  { resource : resource_kind
  ; name : string
  ; action : action
  ; destructive : bool
  ; detail : string
  }

type t =
  { target : string
  ; desired_fingerprint : string
    (** Digest of target/backend/desired state. This is the plan's identity:
            it survives a partial apply, where the prior state and therefore the
            transition changes have moved on. *)
  ; fingerprint : string
    (** Digest of target/backend/desired state. A persisted plan is applied
            only while this is unchanged. *)
  ; changes : change list
  ; unknown : string list
  }

(** Normalize an AWS EventBridge or GCP Scheduler expression to Sol's five-field
    comparison form. *)
val normalize_schedule : string -> string

(** Read the workload a serverless release record declares. Unknown kinds and
    missing provider identity are errors, never a guessed deletion target. *)
val of_serverless_record : service:string -> Yojson.Safe.t -> (workload, string) result

type permissions =
  { scheduler_invoke : bool
  ; gateway_invoke : bool
  }

val no_permissions : permissions
val digest_config : (string * string) list -> string

val compute
  :  target:string
  -> backend:[ `Kubernetes | `Serverless ]
  -> previous:workload list
  -> desired:workload list
  -> unknown:string list
  -> ?permissions:permissions
  -> ?fingerprint:string
  -> unit
  -> t

val destructive : t -> change list
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val has_changes : t -> bool
val render : ?title:string -> t -> string
