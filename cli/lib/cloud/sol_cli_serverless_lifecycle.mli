(** The one serverless lifecycle dispatch boundary.

    Commands resolve the target, service, image, record, and caller token; they do not
    choose a provider adapter or decide which rollback input a provider accepts. This
    module makes that choice once and hands the operation to the provider adapter, which
    keeps provider-native identity, primitive support, and lifecycle mechanics. *)

val deploy
  :  target:Sol_cli_config.target
  -> config:Sol_cli_config.t
  -> project:string
  -> service:Sol_cli_manifest.service
  -> image:string
  -> record:string
  -> (Yojson.Safe.t, string) result

val rollback
  :  target:Sol_cli_config.target
  -> project:string
  -> service:Sol_cli_manifest.service
  -> record:string
  -> version:string option
  -> revision:string option
  -> token:string
  -> (Yojson.Safe.t, string) result

val destroy
  :  target:Sol_cli_config.target
  -> service:string
  -> record:string
  -> (unit, string) result
