let failf format = Printf.ksprintf (fun message -> Windtrap.fail message) format

let check_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label (Sol_task.error_to_string error)
;;

let test_round_trip () =
  let envelope =
    Sol_task.Envelope.create
      ~kind:"send_welcome_email"
      ~payload:{|{"user_id":"u-1"}|}
      ~idempotency_key:"order-42"
      ()
    |> check_ok "create"
  in
  let encoded = Sol_task.Envelope.encode envelope |> check_ok "encode" in
  let decoded = Sol_task.Envelope.decode encoded |> check_ok "decode" in
  Windtrap.equal Windtrap.string ~msg:"task id" envelope.task_id decoded.task_id;
  Windtrap.equal Windtrap.string ~msg:"kind" envelope.kind decoded.kind;
  Windtrap.equal Windtrap.string ~msg:"payload" envelope.payload decoded.payload;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"idempotency key"
    envelope.idempotency_key
    decoded.idempotency_key
;;

let test_generated_task_id () =
  let first = Sol_task.new_task_id () in
  let second = Sol_task.new_task_id () in
  Windtrap.equal Windtrap.int ~msg:"task id length" 32 (String.length first);
  Windtrap.equal
    Windtrap.bool
    ~msg:"task id is lowercase hex"
    true
    (String.for_all
       (function
         | 'a' .. 'f' | '0' .. '9' -> true
         | _ -> false)
       first);
  Windtrap.equal Windtrap.bool ~msg:"task ids differ" false (String.equal first second)
;;

let test_payload_limit () =
  let payload = String.make (Sol_task.max_message_bytes + 1) 'x' in
  match Sol_task.Envelope.create ~kind:"large" ~payload () with
  | Error (Sol_task.Too_large _) -> ()
  | Error error -> failf "expected Too_large, got %s" (Sol_task.error_to_string error)
  | Ok _ -> failf "oversized payload was accepted"
;;

let test_encoded_limit () =
  let payload = String.make (Sol_task.max_message_bytes - 8) 'x' in
  let envelope = Sol_task.Envelope.create ~kind:"near_limit" ~payload () in
  match envelope with
  | Error error -> failf "payload should fit: %s" (Sol_task.error_to_string error)
  | Ok envelope ->
    (match Sol_task.Envelope.encode envelope with
     | Error (Sol_task.Too_large _) -> ()
     | Error error ->
       failf "expected encoded Too_large, got %s" (Sol_task.error_to_string error)
     | Ok _ -> failf "oversized encoded envelope was accepted")
;;

let test_decode_rejects_malformed () =
  let cases =
    [ "{}"
    ; {|{"task_id":"t-1","kind":"k","payload":42}|}
    ; {|{"task_id":"t-1","kind":"K","payload":"p"}|}
    ; "not json"
    ]
  in
  List.iter
    (fun text ->
       match Sol_task.Envelope.decode text with
       | Error _ -> ()
       | Ok _ -> failf "malformed envelope accepted: %s" text)
    cases
;;

let test_decode_preserves_task_id () =
  let decoded =
    Sol_task.Envelope.decode {|{"task_id":"task-1","kind":"k","payload":"p"}|}
    |> check_ok "decode"
  in
  Windtrap.equal Windtrap.string ~msg:"task id" "task-1" decoded.task_id;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no idempotency key"
    None
    decoded.idempotency_key
;;

let () =
  test_round_trip ();
  test_generated_task_id ();
  test_payload_limit ();
  test_encoded_limit ();
  test_decode_rejects_malformed ();
  test_decode_preserves_task_id ();
  print_endline "sol-task core tests passed"
;;
