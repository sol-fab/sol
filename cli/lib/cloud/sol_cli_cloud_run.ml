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
  ; provider_service : string
  ; image : string
  ; identity : identity
  ; ingress : ingress
  ; record : string option
  }

type observed =
  { url : string
  ; revision : string
  ; traffic : (string * int) list
  ; image : string option
  ; provider_service : string
  ; labels : (string * string) list
  }

type release =
  { project : string
  ; region : string
  ; service : string
  ; provider_service : string
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

let provider_service_of service =
  match Sol_cli_kubernetes_name.k8s_name_of_source service with
  | Ok name -> Ok (Sol_cli_kubernetes_name.k8s_name_to_string name)
  | Error message ->
    Error
      (Refused
         (Printf.sprintf
            "Sol service name %S cannot be represented as a Cloud Run resource name: %s"
            service
            message))
;;

type output =
  { stdout : string
  ; stderr : string
  }

type runner =
  { run : string list -> (output, string) result
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
  && (not (String.contains subject ':'))
  && (not (String.contains subject ','))
  && (not (String.contains subject '='))
  && (not (String.contains unit ','))
  && (not (String.contains unit '='))
  && not (String.contains unit ':')
;;

let preflight (request : request) =
  let* _ = nonempty "project" request.project in
  let* _ = nonempty "region" request.region in
  let* _ = nonempty "service" request.service in
  let* _ = nonempty "provider_service" request.provider_service in
  let* expected_provider = provider_service_of request.service in
  let* () =
    if request.provider_service = expected_provider
    then Ok ()
    else
      Error
        (Refused
           (Printf.sprintf
              "provider_service %S does not match the canonical Cloud Run name %S for \
               Sol                service %S"
              request.provider_service
              expected_provider
              request.service))
  in
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
  ; request.provider_service
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
  ; "--labels"
  ; "sol-owned=cloud-run-experiment,sol-service=" ^ request.provider_service
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
  let* latest_revision =
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
  let* provider_service =
    Sol_cli_json.string (Sol_cli_json.field [ "metadata"; "name" ] json)
    |> Option.to_result ~none:"describe has no metadata.name"
  in
  let labels =
    match Sol_cli_json.assoc (Sol_cli_json.field [ "metadata"; "labels" ] json) with
    | None -> []
    | Some fields ->
      List.filter_map
        (fun (key, value) ->
           match Sol_cli_json.string value with
           | Some value -> Some (key, value)
           | None -> None)
        fields
  in
  let image =
    match
      Sol_cli_json.list
        (Sol_cli_json.field [ "spec"; "template"; "spec"; "containers" ] json)
    with
    | Some (container :: _) ->
      Sol_cli_json.string (Sol_cli_json.field [ "image" ] container)
    | _ -> None
  in
  let serving = List.filter (fun (_, percent) -> percent = 100) traffic in
  let* revision =
    match serving with
    | [ (revision, _) ] -> Ok revision
    | [] -> Ok latest_revision
    | _ -> Error "describe reports multiple revisions at 100% traffic"
  in
  if not (String.starts_with ~prefix:"https://" url)
  then Error "Cloud Run service URL is not HTTPS"
  else Ok { url; revision; traffic; image; provider_service; labels }
;;

let inventory runner ~project ~region =
  match runner.run (list_argv ~project ~region) with
  | Error message -> Error message
  | Ok output ->
    if not (Sol_cli_gcp_absence.benign_empty_list_warning output.stderr)
    then
      Error
        (Printf.sprintf
           "service inventory emitted an unexpected warning: %s"
           (String.trim output.stderr))
    else
      Ok
        (String.split_on_char '\n' output.stdout
         |> List.map String.trim
         |> List.filter (fun name -> name <> ""))
;;

(* A successful, scoped listing establishes absence. A failed describe cannot: the
   project, API scope, or caller may be wrong, and gcloud's wording is not a contract. *)
let describe runner (request : request) =
  match
    runner.run
      (describe_argv
         ~project:request.project
         ~region:request.region
         ~service:request.provider_service)
  with
  | Error error -> Error (`Unknown error)
  | Ok output ->
    (match parse_observed output.stdout with
     | Ok observed -> Ok observed
     | Error message -> Error (`Unknown message))
;;

let observe runner (request : request) =
  match inventory runner ~project:request.project ~region:request.region with
  | Error message -> Error (`Unknown message)
  | Ok names when not (List.mem request.provider_service names) -> Ok `Absent
  | Ok _ ->
    (match describe runner request with
     | Ok observed -> Ok (`Present observed)
     | Error error -> Error error)
;;

let release (request : request) (observed : observed) =
  { project = request.project
  ; region = request.region
  ; service = request.service
  ; provider_service = request.provider_service
  ; revision = observed.revision
  ; url = observed.url
  ; image = request.image
  }
;;

let write_record ~path release =
  let json =
    `Assoc
      [ "project", `String release.project
      ; "region", `String release.region
      ; "service", `String release.service
      ; "provider_service", `String release.provider_service
      ; "revision", `String release.revision
      ; "url", `String release.url
      ; "image", `String release.image
      ]
  in
  Sol_cli_fs.write_atomic ~perm:0o600 path (Yojson.Safe.to_string json ^ "\n")
;;

let read_record ~path =
  try
    let text = In_channel.with_open_bin path In_channel.input_all in
    let* json =
      Sol_cli_json.decode ~what:"Cloud Run release record" text
      |> Result.map_error (fun message -> "release record is invalid: " ^ message)
    in
    let* project =
      Sol_cli_json.string (Sol_cli_json.field [ "project" ] json)
      |> Option.to_result ~none:"release record has no project"
    in
    let* region =
      Sol_cli_json.string (Sol_cli_json.field [ "region" ] json)
      |> Option.to_result ~none:"release record has no region"
    in
    let* service =
      Sol_cli_json.string (Sol_cli_json.field [ "service" ] json)
      |> Option.to_result ~none:"release record has no service"
    in
    let* provider_service =
      Sol_cli_json.string (Sol_cli_json.field [ "provider_service" ] json)
      |> Option.to_result ~none:"release record has no provider_service"
    in
    let* revision =
      Sol_cli_json.string (Sol_cli_json.field [ "revision" ] json)
      |> Option.to_result ~none:"release record has no revision"
    in
    let* url =
      Sol_cli_json.string (Sol_cli_json.field [ "url" ] json)
      |> Option.to_result ~none:"release record has no url"
    in
    let* image =
      Sol_cli_json.string (Sol_cli_json.field [ "image" ] json)
      |> Option.to_result ~none:"release record has no image"
    in
    Ok { project; region; service; provider_service; revision; url; image }
  with
  | Sys_error message -> Error ("cannot read release record: " ^ message)
;;

let owns ~service ~provider observed =
  service <> ""
  && provider <> ""
  && List.assoc_opt "sol-owned" observed.labels = Some "cloud-run-experiment"
  && List.assoc_opt "sol-service" observed.labels = Some provider
;;

let deploy runner (request : request) =
  let* () = preflight request in
  let* () =
    match observe runner request with
    | Ok `Absent -> Ok ()
    | Ok (`Present observed)
      when owns ~service:request.service ~provider:request.provider_service observed ->
      Ok ()
    | Ok (`Present _) ->
      Error
        (Refused
           "Cloud Run service already exists without this adapter's ownership labels; \
            refusing to take it over")
    | Error (`Unknown message) ->
      Error (Unknown ("could not inspect existing service: " ^ message))
  in
  match runner.run (deploy_argv request) with
  | Error message ->
    let observed =
      match describe runner request with
      | Ok observed -> Some observed
      | Error _ -> None
    in
    Error (Partial (message, observed))
  | Ok _ ->
    (match describe runner request with
     | Error (`Unknown message) ->
       Error (Unknown ("could not read the deployed service: " ^ message))
     | Ok observed ->
       let* () =
         if owns ~service:request.service ~provider:request.provider_service observed
         then Ok ()
         else Error (Unknown "the deployed service lacks this adapter's ownership labels")
       in
       let* () =
         if
           List.exists
             (fun (revision, percent) -> revision = observed.revision && percent = 100)
             observed.traffic
         then Ok ()
         else Error (Unknown "the deployed revision is not serving 100% of traffic")
       in
       Ok (release request observed))
;;

let verify runner (request : request) ~token =
  match describe runner request with
  | Error (`Unknown message) -> Error (Unknown message)
  | Ok observed ->
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
    let* () =
      match request.record with
      | None -> Ok ()
      | Some path ->
        let* image =
          match observed.image with
          | Some image -> Ok image
          | None ->
            Error
              (Unknown
                 "describe did not report the deployed image; refusing to write a \
                  release record")
        in
        let recorded = { (release request observed) with image } in
        write_record ~path recorded
        |> Result.map_error (fun message ->
          Provider ("could not write release record: " ^ message))
    in
    Ok observed
;;

let serving_revision revision observed =
  List.exists (fun (name, percent) -> name = revision && percent = 100) observed.traffic
;;

let rollback runner (request : request) ~revision ~token ~on_revision_moved =
  let finish observed =
    if serving_revision revision observed
    then
      (* The provider observation establishes that the requested revision is serving. Record
         that serving identity before the smoke, so a failed smoke cannot leave the record
         naming the previous revision. *)
      let* () =
        on_revision_moved revision
        |> Result.map_error (fun message ->
          Partial
            ( "serving revision observed but release record update failed: " ^ message
            , Some observed ))
      in
      match verify runner { request with record = None } ~token with
      | Ok _ -> Ok observed
      | Error failure ->
        Error
          (Partial
             ( "rollback traffic reached the requested revision at 100%, but serving \
                verification failed: "
               ^ failure_to_string failure
             , Some observed ))
    else
      Error (Unknown "rollback did not establish the requested revision at 100% traffic")
  in
  match describe runner request with
  | Error (`Unknown message) -> Error (Unknown message)
  | Ok _ ->
    (match
       runner.run
         (traffic_argv
            ~project:request.project
            ~region:request.region
            ~service:request.provider_service
            ~revision)
     with
     | Ok _ ->
       (match describe runner request with
        | Error (`Unknown message) ->
          Error (Unknown ("could not read rolled-back service: " ^ message))
        | Ok observed -> finish observed)
     | Error message ->
       (* The CLI can report an error after the provider applied the mutation. Reconciling
          against observed traffic distinguishes "the update actually applied" from "the
          update did not apply"; unreadable state stays unknown. *)
       (match describe runner request with
        | Ok observed when serving_revision revision observed ->
          Sol_cli_report.warn
            "gcloud update-traffic reported an error but revision %s is serving 100%%; \
             reconciled: %s"
            revision
            message;
          finish observed
        | Ok observed -> Error (Partial (message, Some observed))
        | Error _ -> Error (Partial (message, None))))
;;

let destroy runner ~project ~region ~service ~record =
  let* provider_service = provider_service_of service in
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message ->
      Refused ("destroy requires an ownership record: " ^ message))
  in
  let* () =
    if
      expected.project = project
      && expected.region = region
      && expected.service = service
      && expected.provider_service = provider_service
    then Ok ()
    else
      Error
        (Refused
           "ownership record does not match the requested project, region and service; \
            refusing to delete an unverified resource")
  in
  let request =
    { project
    ; region
    ; service
    ; provider_service
    ; image = expected.image
    ; identity = { unit = ""; callers = []; issuer = ""; jwks_uri = "" }
    ; ingress = Public
    ; record = None
    }
  in
  match inventory runner ~project ~region with
  | Error message ->
    Error (Unknown ("service inventory failed; absence is unknown: " ^ message))
  | Ok names when not (List.mem provider_service names) -> Ok ()
  | Ok _ ->
    (match describe runner request with
     | Error (`Unknown message) -> Error (Unknown message)
     | Ok observed ->
       let* () =
         if owns ~service ~provider:provider_service observed
         then Ok ()
         else
           Error
             (Refused
                "live service lacks this adapter's ownership labels; refusing to delete \
                 it")
       in
       let* () =
         if
           expected.revision = observed.revision
           && expected.url = observed.url
           && observed.image = Some expected.image
         then Ok ()
         else
           Error
             (Refused
                "live service does not match the recorded revision, URL and image; \
                 refusing to delete a different deployment")
       in
       (match runner.run (delete_argv ~project ~region ~service:provider_service) with
        | Error message -> Error (Partial (message, None))
        | Ok _ ->
          (match inventory runner ~project ~region with
           | Error message ->
             Error (Unknown ("delete returned success but inventory failed: " ^ message))
           | Ok names ->
             if List.mem provider_service names
             then Error (Unknown "service remains after delete")
             else Ok ())))
;;

let observed_json (observed : observed) =
  `Assoc
    [ "url", `String observed.url
    ; "revision", `String observed.revision
    ; "provider_service", `String observed.provider_service
    ; ( "image"
      , match observed.image with
        | Some image -> `String image
        | None -> `Null )
    ; "labels", `Assoc (List.map (fun (key, value) -> key, `String value) observed.labels)
    ; ( "traffic"
      , `Assoc
          (List.map (fun (revision, percent) -> revision, `Int percent) observed.traffic)
      )
    ]
;;

let release_json (release : release) =
  `Assoc
    [ "project", `String release.project
    ; "region", `String release.region
    ; "service", `String release.service
    ; "provider_service", `String release.provider_service
    ; "revision", `String release.revision
    ; "url", `String release.url
    ; "image", `String release.image
    ]
;;

let rollback_argv (request : request) ~revision =
  traffic_argv
    ~project:request.project
    ~region:request.region
    ~service:request.provider_service
    ~revision
;;
