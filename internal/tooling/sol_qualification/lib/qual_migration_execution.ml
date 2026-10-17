(* Qualification-owned launcher for the verified candidate's migration execution.
   It owns the private channel, the product process and the observation window; it
   never owns the product's cleanup. *)
open Result.Syntax
module D = Qual_domain
module M = Sol_cli_migration_execution
module P = Sol_cli_process
module J = Sol_cli_json
module C = Qual_candidate

type locator =
  { receipt : M.receipt
  ; context : D.read_context
  ; identity : D.job_identity
  }

(* The product's claimed identity is not authority; it must agree with the
   independently expected Kubernetes principal, cluster and endpoint, and the
   locator must belong to this launcher and this requested target. *)
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

(* The launcher independently established [context] before handing the locator to
   the consumer. It must describe the same authority and still be fresh; an
   expired or unestablished context is refused here even though the downstream
   evaluator also checks its own reads. *)
let validate_context ~expected (context : D.read_context) =
  let now = int_of_float (Unix.gettimeofday ()) in
  if context.target <> expected
  then Error "independent observation context names another Kubernetes authority"
  else if context.verified_at < 0 || context.verified_at > now
  then Error "independent observation context is not established"
  else if context.finished_at < context.started_at
  then Error "independent observation context timing is inconsistent"
  else if now - context.verified_at > 300
  then Error "independent observation context is stale"
  else (
    match context.expires_at with
    | Some expires when expires > now -> Ok ()
    | _ -> Error "independent observation context has expired")
;;

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

type completion =
  | Completed
  | Overdue

(* Bounded reap. Only the launcher that spawned the product can reap it. An
   overdue child is killed only as a last resort; the caller must report that
   state as unestablished rather than as completed cleanup. *)
let reap pid completion_timeout_s =
  let deadline = Unix.gettimeofday () +. completion_timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () >= deadline
      then (
        (try Unix.kill pid Sys.sigkill with
         | Unix.Unix_error _ -> ());
        (try ignore (Unix.waitpid [] pid) with
         | Unix.Unix_error _ -> ());
        Overdue)
      else (
        Unix.sleepf 0.05;
        loop ())
    | _ -> Completed
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Completed
  in
  loop ()
;;

(* The product either submitted a Job or reported, over the same opt-in channel,
   that its normal lifecycle required none. An absent job is not inferred from a
   name, and a skip is not silently treated as a satisfied execution. *)
type 'a outcome =
  | Executed of 'a
  | Skipped of string

module Fixture = struct
  (* Process boundary without candidate authority. Production callers must use
     [run], which pins the verified candidate's own executable; this entry point
     exists so the process/validation/timeout behaviour can be exercised
     offline. *)
  let run
        ~program
        ~workspace
        ~requested_target
        ~expected
        ~binding
        ~timeout_s
        ~completion_timeout_s
        ~establish
        ~consume
    =
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
    let overdue = ref false in
    let outcome =
      Fun.protect
        ~finally:(fun () ->
          (* Release the product's existing wait/cleanup only after [consume] had
             its observation window; never leave the child running. *)
          ignore (M.acknowledge parent);
          (try Unix.close parent with
           | Unix.Unix_error _ -> ());
          if reap pid completion_timeout_s = Overdue then overdue := true)
        (fun () ->
           let* message = M.receive ~timeout_s parent in
           match message with
           | M.Unavailable ->
             Error "the launched candidate did not establish an execution receipt"
           | M.No_execution reason -> Ok (Skipped reason)
           | M.Execution receipt ->
             let* () = validate ~binding ~requested_target ~expected receipt in
             let* context = establish () in
             let* () = validate_context ~expected context in
             let* result =
               consume
                 { receipt
                 ; context
                 ; identity =
                     D.
                       { namespace = receipt.namespace
                       ; name = receipt.name
                       ; uid = receipt.uid
                       }
                 }
             in
             Ok (Executed result))
    in
    if !overdue
    then
      Error
        (Printf.sprintf
           "the launched migration execution did not finish within %.0fs; its cleanup is \
            unestablished and remains the operator's responsibility"
           completion_timeout_s)
    else outcome
  ;;
end

let run ~verified ~expected ~binding ~timeout_s ~completion_timeout_s ~establish ~consume =
  let install = C.install verified in
  let* () =
    match protocol_supported ~install with
    | Ok true -> Ok ()
    | Ok false ->
      Error "the installed candidate does not advertise the execution-receipt protocol"
    | Error message -> Error message
  in
  Fixture.run
    ~program:(Filename.concat install "bin/sol")
    ~workspace:(C.workspace verified)
    ~requested_target:(C.expected verified).requested_target
    ~expected
    ~binding
    ~timeout_s
    ~completion_timeout_s
    ~establish
    ~consume
;;
