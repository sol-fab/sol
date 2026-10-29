open Result.Syntax

let ensure_serverless = Sol_cli_serverless_target_common.ensure_serverless

let deploy ~target ~config ~project ~service ~image ~record =
  let* () = ensure_serverless target in
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_serverless_target.deploy ~target ~config ~project ~service ~image ~record
  | Sol_cli_provider.Gcp ->
    let* release =
      Sol_cli_gcp_serverless_target.deploy
        ~target
        ~config
        ~project
        ~service
        ~image
        ~record
    in
    Ok (Sol_cli_cloud_run.release_json release)
  | Sol_cli_provider.Byo ->
    Error "target-scoped serverless dispatch currently supports AWS and GCP only"
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
    let* observed =
      Sol_cli_gcp_serverless_target.rollback
        ~target
        ~project
        ~service
        ~record
        ~revision
        ~token
    in
    Ok (Sol_cli_cloud_run.observed_json observed)
  | Sol_cli_provider.Byo -> Error "serverless rollback supports AWS and GCP targets only"
;;

let destroy ~target ~service ~record =
  let* () = ensure_serverless target in
  match target.provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_serverless_target.destroy ~target ~service ~record
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_serverless_target.destroy ~target ~service ~record
  | Sol_cli_provider.Byo -> Error "serverless destroy supports AWS and GCP targets only"
;;
