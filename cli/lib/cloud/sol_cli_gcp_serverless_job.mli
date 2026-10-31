(** Cloud Run Jobs backend for a target-scoped GCP [-fn]. *)

val ownership_tag : string

type request =
  { project : string
  ; region : string
  ; service : string
  ; unit : string
  ; job : string
  ; image : string
  ; service_account : string
  ; schedule : string option
  ; timezone : string option
  ; scheduler_identity : string option
  ; record : string
  ; runner : Sol_cli_cloud_run.runner
  }

type release

val failure_to_string : Sol_cli_cloud_run.failure -> string
val runtime_service_account : release -> string
val release_json : release -> Yojson.Safe.t
val read_record : string -> (release, string) result
val write_record : path:string -> release -> (unit, string) result
val deploy : request -> (release, Sol_cli_cloud_run.failure) result

val rollback
  :  request
  -> record:string
  -> execution:string
  -> (release, Sol_cli_cloud_run.failure) result

val destroy : request -> record:string -> (unit, Sol_cli_cloud_run.failure) result
