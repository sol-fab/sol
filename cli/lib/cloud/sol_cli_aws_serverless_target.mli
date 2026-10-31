(** Provider-native operations behind [Sol_cli_serverless_lifecycle], which
    establishes [execution: serverless] before calling them. *)

val deploy
  :  target:Sol_cli_config.target
  -> config:Sol_cli_config.t
  -> project:string
  -> service:Sol_cli_manifest.service
  -> image:string
  -> record:string
  -> runtime_service_account:string option
  -> schedule:string option
  -> schedule_timezone:string option
  -> scheduler_identity:string option
  -> (Yojson.Safe.t, string) result

(** Dispatch on the ownership record's [kind]. The record, not the command line, is the
    authority for which Lambda lifecycle produced the function. *)
val rollback
  :  target:Sol_cli_config.target
  -> project:string
  -> service:Sol_cli_manifest.service
  -> record:string
  -> version:string
  -> token:string
  -> (Yojson.Safe.t, string) result

val destroy
  :  target:Sol_cli_config.target
  -> service:string
  -> record:string
  -> (unit, string) result
