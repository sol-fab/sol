let failf format = Printf.ksprintf (fun message -> Windtrap.fail message) format

type task =
  | Echo of string
  | Fail of string
  | Raise

let handled = ref []

module T = struct
  type t = task

  let workspace = "test-workspace"

  let kind = function
    | Echo _ -> "echo"
    | Fail _ -> "fail"
    | Raise -> "raise"
  ;;

  let kinds = [ "echo"; "fail"; "raise" ]

  let encode = function
    | Echo value -> "echo:" ^ value
    | Fail value -> "fail:" ^ value
    | Raise -> "raise"
  ;;

  let decode = function
    | "raise" -> Ok Raise
    | text ->
      (match String.index_opt text ':' with
       | None -> Error "missing separator"
       | Some at ->
         let prefix = String.sub text 0 at in
         let value = String.sub text (at + 1) (String.length text - at - 1) in
         (match prefix with
          | "echo" -> Ok (Echo value)
          | "fail" -> Ok (Fail value)
          | _ -> Error ("unknown kind " ^ prefix)))
  ;;

  let handle ~task_id ?idempotency_key task =
    handled := (task_id, idempotency_key, task) :: !handled;
    match task with
    | Echo _ -> Sol_task.Ack
    | Fail message -> Sol_task.Retry message
    | Raise -> raise (Failure "handler exploded")
  ;;
end

module Runtime = Sol_task_lambda.Make (T)

let envelope kind payload =
  Sol_task.Envelope.create ~kind ~payload ~task_id:("task-" ^ kind) ()
  |> Result.get_ok
  |> Sol_task.Envelope.encode
  |> Result.get_ok
;;

let sqs_event records =
  `Assoc
    [ ( "Records"
      , `List
          (List.map
             (fun (message_id, body) ->
                `Assoc [ "messageId", `String message_id; "body", `String body ])
             records) )
    ]
  |> Yojson.Safe.to_string
;;

let failure_ids response =
  let json = Yojson.Safe.from_string response in
  match Yojson.Safe.Util.member "batchItemFailures" json with
  | `List items ->
    List.map
      (fun item -> Yojson.Safe.Util.(member "itemIdentifier" item |> to_string))
      items
  | _ -> failf "batch response has no batchItemFailures"
;;

let test_partial_batch_failure () =
  handled := [];
  let event =
    sqs_event
      [ "m-ok", envelope "echo" "echo:hello"
      ; "m-retry", envelope "fail" "fail:temporary"
      ; "m-malformed", "not a task envelope"
      ; "m-raise", envelope "raise" "raise"
      ]
  in
  let response = Runtime.For_testing.handle_event event |> Result.get_ok in
  let failures = failure_ids response in
  Windtrap.equal Windtrap.int ~msg:"three failures" 3 (List.length failures);
  List.iter
    (fun id ->
       Windtrap.equal Windtrap.bool ~msg:("failure " ^ id) true (List.mem id failures))
    [ "m-retry"; "m-malformed"; "m-raise" ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"ack is not a failure"
    false
    (List.mem "m-ok" failures);
  Windtrap.equal
    Windtrap.int
    ~msg:"handler entered for valid records"
    3
    (List.length !handled)
;;

let test_rejects_non_sqs_event () =
  match Runtime.For_testing.handle_event {|{"hello":"world"}|} with
  | Error _ -> ()
  | Ok _ -> failf "non-SQS event was accepted"
;;

let () =
  test_partial_batch_failure ();
  test_rejects_non_sqs_event ();
  print_endline "sol-task lambda tests passed"
;;
