type container_state =
  | Waiting of
      { reason : string
      ; message : string option
      }
  | Running
  | Terminated of
      { reason : string
      ; exit_code : int
      ; message : string option
      }
  | Unknown_state

type pod_status =
  { name : string
  ; phase : string
  ; ready : bool
  ; restarts : int
  ; image : string option
  ; state : container_state
  ; last_terminated_reason : string option
  }

type event =
  { ev_type : string
  ; reason : string
  ; message : string
  ; count : int
  ; last_timestamp : string option
  ; involved_name : string
  }

let field = Sol_cli_json.field
let string_field path j = field path j |> Sol_cli_json.string

let parse_container_state (c : Yojson.Safe.t) : container_state =
  let reason j = string_field [ "reason" ] j |> Option.value ~default:"Unknown" in
  let message j = string_field [ "message" ] j in
  match field [ "state"; "waiting" ] c, field [ "state"; "running" ] c with
  | (`Assoc _ as w), _ -> Waiting { reason = reason w; message = message w }
  | _, `Assoc _ -> Running
  | _ ->
    (match field [ "state"; "terminated" ] c with
     | `Assoc _ as t ->
       let exit_code =
         field [ "exitCode" ] t |> Sol_cli_json.int |> Option.value ~default:0
       in
       Terminated { reason = reason t; exit_code; message = message t }
     | _ -> Unknown_state)
;;

let parse_last_terminated_reason (c : Yojson.Safe.t) : string option =
  string_field [ "lastState"; "terminated"; "reason" ] c
;;

let parse_pod (item : Yojson.Safe.t) : pod_status =
  let name =
    string_field [ "metadata"; "name" ] item |> Option.value ~default:"unknown"
  in
  let phase =
    string_field [ "status"; "phase" ] item |> Option.value ~default:"Unknown"
  in
  match field [ "status"; "containerStatuses" ] item with
  | `List (c :: _) ->
    { name
    ; phase
    ; ready = field [ "ready" ] c |> Sol_cli_json.bool |> Option.value ~default:false
    ; restarts = field [ "restartCount" ] c |> Sol_cli_json.int |> Option.value ~default:0
    ; image = string_field [ "image" ] c
    ; state = parse_container_state c
    ; last_terminated_reason = parse_last_terminated_reason c
    }
  | _ ->
    { name
    ; phase
    ; ready = false
    ; restarts = 0
    ; image = None
    ; state = Unknown_state
    ; last_terminated_reason = None
    }
;;

type confirmed_pods = Confirmed of pod_status list

let pod_list (Confirmed pods) = pods

let parse_pods_json (s : string) : (confirmed_pods, string) result =
  Sol_cli_json.items ~what:"pods" s
  |> Result.map (fun items -> Confirmed (List.map parse_pod items))
;;

let parse_event (item : Yojson.Safe.t) : event =
  { ev_type = string_field [ "type" ] item |> Option.value ~default:"Normal"
  ; reason = string_field [ "reason" ] item |> Option.value ~default:""
  ; message = string_field [ "message" ] item |> Option.value ~default:""
  ; count = field [ "count" ] item |> Sol_cli_json.int |> Option.value ~default:1
  ; last_timestamp = string_field [ "lastTimestamp" ] item
  ; involved_name =
      string_field [ "involvedObject"; "name" ] item |> Option.value ~default:""
  }
;;

let parse_events_json (s : string) : (event list, string) result =
  Sol_cli_json.items ~what:"events" s |> Result.map (List.map parse_event)
;;

let events_for_pod ?(limit = 5) ~pod_name (events : event list) : event list =
  events
  |> List.filter (fun e -> e.involved_name = pod_name)
  |> List.sort (fun a b -> compare a.last_timestamp b.last_timestamp)
  |> List.rev
  |> List.filteri (fun i _ -> i < limit)
;;

let is_healthy (p : pod_status) : bool =
  p.phase = "Running" && p.ready && p.state = Running
;;

type pod_expectation =
  | Continuous
  | Ephemeral

type events_fetch_result =
  | Events of event list
  | Events_unavailable of string

let format_pod_diagnosis (p : pod_status) (events : events_fetch_result) : string =
  let buf = Buffer.create 256 in
  let with_message = function
    | Some m -> " — " ^ m
    | None -> ""
  in
  let headline, detail =
    match p.state with
    | Waiting { reason; message } ->
      reason, Some (Printf.sprintf "Reason: %s%s\n" reason (with_message message))
    | Terminated { reason; exit_code; message } ->
      ( reason
      , Some
          (Printf.sprintf
             "Reason: %s (exit code %d)%s\n"
             reason
             exit_code
             (with_message message)) )
    | Running | Unknown_state -> p.phase, None
  in
  Buffer.add_string buf (Printf.sprintf "Pod %s: %s\n" p.name headline);
  Option.iter (Buffer.add_string buf) detail;
  (match p.last_terminated_reason with
   | Some r when p.restarts > 0 ->
     Buffer.add_string buf (Printf.sprintf "Last termination: %s\n" r)
   | _ -> ());
  if p.restarts > 0
  then Buffer.add_string buf (Printf.sprintf "Restarts: %d\n" p.restarts);
  p.image
  |> Option.iter (fun img -> Buffer.add_string buf (Printf.sprintf "Image: %s\n" img));
  (match events with
   | Events [] -> Buffer.add_string buf "No events recorded for this pod.\n"
   | Events l ->
     Buffer.add_string buf "Last events:\n";
     l
     |> List.iter (fun e ->
       Buffer.add_string buf (Printf.sprintf "  %s: %s\n" e.reason e.message))
   | Events_unavailable why ->
     Buffer.add_string buf (Printf.sprintf "Events unavailable: %s\n" why));
  Buffer.contents buf
;;

let events_for_pod_result ~pod_name (result : events_fetch_result) : events_fetch_result =
  match result with
  | Events l -> Events (events_for_pod ~pod_name l)
  | Events_unavailable _ as unavailable -> unavailable
;;

let render_pods ~heading (pods : pod_status list) (events : events_fetch_result) : string =
  let buf = Buffer.create 512 in
  Buffer.add_string buf (heading ^ "\n\n");
  pods
  |> List.iter (fun p ->
    Buffer.add_string
      buf
      (format_pod_diagnosis p (events_for_pod_result ~pod_name:p.name events));
    Buffer.add_char buf '\n');
  Buffer.contents buf
;;

type diagnosis =
  | Healthy
  | Unhealthy of string
  | Undetermined of string

let format_service_diagnosis
      ~service_name
      (pods : confirmed_pods)
      (events : events_fetch_result)
  : diagnosis
  =
  let pods = pod_list pods in
  if pods = []
  then
    Unhealthy
      (Printf.sprintf
         "%s rollout failed\n\nNo pods found for this service.\n"
         service_name)
  else (
    let unhealthy = List.filter (fun p -> not (is_healthy p)) pods in
    if unhealthy = []
    then Healthy
    else
      Unhealthy
        (render_pods
           ~heading:(Printf.sprintf "%s rollout failed" service_name)
           unhealthy
           events))
;;

let release_selector release = "app.kubernetes.io/instance=" ^ release

let format_release_diagnosis
      ~release
      ~namespace
      (pods : confirmed_pods)
      (events : events_fetch_result)
  : diagnosis
  =
  let pods = pod_list pods in
  if pods = []
  then
    Unhealthy
      (Printf.sprintf
         "helm release %s in namespace %s did not become ready\n\n\
          No pods found for this release.\n"
         release
         namespace)
  else (
    let unhealthy =
      pods
      |> List.filter (fun p -> p.phase <> "Succeeded")
      |> List.filter (fun p -> not (is_healthy p))
    in
    if unhealthy = []
    then Healthy
    else
      Unhealthy
        (render_pods
           ~heading:
             (Printf.sprintf
                "helm release %s in namespace %s did not become ready"
                release
                namespace)
           unhealthy
           events))
;;

let is_active_run_pod_ok ~(events : events_fetch_result) (p : pod_status) : bool =
  is_healthy p
  || p.phase = "Succeeded"
  || (p.restarts = 0
      && (match events with
          | Events_unavailable _ -> false
          | Events l ->
            not
              (l
               |> List.exists (fun e ->
                 e.involved_name = p.name && e.reason = "FailedScheduling")))
      &&
      match p.state with
      | Waiting { reason; _ } ->
        reason = "ContainerCreating" || reason = "PodInitializing"
      | Unknown_state -> p.phase = "Pending"
      | Running | Terminated _ -> false)
;;

let format_active_run_diagnosis
      ~service_name
      (pods : confirmed_pods)
      (events : events_fetch_result)
  : diagnosis
  =
  let pods = pod_list pods in
  let unhealthy = List.filter (fun p -> not (is_active_run_pod_ok ~events p)) pods in
  if unhealthy = []
  then Healthy
  else
    Unhealthy
      (render_pods
         ~heading:(Printf.sprintf "%s rollout failed" service_name)
         unhealthy
         events)
;;

type cronjob_status =
  { last_schedule_time : string option
  ; last_successful_time : string option
  ; active_job_names : string list
  }

let parse_cronjob_status (s : string) : (cronjob_status, string) result =
  let open Result.Syntax in
  let* j = Sol_cli_json.decode ~what:"the CronJob" s in
  let status = field [ "status" ] j in
  let* active_job_names =
    match field [ "active" ] status with
    | `Null -> Ok []
    | `List active ->
      Sol_cli_result.map_list
        (fun item ->
           Option.to_result
             ~none:"the CronJob: an active job has no name"
             (string_field [ "name" ] item))
        active
    | _ -> Error "the CronJob: status.active is not a list"
  in
  Ok
    { last_schedule_time = string_field [ "lastScheduleTime" ] status
    ; last_successful_time = string_field [ "lastSuccessfulTime" ] status
    ; active_job_names
    }
;;

type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  | Unavailable of string

let is_at_or_after ~reference candidate =
  match Ptime.of_rfc3339 candidate, Ptime.of_rfc3339 reference with
  | Ok (t_candidate, _, _), Ok (t_reference, _, _) ->
    Ptime.compare t_candidate t_reference >= 0
  | _ -> false
;;

let format_cronjob_diagnosis ~service_name (result : cronjob_fetch_result) : diagnosis =
  match result with
  | Unavailable why ->
    Undetermined (Printf.sprintf "the CronJob's status could not be read: %s" why)
  | Missing ->
    Unhealthy
      (Printf.sprintf
         "%s rollout failed\n\nCronJob not found for this service.\n"
         service_name)
  | Found status ->
    if status.active_job_names <> []
    then Healthy
    else (
      match status.last_schedule_time with
      | None -> Healthy
      | Some scheduled ->
        let succeeded_since =
          match status.last_successful_time with
          | Some succeeded -> is_at_or_after ~reference:scheduled succeeded
          | None -> false
        in
        if succeeded_since
        then Healthy
        else
          Unhealthy
            (Printf.sprintf
               "%s rollout failed\n\n\
                Most recently scheduled run (%s) did not complete successfully.\n"
               service_name
               scheduled))
;;

let fetch_namespace_events ~ctx ~ns : events_fetch_result =
  match
    Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; "events"; "-n"; ns; "-o"; "json" ]
  with
  | Ok r ->
    (match parse_events_json r.stdout with
     | Ok events -> Events events
     | Error why -> Events_unavailable why)
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim (r.stderr ^ " " ^ r.stdout) in
    let reason =
      if String.equal detail ""
      then Printf.sprintf "kubectl get events exited with code %d" r.exit_code
      else detail
    in
    Events_unavailable reason
  | Error e -> Events_unavailable (Sol_cli_process.error_to_string e)
;;

let kubectl_read_failure ~what ~exit_code ~stdout ~stderr =
  let detail = String.trim (stderr ^ " " ^ stdout) in
  let suffix =
    if String.equal detail ""
    then Printf.sprintf " (exit %d)" exit_code
    else ": " ^ detail
  in
  Printf.sprintf "%s could not be read%s" what suffix
;;

let fetch_pods_by_selector ~what ~ctx ~ns ~selector : (confirmed_pods, string) result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "pods"; "-n"; ns; "-l"; selector; "-o"; "json" ]
  with
  | Ok r -> parse_pods_json r.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (kubectl_read_failure
         ~what
         ~exit_code:r.exit_code
         ~stdout:r.stdout
         ~stderr:r.stderr)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let fetch_pod_statuses ~ctx ~ns ~k8s_name : (confirmed_pods, string) result =
  fetch_pods_by_selector ~what:"pods" ~ctx ~ns ~selector:("app=" ^ k8s_name)
;;

let fetch_job_pod_statuses ~ctx ~ns ~job_name : (confirmed_pods, string) result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "pods"; "-n"; ns; "-l"; "job-name=" ^ job_name; "-o"; "json" ]
  with
  | Ok r -> parse_pods_json r.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (kubectl_read_failure
         ~what:"the run's pods"
         ~exit_code:r.exit_code
         ~stdout:r.stdout
         ~stderr:r.stderr)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let fetch_active_cronjob_pods ~ctx ~ns job_names : (confirmed_pods, string) result =
  let results =
    List.map (fun job_name -> fetch_job_pod_statuses ~ctx ~ns ~job_name) job_names
  in
  let fetched =
    List.filter_map
      (function
        | Ok (Confirmed pods) -> Some pods
        | Error _ -> None)
      results
  in
  match fetched with
  | [] when job_names <> [] ->
    let reasons =
      List.filter_map
        (function
          | Error why -> Some why
          | Ok _ -> None)
        results
      |> List.sort_uniq String.compare
    in
    Error (String.concat "; " reasons)
  | _ -> Ok (Confirmed (List.concat fetched))
;;

let fetch_cronjob_status ~ctx ~ns ~k8s_name : cronjob_fetch_result =
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "cronjob"; k8s_name; "-n"; ns; "-o"; "json" ]
  with
  | Ok r ->
    (match parse_cronjob_status r.stdout with
     | Ok status -> Found status
     | Error why -> Unavailable why)
  | Error e ->
    (match Sol_cli_kubectl.classify e, e with
     | Not_found, _ -> Missing
     | _, Sol_cli_process.Non_zero r ->
       Unavailable
         (kubectl_read_failure
            ~what:"the CronJob"
            ~exit_code:r.exit_code
            ~stdout:r.stdout
            ~stderr:r.stderr)
     | _, e -> Unavailable (Sol_cli_process.error_to_string e))
;;

let diagnose_service_live ~ctx ~pod_expectation ~ns ~service_name ~k8s_name () : diagnosis
  =
  match pod_expectation with
  | Continuous ->
    (match fetch_pod_statuses ~ctx ~ns ~k8s_name with
     | Error why -> Undetermined why
     | Ok pods ->
       let events = fetch_namespace_events ~ctx ~ns in
       format_service_diagnosis ~service_name pods events)
  | Ephemeral ->
    let cronjob = fetch_cronjob_status ~ctx ~ns ~k8s_name in
    (match cronjob with
     | Found { active_job_names = _ :: _ as job_names; _ } ->
       (match fetch_active_cronjob_pods ~ctx ~ns job_names with
        | Ok (Confirmed (_ :: _) as pods) ->
          let events = fetch_namespace_events ~ctx ~ns in
          format_active_run_diagnosis ~service_name pods events
        | Ok (Confirmed []) -> format_cronjob_diagnosis ~service_name cronjob
        | Error why ->
          Undetermined (Printf.sprintf "the active run's pods could not be read: %s" why))
     | _ -> format_cronjob_diagnosis ~service_name cronjob)
;;

let diagnose_release_live ~ctx ~ns ~release () : diagnosis =
  match
    fetch_pods_by_selector
      ~what:(Printf.sprintf "pods for Helm release %s" release)
      ~ctx
      ~ns
      ~selector:(release_selector release)
  with
  | Error why -> Undetermined why
  | Ok pods ->
    let events = fetch_namespace_events ~ctx ~ns in
    format_release_diagnosis ~release ~namespace:ns pods events
;;
