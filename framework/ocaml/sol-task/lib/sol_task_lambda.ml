open Result.Syntax

let log fields message =
  let rendered =
    fields |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat " "
  in
  Printf.eprintf "sol-task: %s %s\n%!" message rendered
;;

module Make (T : Sol_task.TASK) = struct
  let process_record ~failure_ids (record : Lambda_event.sqs_record) =
    let fail reason =
      log [ "message_id", record.message_id; "error", reason ] "task delivery failed";
      record.message_id :: failure_ids
    in
    match
      Sol_task.Envelope.decode record.body |> Result.map_error Sol_task.error_to_string
    with
    | Error message -> fail message
    | Ok envelope ->
      let task_id = envelope.task_id in
      (match
         T.decode envelope.payload
         |> Result.map_error (fun message -> "payload: " ^ message)
       with
       | Error message -> fail message
       | Ok task ->
         (try
            match T.handle ~task_id ?idempotency_key:envelope.idempotency_key task with
            | Sol_task.Ack ->
              log [ "task_id", task_id; "kind", envelope.kind ] "task acknowledged";
              failure_ids
            | Sol_task.Retry message ->
              log
                [ "task_id", task_id; "kind", envelope.kind; "error", message ]
                "task requested retry";
              record.message_id :: failure_ids
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
          | exn -> fail (Printexc.to_string exn)))
  ;;

  let batch_response ids =
    `Assoc
      [ ( "batchItemFailures"
        , `List
            (List.map (fun id -> `Assoc [ "itemIdentifier", `String id ]) (List.rev ids))
        )
      ]
    |> Yojson.Safe.to_string
  ;;

  let handle_event payload =
    match Yojson.Safe.from_string payload with
    | exception Yojson.Json_error message ->
      Error ("task Lambda event is not JSON: " ^ message)
    | json ->
      let* records =
        Lambda_event.sqs_records_of_json json
        |> Result.map_error (fun message -> "task Lambda event: " ^ message)
      in
      let failure_ids =
        List.fold_left
          (fun failure_ids record -> process_record ~failure_ids record)
          []
          records
      in
      Ok (batch_response failure_ids)
  ;;

  let run ~(env : (_, _, _, _) Sol_env.timed) ?on_error () =
    match Lambda_runtime.runtime_api_base () with
    | Error error -> Error (Lambda_runtime.error_to_string error)
    | Ok base ->
      let runtime = Lambda_runtime.create ~net:env#net ~base in
      Lambda_runtime.run_loop
        runtime
        ~clock:env#clock
        ?on_error
        ~handler:(fun (invocation : Lambda_runtime.invocation) ->
          handle_event invocation.payload)
        ();
      Ok ()
  ;;

  module For_testing = struct
    let handle_event = handle_event
  end
end
