open Result.Syntax

let ensure_gcp (target : Sol_cli_config.target) =
  if target.provider = Sol_cli_provider.Gcp
  then Ok ()
  else Error "target-scoped serverless dispatch expected a GCP target"
;;

let runner () =
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
;;

let deploy_svc
      ~target
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
  =
  let* () = ensure_gcp target in
  let* service_account =
    Option.to_result
      ~none:"GCP serverless deploy requires a provisioned per-unit runtime identity"
      runtime_service_account
  in
  let* () =
    if String.trim service_account = ""
    then Error "GCP serverless runtime identity is empty"
    else Ok ()
  in
  let* () = Sol_cli_serverless_target_common.declared_uses config service in
  let* () = Sol_cli_serverless_target_common.require_http_callers target in
  let* cloud_project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
  let* provider_service =
    Sol_cli_cloud_run.provider_service_of service.name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let identity =
    { Sol_cli_cloud_run.unit =
        Sol_cli_serverless_target_common.unit_of_service ~project service
    ; callers = Sol_cli_serverless_target_common.callers target
    ; issuer = "https://accounts.google.com"
    ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    }
  in
  let request =
    { Sol_cli_cloud_run.project = cloud_project
    ; region = target.region
    ; service = service.name
    ; provider_service
    ; image
    ; identity
    ; ingress = Sol_cli_cloud_run.Public
    ; service_account
    ; record = Some record
    }
  in
  let runner = runner () in
  let* release =
    Sol_cli_cloud_run.deploy runner request
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  (* Write the ownership record before the target's execution smoke. A deploy that moved
     traffic but failed its postcondition must still leave a destroyable record. *)
  let* () =
    Sol_cli_cloud_run.write_record ~path:record release
    |> Result.map_error (fun message -> "could not write release record: " ^ message)
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
  Ok (Sol_cli_cloud_run.release_json release)
;;

let deploy_fn
      ~target
      ~config
      ~project:_project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
  =
  let* () = ensure_gcp target in
  let* service_account =
    Option.to_result
      ~none:"GCP serverless deploy requires a provisioned per-unit runtime identity"
      runtime_service_account
  in
  let* () =
    if String.trim service_account = ""
    then Error "GCP serverless runtime identity is empty"
    else Ok ()
  in
  let* () = Sol_cli_serverless_target_common.declared_uses config service in
  let* cloud_project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
  let* job =
    Sol_cli_cloud_run.provider_service_of service.name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let request : Sol_cli_gcp_serverless_job.request =
    { project = cloud_project
    ; region = target.region
    ; service = service.name
    ; job
    ; image
    ; service_account
    ; record
    ; runner = runner ()
    }
  in
  let* release =
    Sol_cli_gcp_serverless_job.deploy request
    |> Result.map_error Sol_cli_gcp_serverless_job.failure_to_string
  in
  Ok (Sol_cli_gcp_serverless_job.release_json release)
;;

let deploy
      ~target
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
  =
  let* () = ensure_gcp target in
  match service.primitive with
  | Sol_cli_manifest.Svc ->
    deploy_svc ~target ~config ~project ~service ~image ~record ~runtime_service_account
  | Sol_cli_manifest.Fn ->
    deploy_fn ~target ~config ~project ~service ~image ~record ~runtime_service_account
  | Sol_cli_manifest.Worker ->
    Error "target-scoped serverless dispatch does not support -worker on GCP"
;;

let rollback_svc
      ~target
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~revision
      ~token
  =
  let* () = ensure_gcp target in
  let* release = Sol_cli_cloud_run.read_record ~path:record in
  let* cloud_project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
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
    ; service_account = release.service_account
    ; identity =
        { Sol_cli_cloud_run.unit =
            Sol_cli_serverless_target_common.unit_of_service ~project service
        ; callers = Sol_cli_serverless_target_common.callers target
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; ingress = Sol_cli_cloud_run.Public
    ; record = None
    }
  in
  let write_record release =
    Sol_cli_cloud_run.write_record ~path:record release
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  (* If traffic moves but the smoke fails, the record must name what is actually serving.
     Write it at the traffic move, then refine it from the verified state. *)
  let on_revision_moved revision = write_record { release with revision } in
  let* observed =
    Sol_cli_cloud_run.rollback (runner ()) request ~revision ~token ~on_revision_moved
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let recorded =
    { release with
      revision = observed.revision
    ; url = observed.url
    ; image = Option.value observed.image ~default:release.image
    }
  in
  let* () = write_record recorded in
  Ok (Sol_cli_cloud_run.observed_json observed)
;;

let rollback_fn
      ~target
      ~project:_project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~execution
  =
  let* () = ensure_gcp target in
  let* recorded = Sol_cli_gcp_serverless_job.read_record record in
  let* cloud_project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
  let* job =
    Sol_cli_cloud_run.provider_service_of service.name
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let request : Sol_cli_gcp_serverless_job.request =
    { project = cloud_project
    ; region = target.region
    ; service = service.name
    ; job
    ; image = ""
    ; service_account = Sol_cli_gcp_serverless_job.runtime_service_account recorded
    ; record
    ; runner = runner ()
    }
  in
  let* release =
    Sol_cli_gcp_serverless_job.rollback request ~record ~execution
    |> Result.map_error Sol_cli_gcp_serverless_job.failure_to_string
  in
  Ok (Sol_cli_gcp_serverless_job.release_json release)
;;

let rollback
      ~target
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~revision
      ~token
  =
  let* () = ensure_gcp target in
  match service.primitive with
  | Sol_cli_manifest.Svc ->
    rollback_svc ~target ~project ~service ~record ~revision ~token
  | Sol_cli_manifest.Fn ->
    rollback_fn ~target ~project ~service ~record ~execution:revision
  | Sol_cli_manifest.Worker ->
    Error "target-scoped serverless dispatch does not support -worker on GCP"
;;

let destroy ~target ~service ~record =
  let* () = ensure_gcp target in
  let* project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
  match Sol_cli_gcp_serverless_job.read_record record with
  | Ok _ ->
    let* job =
      Sol_cli_cloud_run.provider_service_of service
      |> Result.map_error Sol_cli_cloud_run.failure_to_string
    in
    let request : Sol_cli_gcp_serverless_job.request =
      { project
      ; region = target.region
      ; service
      ; job
      ; image = ""
      ; service_account = ""
      ; record
      ; runner = runner ()
      }
    in
    Sol_cli_gcp_serverless_job.destroy request ~record
    |> Result.map_error Sol_cli_gcp_serverless_job.failure_to_string
  | Error job_error ->
    Sol_cli_cloud_run.destroy (runner ()) ~project ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
    |> Result.map_error (fun message ->
      Printf.sprintf "%s (Cloud Run record: %s)" job_error message)
;;
