(** The one serverless lifecycle dispatch boundary.

    Commands resolve the target, service, image, record, and caller token; they do not
    choose a provider adapter or decide which rollback input a provider accepts. This
    module makes that choice once and hands the operation to the provider adapter, which
    keeps provider-native identity, primitive support, and lifecycle mechanics.

    Provider adapters share one serving-mutation contract: once provider observation
    establishes that a version or revision is serving, they record that identity before
    the execution smoke, and they reconcile a mutation whose CLI call reported an error by
    observing whether the requested state is actually serving. A reconciled mutation keeps
    the provider error as a warning; an unreadable provider state is never treated as
    success. *)

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

val complete_units
  :  config:Sol_cli_config.t
  -> project:string
  -> target:Sol_cli_config.target
  -> model:Sol_cli_workspace_model.t
  -> exclude:string option
  -> ( Sol_cli_grant.serverless_unit list * Sol_cli_grant.scheduler_unit list
       , string )
       result

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

val scheduler_resource_name
  :  target:Sol_cli_config.target
  -> string
  -> (string, string) result
