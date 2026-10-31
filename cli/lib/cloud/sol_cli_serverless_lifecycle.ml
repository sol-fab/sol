open Result.Syntax

let ensure_serverless = Sol_cli_serverless_target_common.ensure_serverless

let deploy ~target ~config ~project ~service ~image ~record ~runtime_service_account =
  let* () = ensure_serverless target in
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_serverless_target.deploy
      ~target
      ~config
      ~project
      ~service
      ~image
      ~record
      ~runtime_service_account
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_serverless_target.deploy
      ~target
      ~config
      ~project
      ~service
      ~image
      ~record
      ~runtime_service_account
  | Sol_cli_provider.Byo ->
    Error "target-scoped serverless dispatch currently supports AWS and GCP only"
;;

let ensure_runtime_identities ~assets ~run_log ~(target : Sol_cli_config.target) ~units =
  match target.provider with
  | Sol_cli_provider.Gcp | Sol_cli_provider.Aws ->
    Sol_cli_authorization_stage.apply_serverless_identities ~assets ~run_log ~target units
  | Sol_cli_provider.Byo -> Error "serverless targets support AWS and GCP only"
;;

let ensure_runtime_identity ~assets ~run_log ~target ~unit ~requirements =
  let* identities =
    ensure_runtime_identities
      ~assets
      ~run_log
      ~target
      ~units:[ { Sol_cli_grant.unit; requirements } ]
  in
  match List.assoc_opt unit identities with
  | Some identity when String.trim identity <> "" -> Ok (Some identity)
  | _ ->
    Error
      (Printf.sprintf
         "the authorization root established no runtime identity for %s"
         unit)
;;

let ensure_scheduler_identities ~assets ~run_log ~(target : Sol_cli_config.target) ~units =
  match target.provider with
  | Sol_cli_provider.Gcp | Sol_cli_provider.Aws ->
    Sol_cli_authorization_stage.apply_scheduler_identities ~assets ~run_log ~target units
  | Sol_cli_provider.Byo -> Error "serverless targets support AWS and GCP only"
;;

let rollback ~target ~project ~service ~record ~version ~revision ~token =
  let* () = ensure_serverless target in
  match target.provider with
  | Sol_cli_provider.Aws ->
    let* version = Option.to_result ~none:"--to-version is required for AWS" version in
    Sol_cli_aws_serverless_target.rollback
      ~target
      ~project
      ~service
      ~record
      ~version
      ~token
  | Sol_cli_provider.Gcp ->
    let* revision = Option.to_result ~none:"--to-revision is required for GCP" revision in
    Sol_cli_gcp_serverless_target.rollback
      ~target
      ~project
      ~service
      ~record
      ~revision
      ~token
  | Sol_cli_provider.Byo -> Error "serverless rollback supports AWS and GCP targets only"
;;

let destroy ~target ~service ~record =
  let* () = ensure_serverless target in
  match target.provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_serverless_target.destroy ~target ~service ~record
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_serverless_target.destroy ~target ~service ~record
  | Sol_cli_provider.Byo -> Error "serverless destroy supports AWS and GCP targets only"
;;
