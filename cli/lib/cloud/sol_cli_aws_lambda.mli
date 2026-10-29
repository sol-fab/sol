type identity =
  { unit : string
  ; callers : (string * string) list
  ; issuer : string
  ; jwks_uri : string
  }

type output =
  { stdout : string
  ; stderr : string
  }

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; identity : identity
  ; record : string option
  ; run : string list -> (output, string) result
  ; http : url:string -> token:string option -> (int * string, string) result
  }

type observed =
  { function_name : string
  ; version : string
  ; alias : string
  ; url : string
  ; tags : (string * string) list
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
  }

type failure =
  | Refused of string
  | Provider of string
  | Partial of string * observed option
  | Unknown of string

val failure_to_string : failure -> string
val provider_service_of : string -> (string, failure) result
val preflight : request -> (unit, failure) result
val deploy : request -> (release, failure) result
val verify : request -> token:string -> (observed, failure) result
val rollback : request -> version:string -> token:string -> (observed, failure) result

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
