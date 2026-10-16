type workload =
  { resource : string
  ; name : string
  ; uid : string
  }

type scope =
  { namespace : string
  ; workloads : workload list
  }

type workload_kind

val kinds : workload_kind list
val optional_kind : workload_kind -> bool
val resource_of_kind : workload_kind -> string
val list_args : namespace:string -> kind:workload_kind -> string list

(** The authoritative existence read of one declared namespace: the cluster-scoped object, not
    the namespaced listing, because RBAC answers [Forbidden] for a namespaced read by an
    identity with no grant there and that cannot be told apart from an empty namespace. *)
val namespace_exists_args : namespace:string -> string list

val delete_args
  :  namespace:string
  -> names:string list
  -> timeout_seconds:int
  -> string list

val wait_args : namespace:string -> workspace:string -> timeout_seconds:int -> string list
val workloads_of_json : string -> workspace:string -> (workload list, string) result
val workload_to_string : workload -> string

val partition_owned
  :  evidence:Sol_cli_release_id.owned_object list
  -> scope
  -> workload list * workload list

val to_string : scope -> string

type release_failure =
  { namespace : string
  ; kind : string option
  ; operation : string
  ; reason : string
  }

type release =
  | Workloads_released
  | Workloads_not_releasable of string
  | Workloads_unestablished of release_failure

val failure_to_string : release_failure -> string

type read_error =
  | No_cluster of string
  | Read_unestablished of release_failure

(** One authoritative namespace-existence observation, classified by the command layer, which
    owns the process error. [Namespace_absent] is a positive observation about the namespace,
    never an inference from a read that could not be authorized. *)
type namespace_probe =
  | Namespace_exists
  | Namespace_absent
  | Namespace_unreachable of string
  (** The existence observation answered something that is neither presence nor absence: the
      view could not be established, the read was refused, it timed out, or it was
      undecodable. Absence is never inferred from it, and it is not replaced by a weaker
      read -- the release refuses and `--accept-unreleased` stays the operator's override. *)
  | Namespace_unestablished of string

type read_result =
  { scopes : scope list
  ; namespaces_absent : string list
  }

val read_workloads
  :  run:(string list -> (string, Sol_cli_process.error) result)
  -> namespace_probe:(string -> namespace_probe)
  -> namespaces:string list
  -> workspace:string
  -> (read_result, read_error) result

val release_workloads
  :  run:(string list -> (string, Sol_cli_process.error) result)
  -> namespace_probe:(string -> namespace_probe)
  -> delete:
       (namespace:string -> names:string list -> (unit, Sol_cli_process.error) result)
  -> wait:(namespace:string -> (unit, Sol_cli_process.error) result)
  -> evidence:Sol_cli_release_id.owned_object list
  -> namespaces:string list
  -> workspace:string
  -> release
