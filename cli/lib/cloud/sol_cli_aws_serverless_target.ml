open Result.Syntax

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

let ensure_aws (target : Sol_cli_config.target) =
  if target.provider = Sol_cli_provider.Aws
  then Ok ()
  else Error "target-scoped serverless dispatch currently supports AWS Lambda only"
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
      ~runtime_service_account
  =
  let* () = Sol_cli_serverless_target_common.declared_uses config service in
  let* () = Sol_cli_serverless_target_common.require_http_callers target in
  let* role_arn =
    Option.to_result
      ~none:"AWS serverless deploy requires a provisioned per-unit execution role"
      runtime_service_account
  in
  let* () =
    if String.trim role_arn = ""
    then Error "AWS serverless execution role is empty"
    else Ok ()
  in
  let* function_name = provider_name service in
  let identity =
    { Sol_cli_aws_lambda.unit =
        Sol_cli_serverless_target_common.unit_of_service ~project service
    ; callers = Sol_cli_serverless_target_common.callers target
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
      ~runtime_service_account
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
  =
  let* () = Sol_cli_serverless_target_common.declared_uses config service in
  let* role_arn =
    Option.to_result
      ~none:"AWS serverless deploy requires a provisioned per-unit execution role"
      runtime_service_account
  in
  let* () =
    if String.trim role_arn = ""
    then Error "AWS serverless execution role is empty"
    else Ok ()
  in
  (* There is deliberately no serverless_callers requirement here: a run-once function
     has no incoming HTTP request, and triggers/incoming identity are a separate
     contract. *)
  let* function_name = provider_name service in
  let* external_env =
    Sol_cli_resource_binding.external_connection ~config ~service_name:service.name
    |> Result.map_error (fun message -> message)
  in
  let request =
    { Sol_cli_aws_lambda_fn.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image
    ; role_arn
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; schedule
    ; timezone = schedule_timezone
    ; scheduler_role_arn = scheduler_identity
    ; external_env
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

let deploy_fn_http
      ~(target : Sol_cli_config.target)
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
      ~(trigger : Sol_cli_toml.http_trigger)
  =
  let* () = Sol_cli_serverless_target_common.declared_uses config service in
  let* () =
    match trigger.exposure with
    | Sol_cli_toml.Http_public -> Ok ()
    | Sol_cli_toml.Http_internal ->
      Error
        "AWS HTTP functions support public exposure only: a Lambda Function URL is \
         reachable from the public internet, so Sol will not create an endpoint it would \
         have to describe as internal. Use a Kubernetes or GCP target for an internal \
         HTTP function."
  in
  let* role_arn =
    Option.to_result
      ~none:"AWS serverless deploy requires a provisioned per-unit execution role"
      runtime_service_account
  in
  let* () =
    if String.trim role_arn = ""
    then Error "AWS serverless execution role is empty"
    else Ok ()
  in
  let* function_name = provider_name service in
  let request =
    { Sol_cli_aws_fn_http.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image
    ; role_arn
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; http_path = trigger.path
    ; record = Some record
    ; run = runner
    }
  in
  let* release =
    Sol_cli_aws_fn_http.deploy request
    |> Result.map_error Sol_cli_aws_fn_http.failure_to_string
  in
  Ok (Sol_cli_aws_fn_http.release_json release)
;;

let deploy
      ~(target : Sol_cli_config.target)
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
      ~http
  =
  let* () = ensure_aws target in
  match service.primitive with
  | Sol_cli_manifest.Svc ->
    (match http with
     | Some _ -> Error "http_path is only valid on a -fn; a -svc owns its HTTP contract"
     | None ->
       deploy_svc
         ~target
         ~config
         ~project
         ~service
         ~image
         ~record
         ~runtime_service_account)
  | Sol_cli_manifest.Fn ->
    (match http with
     | Some http ->
       deploy_fn_http
         ~target
         ~config
         ~project
         ~service
         ~image
         ~record
         ~runtime_service_account
         ~trigger:http
     | None ->
       deploy_fn
         ~target
         ~config
         ~project
         ~service
         ~image
         ~record
         ~runtime_service_account
         ~schedule
         ~schedule_timezone
         ~scheduler_identity)
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
        { Sol_cli_aws_lambda.unit =
            Sol_cli_serverless_target_common.unit_of_service ~project service
        ; callers = Sol_cli_serverless_target_common.callers target
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
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; schedule = None
    ; timezone = None
    ; scheduler_role_arn = None
    ; external_env = []
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

let rollback_fn_http
      ~(target : Sol_cli_config.target)
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
  =
  let* release = Sol_cli_aws_fn_http.read_record ~path:record in
  let* function_name = provider_name service in
  let* () =
    check_record
      ~region:target.region
      ~service:service.name
      ~function_name
      (release.region, release.service, release.function_name)
  in
  let request =
    { Sol_cli_aws_fn_http.profile = Sol_cli_config.provider_field target "profile"
    ; region = target.region
    ; service = service.name
    ; function_name
    ; image = release.image
    ; role_arn = release.role_arn
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; http_path = release.http_path
    ; record = None
    ; run = runner
    }
  in
  let write_record release =
    Sol_cli_aws_fn_http.write_record ~path:record release
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  let on_alias_moved version = write_record { release with version; alias = "live" } in
  let* observed =
    Sol_cli_aws_fn_http.rollback request ~version ~on_alias_moved
    |> Result.map_error Sol_cli_aws_fn_http.failure_to_string
  in
  let recorded = { observed with image = release.image; role_arn = release.role_arn } in
  let* () = write_record recorded in
  Ok (Sol_cli_aws_fn_http.release_json observed)
;;

let rollback
      ~(target : Sol_cli_config.target)
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~version
      ~token
  =
  let* () = ensure_aws target in
  let* kind =
    Sol_cli_aws_lambda_common.record_kind ~path:record
    |> Result.map_error (fun message -> "could not read release record: " ^ message)
  in
  match kind with
  | Some "svc" -> rollback_svc ~target ~project ~service ~record ~version ~token
  | Some "fn" -> rollback_fn ~target ~project ~service ~record ~version
  | Some "fn_http" -> rollback_fn_http ~target ~project ~service ~record ~version
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
      ; schedule = None
      ; timezone = None
      ; scheduler_role_arn = None
      ; external_env = []
      ; record = None
      ; run = runner
      }
    in
    Sol_cli_aws_lambda_fn.destroy request ~profile ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_aws_lambda_fn.failure_to_string
  | Some "fn_http" ->
    let request =
      { Sol_cli_aws_fn_http.profile
      ; region = target.region
      ; service
      ; function_name = ""
      ; image = ""
      ; role_arn = ""
      ; unit = ""
      ; http_path = ""
      ; record = None
      ; run = runner
      }
    in
    Sol_cli_aws_fn_http.destroy ~r:request ~profile ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_aws_fn_http.failure_to_string
  | Some other ->
    Error
      (Printf.sprintf
         "release record kind %S is not an AWS Lambda lifecycle this target can destroy"
         other)
  | None ->
    Error
      "release record has no kind; refusing to infer which Lambda lifecycle produced it"
;;
