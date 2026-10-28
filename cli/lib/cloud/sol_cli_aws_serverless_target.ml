open Result.Syntax

let required_field target name =
  match Sol_cli_config.provider_field target name with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "target must declare aws.%s for serverless execution" name)
;;

let callers target =
  match Sol_cli_config.provider_field target "serverless_callers" with
  | None | Some "" -> []
  | Some text ->
    String.split_on_char ',' text
    |> List.filter_map (fun entry ->
      match String.index_opt entry '=' with
      | None -> None
      | Some at ->
        let unit = String.sub entry 0 at |> String.trim in
        let subject =
          String.sub entry (at + 1) (String.length entry - at - 1) |> String.trim
        in
        if unit = "" || subject = "" then None else Some (subject, unit))
;;

let unit_of_service ~project (service : Sol_cli_manifest.service) =
  match String.split_on_char '/' service.dir |> List.rev with
  | name :: domain :: _ when name = service.name && domain <> "" && domain <> "." ->
    domain ^ "/" ^ service.name
  | _ -> project ^ "/" ^ service.name
;;

let deploy ~target ~config ~project ~(service : Sol_cli_manifest.service) ~image ~record =
  let* () =
    if Sol_cli_config.execution_of_target target = Sol_cli_config.Serverless
    then Ok ()
    else Error "target does not select execution: serverless"
  in
  let* () =
    if target.provider = Sol_cli_provider.Aws
    then Ok ()
    else Error "target-scoped serverless dispatch currently supports AWS Lambda only"
  in
  let* () =
    match service.primitive with
    | Sol_cli_manifest.Svc -> Ok ()
    | _ -> Error "target-scoped serverless dispatch currently supports one HTTP service"
  in
  let* declared =
    Sol_cli_config.services config
    |> List.find_opt (fun (s : Sol_cli_config.service) -> s.name = service.name)
    |> Option.to_result ~none:"service is not declared in sol.yml"
  in
  let* () =
    if declared.uses = []
    then Ok ()
    else
      Error "target-scoped serverless dispatch does not yet support service dependencies"
  in
  let* () =
    if callers target = []
    then
      Error
        "target must declare serverless_callers for incoming application authentication"
    else Ok ()
  in
  let* role_arn = required_field target "lambda_role_arn" in
  let* function_name =
    Sol_cli_aws_lambda.provider_service_of service.name
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  in
  let profile = Sol_cli_config.provider_field target "profile" in
  let identity =
    { Sol_cli_aws_lambda.unit = unit_of_service ~project service
    ; callers = callers target
    ; issuer = "https://accounts.google.com"
    ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    }
  in
  let* () =
    if callers target = []
    then
      Error
        "target must declare serverless_callers for incoming application authentication"
    else Ok ()
  in
  let request =
    { Sol_cli_aws_lambda.profile
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image
    ; role_arn
    ; identity
    ; record = Some record
    ; run =
        (fun argv ->
          Sol_cli_serverless_runner.run argv
          |> Result.map (fun (o : Sol_cli_serverless_runner.output) ->
            ({ Sol_cli_aws_lambda.stdout = o.stdout; stderr = o.stderr }
             : Sol_cli_aws_lambda.output)))
    ; http =
        (fun ~url ~token ->
          Sol_cli_serverless_runner.http ~url ~token
          |> Result.map (fun (status, body) -> status, body))
    }
  in
  Sol_cli_aws_lambda.deploy request
  |> Result.map_error Sol_cli_aws_lambda.failure_to_string
;;

let rollback
      ~target
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
      ~token
  =
  let* () =
    if Sol_cli_config.execution_of_target target = Sol_cli_config.Serverless
    then Ok ()
    else Error "target does not select execution: serverless"
  in
  let* () =
    if target.provider = Sol_cli_provider.Aws
    then Ok ()
    else Error "target-scoped serverless rollback expected an AWS target"
  in
  let* release = Sol_cli_aws_lambda.read_record ~path:record in
  let* role_arn = required_field target "lambda_role_arn" in
  let* function_name =
    Sol_cli_aws_lambda.provider_service_of service.name
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  in
  let request =
    { Sol_cli_aws_lambda.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image = release.image
    ; role_arn
    ; identity =
        { Sol_cli_aws_lambda.unit = unit_of_service ~project service
        ; callers = callers target
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; record = None
    ; run =
        (fun argv ->
          Sol_cli_serverless_runner.run argv
          |> Result.map (fun (o : Sol_cli_serverless_runner.output) ->
            ({ Sol_cli_aws_lambda.stdout = o.stdout; stderr = o.stderr }
             : Sol_cli_aws_lambda.output)))
    ; http =
        (fun ~url ~token ->
          Sol_cli_serverless_runner.http ~url ~token
          |> Result.map (fun (status, body) -> status, body))
    }
  in
  let* observed =
    Sol_cli_aws_lambda.rollback request ~version ~token
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  in
  let recorded =
    { release with version = observed.version; alias = "live"; url = observed.url }
  in
  let* () =
    Sol_cli_aws_lambda.write_record ~path:record recorded
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  Ok observed
;;
