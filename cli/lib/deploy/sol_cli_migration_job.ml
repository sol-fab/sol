open Result.Syntax

type job =
  { namespace : string
  ; job_name : string
  ; configmap_name : string option
  }

type outcome =
  | Succeeded
  | Failed
  | Unstartable of
      { reason : string
      ; detail : string option
      }
  | Timed_out of float

let kubectl ~ctx ?(timeout_s = 30.) args = Sol_cli_kubectl.run ~timeout_s ~ctx args

(* A target's environment and target layers select which services it deploys,
   through `services` and `omit` (DEC-047). Migrations are a workspace-level
   artifact, but the one-shot migration Job must run in a namespace the target
   actually deploys into: a service the target omits is not part of that target,
   so its namespace cannot host the Job. Restricting here keeps the standalone
   `sol migrate apply <target>` namespace selection consistent with the deploy
   path, which plans over its own target-scoped inventory. *)
let services_of_target ~(all : Sol_cli_manifest.service list) ~(active : string list) =
  List.filter (fun (s : Sol_cli_manifest.service) -> List.mem s.name active) all
;;

(** The namespace a **local** migration read runs in.

    Local has no target and no class Secrets: the workspace runtime Secret (`sol-secrets`) is
    written by the local deploy into the workload namespaces and mounted per namespace, so a
    workload namespace can read migration state. This picks one by a rule the local flows agree
    on.

    It is inventory-derived **on purpose** -- there is no target identity to derive from
    locally -- and that is safe because the local deploy is unscoped, so every candidate
    namespace holds the credential. A target never uses this: its namespace comes from the
    database identity (#1424).

    A workspace with no service has no namespace holding the credential, so this fails with that
    reason rather than naming a namespace that would report a missing Secret instead. The
    namespace-name error is propagated, not swallowed. *)
let local_namespace ~workspace ~(services : Sol_cli_manifest.service list)
  : (string, string) result
  =
  let by_domain_and_name (a : Sol_cli_manifest.service) (b : Sol_cli_manifest.service) =
    compare (a.domain, a.name) (b.domain, b.name)
  in
  match List.sort by_domain_and_name services with
  | [] ->
    Error
      "no deployed service found in this workspace -- nothing to run the migration Job \
       in. Deploy at least one service first."
  | (first : Sol_cli_manifest.service) :: _ ->
    Sol_cli_deployment_plan.namespace_name ~workspace ~domain:first.domain
;;

let runner_image () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  let* image = Sol_cli_platform_assets.migration_runner_image assets in
  Sol_cli_report.app "Using migration runner %s" image;
  Ok image
;;

let apply_doc ~ctx ~what doc =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-migrate-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ doc ])
    (fun file ->
       Sol_cli_kubectl.apply ~ctx ~file
       |> Result.map_error (fun e ->
         Printf.sprintf "kubectl apply (%s): %s" what (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

(* This is the API submission response, not a later lookup of a potentially
   replaced Job. Qualification separately observes its content and exact UID. *)
let submitted_uid ~namespace ~name text =
  let module J = Sol_cli_json in
  let* json = J.decode ~what:"submitted migration Job" text in
  let* json = Sol_cli_database_contract_data.canonical json in
  let* uid = J.require ~what:"submitted Job" [ "metadata"; "uid" ] J.string json in
  if
    J.field [ "apiVersion" ] json <> `String "batch/v1"
    || J.field [ "kind" ] json <> `String "Job"
    || J.field [ "metadata"; "namespace" ] json <> `String namespace
    || J.field [ "metadata"; "name" ] json <> `String name
    || String.trim uid = ""
  then Error "unestablished submitted migration Job identity"
  else Ok uid
;;

let notify_execution message =
  Sol_cli_migration_execution.notify message
  |> Result.iter_error (fun _ ->
    Sol_cli_report.warn
      "Migration execution capture is unestablished; continuing normal Job wait and \
       cleanup.")
;;

let record_submission ~ctx ~target ~binding ~before job output =
  let receipt =
    let* before =
      before |> Result.map_error (fun _ -> "unestablished submission identity")
    in
    let* uid = submitted_uid ~namespace:job.namespace ~name:job.job_name output in
    let* after =
      Sol_cli_kube_identity.observe ~ctx
      |> Result.map_error (fun _ -> "unestablished submission identity")
    in
    if not (Sol_cli_kube_identity.same before after)
    then Error "submission authority changed"
    else
      Ok
        Sol_cli_migration_execution.
          { binding
          ; target
          ; namespace = job.namespace
          ; name = job.job_name
          ; uid
          ; principal = after.principal
          ; cluster = after.cluster
          ; endpoint = after.endpoint
          ; observed_at = int_of_float (Unix.gettimeofday ())
          }
  in
  notify_execution
    (match receipt with
     | Ok receipt -> Sol_cli_migration_execution.Execution receipt
     | Error _ -> Unavailable)
;;

let cleanup ~ctx job =
  let delete resource name =
    kubectl
      ~ctx
      [ "delete"
      ; resource
      ; name
      ; "-n"
      ; job.namespace
      ; "--ignore-not-found"
      ; "--wait=false"
      ]
    |> Result.iter_error (fun e ->
      Sol_cli_report.warn
        "warning: could not clean up after the Job: %s"
        (Sol_cli_process.error_to_string e))
  in
  delete "job" job.job_name;
  Option.iter (fun name -> delete "configmap" name) job.configmap_name
;;

let submit_doc ~ctx ~namespace ~name_prefix ~label build_doc =
  let run_id = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
  let job =
    { namespace
    ; job_name = Printf.sprintf "%s-%s" name_prefix run_id
    ; configmap_name = None
    }
  in
  match apply_doc ~ctx ~what:(label ^ " job") (build_doc ~name:job.job_name) with
  | Ok () -> Ok job
  | Error _ as e ->
    cleanup ~ctx job;
    e
;;

let submit
      ~ctx
      ~namespace
      ~name_prefix
      ~label
      ~image
      ~args
      ~files
      ~ddl_creds_name
      ?ca_configmap
      ?execution_target
      ()
  =
  let run_id = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
  let configmap_name = Printf.sprintf "%s-files-%s" name_prefix run_id in
  let job =
    { namespace
    ; job_name = Printf.sprintf "%s-%s" name_prefix run_id
    ; configmap_name = Some configmap_name
    }
  in
  let* () =
    apply_doc
      ~ctx
      ~what:(label ^ "configmap")
      (Sol_cli_manifest.migration_configmap_doc ~name:configmap_name ~namespace files)
  in
  let document =
    Sol_cli_manifest.migration_job_doc
      ~name:job.job_name
      ~namespace
      ~image
      ~args
      ~configmap_name
      ~ddl_creds_name
      ?ca_configmap
      ()
  in
  let apply =
    match execution_target, Sol_cli_migration_execution.requested () with
    | Some target, Some binding ->
      let before = Sol_cli_kube_identity.observe ~ctx in
      let result =
        Sol_cli_fs.with_temp_file
          ~prefix:"sol-migrate-"
          ~suffix:".yaml"
          (Sol_cli_yaml.render [ document ])
          (fun file -> Sol_cli_kubectl.run ~ctx [ "apply"; "-f"; file; "-o"; "json" ])
      in
      (match result with
       | Ok (Ok output) ->
         record_submission ~ctx ~target ~binding ~before job output.stdout;
         Ok ()
       | Ok (Error error) ->
         notify_execution Unavailable;
         Error (Sol_cli_process.error_to_string error)
       | Error error ->
         notify_execution Unavailable;
         Error error)
    | _ -> apply_doc ~ctx ~what:(label ^ "job") document
  in
  match apply with
  | Ok () -> Ok job
  | Error _ as e ->
    cleanup ~ctx job;
    e
;;

let waiting_status ~ctx job =
  let jsonpath =
    "jsonpath={range \
     .items[*]}{.status.containerStatuses[*].state.waiting.reason}\"|\"{.status.containerStatuses[*].state.waiting.message}{\"\\n\"}{end}"
  in
  match
    kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"
      ; "pods"
      ; "-n"
      ; job.namespace
      ; "-l"
      ; "job-name=" ^ job.job_name
      ; "-o"
      ; jsonpath
      ]
  with
  | Ok r ->
    (match String.split_on_char '|' r.stdout with
     | reason :: rest ->
       Sol_cli_string.non_blank reason
       |> Option.map (fun reason ->
         reason, Sol_cli_string.non_blank (String.concat "|" rest))
     | [] -> None)
  | Error _ -> None
;;

let terminal_waiting_reasons =
  [ "CreateContainerConfigError"
  ; "CreateContainerError"
  ; "InvalidImageName"
  ; "ErrImagePull"
  ; "ImagePullBackOff"
  ; "RunContainerError"
  ; "CrashLoopBackOff"
  ]
;;

let job_field ~ctx job field =
  match
    kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"
      ; "job"
      ; job.job_name
      ; "-n"
      ; job.namespace
      ; "-o"
      ; Printf.sprintf "jsonpath={.status.%s}" field
      ]
  with
  | Ok r -> String.trim r.stdout
  | Error _ -> ""
;;

let wait ~ctx ~interval_s ~attempts job =
  let failed () =
    match job_field ~ctx job "failed" with
    | "" | "0" -> false
    | _ -> true
  in
  let rec poll n =
    if n = 0
    then Timed_out (interval_s *. float_of_int attempts)
    else if job_field ~ctx job "succeeded" = "1"
    then Succeeded
    else if failed ()
    then Failed
    else (
      match waiting_status ~ctx job with
      | Some (reason, detail) when List.mem reason terminal_waiting_reasons ->
        Unstartable { reason; detail }
      | _ ->
        Unix.sleepf interval_s;
        poll (n - 1))
  in
  poll attempts
;;

let logs ~ctx job =
  kubectl ~ctx [ "logs"; "job/" ^ job.job_name; "-n"; job.namespace ]
  |> Result.map (fun (r : Sol_cli_process.output) -> r.stdout)
  |> Result.map_error Sol_cli_process.error_to_string
;;

let evidence ~ctx job =
  let logs =
    match
      kubectl
        ~ctx
        ~timeout_s:20.
        [ "logs"; "job/" ^ job.job_name; "-n"; job.namespace; "--tail=200" ]
    with
    | Ok r -> Sol_cli_string.non_blank r.stdout
    | Error (Sol_cli_process.Non_zero r) ->
      Some ("(kubectl logs failed: " ^ Sol_cli_process.failure_message r ^ ")")
    | Error _ -> None
  in
  Sol_cli_migration.evidence_report ~waiting:(waiting_status ~ctx job) ~logs
;;
