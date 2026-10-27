type ingress = Public

type identity =
  { unit : string
  ; callers : (string * string) list
  ; issuer : string
  ; jwks_uri : string
  }

type request =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; identity : identity
  ; ingress : ingress
  ; record : string option
  }

type observed =
  { url : string
  ; revision : string
  ; traffic : (string * int) list
  ; labels : (string * string) list
  }

type release =
  { project : string
  ; region : string
  ; service : string
  ; revision : string
  ; url : string
  ; image : string
  }

type failure =
  | Refused of string
  | Provider of string
  | Partial of string * observed option
  | Unknown of string

val ingress_of_string : string -> (ingress, failure) result

type runner =
  { run : string list -> (string, string) result
  ; http : url:string -> token:string option -> (int * string, string) result
  }

val failure_to_string : failure -> string
val preflight : request -> (unit, failure) result
val deploy_argv : request -> string list
val deploy : runner -> request -> (release, failure) result
val verify : runner -> request -> token:string -> (observed, failure) result
val rollback_argv : request -> revision:string -> string list

val rollback
  :  runner
  -> request
  -> revision:string
  -> token:string
  -> (observed, failure) result

val destroy
  :  runner
  -> project:string
  -> region:string
  -> service:string
  -> record:string
  -> (unit, failure) result

val observed_json : observed -> Yojson.Safe.t
val release_json : release -> Yojson.Safe.t
val write_record : path:string -> release -> (unit, string) result
