open Result.Syntax

let log fields message =
  let rendered =
    fields |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat " "
  in
  Printf.eprintf "sol-task: %s %s\n%!" message rendered
;;

let field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "Pub/Sub push message has no %s" name))
  | _ -> Error "Pub/Sub push body must be a JSON object"
;;

let string_field name json =
  match field name json with
  | Error _ as error -> error
  | Ok (`String value) -> Ok value
  | Ok _ -> Error (Printf.sprintf "Pub/Sub push %s must be a string" name)
;;

module Make (T : Sol_task.TASK) = struct
  let handle_push body =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error message ->
      Error ("Pub/Sub push body is not JSON: " ^ message)
    | json ->
      let* message = field "message" json in
      let* data = string_field "data" message in
      let* payload =
        Base64.decode data
        |> Result.map_error (fun (`Msg message) ->
          "Pub/Sub message data is not base64: " ^ message)
      in
      let* envelope =
        Sol_task.Envelope.decode payload |> Result.map_error Sol_task.error_to_string
      in
      let task_id = envelope.task_id in
      (match
         T.decode envelope.payload
         |> Result.map_error (fun message -> "payload: " ^ message)
       with
       | Error message ->
         log
           [ "task_id", task_id; "kind", envelope.kind; "error", message ]
           "task payload rejected";
         Ok (400, message)
       | Ok task ->
         (try
            match T.handle ~task_id ?idempotency_key:envelope.idempotency_key task with
            | Sol_task.Ack ->
              log [ "task_id", task_id; "kind", envelope.kind ] "task acknowledged";
              Ok (200, "")
            | Sol_task.Retry message ->
              log
                [ "task_id", task_id; "kind", envelope.kind; "error", message ]
                "task requested retry";
              Ok (500, message)
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
          | exn ->
            let message = Printexc.to_string exn in
            log
              [ "task_id", task_id; "kind", envelope.kind; "error", message ]
              "task handler raised";
            Ok (500, message)))
  ;;

  let read_body_limited (req : Cohttp.Request.t) (body : Cohttp_eio.Body.t) max_bytes =
    let too_large_from_header =
      match Cohttp.Header.get (Cohttp.Request.headers req) "content-length" with
      | None -> false
      | Some value ->
        (try int_of_string (String.trim value) > max_bytes with
         | _ -> false)
    in
    if too_large_from_header
    then Error "request body is too large"
    else (
      let probe_limit = if max_bytes >= max_int then max_bytes else max_bytes + 1 in
      match
        let buf = Eio.Buf_read.of_flow body ~max_size:probe_limit in
        Eio.Buf_read.take_all buf
      with
      | exception Eio.Buf_read.Buffer_limit_exceeded -> Error "request body is too large"
      | body when String.length body > max_bytes -> Error "request body is too large"
      | body -> Ok body)
  ;;

  let respond ~status ~body () =
    Cohttp_eio.Server.respond
      ~status
      ~headers:(Cohttp.Header.of_list [ "content-type", "text/plain" ])
      ~body:(Cohttp_eio.Body.of_string body)
      ()
  ;;

  let callback _conn req body =
    match Cohttp.Request.meth req with
    | `GET -> respond ~status:`OK ~body:"sol-task\n" ()
    | `POST ->
      (match read_body_limited req body (Sol_task.max_message_bytes * 2) with
       | Error message -> respond ~status:`Bad_request ~body:message ()
       | Ok body ->
         (match handle_push body with
          | Ok (status, message) ->
            respond ~status:(Cohttp.Code.status_of_code status) ~body:message ()
          | Error message -> respond ~status:`Bad_request ~body:message ()))
    | _ -> respond ~status:`Method_not_allowed ~body:"POST only\n" ()
  ;;

  let run ~(env : (_, _, _, _) Sol_env.timed) ?(port = 8080) ?stop () =
    let port =
      match Sol_runtime.setting "PORT" with
      | None -> port
      | Some raw ->
        (match int_of_string_opt raw with
         | Some value when value >= 0 && value <= 65535 -> value
         | _ -> port)
    in
    Eio.Switch.run (fun sw ->
      let socket =
        Eio.Net.listen
          ~sw
          ~reuse_addr:true
          ~backlog:128
          env#net
          (`Tcp (Eio.Net.Ipaddr.V4.any, port))
      in
      let actual_port =
        match Eio.Net.listening_addr socket with
        | `Tcp (_, actual) -> actual
        | _ -> port
      in
      Printf.eprintf "sol-task: Pub/Sub push listening on :%d\n%!" actual_port;
      let server = Cohttp_eio.Server.make ~callback () in
      let server_stop, server_stop_r = Eio.Promise.create () in
      (match stop with
       | Some external_stop ->
         Eio.Fiber.fork_daemon ~sw (fun () ->
           Eio.Promise.await external_stop;
           Eio.Promise.resolve server_stop_r ();
           `Stop_daemon)
       | None -> Sol_runtime.install_signal_handler ~sw server_stop_r);
      Eio.Fiber.first
        (fun () ->
           Cohttp_eio.Server.run
             ~stop:server_stop
             ~on_error:(fun exn ->
               Printf.eprintf
                 "sol-task: Pub/Sub transport error: %s\n%!"
                 (Printexc.to_string exn))
             socket
             server)
        (fun () -> Eio.Promise.await server_stop));
    Ok ()
  ;;

  module For_testing = struct
    let handle_push = handle_push
  end
end
