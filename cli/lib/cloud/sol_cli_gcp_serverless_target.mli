(** Provider-native operations behind [Sol_cli_serverless_lifecycle], which
    establishes [execution: serverless] before calling them. *)

val deploy
  :  target:Sol_cli_config.target
  -> config:Sol_cli_config.t
  -> project:string
  -> service:Sol_cli_manifest.service
  -> image:string
  -> record:string
  -> (Sol_cli_cloud_run.release, string) result

val rollback
  :  target:Sol_cli_config.target
  -> project:string
  -> service:Sol_cli_manifest.service
  -> record:string
  -> revision:string
  -> token:string
  -> (Sol_cli_cloud_run.observed, string) result

val destroy
  :  target:Sol_cli_config.target
  -> service:string
  -> record:string
  -> (unit, string) result
