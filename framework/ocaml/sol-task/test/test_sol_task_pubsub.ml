let failf format = Printf.ksprintf (fun message -> Windtrap.fail message) format

type task =
  | Ack_task
  | Retry_task

let handled = ref 0
let handled_ids = ref []

module T = struct
  type t = task

  let workspace = "test-workspace"

  let kind = function
    | Ack_task -> "ack"
    | Retry_task -> "retry"
  ;;

  let kinds = [ "ack"; "retry" ]

  let encode = function
    | Ack_task -> "ack"
    | Retry_task -> "retry"
  ;;

  let decode = function
    | "ack" -> Ok Ack_task
    | "retry" -> Ok Retry_task
    | _ -> Error "unknown task"
  ;;

  let handle ~task_id ?idempotency_key:_ task =
    incr handled;
    handled_ids := task_id :: !handled_ids;
    match task with
    | Ack_task -> Sol_task.Ack
    | Retry_task -> Sol_task.Retry "temporary"
  ;;
end

module Runtime = Sol_task_pubsub.Make (T)

let push_body kind payload =
  let envelope =
    Sol_task.Envelope.create ~kind ~payload ~task_id:"task-1" ()
    |> Result.get_ok
    |> Sol_task.Envelope.encode
    |> Result.get_ok
  in
  let data = Base64.encode_string envelope in
  `Assoc
    [ "message", `Assoc [ "data", `String data; "messageId", `String "provider-1" ]
    ; "subscription", `String "projects/p/subscriptions/s"
    ]
  |> Yojson.Safe.to_string
;;

let test_ack_and_retry () =
  handled := 0;
  (match Runtime.For_testing.handle_push (push_body "ack" "ack") with
   | Ok (200, _) -> ()
   | Ok (status, _) -> failf "ack returned %d" status
   | Error message -> failf "ack failed: %s" message);
  (match Runtime.For_testing.handle_push (push_body "retry" "retry") with
   | Ok (500, "temporary") -> ()
   | Ok (status, _) -> failf "retry returned %d" status
   | Error message -> failf "retry failed: %s" message);
  Windtrap.equal Windtrap.int ~msg:"both handlers entered" 2 !handled
;;

let test_duplicate_delivery_keeps_identity () =
  handled := 0;
  handled_ids := [];
  let body = push_body "ack" "ack" in
  (match Runtime.For_testing.handle_push body with
   | Ok (200, _) -> ()
   | Ok (status, _) -> failf "first delivery returned %d" status
   | Error message -> failf "first delivery failed: %s" message);
  (match Runtime.For_testing.handle_push body with
   | Ok (200, _) -> ()
   | Ok (status, _) -> failf "redelivery returned %d" status
   | Error message -> failf "redelivery failed: %s" message);
  match List.rev !handled_ids with
  | [ first; second ] ->
    Windtrap.equal Windtrap.string ~msg:"same task id on redelivery" first second
  | _ -> failf "expected two deliveries"
;;

let test_malformed () =
  (match Runtime.For_testing.handle_push {|{"message":{"data":"%%%"}}|} with
   | Error _ -> ()
   | Ok _ -> failf "invalid base64 was accepted");
  (match Runtime.For_testing.handle_push {|{"message":{}}|} with
   | Error _ -> ()
   | Ok _ -> failf "missing data was accepted");
  let body =
    let envelope =
      Sol_task.Envelope.create ~kind:"ack" ~payload:"unknown" ~task_id:"task-2" ()
      |> Result.get_ok
      |> Sol_task.Envelope.encode
      |> Result.get_ok
    in
    `Assoc
      [ ( "message"
        , `Assoc
            [ "data", `String (Base64.encode_string envelope); "messageId", `String "m" ]
        )
      ]
    |> Yojson.Safe.to_string
  in
  match Runtime.For_testing.handle_push body with
  | Ok (400, _) -> ()
  | Ok (status, _) -> failf "bad task payload returned %d" status
  | Error message -> failf "bad task payload failed: %s" message
;;

let () =
  test_ack_and_retry ();
  test_duplicate_delivery_keeps_identity ();
  test_malformed ();
  print_endline "sol-task pubsub tests passed"
;;
