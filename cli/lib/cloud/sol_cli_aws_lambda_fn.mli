(** The AWS Lambda lifecycle for a run-once Sol [-fn].

    This adapter preserves the [-fn] contract: one run-to-completion invocation with an
    exit status, not an HTTP server and not an event source. It deploys an immutable
    container image plus an explicit execution role, publishes an immutable version,
    moves the [live] alias, invokes [{}] through that alias and requires the framework's
    [{status: "ok"}] acknowledgement. There is deliberately no Function URL, no HTTP
    readiness smoke, and no incoming caller policy: the Lambda execution role authorizes
    AWS resource access, while triggers and incoming identity remain separate contracts. *)

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; unit : string
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type observed =
  { function_name : string
  ; version : string
  ; alias : string
  ; tags : (string * string) list
  ; invocation_status : string
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; image : string
  ; role_arn : string
  }

type failure = Sol_cli_aws_lambda_common.failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

val failure_to_string : failure -> string
val preflight : request -> (unit, failure) result

(** Create or update the function, publish a version, move [live], invoke [{}] through
    that alias, require [{"status":"ok"}], and write the ownership record. *)
val deploy : request -> (release, failure) result

(** Invoke through [qualifier] and return the acknowledgement status. A provider
    [FunctionError] or a non-200 status is a failure, never a successful deployment. *)
val invoke : request -> qualifier:string -> (string, failure) result

(** Move [live] to [version], then invoke and require the same acknowledgement. The
    caller owns rewriting the release record from the observed state. *)
val rollback : request -> version:string -> (observed, failure) result

val destroy
  :  request
  -> profile:string option
  -> region:string
  -> service:string
  -> record:string
  -> (unit, failure) result

val release_json : release -> Yojson.Safe.t
val observed_json : observed -> Yojson.Safe.t
val read_record : path:string -> (release, string) result
val write_record : path:string -> release -> (unit, string) result
