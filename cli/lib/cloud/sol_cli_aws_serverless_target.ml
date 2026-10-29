open Result.Syntax

let required_field (target : Sol_cli_config.target) name =
  match Sol_cli_config.provider_field target name with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "target must declare aws.%s for serverless execution" name)
;;

let callers (target : Sol_cli_config.target) =
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

let runner argv =
  Sol_cli_serverless_runner.run argv
  |> Result.map (fun (o : Sol_cli_serverless_runner.output) ->
    ({ Sol_cli_aws_lambda_common.stdout = o.stdout; stderr = o.stderr }
     : Sol_cli_aws_lambda_common.output))
;;

let http ~url ~token =
  Sol_cli_serverless_runner.http ~url ~token
  |> Result.map (fun (status, body) -> status, body)
;;

let provider_name (service : Sol_cli_manifest.service) =
  Sol_cli_aws_lambda.provider_service_of service.name
  |> Result.map_error Sol_cli_aws_lambda.failure_to_string
;;

let ensure_serverless (target : Sol_cli_config.target) =
  if Sol_cli_config.execution_of_target target = Sol_cli_config.Serverless
  then Ok ()
  else Error "target does not select execution: serverless"
;;

let ensure_aws (target : Sol_cli_config.target) =
  if target.provider = Sol_cli_provider.Aws
  then Ok ()
  else Error "target-scoped serverless dispatch currently supports AWS Lambda only"
;;

let declared_uses config (service : Sol_cli_manifest.service) =
  let* declared =
    Sol_cli_config.services config
    |> List.find_opt (fun (s : Sol_cli_config.service) -> s.name = service.name)
    |> Option.to_result ~none:"service is not declared in sol.yml"
  in
  if declared.uses = []
  then Ok ()
  else Error "target-scoped serverless dispatch does not yet support service dependencies"
;;

let check_record
      ~region
      ~service
      ~function_name
      (release_region, release_service, release_function_name)
  =
  if
    release_region = region
    && release_service = service
    && release_function_name = function_name
  then Ok ()
  else
    Error
      "release record does not match the target region, service, and provider function \
       name"
;;

let deploy_svc
      ~(target : Sol_cli_config.target)
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
  =
  let* () = declared_uses config service in
  let* () =
    if callers target = []
    then
      Error
        "target must declare serverless_callers for incoming application authentication"
    else Ok ()
  in
  let* role_arn = required_field target "lambda_role_arn" in
  let* function_name = provider_name service in
  let identity =
    { Sol_cli_aws_lambda.unit = unit_of_service ~project service
    ; callers = callers target
    ; issuer = "https://accounts.google.com"
    ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    }
  in
  let request =
    { Sol_cli_aws_lambda.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image
    ; role_arn
    ; identity
    ; record = Some record
    ; run = runner
    ; http
    }
  in
  let* release =
    Sol_cli_aws_lambda.deploy request
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
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
    http ~url:(url ^ "/readyz") ~token:None
    |> Result.map_error (fun message ->
      "post-deploy readiness request failed: " ^ message)
  in
  let* () =
    if ready = 200 then Ok () else Error (Printf.sprintf "post-deploy readiness %d" ready)
  in
  let* unauth, _ =
    http ~url:(url ^ "/quote") ~token:None
    |> Result.map_error (fun message ->
      "post-deploy unauthenticated request failed: " ^ message)
  in
  let* () =
    if unauth = 401
    then Ok ()
    else Error (Printf.sprintf "post-deploy unauthenticated /quote %d" unauth)
  in
  Ok (Sol_cli_aws_lambda.release_json release)
;;

let deploy_fn
      ~(target : Sol_cli_config.target)
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
  =
  let* () = declared_uses config service in
  (* There is deliberately no serverless_callers requirement here: a run-once function
     has no incoming HTTP request, and triggers/incoming identity are a separate
     contract. *)
  let* role_arn = required_field target "lambda_role_arn" in
  let* function_name = provider_name service in
  let request =
    { Sol_cli_aws_lambda_fn.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image
    ; role_arn
    ; unit = unit_of_service ~project service
    ; record = Some record
    ; run = runner
    }
  in
  let* release =
    Sol_cli_aws_lambda_fn.deploy request
    |> Result.map_error Sol_cli_aws_lambda_fn.failure_to_string
  in
  Ok (Sol_cli_aws_lambda_fn.release_json release)
;;

let deploy
      ~(target : Sol_cli_config.target)
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
  =
  let* () = ensure_serverless target in
  let* () = ensure_aws target in
  match service.primitive with
  | Sol_cli_manifest.Svc -> deploy_svc ~target ~config ~project ~service ~image ~record
  | Sol_cli_manifest.Fn -> deploy_fn ~target ~config ~project ~service ~image ~record
  | Sol_cli_manifest.Worker ->
    Error
      "target-scoped serverless dispatch does not support -worker: worker delivery needs \
       explicit provider queue semantics"
;;

let rollback_svc
      ~(target : Sol_cli_config.target)
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
      ~token
  =
  let* release = Sol_cli_aws_lambda.read_record ~path:record in
  let* function_name = provider_name service in
  let* () =
    check_record
      ~region:target.region
      ~service:service.name
      ~function_name
      (release.region, release.service, release.function_name)
  in
  let request =
    { Sol_cli_aws_lambda.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image = release.image
    ; role_arn = release.role_arn
    ; identity =
        { Sol_cli_aws_lambda.unit = unit_of_service ~project service
        ; callers = callers target
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; record = None
    ; run = runner
    ; http
    }
  in
  let write_record release =
    Sol_cli_aws_lambda.write_record ~path:record release
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  (* If the alias move succeeds but the smoke fails, the record must name what is
     actually live. Write it at the alias move, then refine it from the verified state. *)
  let on_alias_moved version = write_record { release with version; alias = "live" } in
  let* observed =
    Sol_cli_aws_lambda.rollback request ~version ~token ~on_alias_moved
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  in
  let recorded =
    { release with version = observed.version; alias = "live"; url = observed.url }
  in
  let* () = write_record recorded in
  Ok (Sol_cli_aws_lambda.observed_json observed)
;;

let rollback_fn
      ~(target : Sol_cli_config.target)
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
  =
  let* release = Sol_cli_aws_lambda_fn.read_record ~path:record in
  let* function_name = provider_name service in
  let* () =
    check_record
      ~region:target.region
      ~service:service.name
      ~function_name
      (release.region, release.service, release.function_name)
  in
  let request =
    { Sol_cli_aws_lambda_fn.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image = release.image
    ; role_arn = release.role_arn
    ; unit = unit_of_service ~project service
    ; record = None
    ; run = runner
    }
  in
  let write_record release =
    Sol_cli_aws_lambda_fn.write_record ~path:record release
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  let on_alias_moved version = write_record { release with version; alias = "live" } in
  let* observed =
    Sol_cli_aws_lambda_fn.rollback request ~version ~on_alias_moved
    |> Result.map_error Sol_cli_aws_lambda_fn.failure_to_string
  in
  let recorded = { release with version = observed.version; alias = "live" } in
  let* () = write_record recorded in
  Ok (Sol_cli_aws_lambda_fn.observed_json observed)
;;

let rollback
      ~(target : Sol_cli_config.target)
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
      ~token
  =
  let* () = ensure_serverless target in
  let* () = ensure_aws target in
  let* kind =
    Sol_cli_aws_lambda_common.record_kind ~path:record
    |> Result.map_error (fun message -> "could not read release record: " ^ message)
  in
  match kind with
  | Some "svc" -> rollback_svc ~target ~project ~service ~record ~version ~token
  | Some "fn" -> rollback_fn ~target ~project ~service ~record ~version
  | Some other ->
    Error
      (Printf.sprintf
         "release record kind %S is not an AWS Lambda lifecycle this target can roll back"
         other)
  | None ->
    Error
      "release record has no kind; refusing to infer which Lambda lifecycle produced it"
;;

let destroy ~(target : Sol_cli_config.target) ~service ~record =
  let* () = ensure_serverless target in
  let* () = ensure_aws target in
  let* kind =
    Sol_cli_aws_lambda_common.record_kind ~path:record
    |> Result.map_error (fun message -> "could not read release record: " ^ message)
  in
  let profile = Sol_cli_config.provider_field target "profile" in
  match kind with
  | Some "svc" ->
    let request =
      { Sol_cli_aws_lambda.profile
      ; region = target.region
      ; service
      ; function_name = ""
      ; image = ""
      ; role_arn = ""
      ; identity = { unit = ""; callers = []; issuer = ""; jwks_uri = "" }
      ; record = None
      ; run = runner
      ; http
      }
    in
    Sol_cli_aws_lambda.destroy request ~profile ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_aws_lambda.failure_to_string
  | Some "fn" ->
    let request =
      { Sol_cli_aws_lambda_fn.profile
      ; region = target.region
      ; service
      ; function_name = ""
      ; image = ""
      ; role_arn = ""
      ; unit = ""
      ; record = None
      ; run = runner
      }
    in
    Sol_cli_aws_lambda_fn.destroy request ~profile ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_aws_lambda_fn.failure_to_string
  | Some other ->
    Error
      (Printf.sprintf
         "release record kind %S is not an AWS Lambda lifecycle this target can destroy"
         other)
  | None ->
    Error
      "release record has no kind; refusing to infer which Lambda lifecycle produced it"
;;
