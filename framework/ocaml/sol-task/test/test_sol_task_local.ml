let failf format = Printf.ksprintf (fun message -> Windtrap.fail message) format

type task =
  | Echo of string
  | Fail of string

let handled = ref []

module T = struct
  type t = task

  let workspace = "test-workspace"

  let kind = function
    | Echo _ -> "echo"
    | Fail _ -> "fail"
  ;;

  let kinds = [ "echo"; "fail" ]

  let encode = function
    | Echo value -> "echo:" ^ value
    | Fail value -> "fail:" ^ value
  ;;

  let decode text =
    match String.index_opt text ':' with
    | None -> Error "missing task separator"
    | Some at ->
      let prefix = String.sub text 0 at in
      let value = String.sub text (at + 1) (String.length text - at - 1) in
      (match prefix with
       | "echo" -> Ok (Echo value)
       | "fail" -> Ok (Fail value)
       | _ -> Error ("unknown task kind " ^ prefix))
  ;;

  let handle ~task_id ?idempotency_key task =
    handled := (task_id, idempotency_key, task) :: !handled;
    match task with
    | Echo _ -> Sol_task.Ack
    | Fail message -> Sol_task.Retry message
  ;;
end

module Runtime = Sol_task_local.Make (T)

let test_envelope_round_trip () =
  let encoded = Runtime.For_testing.encode (Echo "hello") |> Result.get_ok in
  let envelope, task = Runtime.For_testing.decode encoded |> Result.get_ok in
  Windtrap.equal Windtrap.string ~msg:"kind" "echo" envelope.kind;
  Windtrap.equal Windtrap.string ~msg:"payload" "echo:hello" envelope.payload;
  Windtrap.equal
    Windtrap.bool
    ~msg:"task id is populated"
    true
    (String.length envelope.task_id > 0);
  match task with
  | Echo "hello" -> ()
  | _ -> failf "decoded the wrong task"
;;

let test_ack_and_retry () =
  handled := [];
  let envelope =
    { Sol_task.task_id = "task-1"
    ; kind = "echo"
    ; payload = "echo:hello"
    ; idempotency_key = Some "business-1"
    }
  in
  (match Runtime.For_testing.handle envelope (Echo "hello") with
   | Ok () -> ()
   | Error message -> failf "Ack mapped to error: %s" message);
  Windtrap.equal Windtrap.int ~msg:"handler called once" 1 (List.length !handled);
  (match !handled with
   | [ (task_id, key, Echo "hello") ] ->
     Windtrap.equal Windtrap.string ~msg:"task id passed" "task-1" task_id;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"idempotency key passed"
       (Some "business-1")
       key
   | _ -> failf "handler metadata was not passed");
  match Runtime.For_testing.handle envelope (Fail "temporary") with
  | Error "temporary" -> ()
  | _ -> failf "Retry did not map to an error"
;;

let test_decode_rejects_bad_payload () =
  let envelope =
    Sol_task.Envelope.create ~kind:"echo" ~payload:"not-a-task" ~task_id:"task-2" ()
    |> Result.get_ok
  in
  match
    Runtime.For_testing.decode (Sol_task.Envelope.encode envelope |> Result.get_ok)
  with
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"decode error names the task"
      true
      (String.starts_with ~prefix:"task task-2" message)
  | Ok _ -> failf "bad task payload was accepted"
;;

let () =
  test_envelope_round_trip ();
  test_ack_and_retry ();
  test_decode_rejects_bad_payload ();
  print_endline "sol-task local tests passed"
;;
