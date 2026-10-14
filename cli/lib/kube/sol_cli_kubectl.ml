let invocation ?timeout_s ~ctx args =
  Sol_cli_process.cmd
    ~env:(Sol_cli_kube_destination.context_environment ctx)
    ?timeout_s
    ([ "kubectl" ] @ Sol_cli_kube_destination.kubectl_context_args ctx @ args)
;;

let kubectl ?timeout_s ~ctx args = Sol_cli_process.run (invocation ?timeout_s ~ctx args)
let run = kubectl
let succeeded r = Result.map ignore r
let apply ~ctx ~file = kubectl ~ctx [ "apply"; "-f"; file ] |> succeeded

let apply_dry_run ~ctx ~file =
  kubectl ~ctx [ "apply"; "-f"; file; "--dry-run=server" ] |> succeeded
;;

let get ~ctx ~resource ~name ~namespace ~output =
  kubectl ~ctx [ "get"; resource; name; "-n"; namespace; "-o"; output ]
;;

let get_raw ~ctx ~args = kubectl ~ctx args

type reason =
  | Not_found
  | Already_exists
  | Conflict
  | No_resource_type
  | Refused
  | Unreachable
  | Other

let unreachable_needles =
  [ "Unable to connect to the server"
  ; "The connection to the server"
  ; "connection refused"
  ; "no such host"
  ; "no configuration has been provided"
  ; "couldn't get current server API group list"
  ; "dial tcp"
  ; "current-context is not set"
  ; "no context exists with the name"
  ; "does not exist"
  ; "no server found for cluster"
  ; "error loading config file"
  ]
;;

let says_unreachable text =
  List.exists (fun needle -> Sol_cli_string.contains ~needle text) unreachable_needles
;;

let status_reason text =
  match Sol_cli_string.after_opt ~needle:"Error from server (" text with
  | None -> None
  | Some rest ->
    (match String.index_opt rest ')' with
     | Some j when j > 0 -> Some (String.sub rest 0 j)
     | _ -> None)
;;

let classify (error : Sol_cli_process.error) =
  match error with
  | Non_zero f ->
    let text = f.stderr ^ "\n" ^ f.stdout in
    let says needle = Sol_cli_string.contains ~needle text in
    if says "doesn't have a resource type" || says "could not find the requested resource"
    then No_resource_type
    else if
      says "You must be logged in"
      || says "the server has asked for the client to provide credentials"
    then Refused
    else if says_unreachable text
    then Unreachable
    else (
      match status_reason text with
      | Some "NotFound" -> Not_found
      | Some "AlreadyExists" -> Already_exists
      | Some "Conflict" -> Conflict
      | Some ("Unauthorized" | "Forbidden") -> Refused
      | _ -> Other)
  | Spawn_failed _ | Timeout _ -> Other
;;

let get_if_present ~ctx ~args =
  match kubectl ~ctx args with
  | Ok (o : Sol_cli_process.output) -> Ok (Some o.stdout)
  | Error e when classify e = Not_found -> Ok None
  | Error e -> Error e
;;

let logs ~ctx ~pod ~namespace ~container =
  let container_args = Option.fold container ~none:[] ~some:(fun c -> [ "-c"; c ]) in
  kubectl ~ctx ([ "logs"; pod; "-n"; namespace ] @ container_args)
;;

let rollout_status ~ctx ~kind_name ~namespace =
  kubectl ~ctx [ "rollout"; "status"; kind_name; "-n"; namespace ]
;;

let rollout_status_with_timeout ~ctx ~kind_name ~namespace ~timeout_s =
  kubectl
    ~ctx
    [ "rollout"
    ; "status"
    ; kind_name
    ; "-n"
    ; namespace
    ; Printf.sprintf "--timeout=%ds" timeout_s
    ]
;;

let rollout_restart ~ctx ~kind ~namespace =
  kubectl ~ctx [ "rollout"; "restart"; kind; "-n"; namespace ]
;;

let patch ~ctx ~resource ~name ~namespace ~patch_type ~patch =
  kubectl
    ~ctx
    [ "patch"; resource; name; "-n"; namespace; "--type"; patch_type; "-p"; patch ]
;;

(** A patch whose body is a file, not an argument. A patch that carries a secret value must
    not put it in the process argv, where every local user can read it from `ps`; the caller
    writes it to a 0600 temp file instead ([Sol_cli_fs.with_temp_file]). *)
let patch_file ~ctx ~resource ~name ~namespace ~patch_type ~file =
  kubectl
    ~ctx
    [ "patch"
    ; resource
    ; name
    ; "-n"
    ; namespace
    ; "--type"
    ; patch_type
    ; "--patch-file"
    ; file
    ]
;;

let create ~ctx ~file = kubectl ~ctx [ "create"; "-f"; file ]
let replace ~ctx ~file = kubectl ~ctx [ "replace"; "-f"; file ]

let delete ~ctx ~resource ~name ~namespace =
  kubectl ~ctx [ "delete"; resource; name; "-n"; namespace; "--ignore-not-found" ]
  |> succeeded
;;

let probe_timeout_s = 15.0

type probe =
  | Succeeded of string
  | Failed of Sol_cli_process.failure

let probe_result ~ctx ~args =
  match kubectl ~timeout_s:probe_timeout_s ~ctx args with
  | Ok (o : Sol_cli_process.output) -> Ok (Succeeded o.stdout)
  | Error (Sol_cli_process.Non_zero failure) -> Ok (Failed failure)
  | Error e -> Error ("kubectl could not be run: " ^ Sol_cli_process.error_to_string e)
;;

type presence =
  | Present
  | Absent of string
  | Uncheckable of string

let presence_failure_reason (failure : Sol_cli_process.failure) =
  let why =
    match classify (Sol_cli_process.Non_zero failure) with
    | Unreachable -> "the cluster could not be reached"
    | Refused -> "the cluster refused the request"
    | No_resource_type -> "the cluster has no such resource type"
    | Not_found -> "not found"
    | Already_exists -> "already exists"
    | Conflict -> "conflict"
    | Other -> "kubectl failed"
  in
  let message = Sol_cli_process.failure_message failure in
  let first_line =
    match String.index_opt message '\n' with
    | Some i -> String.sub message 0 i
    | None -> message
  in
  Printf.sprintf "kubectl exited %d (%s): %s" failure.exit_code why first_line
;;

let presence_of_probe_result = function
  | Ok (Succeeded stdout) ->
    if String.trim stdout = "" then Absent "kubectl reported no such object" else Present
  | Ok (Failed failure) ->
    let reason = presence_failure_reason failure in
    (match classify (Sol_cli_process.Non_zero failure) with
     | Not_found -> Absent reason
     | _ -> Uncheckable reason)
  | Error why -> Uncheckable why
;;

let presence ~ctx ~args = presence_of_probe_result (probe_result ~ctx ~args)

type forward_error =
  | Not_started of Sol_cli_process.error
  | Not_ready
  | Readiness_check_failed of string

let accepts_connections ~local_port =
  let is_not_listening_yet = function
    | Unix.ECONNREFUSED
    | Unix.ETIMEDOUT
    | Unix.ENETUNREACH
    | Unix.EHOSTUNREACH
    | Unix.ECONNRESET -> true
    | _ -> false
  in
  match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
  | exception Unix.Unix_error (e, fn, _) ->
    `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
  | s ->
    let result =
      match Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, local_port)) with
      | () -> `Ready
      | exception Unix.Unix_error (e, _, _) when is_not_listening_yet e ->
        `Not_listening_yet
      | exception Unix.Unix_error (e, fn, _) ->
        `Failed (Printf.sprintf "%s: %s" fn (Unix.error_message e))
    in
    Unix.close s;
    result
;;

let forward_alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false
  | exception Unix.Unix_error _ -> true
;;

let temporary_port_forward ~ctx ~service ~namespace ~local_port ~remote_port =
  let open Result.Syntax in
  let* () =
    match accepts_connections ~local_port with
    | `Ready ->
      Error
        (Readiness_check_failed
           (Printf.sprintf
              "something is already listening on localhost:%d, so a forward to %s/%s \
               cannot own it; refusing to treat that listener as this forward"
              local_port
              namespace
              service))
    | `Not_listening_yet | `Failed _ -> Ok ()
  in
  let* forward =
    Sol_cli_process.spawn
      (invocation
         ~ctx
         [ "port-forward"
         ; "svc/" ^ service
         ; "-n"
         ; namespace
         ; Printf.sprintf "%d:%d" local_port remote_port
         ])
    |> Result.map_error (fun e -> Not_started e)
  in
  at_exit (fun () -> Sol_cli_process.stop forward);
  let pid = Sol_cli_process.pid forward in
  let rec wait attempts =
    if not (forward_alive pid)
    then
      Error
        (Readiness_check_failed
           (Printf.sprintf
              "the port-forward to %s/%s exited before localhost:%d was ready"
              namespace
              service
              local_port))
    else if attempts = 0
    then Error Not_ready
    else (
      match accepts_connections ~local_port with
      | `Ready -> Ok ()
      | `Not_listening_yet ->
        Unix.sleepf 0.5;
        wait (attempts - 1)
      | `Failed reason -> Error (Readiness_check_failed reason))
  in
  wait 10
;;
