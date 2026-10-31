open Result.Syntax

type runner = { run : string list -> (Sol_cli_cloud_run.output, string) result }

type request =
  { project : string
  ; region : string
  ; unit : string
  ; job : string
  ; schedule : string
  ; timezone : string option
  ; service_account : string
  ; runner : runner
  }

type release =
  { name : string
  ; uri : string
  ; schedule : string
  ; timezone : string
  ; service_account : string
  }

let to_json (r : release) =
  `Assoc
    [ "name", `String r.name
    ; "uri", `String r.uri
    ; "schedule", `String r.schedule
    ; "timezone", `String r.timezone
    ; "service_account", `String r.service_account
    ]
;;

let of_json json =
  let field name =
    Sol_cli_json.string (Sol_cli_json.field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let open Result.Syntax in
  let* name = field "name" in
  let* uri = field "uri" in
  let* schedule = field "schedule" in
  let* timezone = field "timezone" in
  let* service_account = field "service_account" in
  Ok { name; uri; schedule; timezone; service_account }
;;

let gcloud (r : request) args = r.runner.run ("gcloud" :: args)

let is_not_found message =
  let lower = String.lowercase_ascii message in
  Sol_cli_string.contains ~needle:"not_found" lower
  || Sol_cli_string.contains ~needle:"not found" lower
  || Sol_cli_string.contains ~needle:"cannot find" lower
;;

let name (r : request) =
  let digest =
    Digestif.SHA1.digest_string r.unit
    |> Digestif.SHA1.to_hex
    |> fun hex -> String.sub hex 0 8
  in
  "sol-schedule-" ^ digest
;;

let timezone (r : request) = Option.value r.timezone ~default:"UTC"

let uri (r : request) =
  Printf.sprintf
    "https://run.googleapis.com/v1/projects/%s/locations/%s/jobs/%s:run"
    r.project
    r.region
    r.job
;;

let create_or_update (r : request) ~name ~uri ~timezone =
  let common =
    [ name
    ; "--location"
    ; r.region
    ; "--schedule"
    ; r.schedule
    ; "--time-zone"
    ; timezone
    ; "--uri"
    ; uri
    ; "--http-method"
    ; "POST"
    ; "--oauth-service-account-email"
    ; r.service_account
    ; "--oauth-token-scope"
    ; "https://www.googleapis.com/auth/cloud-platform"
    ; "--message-body"
    ; "{}"
    ]
  in
  let* exists =
    match gcloud r [ "scheduler"; "jobs"; "describe"; name; "--location"; r.region ] with
    | Ok _ -> Ok true
    | Error _ -> Ok false
  in
  if exists
  then
    gcloud r ([ "scheduler"; "jobs"; "update"; "http" ] @ common)
    |> Result.map (fun _ -> ())
  else
    gcloud r ([ "scheduler"; "jobs"; "create"; "http" ] @ common)
    |> Result.map (fun _ -> ())
;;

let deploy (r : request) =
  let* () =
    if String.trim r.service_account = ""
    then
      Error
        "scheduled serverless function has no provisioned scheduler identity; the \
         authorization root must establish a dedicated scheduler service account"
    else Ok ()
  in
  let* policy =
    gcloud
      r
      [ "run"
      ; "jobs"
      ; "get-iam-policy"
      ; r.job
      ; "--project"
      ; r.project
      ; "--region"
      ; r.region
      ; "--format"
      ; "json"
      ]
    |> Result.map_error (fun message ->
      Printf.sprintf "could not verify Cloud Run Job IAM: %s" message)
  in
  let* () =
    let member = "serviceAccount:" ^ r.service_account in
    if
      Sol_cli_string.contains ~needle:member policy.stdout
      && Sol_cli_string.contains ~needle:"roles/run.jobsExecutor" policy.stdout
    then Ok ()
    else
      Error
        "scheduler service account is not granted roles/run.jobsExecutor on this \
         job;          refusing to create the schedule"
  in
  let schedule_name = name r in
  let uri = uri r in
  let timezone = timezone r in
  let* () =
    create_or_update r ~name:schedule_name ~uri ~timezone
    |> Result.map_error (fun message ->
      Printf.sprintf "could not configure Cloud Scheduler job: %s" message)
  in
  let* () =
    let* output =
      gcloud
        r
        [ "scheduler"
        ; "jobs"
        ; "describe"
        ; schedule_name
        ; "--location"
        ; r.region
        ; "--format"
        ; "json"
        ]
    in
    let* json =
      Sol_cli_json.decode ~what:"Cloud Scheduler job" output.stdout
      |> Result.map_error (fun message -> "Cloud Scheduler job is invalid: " ^ message)
    in
    let* actual_uri =
      Sol_cli_json.string (Sol_cli_json.field [ "httpTarget"; "uri" ] json)
      |> Option.to_result ~none:"Cloud Scheduler job has no HTTP target URI"
    in
    let* actual_sa =
      Sol_cli_json.string
        (Sol_cli_json.field [ "httpTarget"; "oauthToken"; "serviceAccountEmail" ] json)
      |> Option.to_result ~none:"Cloud Scheduler job has no OAuth service account"
    in
    let* () =
      if String.equal actual_uri uri
      then Ok ()
      else
        Error (Printf.sprintf "Cloud Scheduler target is %S, expected %S" actual_uri uri)
    in
    let* () =
      if String.equal actual_sa r.service_account
      then Ok ()
      else
        Error
          (Printf.sprintf
             "Cloud Scheduler identity is %S, expected %S"
             actual_sa
             r.service_account)
    in
    Ok ()
  in
  Ok
    { name = schedule_name
    ; uri
    ; schedule = r.schedule
    ; timezone
    ; service_account = r.service_account
    }
;;

let destroy_by_unit (r : request) =
  let schedule_name = name r in
  match
    gcloud r [ "scheduler"; "jobs"; "describe"; schedule_name; "--location"; r.region ]
  with
  | Error message when is_not_found message -> Ok ()
  | Error message ->
    Error (Printf.sprintf "could not read Cloud Scheduler job: %s" message)
  | Ok _ ->
    gcloud
      r
      [ "scheduler"; "jobs"; "delete"; schedule_name; "--location"; r.region; "--quiet" ]
    |> Result.map (fun _ -> ())
;;

let destroy (r : request) (release : release) =
  match
    gcloud r [ "scheduler"; "jobs"; "describe"; release.name; "--location"; r.region ]
  with
  | Error message when is_not_found message -> Ok ()
  | Error message ->
    Error (Printf.sprintf "could not read Cloud Scheduler job: %s" message)
  | Ok _ ->
    gcloud
      r
      [ "scheduler"; "jobs"; "delete"; release.name; "--location"; r.region; "--quiet" ]
    |> Result.map (fun _ -> ())
;;
