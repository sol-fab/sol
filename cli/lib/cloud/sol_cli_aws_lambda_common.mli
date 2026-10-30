(** Provider plumbing shared by the two AWS Lambda lifecycle adapters.

    The HTTP service adapter and the run-once function adapter have different invocation
    contracts, but they observe the same AWS Lambda resources: immutable container images
    in ECR, an execution role, immutable published versions, a [live] alias, ownership tags,
    and inventory-based absence. Keeping those observations in one place is what lets a
    [destroy] decision read the same ownership and absence rules the deploy wrote. *)

type output =
  { stdout : string
  ; stderr : string
  }

type failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

val failure_to_string : failure -> string

(** The provider name is derived once, from the Sol service name, through the same
    Kubernetes/Lambda naming rule. *)
val provider_service_of : string -> (string, failure) result

type scope =
  { profile : string option
  ; region : string
  ; run : string list -> (output, string) result
  }

val workspace_label : unit -> string
val aws : profile:string option -> region:string -> string list -> string list

(** An immutable OCI reference: [<repo>@sha256:<64 lowercase hex>]. *)
val valid_image : string -> (unit, failure) result

val inventory : scope -> (string list, string) result
val resource_is_absent : string -> bool

val describe
  :  scope
  -> function_name:string
  -> ( [ `Present of string * (string * string) list ]
       , [> `Provider of string | `Unknown of string ] )
       result

(** [Ok None] only when the provider positively reports the alias as absent. Any other
    failure is an error, so a transient or permission failure cannot be mistaken for "no
    alias yet" and trigger a create that masks the real problem. *)
val alias_version : scope -> function_name:string -> (string option, failure) result

val put_alias : scope -> function_name:string -> version:string -> (unit, failure) result

(** Create or update a Lambda function from an immutable image, wait for the
    update, and leave the function ready to publish. The caller has already
    established ownership for an existing function. [timeout_s] and [memory_mb]
    are updated only when supplied; creation uses 30 seconds and 512 MB by
    default. *)
val ensure_function
  :  scope
  -> function_name:string
  -> image:string
  -> role_arn:string
  -> environment:(string * string) list
  -> tags:(string * string) list
  -> ?timeout_s:int
  -> ?memory_mb:int
  -> existing:bool
  -> unit
  -> (unit, failure) result

val publish_version : scope -> function_name:string -> (string, failure) result
val trim_url : string -> string
val record_kind : path:string -> (string option, string) result
val read_json : path:string -> (Yojson.Safe.t, string) result
val write_json : path:string -> Yojson.Safe.t -> (unit, string) result
