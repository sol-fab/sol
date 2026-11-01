open Result.Syntax

let ensure_serverless = Sol_cli_serverless_target_common.ensure_serverless

let deploy
      ~target
      ~config
      ~project
      ~service
      ~image
      ~record
      ~runtime_service_account
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
  =
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
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_serverless_target.deploy
      ~target
      ~config
      ~project
      ~service
      ~image
      ~record
      ~runtime_service_account
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
  | Sol_cli_provider.Byo ->
    Error "target-scoped serverless dispatch currently supports AWS and GCP only"
;;

let scheduler_resource_name ~(target : Sol_cli_config.target) service_name =
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_lambda.provider_service_of service_name
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  | Sol_cli_provider.Gcp ->
    Sol_cli_cloud_run.provider_service_of service_name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  | Sol_cli_provider.Byo -> Error "serverless targets support AWS and GCP only"
;;

let complete_units
      ~(config : Sol_cli_config.t)
      ~project
      ~(target : Sol_cli_config.target)
      ~model
      ~exclude
      ~serverless_all
  =
  let open Result.Syntax in
  let unsupported workload =
    Error
      (Printf.sprintf
         "serverless function %S has no readable sol.toml, so the complete target \
          authorization model cannot be constructed"
         workload.Sol_cli_workspace_model.service.name)
  in
  let* units =
    Sol_cli_workspace_model.workloads model
    |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
      match workload.service.primitive, workload.config with
      | (Sol_cli_manifest.Fn | Svc | Worker), Ok toml
        when serverless_all || workload.service.primitive = Sol_cli_manifest.Fn ->
        if Some workload.service.name = exclude
        then Ok None
        else (
          match
            Sol_cli_resource_binding.external_requirements
              ~config
              ~service_name:workload.service.name
          with
          | Error message -> Error message
          | Ok external_requirements ->
            let function_result =
              if Option.is_some toml.schedule
              then
                scheduler_resource_name ~target workload.service.name
                |> Result.map Option.some
              else Ok None
            in
            (match function_result with
             | Error message -> Error message
             | Ok function_name ->
               let unit =
                 Sol_cli_serverless_target_common.unit_of_service
                   ~project
                   workload.service
               in
               let requirements =
                 (toml.secret_keys |> List.map Sol_cli_grant.secret_requirement)
                 @ external_requirements
               in
               Ok
                 (Some
                    ( { Sol_cli_grant.unit; requirements }
                    , Option.map
                        (fun function_name -> { Sol_cli_grant.unit; function_name })
                        function_name ))))
      | (Sol_cli_manifest.Fn | Svc | Worker), Error _ -> unsupported workload
      | _ -> Ok None)
    |> Result.map (List.filter_map Fun.id)
  in
  let serverless = List.map fst units in
  let scheduler = List.filter_map snd units in
  Ok (serverless, scheduler)
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
