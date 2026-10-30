open Result.Syntax

type request =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; max_attempts : int
  ; ack_deadline_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  ; record : string option
  ; run : string list -> (Sol_cli_cloud_run.output, string) result
  }

type release =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; cloud_run_service : string
  ; cloud_run_url : string
  ; revision : string
  ; topic : string
  ; subscription : string
  ; dlq_topic : string
  ; dlq_subscription : string
  ; push_service_account : string
  ; max_attempts : int
  ; ack_deadline_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  }

let ownership_label = "cloud-run-task-experiment"
let ownership_description = "sol-owned=" ^ ownership_label

let contains_substring ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec at index =
    if index + needle_length > haystack_length
    then false
    else if String.sub haystack index needle_length = needle
    then true
    else at (index + 1)
  in
  needle_length = 0 || at 0
;;

let missing message =
  contains_substring ~needle:"NOT_FOUND" message
  || contains_substring ~needle:"NotFound" message
  || contains_substring ~needle:"not found" message
  || contains_substring ~needle:"does not exist" message
  || contains_substring ~needle:"Cannot find" message
;;

let project_argv (r : request) = [ "--project"; r.project ] @ []
let region_argv (r : request) = [ "--region"; r.region ]
let gcloud (r : request) args = r.run (([ "gcloud" ] @ args) @ [ "--quiet" ])

let gcloud_json (r : request) args =
  match r.run ([ "gcloud" ] @ args @ [ "--format=json"; "--quiet" ]) with
  | Error message -> Error (Sol_cli_cloud_run.Provider message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"gcloud output" output.stdout with
     | Error message -> Error (Sol_cli_cloud_run.Unknown message)
     | Ok json -> Ok json)
;;

let labels_string labels =
  labels |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat ","
;;

let workspace_label () =
  Sol_cli_workspace.current_name ()
  |> String.map (function
    | ('a' .. 'z' | '0' .. '9' | '-' | '_' | '.') as c -> c
    | 'A' .. 'Z' as c -> Char.lowercase_ascii c
    | _ -> '-')
  |> fun value -> if String.length value > 63 then String.sub value 0 63 else value
;;

let own_labels ~service =
  [ "sol-owned", ownership_label
  ; "sol-service", service
  ; "sol-workspace", workspace_label ()
  ]
;;

let json_field path json = Sol_cli_json.field path json

let labels_of json =
  match Sol_cli_json.assoc (json_field [ "labels" ] json) with
  | None -> []
  | Some fields ->
    List.filter_map
      (fun (key, value) ->
         Option.map (fun value -> key, value) (Sol_cli_json.string value))
      fields
;;

let owns_labels ~service labels =
  List.assoc_opt "sol-owned" labels = Some ownership_label
  && List.assoc_opt "sol-service" labels = Some service
  &&
  match List.assoc_opt "sol-workspace" labels with
  | Some workspace -> String.equal workspace (workspace_label ())
  | None -> true
;;

let validate_settings (r : request) =
  let* () =
    if r.max_attempts >= 5 && r.max_attempts <= 100
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused "max_attempts must be between 5 and 100 for Pub/Sub")
  in
  let* () =
    if r.ack_deadline_s >= 10 && r.ack_deadline_s <= 600
    then Ok ()
    else Error (Sol_cli_cloud_run.Refused "ack_deadline_s must be between 10 and 600")
  in
  let* () =
    if r.dlq_retention_s >= 600 && r.dlq_retention_s <= 604800
    then Ok ()
    else
      Error (Sol_cli_cloud_run.Refused "dlq_retention_s must be between 600 and 604800")
  in
  if r.concurrency > 0
  then Ok ()
  else Error (Sol_cli_cloud_run.Refused "concurrency must be greater than zero")
;;

let truncate_to length value =
  if String.length value <= length then value else String.sub value 0 length
;;

let provider_names ~service =
  let* provider = Sol_cli_cloud_run.provider_service_of service in
  let cloud_run_service = provider ^ "-task" in
  if String.length cloud_run_service > 49
  then
    Error
      (Sol_cli_cloud_run.Refused
         "task Cloud Run service name is longer than 49 characters")
  else (
    let push_service_account = truncate_to 17 provider ^ "-push" in
    Ok
      ( cloud_run_service
      , provider ^ "-task"
      , provider ^ "-task-sub"
      , provider ^ "-task-dlq"
      , provider ^ "-task-dlq-sub"
      , push_service_account ))
;;

(* gcloud expects the service name as a positional before the IAM subcommand flags. *)
let add_invoker (r : request) ~cloud_run_service ~member =
  gcloud
    r
    ([ "run"
     ; "services"
     ; "add-iam-policy-binding"
     ; cloud_run_service
     ; "--role=roles/run.invoker"
     ; "--member=serviceAccount:" ^ member
     ]
     @ project_argv r
     @ region_argv r)
;;

let remove_invoker (r : request) ~cloud_run_service ~member =
  gcloud
    r
    ([ "run"
     ; "services"
     ; "remove-iam-policy-binding"
     ; cloud_run_service
     ; "--role=roles/run.invoker"
     ; "--member=serviceAccount:" ^ member
     ]
     @ project_argv r
     @ region_argv r)
;;

let add_token_creator (r : request) ~service_account ~member =
  gcloud
    r
    ([ "iam"
     ; "service-accounts"
     ; "add-iam-policy-binding"
     ; service_account
     ; "--role=roles/iam.serviceAccountTokenCreator"
     ; "--member=serviceAccount:" ^ member
     ]
     @ project_argv r)
;;

let remove_token_creator (r : request) ~service_account ~member =
  gcloud
    r
    ([ "iam"
     ; "service-accounts"
     ; "remove-iam-policy-binding"
     ; service_account
     ; "--role=roles/iam.serviceAccountTokenCreator"
     ; "--member=serviceAccount:" ^ member
     ]
     @ project_argv r)
;;

let service_json (r : request) ~cloud_run_service =
  match
    gcloud_json
      r
      ([ "run"; "services"; "describe"; cloud_run_service ]
       @ project_argv r
       @ region_argv r)
  with
  | Ok json -> Ok (Some json)
  | Error (Sol_cli_cloud_run.Provider message) when missing message -> Ok None
  | Error failure -> Error failure
;;

let topic_json (r : request) ~topic =
  match gcloud_json r ([ "pubsub"; "topics"; "describe"; topic ] @ project_argv r) with
  | Ok json -> Ok (Some json)
  | Error (Sol_cli_cloud_run.Provider message) when missing message -> Ok None
  | Error failure -> Error failure
;;

let subscription_json (r : request) ~subscription =
  match
    gcloud_json
      r
      ([ "pubsub"; "subscriptions"; "describe"; subscription ] @ project_argv r)
  with
  | Ok json -> Ok (Some json)
  | Error (Sol_cli_cloud_run.Provider message) when missing message -> Ok None
  | Error failure -> Error failure
;;

let service_account_json (r : request) ~email =
  match
    gcloud_json r ([ "iam"; "service-accounts"; "describe"; email ] @ project_argv r)
  with
  | Ok json -> Ok (Some json)
  | Error (Sol_cli_cloud_run.Provider message) when missing message -> Ok None
  | Error failure -> Error failure
;;

let ensure_service_account (r : request) ~name ~email =
  let* existing = service_account_json r ~email in
  match existing with
  | Some json ->
    let description =
      Sol_cli_json.string (json_field [ "description" ] json) |> Option.value ~default:""
    in
    if description = ownership_description
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           (Printf.sprintf
              "service account %s exists without this adapter's description"
              email))
  | None ->
    (match
       gcloud
         r
         ([ "iam"
          ; "service-accounts"
          ; "create"
          ; name
          ; "--display-name=Sol task push " ^ name
          ; "--description=" ^ ownership_description
          ]
          @ project_argv r)
     with
     | Ok _ -> Ok ()
     | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
;;

let ensure_topic (r : request) ~topic ~service ~retention_s =
  let* existing = topic_json r ~topic in
  match existing with
  | Some json ->
    let labels = labels_of json in
    if owns_labels ~service labels
    then (
      match
        gcloud
          r
          ([ "pubsub"
           ; "topics"
           ; "update"
           ; topic
           ; "--message-retention-duration=" ^ string_of_int retention_s ^ "s"
           ; "--update-labels=" ^ labels_string (own_labels ~service)
           ]
           @ project_argv r)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else
      Error
        (Sol_cli_cloud_run.Refused
           (Printf.sprintf "topic %s exists without this adapter's labels" topic))
  | None ->
    (match
       gcloud
         r
         ([ "pubsub"
          ; "topics"
          ; "create"
          ; topic
          ; "--message-retention-duration=" ^ string_of_int retention_s ^ "s"
          ; "--labels=" ^ labels_string (own_labels ~service)
          ]
          @ project_argv r)
     with
     | Ok _ -> Ok ()
     | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
;;

let deploy_service (r : request) ~cloud_run_service =
  let args =
    [ "run"
    ; "deploy"
    ; cloud_run_service
    ; "--image"
    ; r.image
    ; "--no-allow-unauthenticated"
    ; "--port"
    ; "8080"
    ; "--concurrency"
    ; "1"
    ; "--max-instances"
    ; string_of_int r.concurrency
    ; "--timeout"
    ; string_of_int r.ack_deadline_s
    ; "--set-env-vars"
    ; "SOL_TASK_RUNTIME=pubsub"
    ; "--labels"
    ; labels_string (own_labels ~service:cloud_run_service)
    ]
    @ project_argv r
    @ region_argv r
  in
  match gcloud r args with
  | Ok _ -> Ok ()
  | Error message -> Error (Sol_cli_cloud_run.Partial (message, None))
;;

let service_details (r : request) ~cloud_run_service =
  match service_json r ~cloud_run_service with
  | Error failure -> Error failure
  | Ok None ->
    Error
      (Sol_cli_cloud_run.Unknown
         ("Cloud Run service " ^ cloud_run_service ^ " is absent after deploy"))
  | Ok (Some json) ->
    let* url =
      Sol_cli_json.string (json_field [ "status"; "url" ] json)
      |> Option.to_result ~none:"Cloud Run service has no URL"
      |> Result.map_error (fun message -> Sol_cli_cloud_run.Unknown message)
    in
    let* revision =
      Sol_cli_json.string (json_field [ "status"; "latestReadyRevisionName" ] json)
      |> Option.to_result ~none:"Cloud Run service has no ready revision"
      |> Result.map_error (fun message -> Sol_cli_cloud_run.Unknown message)
    in
    let labels = labels_of (json_field [ "metadata" ] json) in
    if owns_labels ~service:cloud_run_service labels
    then Ok (url, revision)
    else Error (Sol_cli_cloud_run.Refused "Cloud Run service lacks this adapter's labels")
;;

let ensure_subscription
      (r : request)
      ~subscription
      ~topic
      ~dlq_topic
      ~push_url
      ~push_service_account
      ~service
  =
  let* existing = subscription_json r ~subscription in
  let common =
    [ "--push-endpoint=" ^ push_url
    ; "--push-auth-service-account=" ^ push_service_account
    ; "--ack-deadline=" ^ string_of_int r.ack_deadline_s
    ; "--dead-letter-topic=" ^ dlq_topic
    ; "--max-delivery-attempts=" ^ string_of_int r.max_attempts
    ; "--message-retention-duration=" ^ string_of_int r.dlq_retention_s ^ "s"
    ; "--min-retry-delay=1s"
    ; "--max-retry-delay=600s"
    ]
    @ project_argv r
  in
  let labels_arg = labels_string (own_labels ~service) in
  match existing with
  | Some json ->
    let labels = labels_of json in
    if owns_labels ~service labels
    then (
      match
        gcloud
          r
          ([ "pubsub"
           ; "subscriptions"
           ; "update"
           ; subscription
           ; "--update-labels=" ^ labels_arg
           ]
           @ common)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else
      Error
        (Sol_cli_cloud_run.Refused
           (Printf.sprintf
              "subscription %s exists without this adapter's labels"
              subscription))
  | None ->
    (match
       gcloud
         r
         ([ "pubsub"
          ; "subscriptions"
          ; "create"
          ; subscription
          ; "--topic"
          ; topic
          ; "--labels=" ^ labels_arg
          ]
          @ common)
     with
     | Ok _ -> Ok ()
     | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
;;

let ensure_dlq_subscription (r : request) ~subscription ~topic ~service =
  let* existing = subscription_json r ~subscription in
  let common =
    [ "--ack-deadline=10"
    ; "--message-retention-duration=" ^ string_of_int r.dlq_retention_s ^ "s"
    ; "--expiration-period=never"
    ]
    @ project_argv r
  in
  let labels_arg = labels_string (own_labels ~service) in
  match existing with
  | Some json ->
    let labels = labels_of json in
    if owns_labels ~service labels
    then (
      match
        gcloud
          r
          ([ "pubsub"
           ; "subscriptions"
           ; "update"
           ; subscription
           ; "--update-labels=" ^ labels_arg
           ]
           @ common)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else
      Error
        (Sol_cli_cloud_run.Refused
           (Printf.sprintf
              "dead-letter subscription %s exists without this adapter's labels"
              subscription))
  | None ->
    (match
       gcloud
         r
         ([ "pubsub"
          ; "subscriptions"
          ; "create"
          ; subscription
          ; "--topic"
          ; topic
          ; "--labels=" ^ labels_arg
          ]
          @ common)
     with
     | Ok _ -> Ok ()
     | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
;;

let add_topic_publisher (r : request) ~topic ~member =
  gcloud
    r
    ([ "pubsub"
     ; "topics"
     ; "add-iam-policy-binding"
     ; topic
     ; "--role=roles/pubsub.publisher"
     ; "--member=serviceAccount:" ^ member
     ]
     @ project_argv r)
;;

let project_number (r : request) =
  match
    r.run
      [ "gcloud"
      ; "projects"
      ; "describe"
      ; r.project
      ; "--format=value(projectNumber)"
      ; "--quiet"
      ]
  with
  | Error message -> Error (Sol_cli_cloud_run.Provider message)
  | Ok output -> Ok (String.trim output.stdout)
;;

let release_json (r : release) =
  `Assoc
    [ "kind", `String "gcp-task"
    ; "project", `String r.project
    ; "region", `String r.region
    ; "service", `String r.service
    ; "image", `String r.image
    ; "cloud_run_service", `String r.cloud_run_service
    ; "cloud_run_url", `String r.cloud_run_url
    ; "revision", `String r.revision
    ; "topic", `String r.topic
    ; "subscription", `String r.subscription
    ; "dlq_topic", `String r.dlq_topic
    ; "dlq_subscription", `String r.dlq_subscription
    ; "push_service_account", `String r.push_service_account
    ; "max_attempts", `Int r.max_attempts
    ; "ack_deadline_s", `Int r.ack_deadline_s
    ; "dlq_retention_s", `Int r.dlq_retention_s
    ; "concurrency", `Int r.concurrency
    ]
;;

let write_record ~path r =
  Sol_cli_fs.write_atomic ~perm:0o600 path (Yojson.Safe.to_string (release_json r) ^ "\n")
;;

let read_record ~path =
  let* text = Sol_cli_fs.read_file path in
  let* json = Sol_cli_json.decode ~what:"GCP task release" text in
  let field name =
    Sol_cli_json.string (json_field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let int_field name =
    Sol_cli_json.int (json_field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let* kind = field "kind" in
  let* () =
    if kind = "gcp-task"
    then Ok ()
    else Error (Printf.sprintf "release record kind %S is not a GCP task record" kind)
  in
  let* project = field "project" in
  let* region = field "region" in
  let* service = field "service" in
  let* image = field "image" in
  let* cloud_run_service = field "cloud_run_service" in
  let* cloud_run_url = field "cloud_run_url" in
  let* revision = field "revision" in
  let* topic = field "topic" in
  let* subscription = field "subscription" in
  let* dlq_topic = field "dlq_topic" in
  let* dlq_subscription = field "dlq_subscription" in
  let* push_service_account = field "push_service_account" in
  let* max_attempts = int_field "max_attempts" in
  let* ack_deadline_s = int_field "ack_deadline_s" in
  let* dlq_retention_s = int_field "dlq_retention_s" in
  let* concurrency = int_field "concurrency" in
  Ok
    { project
    ; region
    ; service
    ; image
    ; cloud_run_service
    ; cloud_run_url
    ; revision
    ; topic
    ; subscription
    ; dlq_topic
    ; dlq_subscription
    ; push_service_account
    ; max_attempts
    ; ack_deadline_s
    ; dlq_retention_s
    ; concurrency
    }
;;

let local_part email =
  match String.split_on_char '@' email with
  | name :: _ -> name
  | [] -> email
;;

let new_push_service_account_name prefix =
  let suffix =
    Printf.sprintf "%06x" (int_of_float (Unix.gettimeofday () *. 1000.) land 0xffffff)
  in
  prefix ^ "-" ^ suffix
;;

(* A deleted GCP service-account ID stays reserved. Reuse the recorded push
   account while it exists, but allocate a fresh ID after a destroy (or any
   unreadable/deleted state) instead of trying to recreate a reserved name. *)
let reusable_push_service_account (r : request) ~record ~service =
  if not (Sys.file_exists record)
  then None
  else (
    match read_record ~path:record with
    | Error _ -> None
    | Ok previous ->
      if
        previous.project = r.project
        && previous.region = r.region
        && previous.service = service
        && previous.push_service_account <> ""
      then (
        match service_account_json r ~email:previous.push_service_account with
        | Ok (Some _) -> Some previous.push_service_account
        | Ok None | Error _ -> None)
      else None)
;;

let verify (r : request) ~record =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Refused message)
  in
  let* () =
    if
      expected.project = r.project
      && expected.region = r.region
      && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           "release record does not match the target project, region, and service")
  in
  let* () =
    if expected.cloud_run_url = "" || expected.revision = ""
    then
      Error
        (Sol_cli_cloud_run.Refused
           "task ownership record is incomplete; the deploy did not finish")
    else Ok ()
  in
  let* url, _revision = service_details r ~cloud_run_service:expected.cloud_run_service in
  let* () =
    if url = expected.cloud_run_url
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           (Printf.sprintf
              "Cloud Run URL changed (recorded %s, observed %s)"
              expected.cloud_run_url
              url))
  in
  let* subscription =
    match subscription_json r ~subscription:expected.subscription with
    | Ok (Some json) -> Ok json
    | Ok None -> Error (Sol_cli_cloud_run.Unknown "task subscription is absent")
    | Error failure -> Error failure
  in
  let push_endpoint =
    Sol_cli_json.string (json_field [ "pushConfig"; "pushEndpoint" ] subscription)
    |> Option.value ~default:""
  in
  let* () =
    if push_endpoint = expected.cloud_run_url
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           (Printf.sprintf
              "subscription push endpoint is %s, expected %s"
              push_endpoint
              expected.cloud_run_url))
  in
  let push_service_account =
    Sol_cli_json.string
      (json_field [ "pushConfig"; "oidcToken"; "serviceAccountEmail" ] subscription)
    |> Option.value ~default:""
  in
  let* () =
    if push_service_account = expected.push_service_account
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           (Printf.sprintf
              "subscription OIDC identity is %s, recorded %s"
              push_service_account
              expected.push_service_account))
  in
  let* () =
    match
      Sol_cli_json.int
        (json_field [ "deadLetterPolicy"; "maxDeliveryAttempts" ] subscription)
    with
    | Some attempts when attempts = expected.max_attempts -> Ok ()
    | Some attempts ->
      Error
        (Sol_cli_cloud_run.Unknown
           (Printf.sprintf
              "subscription max delivery attempts is %d, recorded %d"
              attempts
              expected.max_attempts))
    | None ->
      Error
        (Sol_cli_cloud_run.Unknown
           "subscription has no dead-letter delivery-attempt limit")
  in
  let* dlq_sub =
    match subscription_json r ~subscription:expected.dlq_subscription with
    | Ok (Some json) -> Ok json
    | Ok None -> Error (Sol_cli_cloud_run.Unknown "dead-letter subscription is absent")
    | Error failure -> Error failure
  in
  let* () =
    if owns_labels ~service:expected.cloud_run_service (labels_of dlq_sub)
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused "dead-letter subscription lacks this adapter's labels")
  in
  let* project_number = project_number r in
  let pubsub_agent =
    Printf.sprintf "service-%s@gcp-sa-pubsub.iam.gserviceaccount.com" project_number
  in
  let member_role ~role ~member json =
    match Sol_cli_json.list (json_field [ "bindings" ] json) with
    | None -> false
    | Some bindings ->
      List.exists
        (fun binding ->
           Sol_cli_json.string (json_field [ "role" ] binding) = Some role
           &&
           match Sol_cli_json.list (json_field [ "members" ] binding) with
           | None -> false
           | Some members ->
             List.exists
               (fun candidate ->
                  Sol_cli_json.string candidate = Some ("serviceAccount:" ^ member))
               members)
        bindings
  in
  let* run_policy =
    gcloud_json
      r
      ([ "run"; "services"; "get-iam-policy"; expected.cloud_run_service ]
       @ project_argv r
       @ region_argv r)
  in
  let* () =
    if
      member_role
        ~role:"roles/run.invoker"
        ~member:expected.push_service_account
        run_policy
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           "Cloud Run service does not grant the push identity invoker")
  in
  let* sa_policy =
    gcloud_json
      r
      ([ "iam"; "service-accounts"; "get-iam-policy"; expected.push_service_account ]
       @ project_argv r)
  in
  let* () =
    if
      member_role
        ~role:"roles/iam.serviceAccountTokenCreator"
        ~member:pubsub_agent
        sa_policy
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           "push identity does not grant the Pub/Sub agent token creation")
  in
  let* policy =
    gcloud_json
      r
      ([ "pubsub"; "topics"; "get-iam-policy"; expected.dlq_topic ] @ project_argv r)
  in
  let bindings =
    match Sol_cli_json.list (json_field [ "bindings" ] policy) with
    | None -> []
    | Some bindings -> bindings
  in
  let has_publisher =
    List.exists
      (fun binding ->
         match Sol_cli_json.string (json_field [ "role" ] binding) with
         | Some "roles/pubsub.publisher" ->
           (match Sol_cli_json.list (json_field [ "members" ] binding) with
            | None -> false
            | Some members ->
              List.exists
                (fun member ->
                   Sol_cli_json.string member = Some ("serviceAccount:" ^ pubsub_agent))
                members)
         | _ -> false)
      bindings
  in
  let* () =
    if has_publisher
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Unknown
           "dead-letter topic does not grant the Pub/Sub service agent publisher")
  in
  Ok expected
;;

let deploy (r : request) =
  let* () = validate_settings r in
  let* () =
    if Sol_cli_image_ref.is_digest r.image
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           "image must be an immutable <repo>@sha256:<digest> reference")
  in
  let* record =
    r.record
    |> Option.to_result
         ~none:(Sol_cli_cloud_run.Refused "task deploy requires an ownership record path")
  in
  let* cloud_run_service, topic, subscription, dlq_topic, dlq_subscription, push_sa_prefix
    =
    provider_names ~service:r.service
  in
  let push_service_account =
    match reusable_push_service_account r ~record ~service:r.service with
    | Some email -> email
    | None ->
      Printf.sprintf
        "%s@%s.iam.gserviceaccount.com"
        (new_push_service_account_name push_sa_prefix)
        r.project
  in
  let push_sa_name = local_part push_service_account in
  (* Ownership before any mutation, including [gcloud run deploy]. *)
  let* existing_service = service_json r ~cloud_run_service in
  let* () =
    match existing_service with
    | None -> Ok ()
    | Some json ->
      let labels = labels_of (json_field [ "metadata" ] json) in
      if owns_labels ~service:cloud_run_service labels
      then Ok ()
      else
        Error
          (Sol_cli_cloud_run.Refused
             "Cloud Run service exists without this adapter's labels")
  in
  let release ~cloud_run_url ~revision ~image ~push_service_account =
    { project = r.project
    ; region = r.region
    ; service = r.service
    ; image
    ; cloud_run_service
    ; cloud_run_url
    ; revision
    ; topic
    ; subscription
    ; dlq_topic
    ; dlq_subscription
    ; push_service_account
    ; max_attempts = r.max_attempts
    ; ack_deadline_s = r.ack_deadline_s
    ; dlq_retention_s = r.dlq_retention_s
    ; concurrency = r.concurrency
    }
  in
  let write release =
    write_record ~path:record release
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Provider message)
  in
  let* () =
    write (release ~cloud_run_url:"" ~revision:"" ~image:r.image ~push_service_account)
  in
  let* () =
    ensure_topic
      r
      ~topic:dlq_topic
      ~service:cloud_run_service
      ~retention_s:r.dlq_retention_s
  in
  let* () =
    ensure_dlq_subscription
      r
      ~subscription:dlq_subscription
      ~topic:dlq_topic
      ~service:cloud_run_service
  in
  let* () =
    ensure_topic r ~topic ~service:cloud_run_service ~retention_s:r.dlq_retention_s
  in
  let* project_number = project_number r in
  let pubsub_agent =
    Printf.sprintf "service-%s@gcp-sa-pubsub.iam.gserviceaccount.com" project_number
  in
  (* Pub/Sub must be able to publish an exhausted task into its dead-letter topic. *)
  let* () =
    add_topic_publisher r ~topic:dlq_topic ~member:pubsub_agent
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Partial (message, None))
  in
  let* () = ensure_service_account r ~name:push_sa_name ~email:push_service_account in
  let* () = deploy_service r ~cloud_run_service in
  let* cloud_run_url, revision = service_details r ~cloud_run_service in
  let* () =
    write (release ~cloud_run_url ~revision ~image:r.image ~push_service_account)
  in
  let* () =
    add_invoker r ~cloud_run_service ~member:push_service_account
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Partial (message, None))
  in
  let* () =
    add_token_creator r ~service_account:push_service_account ~member:pubsub_agent
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Partial (message, None))
  in
  let* () =
    ensure_subscription
      r
      ~subscription
      ~topic
      ~dlq_topic
      ~push_url:cloud_run_url
      ~push_service_account
      ~service:cloud_run_service
  in
  let release = release ~cloud_run_url ~revision ~image:r.image ~push_service_account in
  let* () = write release in
  let* _ = verify r ~record in
  Ok release
;;

let enqueue (r : request) ~record ~body =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Refused message)
  in
  let* () =
    if expected.project = r.project && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           "release record does not match the target project and service")
  in
  match
    r.run
      ([ "gcloud"
       ; "pubsub"
       ; "topics"
       ; "publish"
       ; expected.topic
       ; "--message"
       ; body
       ; "--format=json"
       ; "--quiet"
       ]
       @ project_argv r)
  with
  | Error message -> Error (Sol_cli_cloud_run.Provider message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"Pub/Sub publish" output.stdout with
     | Error message -> Error (Sol_cli_cloud_run.Unknown message)
     | Ok json ->
       (match Sol_cli_json.list (json_field [ "messageIds" ] json) with
        | Some (first :: _) ->
          (match Sol_cli_json.string first with
           | Some id -> Ok id
           | None -> Error (Sol_cli_cloud_run.Unknown "message id is not a string"))
        | _ -> Error (Sol_cli_cloud_run.Unknown "Pub/Sub publish returned no messageIds")))
;;

let rollback (r : request) ~record ~revision =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Refused message)
  in
  let* () =
    if expected.project = r.project && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           "release record does not match the target project and service")
  in
  let* () =
    if String.trim revision = ""
    then Error (Sol_cli_cloud_run.Refused "rollback revision is required")
    else Ok ()
  in
  let* () =
    match
      gcloud
        r
        ([ "run"
         ; "services"
         ; "update-traffic"
         ; expected.cloud_run_service
         ; "--to-revisions=" ^ revision ^ "=100"
         ]
         @ project_argv r
         @ region_argv r)
    with
    | Ok _ -> Ok ()
    | Error message -> Error (Sol_cli_cloud_run.Partial (message, None))
  in
  let* url, _ = service_details r ~cloud_run_service:expected.cloud_run_service in
  let recorded = { expected with revision; cloud_run_url = url } in
  let* () =
    write_record ~path:record recorded
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Provider message)
  in
  let* () =
    match subscription_json r ~subscription:expected.subscription with
    | Ok (Some _) -> Ok ()
    | Ok None ->
      Error (Sol_cli_cloud_run.Unknown "task subscription is absent after rollback")
    | Error failure -> Error failure
  in
  Ok recorded
;;

let delete_topic (r : request) ~topic =
  match gcloud r ([ "pubsub"; "topics"; "delete"; topic ] @ project_argv r) with
  | Ok _ -> Ok ()
  | Error message ->
    if missing message then Ok () else Error (Sol_cli_cloud_run.Partial (message, None))
;;

let destroy (r : request) ~record =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message -> Sol_cli_cloud_run.Refused message)
  in
  let* () =
    if
      expected.project = r.project
      && expected.region = r.region
      && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_cloud_run.Refused
           "release record does not match the target project, region, and service")
  in
  (* Ownership before mutation. *)
  let* service = service_json r ~cloud_run_service:expected.cloud_run_service in
  let* service_owned =
    match service with
    | None -> Ok false
    | Some json ->
      let labels = labels_of (json_field [ "metadata" ] json) in
      if owns_labels ~service:expected.cloud_run_service labels
      then Ok true
      else
        Error (Sol_cli_cloud_run.Refused "Cloud Run service lacks this adapter's labels")
  in
  let* subscription = subscription_json r ~subscription:expected.subscription in
  let* subscription_owned =
    match subscription with
    | None -> Ok false
    | Some json ->
      let labels = labels_of json in
      if owns_labels ~service:expected.cloud_run_service labels
      then Ok true
      else
        Error (Sol_cli_cloud_run.Refused "task subscription lacks this adapter's labels")
  in
  let* dlq_subscription = subscription_json r ~subscription:expected.dlq_subscription in
  let* dlq_subscription_owned =
    match dlq_subscription with
    | None -> Ok false
    | Some json ->
      let labels = labels_of json in
      if owns_labels ~service:expected.cloud_run_service labels
      then Ok true
      else
        Error
          (Sol_cli_cloud_run.Refused
             "dead-letter subscription lacks this adapter's labels")
  in
  let* topic = topic_json r ~topic:expected.topic in
  let* topic_owned =
    match topic with
    | None -> Ok false
    | Some json ->
      let labels = labels_of json in
      if owns_labels ~service:expected.cloud_run_service labels
      then Ok true
      else Error (Sol_cli_cloud_run.Refused "task topic lacks this adapter's labels")
  in
  let* dlq_topic = topic_json r ~topic:expected.dlq_topic in
  let* dlq_owned =
    match dlq_topic with
    | None -> Ok false
    | Some json ->
      let labels = labels_of json in
      if owns_labels ~service:expected.cloud_run_service labels
      then Ok true
      else Error (Sol_cli_cloud_run.Refused "task DLQ topic lacks this adapter's labels")
  in
  let* () =
    if subscription_owned
    then (
      match
        gcloud
          r
          ([ "pubsub"; "subscriptions"; "delete"; expected.subscription ] @ project_argv r)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else Ok ()
  in
  let* () =
    if dlq_subscription_owned
    then (
      match
        gcloud
          r
          ([ "pubsub"; "subscriptions"; "delete"; expected.dlq_subscription ]
           @ project_argv r)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else Ok ()
  in
  let* () =
    if service_owned
    then (
      match
        remove_invoker
          r
          ~cloud_run_service:expected.cloud_run_service
          ~member:expected.push_service_account
      with
      | Ok _ -> Ok ()
      | Error message ->
        if missing message
        then Ok ()
        else Error (Sol_cli_cloud_run.Partial (message, None)))
    else Ok ()
  in
  let* () =
    if service_owned
    then (
      match
        gcloud
          r
          ([ "run"; "services"; "delete"; expected.cloud_run_service ]
           @ project_argv r
           @ region_argv r)
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
    else Ok ()
  in
  let* sa = service_account_json r ~email:expected.push_service_account in
  let* () =
    match sa with
    | None -> Ok ()
    | Some json ->
      let description =
        Sol_cli_json.string (json_field [ "description" ] json)
        |> Option.value ~default:""
      in
      if description <> ownership_description
      then
        Error
          (Sol_cli_cloud_run.Refused
             "push service account lacks this adapter's description")
      else
        let* project_number = project_number r in
        let pubsub_agent =
          Printf.sprintf "service-%s@gcp-sa-pubsub.iam.gserviceaccount.com" project_number
        in
        let* () =
          match
            remove_token_creator
              r
              ~service_account:expected.push_service_account
              ~member:pubsub_agent
          with
          | Ok _ -> Ok ()
          | Error message ->
            if missing message
            then Ok ()
            else Error (Sol_cli_cloud_run.Partial (message, None))
        in
        (match
           gcloud
             r
             ([ "iam"; "service-accounts"; "delete"; expected.push_service_account ]
              @ project_argv r)
         with
         | Ok _ -> Ok ()
         | Error message -> Error (Sol_cli_cloud_run.Partial (message, None)))
  in
  let* () = if topic_owned then delete_topic r ~topic:expected.topic else Ok () in
  let* () = if dlq_owned then delete_topic r ~topic:expected.dlq_topic else Ok () in
  (* Independent absence. The push identity is a created resource too: a delete
     success is not proof that the IAM account is gone. *)
  let* () =
    match service_account_json r ~email:expected.push_service_account with
    | Ok None -> Ok ()
    | Ok (Some _) ->
      Error (Sol_cli_cloud_run.Unknown "push service account remains after delete")
    | Error failure -> Error failure
  in
  let* () =
    match service_json r ~cloud_run_service:expected.cloud_run_service with
    | Ok None -> Ok ()
    | Ok (Some _) ->
      Error (Sol_cli_cloud_run.Unknown "Cloud Run service remains after delete")
    | Error failure -> Error failure
  in
  let* () =
    match subscription_json r ~subscription:expected.subscription with
    | Ok None -> Ok ()
    | Ok (Some _) ->
      Error (Sol_cli_cloud_run.Unknown "task subscription remains after delete")
    | Error failure -> Error failure
  in
  let* () =
    match subscription_json r ~subscription:expected.dlq_subscription with
    | Ok None -> Ok ()
    | Ok (Some _) ->
      Error (Sol_cli_cloud_run.Unknown "dead-letter subscription remains after delete")
    | Error failure -> Error failure
  in
  let* () =
    match topic_json r ~topic:expected.topic with
    | Ok None -> Ok ()
    | Ok (Some _) -> Error (Sol_cli_cloud_run.Unknown "task topic remains after delete")
    | Error failure -> Error failure
  in
  match topic_json r ~topic:expected.dlq_topic with
  | Ok None -> Ok ()
  | Ok (Some _) -> Error (Sol_cli_cloud_run.Unknown "task DLQ topic remains after delete")
  | Error failure -> Error failure
;;
