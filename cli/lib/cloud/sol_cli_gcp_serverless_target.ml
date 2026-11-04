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

(* HTTP-function records reuse the Cloud Run ownership fields so the existing
   Cloud Run destroy/absence path can read and delete them, and add the trigger
   identity that distinguishes an HTTP function from a -svc. *)
let fn_http_json (release : Sol_cli_cloud_run.release) ~(http : Sol_cli_toml.http_trigger)
  =
  `Assoc
    [ "kind", `String "fn_http"
    ; "provider", `String "gcp"
    ; "project", `String release.project
    ; "region", `String release.region
    ; "service", `String release.service
    ; "provider_service", `String release.provider_service
    ; "revision", `String release.revision
    ; "url", `String release.url
    ; "image", `String release.image
    ; "service_account", `String release.service_account
    ; "http_path", `String http.path
    ; "http_exposure", `String (Sol_cli_toml.http_exposure_to_string http.exposure)
    ]
;;

let write_fn_http_record ~path release ~http =
  Sol_cli_fs.write_atomic
    ~perm:0o600
    path
    (Yojson.Safe.to_string (fn_http_json release ~http) ^ "\n")
;;

let fn_http_ready ~http url =
  let url =
    let rec trim value =
      if String.length value > 0 && value.[String.length value - 1] = '/'
      then trim (String.sub value 0 (String.length value - 1))
      else value
    in
    trim url
  in
  match Sol_cli_serverless_runner.http ~url:(url ^ "/readyz") ~token:None with
  | Error message -> Error ("post-deploy readiness request failed: " ^ message)
  | Ok (status, _) ->
    if status = 200
    then Ok ()
    else
      Error
        (Printf.sprintf
           "post-deploy readiness for %s returned %d"
           http.Sol_cli_toml.path
           status)
;;

let read_record_kind path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text ->
    (match Sol_cli_json.decode ~what:"release record" text with
     | Ok json ->
       (match Sol_cli_json.string (Sol_cli_json.field [ "kind" ] json) with
        | Some kind -> Ok (Some kind)
        | None -> Ok None)
     | Error message -> Error message)
  | exception Sys_error message -> Error message
;;

let read_fn_http_trigger path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error message -> Error message
  | text ->
    (match Sol_cli_json.decode ~what:"HTTP function release record" text with
     | Error message -> Error message
     | Ok json ->
       let field name =
         Sol_cli_json.string (Sol_cli_json.field [ name ] json)
         |> Option.to_result ~none:(name ^ " missing from release record")
       in
       let* path = field "http_path" in
       let* exposure = field "http_exposure" in
       let* exposure =
         Sol_cli_toml.http_exposure_of_string exposure
         |> Result.map_error (fun message -> "release record: " ^ message)
       in
       Ok { Sol_cli_toml.path; exposure })
;;

let deploy_fn_http
      ~target
      ~config
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
      ~(http : Sol_cli_toml.http_trigger)
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
  let* callers =
    match http.exposure with
    | Sol_cli_toml.Http_public -> Ok []
    | Sol_cli_toml.Http_internal ->
      let* () = Sol_cli_serverless_target_common.require_http_callers target in
      Ok (Sol_cli_serverless_target_common.callers target)
  in
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
    ; callers
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
    ; ingress =
        (match http.exposure with
         | Sol_cli_toml.Http_public -> Sol_cli_cloud_run.Public
         | Sol_cli_toml.Http_internal -> Sol_cli_cloud_run.Internal)
    ; service_account
    ; extra_env =
        [ "SOL_HTTP_PATH", http.path
        ; "SOL_HTTP_EXPOSURE", Sol_cli_toml.http_exposure_to_string http.exposure
        ]
    ; record = None
    }
  in
  let provisional =
    { Sol_cli_cloud_run.project = cloud_project
    ; region = target.region
    ; service = service.name
    ; provider_service
    ; revision = ""
    ; url = ""
    ; image
    ; service_account
    }
  in
  (* A provider deploy can create the service and still fail. Write a destroyable
     record before the mutation, then replace it with the observed revision before
     the readiness smoke. *)
  let* () =
    write_fn_http_record ~path:record provisional ~http
    |> Result.map_error (fun message -> "could not write release record: " ^ message)
  in
  let* release =
    Sol_cli_cloud_run.deploy (runner ()) request
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  in
  let* () =
    write_fn_http_record ~path:record release ~http
    |> Result.map_error (fun message -> "could not write release record: " ^ message)
  in
  let* () = fn_http_ready ~http release.url in
  Ok (fn_http_json release ~http)
;;

let rollback_fn_http
      ~target
      ~project
      ~(service : Sol_cli_manifest.service)
      ~record
      ~(http : Sol_cli_toml.http_trigger)
      ~revision
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
  let callers =
    match http.exposure with
    | Sol_cli_toml.Http_public -> []
    | Sol_cli_toml.Http_internal -> Sol_cli_serverless_target_common.callers target
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
        ; callers
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; ingress =
        (match http.exposure with
         | Sol_cli_toml.Http_public -> Sol_cli_cloud_run.Public
         | Sol_cli_toml.Http_internal -> Sol_cli_cloud_run.Internal)
    ; extra_env =
        [ "SOL_HTTP_PATH", http.path
        ; "SOL_HTTP_EXPOSURE", Sol_cli_toml.http_exposure_to_string http.exposure
        ]
    ; record = None
    }
  in
  let write_record release =
    write_fn_http_record ~path:record release ~http
    |> Result.map_error (fun message -> "could not update release record: " ^ message)
  in
  let on_revision_moved revision = write_record { release with revision } in
  let* observed =
    Sol_cli_cloud_run.rollback_with
      (runner ())
      request
      ~revision
      ~on_revision_moved
      ~verify:(fun observed ->
        match fn_http_ready ~http observed.url with
        | Ok () -> Ok ()
        | Error message -> Error (Sol_cli_cloud_run.Refused message))
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
  Ok (fn_http_json recorded ~http)
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
    ; extra_env = []
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
      ~project
      ~(service : Sol_cli_manifest.service)
      ~image
      ~record
      ~runtime_service_account
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
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
  let* external_env =
    Sol_cli_resource_binding.external_connection ~config ~service_name:service.name
  in
  let request : Sol_cli_gcp_serverless_job.request =
    { project = cloud_project
    ; region = target.region
    ; service = service.name
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; job
    ; image
    ; service_account
    ; schedule
    ; timezone = schedule_timezone
    ; scheduler_identity
    ; external_env
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
      ~schedule
      ~schedule_timezone
      ~scheduler_identity
      ~http
  =
  let* () = ensure_gcp target in
  match service.primitive with
  | Sol_cli_manifest.Svc ->
    deploy_svc ~target ~config ~project ~service ~image ~record ~runtime_service_account
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
         ~http
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
    ; extra_env = []
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

let rollback_fn ~target ~project ~(service : Sol_cli_manifest.service) ~record ~execution =
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
    ; unit = Sol_cli_serverless_target_common.unit_of_service ~project service
    ; job
    ; image = ""
    ; service_account = Sol_cli_gcp_serverless_job.runtime_service_account recorded
    ; schedule = None
    ; timezone = None
    ; scheduler_identity = None
    ; external_env = []
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
    (match read_record_kind record with
     | Ok (Some "fn_http") ->
       let* http = read_fn_http_trigger record in
       rollback_fn_http ~target ~project ~service ~record ~http ~revision
     | Ok _ -> rollback_fn ~target ~project ~service ~record ~execution:revision
     | Error message -> Error ("could not read release record: " ^ message))
  | Sol_cli_manifest.Worker ->
    Error "target-scoped serverless dispatch does not support -worker on GCP"
;;

let destroy ~target ~service ~record =
  let* () = ensure_gcp target in
  let* project =
    Sol_cli_serverless_target_common.required_field target ~provider:"gcp" "project_id"
  in
  match read_record_kind record with
  | Ok (Some "fn_http") ->
    Sol_cli_cloud_run.destroy (runner ()) ~project ~region:target.region ~service ~record
    |> Result.map_error Sol_cli_cloud_run.failure_to_string
  | Error message -> Error ("could not read release record: " ^ message)
  | Ok _ ->
    (match Sol_cli_gcp_serverless_job.read_record record with
     | Ok _ ->
       let* job =
         Sol_cli_cloud_run.provider_service_of service
         |> Result.map_error Sol_cli_cloud_run.failure_to_string
       in
       let request : Sol_cli_gcp_serverless_job.request =
         { project
         ; region = target.region
         ; service
         ; unit = service
         ; job
         ; image = ""
         ; service_account = ""
         ; schedule = None
         ; timezone = None
         ; scheduler_identity = None
         ; external_env = []
         ; record
         ; runner = runner ()
         }
       in
       Sol_cli_gcp_serverless_job.destroy request ~record
       |> Result.map_error Sol_cli_gcp_serverless_job.failure_to_string
     | Error job_error ->
       Sol_cli_cloud_run.destroy
         (runner ())
         ~project
         ~region:target.region
         ~service
         ~record
       |> Result.map_error Sol_cli_cloud_run.failure_to_string
       |> Result.map_error (fun message ->
         Printf.sprintf "%s (Cloud Run record: %s)" job_error message))
;;
