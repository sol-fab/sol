open Result.Syntax

(* Cloud Run Jobs is the GCP run-to-completion backend. It has no Lambda-style
   version/alias pointer: each execution is a separate immutable resource, and a
   rollback patches the job template back to an earlier execution's image and
   starts a new execution. The release record carries the job and execution
   identities needed for destroy and rollback. *)

let ownership_tag = "cloud-run-job-experiment"
let task_timeout_s = 600

type request =
  { project : string
  ; region : string
  ; service : string
  ; job : string
  ; image : string
  ; record : string
  ; runner : Sol_cli_cloud_run.runner
  }

type release =
  { project : string
  ; region : string
  ; service : string
  ; job : string
  ; image : string
  ; generation : int
  ; execution : string
  ; task_timeout_s : int
  }

type failure = Sol_cli_cloud_run.failure =
  | Refused of string
  | Provider of string
  | Partial of string * Sol_cli_cloud_run.observed option
  | Unknown of string

let failure_to_string = Sol_cli_cloud_run.failure_to_string

let release_json (r : release) =
  `Assoc
    [ "kind", `String "fn"
    ; "provider", `String "gcp"
    ; "project", `String r.project
    ; "region", `String r.region
    ; "service", `String r.service
    ; "job", `String r.job
    ; "image", `String r.image
    ; "generation", `Int r.generation
    ; "execution", `String r.execution
    ; "task_timeout_s", `Int r.task_timeout_s
    ]
;;

let read_record path =
  try
    let json = Yojson.Safe.from_file path in
    let string name =
      match Sol_cli_json.field [ name ] json with
      | `String value when value <> "" -> Ok value
      | _ -> Error (Printf.sprintf "release record has no %s" name)
    in
    let int_or_zero name =
      match Sol_cli_json.field [ name ] json with
      | `Int value -> value
      | _ -> 0
    in
    let* kind = string "kind" in
    let* provider = string "provider" in
    let* () =
      if kind = "fn" && provider = "gcp"
      then Ok ()
      else Error "release record is not a GCP Cloud Run Job release"
    in
    let+ project = string "project"
    and+ region = string "region"
    and+ service = string "service"
    and+ job = string "job"
    and+ image = string "image"
    and+ execution = string "execution" in
    { project
    ; region
    ; service
    ; job
    ; image
    ; generation = int_or_zero "generation"
    ; execution
    ; task_timeout_s = int_or_zero "task_timeout_s"
    }
  with
  | Sys_error message -> Error message
  | Yojson.Json_error message -> Error ("release record is not JSON: " ^ message)
;;

let write_record ~path (r : release) =
  Sol_cli_fs.write_atomic ~perm:0o600 path (Yojson.Safe.to_string (release_json r) ^ "\n")
  |> Result.map_error (fun message -> "could not write release record: " ^ message)
;;

let valid_image image =
  if Sol_cli_image_ref.is_digest image
  then Ok image
  else
    Error
      (Refused
         "image must be an immutable <repo>@sha256:<64 lowercase hexadecimal digits> \
          reference")
;;

let gcloud r args = r.Sol_cli_cloud_run.run ("gcloud" :: args)
let output_json ~what output = Sol_cli_json.decode ~what output.Sol_cli_cloud_run.stdout
let lower s = String.lowercase_ascii s

let is_not_found message =
  let message = lower message in
  let contains needle =
    let n = String.length needle in
    let m = String.length message in
    let rec go i = i + n <= m && (String.sub message i n = needle || go (i + 1)) in
    go 0
  in
  contains "not found" || contains "not_found" || contains "cannot find" || contains "404"
;;

let not_found message = is_not_found message

let json_string path json =
  match Sol_cli_json.field path json with
  | `String value -> Some value
  | _ -> None
;;

let json_int path json =
  match Sol_cli_json.field path json with
  | `Int value -> Some value
  | _ -> None
;;

let labels_of_job json =
  match Sol_cli_json.field [ "metadata"; "labels" ] json with
  | `Assoc labels ->
    List.filter_map
      (function
        | key, `String value -> Some (key, value)
        | _ -> None)
      labels
  | _ -> []
;;

let owns ~job labels =
  List.assoc_opt "sol-owned" labels = Some ownership_tag
  && List.assoc_opt "sol-service" labels = Some job
;;

let describe_job (r : request) ~job =
  match
    gcloud
      r.runner
      [ "run"
      ; "jobs"
      ; "describe"
      ; job
      ; "--project"
      ; r.project
      ; "--region"
      ; r.region
      ; "--format=json"
      ]
  with
  | Error message when not_found message -> Ok None
  | Error message -> Error (Unknown ("could not describe Cloud Run job: " ^ message))
  | Ok output ->
    (match output_json ~what:"Cloud Run job" output with
     | Error message -> Error (Unknown message)
     | Ok json -> Ok (Some json))
;;

let job_generation json =
  match json_int [ "metadata"; "generation" ] json with
  | Some generation -> generation
  | None ->
    (match json_string [ "metadata"; "generation" ] json with
     | Some value -> Option.value (int_of_string_opt value) ~default:0
     | None -> 0)
;;

let deploy_argv (r : request) ~job ~image =
  [ "run"
  ; "jobs"
  ; "deploy"
  ; job
  ; "--image"
  ; image
  ; "--project"
  ; r.project
  ; "--region"
  ; r.region
  ; "--labels"
  ; "sol-owned=cloud-run-job-experiment,sol-service=" ^ job
  ; "--max-retries"
  ; "0"
  ; "--tasks"
  ; "1"
  ; "--parallelism"
  ; "1"
  ; "--task-timeout"
  ; "600s"
  ; "--quiet"
  ]
;;

let execute_argv (r : request) ~job =
  [ "run"
  ; "jobs"
  ; "execute"
  ; job
  ; "--project"
  ; r.project
  ; "--region"
  ; r.region
  ; "--wait"
  ; "--format=json"
  ]
;;

let latest_execution (r : request) ~job =
  match
    gcloud
      r.runner
      [ "run"
      ; "jobs"
      ; "executions"
      ; "list"
      ; "--job"
      ; job
      ; "--project"
      ; r.project
      ; "--region"
      ; r.region
      ; "--limit"
      ; "1"
      ; "--sort-by=~metadata.creationTimestamp"
      ; "--format=json"
      ]
  with
  | Error message ->
    Error (Unknown ("could not list Cloud Run job executions: " ^ message))
  | Ok output ->
    (match output_json ~what:"Cloud Run job executions" output with
     | Error message -> Error (Unknown message)
     | Ok (`List (first :: _)) ->
       (match json_string [ "metadata"; "name" ] first with
        | Some name -> Ok name
        | None -> Error (Unknown "Cloud Run job execution has no name"))
     | Ok (`List []) -> Error (Unknown "Cloud Run job produced no execution")
     | Ok _ -> Error (Unknown "Cloud Run job executions list is not an array"))
;;

let describe_execution (r : request) ~execution =
  match
    gcloud
      r.runner
      [ "run"
      ; "jobs"
      ; "executions"
      ; "describe"
      ; execution
      ; "--project"
      ; r.project
      ; "--region"
      ; r.region
      ; "--format=json"
      ]
  with
  | Error message ->
    Error (Unknown ("could not describe Cloud Run job execution: " ^ message))
  | Ok output ->
    (match output_json ~what:"Cloud Run job execution" output with
     | Error message -> Error (Unknown message)
     | Ok json -> Ok json)
;;

let execution_image json =
  let candidates =
    [ [ "spec"; "template"; "containers"; "0"; "image" ]
    ; [ "template"; "containers"; "0"; "image" ]
    ; [ "spec"; "template"; "containers"; "image" ]
    ; [ "template"; "containers"; "image" ]
    ]
  in
  let rec first = function
    | [] -> None
    | path :: rest ->
      (match json_string path json with
       | Some image -> Some image
       | None -> first rest)
  in
  (* A JSON array path cannot be represented by [Sol_cli_json.field]; inspect the
     containers list directly for the common shape. *)
  let containers =
    [ [ "spec"; "template"; "spec"; "containers" ]
    ; [ "spec"; "template"; "containers" ]
    ; [ "template"; "containers" ]
    ]
    |> List.find_map (fun path ->
      match Sol_cli_json.field path json with
      | `List (first :: _) ->
        (match Sol_cli_json.field [ "image" ] first with
         | `String image -> Some image
         | _ -> None)
      | _ -> None)
  in
  match containers with
  | Some image -> Some image
  | None -> first candidates
;;

let execution_succeeded json =
  let failed = Option.value (json_int [ "status"; "failedCount" ] json) ~default:0 in
  let cancelled =
    Option.value (json_int [ "status"; "cancelledCount" ] json) ~default:0
  in
  let succeeded =
    Option.value (json_int [ "status"; "succeededCount" ] json) ~default:0
  in
  if failed > 0 || cancelled > 0
  then false
  else if succeeded > 0
  then true
  else (
    match Sol_cli_json.field [ "status"; "conditions" ] json with
    | `List conditions ->
      List.exists
        (fun condition ->
           json_string [ "type" ] condition = Some "Completed"
           && json_string [ "status" ] condition = Some "True")
        conditions
    | _ -> false)
;;

let execution_job json =
  match json_string [ "job" ] json with
  | Some job -> Some job
  | None ->
    (match json_string [ "metadata"; "labels"; "run.googleapis.com/job" ] json with
     | Some job -> Some job
     | None -> None)
;;

let update_record r ~job ~image ~generation ~execution =
  write_record
    ~path:r.record
    { project = r.project
    ; region = r.region
    ; service = r.service
    ; job
    ; image
    ; generation
    ; execution
    ; task_timeout_s
    }
;;

let execute ~(r : request) ~job ~image ~generation =
  match gcloud r.runner (execute_argv r ~job) with
  | Error message ->
    let* () =
      update_record r ~job ~image ~generation ~execution:""
      |> Result.map_error (fun message -> Unknown message)
    in
    Error (Provider ("could not execute Cloud Run job: " ^ message))
  | Ok _ ->
    (* [gcloud run jobs execute --wait --format=json] can print an operation or an
       execution depending on the provider version. The execution list is the stable
       observation, so use it rather than interpreting the command's shape. *)
    let execution = latest_execution r ~job in
    let* execution =
      match execution with
      | Ok execution -> Ok execution
      | Error failure ->
        let* () =
          update_record r ~job ~image ~generation ~execution:""
          |> Result.map_error (fun message -> Unknown message)
        in
        Error failure
    in
    let* observed =
      match describe_execution r ~execution with
      | Error failure -> Error failure
      | Ok json -> Ok json
    in
    let* () =
      update_record r ~job ~image ~generation ~execution
      |> Result.map_error (fun message -> Unknown message)
    in
    let* () =
      if execution_succeeded observed
      then Ok ()
      else Error (Provider "Cloud Run job execution did not succeed")
    in
    Ok execution
;;

let deploy (r : request) =
  let* () =
    if String.trim r.project = ""
    then Error (Refused "project must not be empty")
    else Ok ()
  in
  let* () =
    if String.trim r.region = ""
    then Error (Refused "region must not be empty")
    else Ok ()
  in
  let* () =
    if String.trim r.job = ""
    then Error (Refused "Cloud Run job name must not be empty")
    else Ok ()
  in
  let* _ = valid_image r.image in
  let* existing =
    match describe_job r ~job:r.job with
    | Ok existing -> Ok existing
    | Error failure -> Error failure
  in
  let* () =
    match existing with
    | None -> Ok ()
    | Some json ->
      if owns ~job:r.job (labels_of_job json)
      then Ok ()
      else
        Error
          (Refused
             "Cloud Run job exists without this adapter's ownership labels; refusing to \
              adopt it")
  in
  (* Record the intended resource before mutation: a partially created job or a
     failed execution must remain destroyable. *)
  let* () =
    update_record r ~job:r.job ~image:r.image ~generation:0 ~execution:""
    |> Result.map_error (fun message -> Unknown message)
  in
  let* () =
    match gcloud r.runner (deploy_argv r ~job:r.job ~image:r.image) with
    | Ok _ -> Ok ()
    | Error message -> Error (Provider ("could not deploy Cloud Run job: " ^ message))
  in
  let* job_json =
    match describe_job r ~job:r.job with
    | Ok (Some json) -> Ok json
    | Ok None -> Error (Unknown "Cloud Run job is absent after deploy")
    | Error failure -> Error failure
  in
  let generation = job_generation job_json in
  let* () =
    update_record r ~job:r.job ~image:r.image ~generation ~execution:""
    |> Result.map_error (fun message -> Unknown message)
  in
  let* execution = execute ~r ~job:r.job ~image:r.image ~generation in
  Ok
    { project = r.project
    ; region = r.region
    ; service = r.service
    ; job = r.job
    ; image = r.image
    ; generation
    ; execution
    ; task_timeout_s
    }
;;

let rollback (r : request) ~record ~execution =
  let* recorded =
    read_record record |> Result.map_error (fun message -> Refused message)
  in
  let* () =
    if
      recorded.project = r.project
      && recorded.region = r.region
      && recorded.service = r.service
      && recorded.job = r.job
    then Ok ()
    else
      Error
        (Refused
           "release record does not match the target project, region, service, and Cloud \
            Run job")
  in
  let* target =
    describe_execution r ~execution
    |> Result.map_error (function
      | Unknown message -> Refused ("could not read the rollback execution: " ^ message)
      | other -> other)
  in
  let* () =
    match execution_job target with
    | Some job when String.equal job r.job || String.ends_with ~suffix:("/" ^ r.job) job
      -> Ok ()
    | Some _ -> Error (Refused "rollback execution belongs to a different Cloud Run job")
    | None -> Ok ()
  in
  let* existing =
    describe_job r ~job:r.job
    |> Result.map_error (function
      | Unknown message -> Refused ("could not read the live Cloud Run job: " ^ message)
      | other -> other)
  in
  let* () =
    match existing with
    | None -> Error (Refused "Cloud Run job is absent during rollback")
    | Some json ->
      if owns ~job:r.job (labels_of_job json)
      then Ok ()
      else
        Error
          (Refused
             "live Cloud Run job lacks this adapter's ownership labels; refusing to \
              redeploy an unverified job")
  in
  let* image =
    match execution_image target with
    | Some image -> valid_image image
    | None -> Error (Refused "rollback execution does not record a container image")
  in
  let* () =
    update_record r ~job:r.job ~image ~generation:recorded.generation ~execution:""
    |> Result.map_error (fun message -> Unknown message)
  in
  let* () =
    match gcloud r.runner (deploy_argv r ~job:r.job ~image) with
    | Ok _ -> Ok ()
    | Error message -> Error (Provider ("could not roll back Cloud Run job: " ^ message))
  in
  let* job_json =
    match describe_job r ~job:r.job with
    | Ok (Some json) -> Ok json
    | Ok None -> Error (Unknown "Cloud Run job is absent after rollback")
    | Error failure -> Error failure
  in
  let generation = job_generation job_json in
  let* execution = execute ~r ~job:r.job ~image ~generation in
  Ok
    { project = r.project
    ; region = r.region
    ; service = r.service
    ; job = r.job
    ; image
    ; generation
    ; execution
    ; task_timeout_s
    }
;;

let list_executions (r : request) ~job =
  match
    gcloud
      r.runner
      [ "run"
      ; "jobs"
      ; "executions"
      ; "list"
      ; "--job"
      ; job
      ; "--project"
      ; r.project
      ; "--region"
      ; r.region
      ; "--format=json"
      ]
  with
  | Error message when not_found message -> Ok []
  | Error message ->
    Error (Unknown ("could not list Cloud Run job executions: " ^ message))
  | Ok output ->
    (match output_json ~what:"Cloud Run job executions" output with
     | Error message -> Error (Unknown message)
     | Ok (`List items) ->
       Ok
         (List.filter_map
            (fun item ->
               match json_string [ "metadata"; "name" ] item with
               | Some name -> Some name
               | None -> None)
            items)
     | Ok _ -> Error (Unknown "Cloud Run job executions list is not an array"))
;;

let execution_id name =
  match List.rev (String.split_on_char '/' name) with
  | id :: _ -> id
  | [] -> name
;;

let destroy (r : request) ~record =
  let* recorded =
    read_record record |> Result.map_error (fun message -> Refused message)
  in
  let* () =
    if
      recorded.project = r.project
      && recorded.region = r.region
      && recorded.service = r.service
      && recorded.job = r.job
    then Ok ()
    else
      Error
        (Refused
           "release record does not match the target project, region, service, and Cloud \
            Run job")
  in
  let* existing = describe_job r ~job:r.job in
  let* () =
    match existing with
    | None -> Ok ()
    | Some json ->
      if owns ~job:r.job (labels_of_job json)
      then Ok ()
      else
        Error
          (Refused
             "Cloud Run job exists without this adapter's ownership labels; refusing to \
              delete it")
  in
  let* executions = list_executions r ~job:r.job in
  let rec delete_executions = function
    | [] -> Ok ()
    | execution :: rest ->
      (match
         gcloud
           r.runner
           [ "run"
           ; "jobs"
           ; "executions"
           ; "delete"
           ; execution_id execution
           ; "--project"
           ; r.project
           ; "--region"
           ; r.region
           ; "--quiet"
           ]
       with
       | Ok _ -> delete_executions rest
       | Error message when not_found message -> delete_executions rest
       | Error message ->
         Error
           (Provider
              ("could not delete Cloud Run job execution " ^ execution ^ ": " ^ message)))
  in
  let* () = delete_executions executions in
  let* () =
    match
      gcloud
        r.runner
        [ "run"
        ; "jobs"
        ; "delete"
        ; r.job
        ; "--project"
        ; r.project
        ; "--region"
        ; r.region
        ; "--quiet"
        ]
    with
    | Ok _ -> Ok ()
    | Error message when not_found message -> Ok ()
    | Error message -> Error (Provider ("could not delete Cloud Run job: " ^ message))
  in
  let* remaining_jobs =
    match
      gcloud
        r.runner
        [ "run"
        ; "jobs"
        ; "list"
        ; "--project"
        ; r.project
        ; "--region"
        ; r.region
        ; "--format=json"
        ]
    with
    | Error message -> Error (Unknown ("could not verify Cloud Run jobs: " ^ message))
    | Ok output ->
      (match output_json ~what:"Cloud Run jobs" output with
       | Error message -> Error (Unknown message)
       | Ok (`List items) ->
         Ok
           (List.filter_map
              (fun item ->
                 match json_string [ "metadata"; "name" ] item with
                 | Some name -> Some (execution_id name)
                 | None -> None)
              items)
       | Ok _ -> Error (Unknown "Cloud Run jobs list is not an array"))
  in
  let* () =
    if List.mem r.job remaining_jobs
    then Error (Provider "Cloud Run job still exists after delete")
    else Ok ()
  in
  let* remaining_executions = list_executions r ~job:r.job in
  let* () =
    if remaining_executions = []
    then Ok ()
    else Error (Provider "Cloud Run job executions still exist after delete")
  in
  Ok ()
;;
