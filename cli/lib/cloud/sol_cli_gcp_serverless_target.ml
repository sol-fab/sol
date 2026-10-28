open Result.Syntax

let required_project target =
  match Sol_cli_config.provider_field target "project_id" with
  | Some project when String.trim project <> "" -> Ok project
  | _ -> Error "target must declare gcp.project_id for serverless execution"
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
    if target.provider = Sol_cli_provider.Gcp
    then Ok ()
    else Error "target-scoped serverless dispatch expected a GCP target"
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
  let* cloud_project = required_project target in
  let* provider_service =
    Sol_cli_cloud_run.provider_service_of service.name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let identity =
    { Sol_cli_cloud_run.unit = unit_of_service ~project service
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
    { Sol_cli_cloud_run.project = cloud_project
    ; region = target.region
    ; service = service.name
    ; provider_service
    ; image
    ; identity
    ; ingress = Sol_cli_cloud_run.Public
    ; record = Some record
    }
  in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          Sol_cli_serverless_runner.run argv
          |> Result.map (fun (o : Sol_cli_serverless_runner.output) ->
            ({ Sol_cli_cloud_run.stdout = o.stdout; stderr = o.stderr }
             : Sol_cli_cloud_run.output)))
    ; http =
        (fun ~url ~token ->
          Sol_cli_serverless_runner.http ~url ~token
          |> Result.map (fun (status, body) -> status, body))
    }
  in
  let* release =
    Sol_cli_cloud_run.deploy runner request
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let url =
    let rec trim value =
      if String.length value > 0 && value.[String.length value - 1] = '/'
      then trim (String.sub value 0 (String.length value - 1))
      else value
    in
    trim release.url
  in
  let* ready, _ =
    runner.http ~url:(url ^ "/readyz") ~token:None
    |> Result.map_error (fun message ->
      "post-deploy readiness request failed: " ^ message)
  in
  let* () =
    if ready = 200 then Ok () else Error (Printf.sprintf "post-deploy readiness %d" ready)
  in
  let* unauth, _ =
    runner.http ~url:(url ^ "/quote") ~token:None
    |> Result.map_error (fun message ->
      "post-deploy unauthenticated request failed: " ^ message)
  in
  let* () =
    if unauth = 401
    then Ok ()
    else Error (Printf.sprintf "post-deploy unauthenticated /quote %d" unauth)
  in
  let* () =
    Sol_cli_cloud_run.write_record ~path:record release
    |> Result.map_error (fun message -> "could not write release record: " ^ message)
  in
  Ok release
;;

let rollback
      ~target
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~revision
      ~token
  =
  let* () =
    if Sol_cli_config.execution_of_target target = Sol_cli_config.Serverless
    then Ok ()
    else Error "target does not select execution: serverless"
  in
  let* () =
    if target.provider = Sol_cli_provider.Gcp
    then Ok ()
    else Error "target-scoped serverless rollback expected a GCP target"
  in
  let* release = Sol_cli_cloud_run.read_record ~path:record in
  let* cloud_project = required_project target in
  let* provider_service =
    Sol_cli_cloud_run.provider_service_of service.name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let request =
    { Sol_cli_cloud_run.project = cloud_project
    ; region = target.region
    ; service = service.name
    ; provider_service
    ; image = release.image
    ; identity =
        { Sol_cli_cloud_run.unit = unit_of_service ~project service
        ; callers = callers target
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; ingress = Sol_cli_cloud_run.Public
    ; record = None
    }
  in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          Sol_cli_serverless_runner.run argv
          |> Result.map (fun (o : Sol_cli_serverless_runner.output) ->
            ({ Sol_cli_cloud_run.stdout = o.stdout; stderr = o.stderr }
             : Sol_cli_cloud_run.output)))
    ; http =
        (fun ~url ~token ->
          Sol_cli_serverless_runner.http ~url ~token
          |> Result.map (fun (status, body) -> status, body))
    }
  in
  let* observed =
    Sol_cli_cloud_run.rollback runner request ~revision ~token
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let recorded =
    { release with
      revision = observed.revision
    ; url = observed.url
    ; image = Option.value observed.image ~default:release.image
    }
  in
  let* () =
    Sol_cli_cloud_run.write_record ~path:record recorded
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  Ok observed
;;
