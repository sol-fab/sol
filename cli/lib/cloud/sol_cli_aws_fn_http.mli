(** The AWS Lambda lifecycle for an HTTP-triggered Sol [-fn].

    A Lambda Function URL is a public endpoint. AWS has no network-private HTTP
    endpoint for a function, so this adapter supports public exposure only and
    the target dispatcher refuses an internal HTTP function before mutation. The
    function runtime answers the declared route and the built-in readiness
    endpoints; the execution role authorizes AWS resource access, and the public
    Function URL resource policy is scoped to the function alias. *)

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; unit : string
  ; http_path : string
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; url : string
  ; image : string
  ; role_arn : string
  ; http_path : string
  }

type failure = Sol_cli_aws_lambda_common.failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

val failure_to_string : failure -> string
val preflight : request -> (unit, failure) result
val deploy : request -> (release, failure) result

val rollback
  :  request
  -> version:string
  -> on_alias_moved:(string -> (unit, string) result)
  -> (release, failure) result

val destroy
  :  r:request
  -> profile:string option
  -> region:string
  -> service:string
  -> record:string
  -> (unit, failure) result

val release_json : release -> Yojson.Safe.t
val read_record : path:string -> (release, string) result
val write_record : path:string -> release -> (unit, string) result
