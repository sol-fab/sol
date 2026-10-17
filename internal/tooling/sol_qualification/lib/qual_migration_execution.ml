(* Qualification-owned launcher for the verified candidate's migration execution.
   It owns the private channel, the product process and the observation window; it
   never owns the product's cleanup. *)
open Result.Syntax
module D = Qual_domain
module M = Sol_cli_migration_execution
module P = Sol_cli_process
module J = Sol_cli_json

type locator =
  { receipt : M.receipt
  ; context : D.read_context
  ; identity : D.job_identity
  }

let canonical json =
  Sol_cli_database_contract_data.canonical json
  |> Result.map_error (fun _ -> "noncanonical receipt protocol")
;;

let protocol_supported ~install =
  let program = Filename.concat install "bin/sol-database-contract" in
  let* output =
    P.run (P.cmd ~timeout_s:20. [ program; "migration-receipt-protocol" ])
    |> Result.map_error (fun error ->
      "cannot probe the bundled receipt protocol: " ^ P.error_to_string error)
  in
  let* json =
    J.decode ~what:"receipt protocol" output.stdout
    |> Result.map_error (fun _ -> "malformed bundled receipt protocol")
  in
  let* observed = canonical json in
  let* expected = canonical M.protocol in
  Ok (observed = expected)
;;

(* Bounded reap. Only the launcher that spawned the product can reap it. A
   completion timeout is reported by the caller's own supervision; it must exceed
   the product's wait/cleanup window so an overdue kill cannot truncate cleanup. *)
let reap pid completion_timeout_s =
  let deadline = Unix.gettimeofday () +. completion_timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () >= deadline
      then (
        (try Unix.kill pid Sys.sigkill with
         | Unix.Unix_error _ -> ());
        try ignore (Unix.waitpid [] pid) with
        | Unix.Unix_error _ -> ())
      else (
        Unix.sleepf 0.05;
        loop ())
    | _ -> ()
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  loop ()
;;

let validate ~binding ~requested_target ~expected (receipt : M.receipt) =
  if receipt.binding <> binding
  then Error "execution receipt belongs to another launcher binding"
  else if receipt.target <> requested_target
  then Error "execution receipt names another requested target"
  else if
    receipt.principal <> expected.D.principal
    || receipt.cluster <> expected.D.cluster
    || receipt.endpoint <> expected.D.endpoint
  then Error "execution receipt names another Kubernetes authority"
  else Ok ()
;;

let run
      ~install
      ~workspace
      ~requested_target
      ~expected
      ~binding
      ~timeout_s
      ~completion_timeout_s
      ~establish
      ~consume
  =
  (* A candidate that cannot produce the private receipt is refused before any
     mutation, so an unlaunched execution can never be mistaken for a missing one. *)
  let* () =
    match protocol_supported ~install with
    | Ok true -> Ok ()
    | Ok false ->
      Error "the installed candidate does not advertise the execution-receipt protocol"
    | Error message -> Error message
  in
  let program = Filename.concat install "bin/sol" in
  let parent, channel = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let pid =
    match Unix.fork () with
    | 0 ->
      (try
         Unix.close parent;
         Unix.dup2 channel Unix.stdin;
         Unix.close channel;
         Unix.putenv M.environment binding;
         Unix.chdir workspace;
         Unix.execv program [| program; "migrate"; "apply"; requested_target |]
       with
       | _ -> ());
      Unix._exit 127
    | pid -> pid
  in
  Unix.close channel;
  Fun.protect
    ~finally:(fun () ->
      (* Release the product's existing wait/cleanup only after [consume] had its
         observation window; never leave the child running. *)
      ignore (M.acknowledge parent);
      (try Unix.close parent with
       | Unix.Unix_error _ -> ());
      reap pid completion_timeout_s)
    (fun () ->
       let* message = M.receive ~timeout_s parent in
       match message with
       | M.Unavailable ->
         Error "the launched candidate did not establish an execution receipt"
       | M.Execution receipt ->
         let* () = validate ~binding ~requested_target ~expected receipt in
         let* context = establish () in
         consume
           { receipt
           ; context
           ; identity =
               D.{ namespace = receipt.namespace; name = receipt.name; uid = receipt.uid }
           })
;;
