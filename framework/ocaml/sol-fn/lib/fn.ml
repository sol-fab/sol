type trigger =
  | Cron
  | Lambda

type run_error =
  [ `Config of string
  | `Run of string
  | `Signalled
  ]

let run_error_to_string = function
  | `Config msg -> "sol-fn: config error: " ^ msg
  | `Run msg -> "sol-fn: run failed: " ^ msg
  | `Signalled -> "sol-fn: interrupted by signal"
;;

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end

module Make (F : FN) = struct
  let default_job = function
    | Cron -> "sol-fn"
    | Lambda -> "lambda"
  ;;

  let run ~(env : (_, _, _, _) Sol_env.timed) ?pushgateway_url ?job ?ot ?stop () =
    let job =
      match job, Sol_runtime.setting "SOL_PUSHGATEWAY_JOB" with
      | Some job, _ | None, Some job -> job
      | None, None -> default_job F.trigger
    in
    let pushgateway_url =
      match pushgateway_url with
      | Some _ as url -> url
      | None -> Sol_runtime.setting "PUSHGATEWAY_URL"
    in
    let flush_logs () = Option.iter (fun o -> Sol_obs.flush o) ot in
    let backend, renderer =
      match ot with
      | Some o -> Sol_obs.backend_and_renderer o
      | None -> Obs_prometheus.create ()
    in
    (* Preserve the caller's Sol_obs context and service identity. Rebuilding an
       Obs_eio.t here discarded the workspace/env/domain labels that svc, worker and jobs
       all carry and replaced the service with the Pushgateway job name. *)
    let ot =
      match ot with
      | Some o -> Sol_obs.obs_eio o
      | None -> Obs_eio.create ~service:job ~mono_clock:env#mono_clock ~backend ()
    in
    let invocations, duration_h =
      Obs_eio.register_counter_and_histogram
        ot
        ~counter_name:"sol_fn_invocations_total"
        ~counter_help:"Total function invocations by status"
        ~counter_labels:[ "status" ]
        ~histogram_name:"sol_fn_duration_seconds"
        ~histogram_help:"Function run duration in seconds"
        ~histogram_labels:[]
    in
    let push_metrics url =
      match Obs_prometheus.push ~net:env#net ~clock:env#clock ~url ~job renderer with
      | Ok () -> ()
      | Error e ->
        Obs_eio.log_standalone
          ot
          Obs_eio.Warn
          ~fields:[ "error", Obs_prometheus.push_error_to_string e ]
          "sol-fn: push failed; continuing"
    in
    let record_and_push ~t0 outcome =
      let dt = Eio.Time.now env#clock -. t0 in
      duration_h dt;
      (match outcome with
       | `Completed (Ok ()) -> invocations ~labels:[ "status", "ok" ] 1
       | `Completed (Error _) -> invocations ~labels:[ "status", "error" ] 1
       | `Signalled -> invocations ~labels:[ "status", "cancelled" ] 1);
      Option.iter push_metrics pushgateway_url
    in
    let run_body () =
      try F.run () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    match F.trigger with
    | Cron ->
      let signal_stop, signal_stop_r = Eio.Promise.create () in
      let await_stop () =
        match stop with
        | None -> Eio.Promise.await signal_stop
        | Some external_stop ->
          Eio.Fiber.first
            (fun () -> Eio.Promise.await signal_stop)
            (fun () -> Eio.Promise.await external_stop)
      in
      let t0 = Eio.Time.now env#clock in
      let outcome =
        match stop with
        | Some external_stop when Eio.Promise.is_resolved external_stop -> `Signalled
        | _ ->
          Eio.Switch.run (fun sw ->
            Sol_runtime.install_signal_handler ~sw signal_stop_r;
            Eio.Fiber.first
              (fun () -> `Completed (run_body ()))
              (fun () ->
                 await_stop ();
                 `Signalled))
      in
      record_and_push ~t0 outcome;
      flush_logs ();
      (match outcome with
       | `Completed (Ok ()) -> Ok ()
       | `Completed (Error msg) -> Error (`Run msg)
       | `Signalled -> Error `Signalled)
    | Lambda ->
      (match Lambda_runtime.runtime_api_base () with
       | Error err -> Error (`Config (Lambda_runtime.error_to_string err))
       | Ok base ->
         let signal_stop, signal_stop_r = Eio.Promise.create () in
         let await_stop () =
           match stop with
           | None -> Eio.Promise.await signal_stop
           | Some external_stop ->
             Eio.Fiber.first
               (fun () -> Eio.Promise.await signal_stop)
               (fun () -> Eio.Promise.await external_stop)
         in
         let result =
           Eio.Switch.run (fun sw ->
             Sol_runtime.install_signal_handler ~sw signal_stop_r;
             let runtime = Lambda_runtime.create ~net:env#net ~base in
             Eio.Fiber.first
               (fun () ->
                  Lambda_runtime.run_loop
                    runtime
                    ~clock:env#clock
                    ~on_error:(fun msg ->
                      Obs_eio.log_standalone
                        ot
                        Obs_eio.Error
                        ~fields:[ "error", msg ]
                        "sol-fn: lambda-eio runtime loop error")
                    ~handler:(fun (_ : Lambda_runtime.invocation) ->
                      let t0 = Eio.Time.now env#clock in
                      let result = run_body () in
                      record_and_push ~t0 (`Completed result);
                      flush_logs ();
                      Result.map (fun () -> {|{"status":"ok"}|}) result)
                    ();
                  Ok ())
               (fun () ->
                  await_stop ();
                  Ok ()))
         in
         result)
  ;;
end

module type HTTP = sig
  val handle : Request.t -> Response.t
end

(* An HTTP function has one route and one handler. The platform owns the request
   boundary: a public function is marked external (the gateway/ingress is the
   security boundary), while an internal function keeps the workload-identity
   check that [sol-svc] installs for every non-external route. *)
module Make_http (H : HTTP) = struct
  let fn_header = "x-sol-fn", "1"

  let respond request =
    let response = H.handle request in
    { response with headers = fn_header :: response.headers }
  ;;

  let health path =
    match path with
    | "/healthz" -> Some (Response.json {|{"status":"ok"}|})
    | "/readyz" -> Some (Response.json {|{"status":"ready"}|})
    | _ -> None
  ;;

  let exposure () =
    match Sol_runtime.setting "SOL_HTTP_EXPOSURE" with
    | Some "public" -> Ok `Public
    | Some "internal" -> Ok `Internal
    | Some other ->
      Error
        (`Config
            (Printf.sprintf
               "SOL_HTTP_EXPOSURE must be \"public\" or \"internal\", got %S"
               other))
    | None ->
      Error
        (`Config
            "SOL_HTTP_EXPOSURE is not set; an HTTP function must declare its exposure")
  ;;

  let path () =
    match Sol_runtime.setting "SOL_HTTP_PATH" with
    | Some path when String.length path > 0 && path.[0] = '/' -> Ok path
    | Some path ->
      Error (`Config (Printf.sprintf "SOL_HTTP_PATH must start with \"/\", got %S" path))
    | None -> Error (`Config "SOL_HTTP_PATH is not set")
  ;;

  let route handler ~path exposure method_ =
    let route =
      match method_ with
      | `GET -> Route.get path handler
      | `POST -> Route.post path handler
      | `PUT -> Route.put path handler
      | `PATCH -> Route.patch path handler
      | `DELETE -> Route.delete path handler
    in
    match exposure with
    | `Public -> Route.external_ route
    | `Internal -> route
  ;;

  let method_of_string = function
    | "GET" -> Some `GET
    | "POST" -> Some `POST
    | "PUT" -> Some `PUT
    | "PATCH" -> Some `PATCH
    | "DELETE" -> Some `DELETE
    | _ -> None
  ;;

  let json_string json path =
    match Yojson.Safe.Util.member path json with
    | `String value -> Some value
    | _ -> None
  ;;

  let api_gateway_request payload =
    match Yojson.Safe.from_string payload with
    | exception Yojson.Json_error message ->
      Error (Printf.sprintf "Lambda event is not JSON: %s" message)
    | json ->
      let method_string =
        match
          Yojson.Safe.Util.member "requestContext" json
          |> Yojson.Safe.Util.member "http"
          |> Yojson.Safe.Util.member "method"
        with
        | `String method_ -> method_
        | _ ->
          (match json_string json "httpMethod" with
           | Some method_ -> method_
           | None -> "GET")
      in
      (match method_of_string method_string with
       | None -> Error (Printf.sprintf "unsupported HTTP method %S" method_string)
       | Some method_ ->
         let path =
           match json_string json "rawPath" with
           | Some path -> path
           | None ->
             (match json_string json "path" with
              | Some path -> path
              | None -> "/")
         in
         let query =
           match json_string json "rawQueryString" with
           | Some query -> query
           | None -> ""
         in
         let headers =
           match Yojson.Safe.Util.member "headers" json with
           | `Assoc fields ->
             fields
             |> List.filter_map (fun (key, value) ->
               match value with
               | `String value -> Some (key, value)
               | _ -> None)
           | _ -> []
         in
         let body =
           match json_string json "body" with
           | None -> ""
           | Some body ->
             (match Yojson.Safe.Util.member "isBase64Encoded" json with
              | `Bool true ->
                (try Base64.decode_exn body with
                 | _ -> body)
              | _ -> body)
         in
         let uri =
           let target = if query = "" then path else path ^ "?" ^ query in
           Uri.of_string target
         in
         Ok
           { Request.method_
           ; path
           ; headers = Http.Header.of_list headers
           ; params = []
           ; uri
           ; body
           ; auth = None
           ; trace_ctx = None
           })
  ;;

  let api_gateway_response (response : Response.t) =
    let headers =
      `Assoc (List.map (fun (key, value) -> key, `String value) response.headers)
    in
    Yojson.Safe.to_string
      (`Assoc
          [ "statusCode", `Int response.status
          ; "headers", headers
          ; "body", `String response.body
          ; "isBase64Encoded", `Bool false
          ])
  ;;

  let lambda_run ~env ?stop ~path () =
    match Lambda_runtime.runtime_api_base () with
    | Error error -> Error (`Config (Lambda_runtime.error_to_string error))
    | Ok base ->
      let signal_stop, signal_stop_r = Eio.Promise.create () in
      let await_stop () =
        match stop with
        | None -> Eio.Promise.await signal_stop
        | Some external_stop ->
          Eio.Fiber.first
            (fun () -> Eio.Promise.await signal_stop)
            (fun () -> Eio.Promise.await external_stop)
      in
      Eio.Switch.run (fun sw ->
        Sol_runtime.install_signal_handler ~sw signal_stop_r;
        let runtime = Lambda_runtime.create ~net:env#net ~base in
        Eio.Fiber.first
          (fun () ->
             Lambda_runtime.run_loop
               runtime
               ~clock:env#clock
               ~handler:(fun (invocation : Lambda_runtime.invocation) ->
                 match api_gateway_request invocation.payload with
                 | Error message -> Error message
                 | Ok request ->
                   (match health request.Request.path with
                    | Some response -> Ok (api_gateway_response response)
                    | None ->
                      if String.equal request.Request.path path
                      then Ok (api_gateway_response (respond request))
                      else (
                        let response = Response.not_found in
                        Ok
                          (api_gateway_response
                             { response with
                               headers = ("x-sol-fn", "1") :: response.headers
                             }))))
               ();
             Ok ())
          (fun () ->
             await_stop ();
             Ok ()))
  ;;

  let http_run ~env ?port ?ot ?stop ?on_listen ~path ~exposure () =
    let handler = respond in
    let routes =
      [ `GET; `POST; `PUT; `PATCH; `DELETE ]
      |> List.map (fun method_ -> route handler ~path exposure method_)
    in
    let port =
      match port with
      | Some port -> Some port
      | None ->
        (match Sol_runtime.setting "PORT" with
         | Some value ->
           (match int_of_string_opt value with
            | Some port -> Some port
            | None -> None)
         | None -> None)
    in
    let metrics_auth =
      match exposure with
      | `Public -> `Public
      | `Internal -> `Workload_identity
    in
    match Service.run routes ~env ?port ?ot ?stop ?on_listen ~metrics_auth () with
    | Ok () -> Ok ()
    | Error (`Config message) -> Error (`Config message)
  ;;

  let run ~env ?port ?ot ?stop ?on_listen () =
    match exposure (), path () with
    | Error error, _ | _, Error error -> Error error
    | Ok exposure, Ok path ->
      (match Lambda_runtime.runtime_api_base () with
       | Ok _ ->
         (match exposure with
          | `Public -> lambda_run ~env ?stop ~path ()
          | `Internal ->
            Error
              (`Config
                  "an internal HTTP function cannot run on Lambda: a Function URL is \
                   publicly reachable and the Lambda runtime has no workload-identity \
                   boundary"))
       | Error Lambda_runtime.Missing_runtime_api ->
         http_run ~env ?port ?ot ?stop ?on_listen ~path ~exposure ()
       | Error error -> Error (`Config (Lambda_runtime.error_to_string error)))
  ;;

  module For_testing = struct
    let api_gateway_request = api_gateway_request
    let api_gateway_response = api_gateway_response
  end
end
