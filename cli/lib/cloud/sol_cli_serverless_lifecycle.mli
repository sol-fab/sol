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

val ensure_runtime_identities
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> units:Sol_cli_grant.serverless_unit list
  -> ((string * string) list, string) result

val ensure_runtime_identity
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> unit:string
  -> requirements:Sol_cli_grant.requirement list
  -> (string option, string) result

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

val ensure_scheduler_identities
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> units:Sol_cli_grant.scheduler_unit list
  -> ((string * string) list, string) result

val scheduler_resource_name
  :  target:Sol_cli_config.target
  -> string
  -> (string, string) result
