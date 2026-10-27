open Result.Syntax

type ingress = Public

type identity =
  { unit : string
  ; callers : (string * string) list
  ; issuer : string
  ; jwks_uri : string
  }

type request =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; identity : identity
  ; ingress : ingress
  ; record : string option
  }

type observed =
  { url : string
  ; revision : string
  ; traffic : (string * int) list
  }

type release =
  { service : string
  ; revision : string
  ; url : string
  ; image : string
  }

type failure =
  | Refused of string
  | Provider of string
  | Partial of string * observed option
  | Unknown of string

let ingress_of_string = function
  | "public" -> Ok Public
  | value ->
    Error
      (Refused
         (Printf.sprintf
            "unsupported ingress %S (experimental adapter supports public only)"
            value))
;;

type runner =
  { run : string list -> (string, string) result
  ; http : url:string -> token:string option -> (int * string, string) result
  }

let failure_to_string = function
  | Refused message -> "refused: " ^ message
  | Provider message -> "provider failure: " ^ message
  | Partial (message, Some observed) ->
    Printf.sprintf
      "partial: %s (observed revision %s at %s)"
      message
      observed.revision
      observed.url
  | Partial (message, None) -> "partial: " ^ message ^ " (current state unknown)"
  | Unknown message -> "unknown: " ^ message
;;

let nonempty name value =
  if String.trim value = ""
  then Error (Refused (Printf.sprintf "%s must not be empty" name))
  else Ok value
;;

let valid_image image =
  match String.index_opt image '@' with
  | None -> Error (Refused "image must be an immutable @sha256: reference")
  | Some at ->
    let digest = String.sub image (at + 1) (String.length image - at - 1) in
    if String.starts_with ~prefix:"sha256:" digest && String.length digest > 7
    then Ok image
    else Error (Refused "image must be an immutable @sha256: reference")
;;

let valid_caller (subject, unit) =
  subject <> ""
  && unit <> ""
  && (not (String.starts_with ~prefix:"system:serviceaccount:" subject))
  && not (String.contains subject ':')
;;

let preflight (request : request) =
  let* _ = nonempty "project" request.project in
  let* _ = nonempty "region" request.region in
  let* _ = nonempty "service" request.service in
  let* _ = valid_image request.image in
  let* _ = nonempty "identity.unit" request.identity.unit in
  let* () =
    if request.identity.issuer = "https://accounts.google.com"
    then Ok ()
    else Error (Refused "the experimental Cloud Run adapter requires the Google issuer")
  in
  let* () =
    if request.identity.jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    then Ok ()
    else
      Error
        (Refused "the experimental Cloud Run adapter requires Google's canonical JWKS URI")
  in
  let* () =
    match request.identity.callers with
    | [] -> Error (Refused "at least one caller must be configured")
    | callers ->
      if List.for_all valid_caller callers
      then Ok ()
      else Error (Refused "callers must be unit=non-Kubernetes-subject entries")
  in
  match request.ingress with
  | Public -> Ok ()
;;

let env_vars (request : request) =
  let callers =
    request.identity.callers
    |> List.map (fun (subject, unit) -> unit ^ "=" ^ subject)
    |> String.concat ","
  in
  [ "SOL_UNIT", request.identity.unit
  ; "SOL_CALLED_BY", callers
  ; "SOL_TRUSTED_WORKLOAD_ISSUER", request.identity.issuer
  ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", request.identity.jwks_uri
  ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
  ]
;;

let deploy_argv (request : request) =
  [ "gcloud"
  ; "run"
  ; "deploy"
  ; request.service
  ; "--project"
  ; request.project
  ; "--region"
  ; request.region
  ; "--image"
  ; request.image
  ; "--allow-unauthenticated"
  ; "--port"
  ; "8080"
  ; "--set-env-vars"
  ; env_vars request
    |> List.map (fun (key, value) -> key ^ "=" ^ value)
    |> String.concat ","
  ; "--quiet"
  ]
;;

let describe_argv ~project ~region ~service =
  [ "gcloud"
  ; "run"
  ; "services"
  ; "describe"
  ; service
  ; "--project"
  ; project
  ; "--region"
  ; region
  ; "--format=json"
  ]
;;

let list_argv ~project ~region =
  [ "gcloud"
  ; "run"
  ; "services"
  ; "list"
  ; "--project"
  ; project
  ; "--region"
  ; region
  ; "--format=value(metadata.name)"
  ]
;;

let delete_argv ~project ~region ~service =
  [ "gcloud"
  ; "run"
  ; "services"
  ; "delete"
  ; service
  ; "--project"
  ; project
  ; "--region"
  ; region
  ; "--quiet"
  ]
;;

let traffic_argv ~project ~region ~service ~revision =
  [ "gcloud"
  ; "run"
  ; "services"
  ; "update-traffic"
  ; service
  ; "--project"
  ; project
  ; "--region"
  ; region
  ; Printf.sprintf "--to-revisions=%s=100" revision
  ; "--quiet"
  ]
;;

let parse_observed text =
  let* json =
    Sol_cli_json.decode ~what:"Cloud Run service" text
    |> Result.map_error (fun message -> "describe returned invalid JSON: " ^ message)
  in
  let status = Sol_cli_json.field [ "status" ] json in
  let* url =
    Sol_cli_json.string (Sol_cli_json.field [ "url" ] status)
    |> Option.to_result ~none:"describe has no status.url"
  in
  let* revision =
    Sol_cli_json.string (Sol_cli_json.field [ "latestReadyRevisionName" ] status)
    |> Option.to_result ~none:"describe has no latestReadyRevisionName"
  in
  let traffic =
    match Sol_cli_json.list (Sol_cli_json.field [ "traffic" ] status) with
    | None -> []
    | Some entries ->
      List.filter_map
        (fun entry ->
           match
             ( Sol_cli_json.string (Sol_cli_json.field [ "revisionName" ] entry)
             , Sol_cli_json.int (Sol_cli_json.field [ "percent" ] entry) )
           with
           | Some revision, Some percent -> Some (revision, percent)
           | _ -> None)
        entries
  in
  if not (String.starts_with ~prefix:"https://" url)
  then Error "Cloud Run service URL is not HTTPS"
  else Ok { url; revision; traffic }
;;

let contains text needle =
  let n = String.length needle in
  let rec scan i =
    i + n <= String.length text && (String.sub text i n = needle || scan (i + 1))
  in
  scan 0
;;

let is_not_found text =
  let text = String.lowercase_ascii text in
  List.exists (contains text) [ "not found"; "not_found"; "404"; "does not exist" ]
;;

let describe runner (request : request) =
  match
    runner.run
      (describe_argv
         ~project:request.project
         ~region:request.region
         ~service:request.service)
  with
  | Error error ->
    if is_not_found error then Error `Not_found else Error (`Provider error)
  | Ok text ->
    (match parse_observed text with
     | Ok observed -> Ok (`Present observed)
     | Error message -> Error (`Unknown message))
;;

let release (request : request) (observed : observed) =
  { service = request.service
  ; revision = observed.revision
  ; url = observed.url
  ; image = request.image
  }
;;

let write_record ~path release =
  let json =
    `Assoc
      [ "service", `String release.service
      ; "revision", `String release.revision
      ; "url", `String release.url
      ; "image", `String release.image
      ]
  in
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out channel)
      (fun () ->
         Yojson.Safe.to_channel channel json;
         output_char channel '\n');
    Ok ()
  with
  | Sys_error message -> Error message
;;

let deploy runner (request : request) =
  let* () = preflight request in
  match runner.run (deploy_argv request) with
  | Error message ->
    let observed =
      match describe runner request with
      | Ok (`Present observed) -> Some observed
      | _ -> None
    in
    Error (Partial (message, observed))
  | Ok _ ->
    (match describe runner request with
     | Error `Not_found ->
       Error (Unknown "deploy returned success but the service is absent")
     | Error (`Provider message) ->
       Error (Unknown ("could not read the deployed service: " ^ message))
     | Error (`Unknown message) -> Error (Unknown message)
     | Ok (`Present observed) ->
       let* () =
         if
           List.exists
             (fun (revision, percent) -> revision = observed.revision && percent = 100)
             observed.traffic
         then Ok ()
         else Error (Unknown "the deployed revision is not serving 100% of traffic")
       in
       let deployed = release request observed in
       let* () =
         match request.record with
         | None -> Ok ()
         | Some path ->
           write_record ~path deployed
           |> Result.map_error (fun message ->
             Provider ("could not write release record: " ^ message))
       in
       Ok deployed)
;;

let verify runner (request : request) ~token =
  match describe runner request with
  | Error `Not_found -> Error (Unknown "service is absent; nothing to verify")
  | Error (`Provider message) -> Error (Provider message)
  | Error (`Unknown message) -> Error (Unknown message)
  | Ok (`Present observed) ->
    let* () =
      if token = ""
      then
        Error (Refused "an authorized caller token is required for /quote verification")
      else Ok ()
    in
    let* ready_status, _ =
      runner.http ~url:(observed.url ^ "/readyz") ~token:None
      |> Result.map_error (fun message ->
        Unknown ("readiness request failed: " ^ message))
    in
    let* () =
      if ready_status = 200
      then Ok ()
      else Error (Unknown (Printf.sprintf "readiness returned %d" ready_status))
    in
    let* auth_status, _ =
      runner.http ~url:(observed.url ^ "/quote") ~token:(Some token)
      |> Result.map_error (fun message ->
        Unknown ("authorized request failed: " ^ message))
    in
    let* () =
      if auth_status = 200
      then Ok ()
      else Error (Unknown (Printf.sprintf "authorized /quote returned %d" auth_status))
    in
    let* unauth_status, _ =
      runner.http ~url:(observed.url ^ "/quote") ~token:None
      |> Result.map_error (fun message ->
        Unknown ("unauthenticated request failed: " ^ message))
    in
    let* () =
      if unauth_status = 401
      then Ok ()
      else
        Error
          (Unknown (Printf.sprintf "unauthenticated /quote returned %d" unauth_status))
    in
    Ok observed
;;

let rollback runner (request : request) ~revision =
  match describe runner request with
  | Error `Not_found -> Error (Unknown "service is absent; cannot roll back")
  | Error (`Provider message) -> Error (Provider message)
  | Error (`Unknown message) -> Error (Unknown message)
  | Ok (`Present _) ->
    (match
       runner.run
         (traffic_argv
            ~project:request.project
            ~region:request.region
            ~service:request.service
            ~revision)
     with
     | Error message -> Error (Partial (message, None))
     | Ok _ ->
       (match describe runner request with
        | Error `Not_found ->
          Error (Unknown "rollback returned success but the service is absent")
        | Error (`Provider message) ->
          Error (Unknown ("could not read rolled-back service: " ^ message))
        | Error (`Unknown message) -> Error (Unknown message)
        | Ok (`Present observed) ->
          if
            List.exists
              (fun (name, percent) -> name = revision && percent = 100)
              observed.traffic
          then Ok observed
          else
            Error
              (Unknown "rollback did not establish the requested revision at 100% traffic")))
;;

let destroy runner ~project ~region ~service =
  let request =
    { project
    ; region
    ; service
    ; image = "unused"
    ; identity = { unit = ""; callers = []; issuer = ""; jwks_uri = "" }
    ; ingress = Public
    ; record = None
    }
  in
  match describe runner request with
  | Error `Not_found ->
    (match runner.run (list_argv ~project ~region) with
     | Error message ->
       Error (Unknown ("service is not readable and inventory failed: " ^ message))
     | Ok names ->
       if
         List.exists
           (fun name -> String.trim name = service)
           (String.split_on_char '\n' names)
       then Error (Unknown "service was absent by describe but present in inventory")
       else Ok ())
  | Error (`Provider message) -> Error (Provider message)
  | Error (`Unknown message) -> Error (Unknown message)
  | Ok (`Present _) ->
    (match runner.run (delete_argv ~project ~region ~service) with
     | Error message -> Error (Partial (message, None))
     | Ok _ ->
       (match runner.run (list_argv ~project ~region) with
        | Error message ->
          Error (Unknown ("delete returned success but inventory failed: " ^ message))
        | Ok names ->
          if
            List.exists
              (fun name -> String.trim name = service)
              (String.split_on_char '\n' names)
          then Error (Unknown "service remains after delete")
          else Ok ()))
;;

let observed_json (observed : observed) =
  `Assoc
    [ "url", `String observed.url
    ; "revision", `String observed.revision
    ; ( "traffic"
      , `Assoc
          (List.map (fun (revision, percent) -> revision, `Int percent) observed.traffic)
      )
    ]
;;

let release_json (release : release) =
  `Assoc
    [ "service", `String release.service
    ; "revision", `String release.revision
    ; "url", `String release.url
    ; "image", `String release.image
    ]
;;

let rollback_argv (request : request) ~revision =
  traffic_argv
    ~project:request.project
    ~region:request.region
    ~service:request.service
    ~revision
;;
