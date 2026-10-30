open Eio.Std

let get_json _req = Response.json {|{"ok":true}|}
let echo_body req = Response.ok req.Request.body
let jwt_cfg scopes = `Jwt Auth.{ scopes; verification = Unverified_dev_only }

module H = struct
  let routes =
    [ Route.external_ (Route.get "/hello" get_json)
    ; Route.external_ (Route.post "/echo" echo_body)
    ; Route.external_
        (Route.get "/users/:id" (fun req ->
           Response.json (Printf.sprintf {|{"id":"%s"}|} (Request.param_exn req "id"))))
    ]
  ;;
end

let with_server env ~sw f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (H) in
    S.run
      ~env
      ~port:0
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port)
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

let with_server_obs env ~sw f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"test-svc"
      ()
  in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (H) in
    S.run
      ~env
      ~port:0
      ~ot:obs
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port (Sol_obs.metrics_renderer obs))
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

let http_call env ~sw ~port ~meth ~path ?(headers = []) ?(body = "") () =
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path) in
  let hdrs = Http.Header.of_list (("connection", "close") :: headers) in
  let body_val = if body = "" then None else Some (Cohttp_eio.Body.of_string body) in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers:hdrs ?body:body_val meth uri
  in
  let status = Http.Status.to_int (Http.Response.status resp) in
  let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:65536 in
  status, body_str
;;

let test_healthz env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body = http_call env ~sw ~port ~meth:`GET ~path:"/healthz" () in
      Windtrap.equal Windtrap.int ~msg:"status 200" 200 status;
      Windtrap.equal
        Windtrap.bool
        ~msg:"body ok"
        true
        (String.trim body = {|{"status":"ok"}|})))
;;

let test_not_found env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/does-not-exist" () in
      Windtrap.equal Windtrap.int ~msg:"status 404" 404 status))
;;

let test_method_not_allowed env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`DELETE ~path:"/hello" () in
      Windtrap.equal Windtrap.int ~msg:"status 405" 405 status))
;;

let test_public_route env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      Windtrap.equal Windtrap.int ~msg:"status 200" 200 status))
;;

let test_path_param env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body = http_call env ~sw ~port ~meth:`GET ~path:"/users/42" () in
      Windtrap.equal Windtrap.int ~msg:"status 200" 200 status;
      Windtrap.equal
        Windtrap.bool
        ~msg:"contains id"
        true
        (try
           let _ = String.index body '4' in
           true
         with
         | Not_found -> false)))
;;

let test_echo_body env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, body =
        http_call env ~sw ~port ~meth:`POST ~path:"/echo" ~body:"hello world" ()
      in
      Windtrap.equal Windtrap.int ~msg:"status 200" 200 status;
      Windtrap.equal
        Windtrap.bool
        ~msg:"body echoed"
        true
        (String.trim body = "hello world")))
;;

let test_metrics_no_renderer env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/metrics" () in
      Windtrap.equal Windtrap.int ~msg:"status 404" 404 status))
;;

let test_handler_exception env () =
  let module Hx = struct
    let routes =
      [ Route.external_ (Route.get "/boom" (fun _ -> raise (Failure "boom")))
      ; Route.external_ (Route.get "/ok" (fun _ -> Response.json {|"ok"|}))
      ]
    ;;
  end
  in
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Switch.run (fun sw ->
    Fiber.fork ~sw (fun () ->
      let module S = Service.Make (Hx) in
      S.run
        ~env
        ~port:0
        ~stop
        ~shutdown_delay_s:0.0
        ~drain_timeout_s:0.1
        ~on_listen:(fun p -> Promise.resolve port_r p)
        ()
      |> Result.map_error Service.run_error_to_string
      |> function
      | Ok () -> ()
      | Error e -> failwith e);
    let port = Promise.await port_p in
    let s1, _ = http_call env ~sw ~port ~meth:`GET ~path:"/boom" () in
    Windtrap.equal Windtrap.int ~msg:"500 on exception" 500 s1;
    let s2, _ = http_call env ~sw ~port ~meth:`GET ~path:"/ok" () in
    Windtrap.equal Windtrap.int ~msg:"server still up" 200 s2;
    Promise.resolve stop_r ())
;;

let test_external_stop_on_listen env () =
  Switch.run (fun _sw ->
    let module S = Service.Make (H) in
    let stop, stop_r = Promise.create () in
    match
      S.run
        ~env
        ~port:0
        ~stop
        ~shutdown_delay_s:0.0
        ~drain_timeout_s:0.1
        ~on_listen:(fun _ -> Promise.resolve stop_r ())
        ()
    with
    | Ok () -> ()
    | Error e -> Windtrap.fail (Service.run_error_to_string e))
;;

let test_metrics_counter env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      let output = render () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"requests_total counter present"
        true
        (Sol_runtime.contains_substring ~needle:"sol_svc_requests_total" output);
      Windtrap.equal
        Windtrap.bool
        ~msg:"route label in output"
        true
        (Sol_runtime.contains_substring ~needle:{|route="/hello"|} output);
      Windtrap.equal
        Windtrap.bool
        ~msg:"status_class label in output"
        true
        (Sol_runtime.contains_substring ~needle:{|status_class="2xx"|} output)))
;;

let test_metrics_duration env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
      let output = render () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"duration histogram present"
        true
        (Sol_runtime.contains_substring ~needle:"sol_svc_request_duration_seconds" output)))
;;

let test_metrics_route_pattern_label env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/users/42" () in
      let _ = http_call env ~sw ~port ~meth:`GET ~path:"/users/999" () in
      let output = render () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"pattern label present"
        true
        (Sol_runtime.contains_substring ~needle:{|route="/users/:id"|} output);
      Windtrap.equal
        Windtrap.bool
        ~msg:"concrete value 42 not a label"
        false
        (Sol_runtime.contains_substring ~needle:{|route="/users/42"|} output);
      Windtrap.equal
        Windtrap.bool
        ~msg:"concrete value 999 not a label"
        false
        (Sol_runtime.contains_substring ~needle:{|route="/users/999"|} output)))
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () -> Unix.putenv name (Option.value old ~default:""))
;;

let stopped () =
  let p, r = Promise.create () in
  Promise.resolve r ();
  p
;;

let expect_unverified_refused result =
  match result with
  | Error (`Config msg) ->
    Windtrap.is_true
      ~msg:"names unverified JWT opt-in"
      (Sol_runtime.contains_substring ~needle:"SOL_ALLOW_UNVERIFIED_JWT" msg)
  | Ok () -> Windtrap.fail "expected unverified JWT auth to be refused"
;;

let test_unverified_metrics_auth_refused_without_opt_in env () =
  with_env "SOL_ALLOW_UNVERIFIED_JWT" "0" (fun () ->
    let module S = Service.Make (struct
        let routes = []
      end)
    in
    expect_unverified_refused
      (S.run
         ~env
         ~port:0
         ~stop:(stopped ())
         ~drain_timeout_s:0.1
         ~metrics_auth:(jwt_cfg [])
         ()))
;;

let jwks_url_auth url =
  `Jwt
    Auth.
      { scopes = []
      ; verification =
          Verified_signature_required
            { issuer = "https://issuer.example.com"
            ; audience = "svc"
            ; algorithms = [ `RS256 ]
            ; key_source = Jwks_url url
            }
      }
;;

let run_with_jwks_url env url =
  let auth = jwks_url_auth url in
  let module S = Service.Make (struct
      let routes = []
    end)
  in
  S.run ~env ~port:0 ~stop:(stopped ()) ~drain_timeout_s:0.1 ~metrics_auth:auth ()
;;

let test_http_jwks_url_refused env () =
  List.iter
    (fun url ->
       match run_with_jwks_url env url with
       | Error (`Config msg) ->
         Windtrap.equal
           Windtrap.bool
           ~msg:("names the URL: " ^ url)
           true
           (Sol_runtime.contains_substring ~needle:url msg)
       | Ok () -> Windtrap.failf "a Jwks_url of %S must not start" url)
    [ "http://idp.example.com/jwks.json"; "idp.example.com/jwks.json" ]
;;

let test_https_jwks_url_starts env () =
  match run_with_jwks_url env "https://idp.example.com/jwks.json" with
  | Ok () -> ()
  | Error e -> Windtrap.fail (Service.run_error_to_string e)
;;

let test_external_stop_is_prompt env () =
  let module S = Service.Make (H) in
  let stop, stop_r = Promise.create () in
  let t0 = Unix.gettimeofday () in
  (match
     S.run
       ~env
       ~port:0
       ~stop
       ~shutdown_delay_s:0.0
       ~drain_timeout_s:3.0
       ~on_listen:(fun _ -> Promise.resolve stop_r ())
       ()
   with
   | Ok () -> ()
   | Error e -> Windtrap.fail (Service.run_error_to_string e));
  let elapsed = Unix.gettimeofday () -. t0 in
  Windtrap.equal
    Windtrap.bool
    ~msg:(Printf.sprintf "returned in %.2fs, well inside the 3s drain window" elapsed)
    true
    (elapsed < 1.5)
;;

let test_duplicate_routes_are_config_errors env () =
  let module H = struct
    let routes =
      [ Route.external_ (Route.get "/x" (fun _ -> Response.ok "public"))
      ; Route.get "/x" (fun _ -> Response.ok "internal")
      ]
    ;;
  end
  in
  let module S = Service.Make (H) in
  let stop, stop_r = Promise.create () in
  Promise.resolve stop_r ();
  match S.run ~env ~port:0 ~stop ~shutdown_delay_s:0.0 ~drain_timeout_s:0.1 () with
  | Error (`Config message) ->
    Windtrap.is_true
      ~msg:"the refusal names the duplicate pattern"
      (Sol_runtime.contains_substring ~needle:"/x" message)
  | Ok () -> Windtrap.fail "a duplicate route was accepted"
;;

let test_malformed_port_is_config_error env () =
  with_env "PORT" "80800x" (fun () ->
    let module S = Service.Make (H) in
    let stop, stop_r = Promise.create () in
    Promise.resolve stop_r ();
    match S.run ~env ~port:0 ~stop ~shutdown_delay_s:0.0 ~drain_timeout_s:0.1 () with
    | Error (`Config msg) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names PORT and the value"
        true
        (Sol_runtime.contains_substring ~needle:"80800x" msg)
    | Ok () -> Windtrap.fail "expected a malformed PORT to be a startup Config error")
;;

let test_readyz_flips_before_listener_closes env () =
  Switch.run (fun sw ->
    let port_p, port_r = Promise.create () in
    let stop, stop_r = Promise.create () in
    let finished, finished_r = Promise.create () in
    Fiber.fork ~sw (fun () ->
      let module S = Service.Make (H) in
      ignore
        (S.run
           ~env
           ~port:0
           ~stop
           ~shutdown_delay_s:1.5
           ~drain_timeout_s:0.1
           ~on_listen:(fun p -> Promise.resolve port_r p)
           ());
      Promise.resolve finished_r ());
    let port = Promise.await port_p in
    let ready_status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/readyz" () in
    Windtrap.equal Windtrap.int ~msg:"ready before stop" 200 ready_status;
    Promise.resolve stop_r ();
    Eio.Time.sleep env#clock 0.2;
    let status, _ = http_call env ~sw ~port ~meth:`GET ~path:"/readyz" () in
    Windtrap.equal Windtrap.int ~msg:"readyz is 503 once stopping" 503 status;
    let hello, _ = http_call env ~sw ~port ~meth:`GET ~path:"/hello" () in
    Windtrap.equal Windtrap.int ~msg:"requests still served during the delay" 200 hello;
    let live, _ = http_call env ~sw ~port ~meth:`GET ~path:"/healthz" () in
    Windtrap.equal Windtrap.int ~msg:"liveness is unaffected" 200 live;
    Windtrap.equal
      Windtrap.bool
      ~msg:"run has not returned during the delay"
      false
      (Promise.is_resolved finished);
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Promise.await finished))
;;

module Hauth = struct
  let routes = [ Route.external_ (Route.post "/upload" echo_body) ]
end

let with_small_body_server env ~sw ?(max_body_bytes = 50) f =
  let port_p, port_r = Promise.create () in
  let stop, stop_r = Promise.create () in
  Fiber.fork ~sw (fun () ->
    let module S = Service.Make (Hauth) in
    S.run
      ~env
      ~port:0
      ~max_body_bytes
      ~stop
      ~shutdown_delay_s:0.0
      ~drain_timeout_s:0.1
      ~on_listen:(fun p -> Promise.resolve port_r p)
      ()
    |> Result.map_error Service.run_error_to_string
    |> function
    | Ok () -> ()
    | Error e -> failwith e);
  let port = Promise.await port_p in
  Fun.protect
    (fun () -> f port)
    ~finally:(fun () ->
      try Promise.resolve stop_r () with
      | _ -> ())
;;

let test_public_oversized_body_gets_413 env () =
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let big_body = String.make 200 'x' in
      let status, _ =
        http_call env ~sw ~port ~meth:`POST ~path:"/upload" ~body:big_body ()
      in
      Windtrap.equal Windtrap.int ~msg:"413 on oversized public upload" 413 status))
;;

let test_body_exactly_at_limit env () =
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let upload body = http_call env ~sw ~port ~meth:`POST ~path:"/upload" ~body () in
      let status_49, echoed_49 = upload (String.make 49 'x') in
      Windtrap.equal Windtrap.int ~msg:"N-1 accepted" 200 status_49;
      Windtrap.equal Windtrap.int ~msg:"N-1 echoed intact" 49 (String.length echoed_49);
      let status_50, echoed_50 = upload (String.make 50 'x') in
      Windtrap.equal Windtrap.int ~msg:"exactly N accepted" 200 status_50;
      Windtrap.equal
        Windtrap.int
        ~msg:"exactly N echoed intact"
        50
        (String.length echoed_50);
      let status_51, _ = upload (String.make 51 'x') in
      Windtrap.equal Windtrap.int ~msg:"N+1 rejected with 413" 413 status_51))
;;

let test_empty_body_accepted env () =
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let status, body = http_call env ~sw ~port ~meth:`POST ~path:"/upload" () in
      Windtrap.equal Windtrap.int ~msg:"empty body accepted" 200 status;
      Windtrap.equal Windtrap.string ~msg:"empty body echoed" "" body))
;;

let raw_chunked_status env ~sw ~port payload =
  let flow = Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let chunk = Printf.sprintf "%x\r\n%s\r\n" (String.length payload) payload in
  let request =
    "POST /upload HTTP/1.1\r\n\
     Host: 127.0.0.1\r\n\
     Transfer-Encoding: chunked\r\n\
     Connection: close\r\n\
     \r\n"
    ^ chunk
    ^ "0\r\n\r\n"
  in
  Eio.Flow.copy_string request flow;
  Eio.Flow.shutdown flow `Send;
  let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let status_line = Eio.Buf_read.line reader in
  ignore (Eio.Buf_read.take_all reader);
  match String.split_on_char ' ' status_line with
  | _ :: code :: _ -> int_of_string code
  | _ -> failwith ("unexpected status line: " ^ status_line)
;;

let test_chunked_body_limit env () =
  Switch.run (fun sw ->
    with_small_body_server env ~sw (fun port ->
      let status_50 = raw_chunked_status env ~sw ~port (String.make 50 'x') in
      Windtrap.equal Windtrap.int ~msg:"exactly N chunked accepted" 200 status_50;
      let status_51 = raw_chunked_status env ~sw ~port (String.make 51 'x') in
      Windtrap.equal Windtrap.int ~msg:"N+1 chunked rejected with 413" 413 status_51))
;;

let test_boundary_turns_exceptions_into_500 _env () =
  let r =
    Service.For_testing.respond_or_500 (fun () ->
      raise (Sys_error "Mutex.lock: Resource deadlock avoided"))
  in
  Windtrap.equal Windtrap.int ~msg:"500" 500 r.Response.status;
  Windtrap.equal
    Windtrap.int
    ~msg:"a normal response passes through"
    201
    (Service.For_testing.respond_or_500 (fun () -> Response.created "x")).Response.status
;;

let test_reports_handler_failure _env () =
  let reported = ref [] in
  let report_error ~operation ~exn =
    reported := (operation, Printexc.to_string exn) :: !reported
  in
  let response =
    Service.For_testing.dispatch
      ~report_error
      ~routes:[ Route.external_ (Route.get "/boom" (fun _ -> failwith "handler boom")) ]
      (Http.Request.make ~meth:`GET "/boom")
      (Cohttp_eio.Body.of_string "")
  in
  Windtrap.equal Windtrap.int ~msg:"generic 500" 500 response.Response.status;
  match !reported with
  | [ (operation, message) ] ->
    Windtrap.equal Windtrap.string ~msg:"route operation" "/boom" operation;
    Windtrap.is_true ~msg:"cause retained" (String.length message > 0)
  | _ -> Windtrap.failf "expected one diagnostic, got %d" (List.length !reported)
;;

let test_reports_outer_dispatch_failure _env () =
  let reported = ref [] in
  let report_error ~operation ~exn =
    reported := (operation, Printexc.to_string exn) :: !reported
  in
  let response =
    Service.For_testing.respond_or_500 ~report_error (fun () -> failwith "outer boom")
  in
  Windtrap.equal Windtrap.int ~msg:"generic 500" 500 response.Response.status;
  match !reported with
  | [ (operation, message) ] ->
    Windtrap.equal Windtrap.string ~msg:"dispatch operation" "dispatch" operation;
    Windtrap.is_true ~msg:"cause retained" (String.length message > 0)
  | _ -> Windtrap.failf "expected one diagnostic, got %d" (List.length !reported)
;;

let test_fallback_returns_generic_500 _env () =
  let response =
    Service.For_testing.respond_or_500 (fun () -> failwith "fallback boom")
  in
  Windtrap.equal Windtrap.int ~msg:"fallback generic 500" 500 response.Response.status
;;

let () =
  Unix.putenv "SOL_ALLOW_UNVERIFIED_JWT" "1";
  Eio_main.run (fun env ->
    Windtrap.run
      "service"
      [ Windtrap.group
          "built-ins"
          [ Windtrap.test "GET /healthz → 200" (test_healthz env)
          ; Windtrap.test "GET /metrics, no renderer → 404" (test_metrics_no_renderer env)
          ]
      ; Windtrap.group
          "routing"
          [ Windtrap.test "unknown path → 404" (test_not_found env)
          ; Windtrap.test "wrong method → 405" (test_method_not_allowed env)
          ; Windtrap.test "public route → 200" (test_public_route env)
          ; Windtrap.test "path param extracted" (test_path_param env)
          ; Windtrap.test "POST body echoed" (test_echo_body env)
          ]
      ; Windtrap.group
          "metrics_auth"
          [ Windtrap.test
              "Unverified_dev_only metrics auth without opt-in is refused"
              (test_unverified_metrics_auth_refused_without_opt_in env)
          ; Windtrap.test "Jwks_url not https is refused" (test_http_jwks_url_refused env)
          ; Windtrap.test "Jwks_url https starts" (test_https_jwks_url_starts env)
          ]
      ; Windtrap.group
          "resilience"
          [ Windtrap.test
              "exception outside the handler → 500"
              (test_boundary_turns_exceptions_into_500 env)
          ; Windtrap.test
              "handler exception → 500, server survives"
              (test_handler_exception env)
          ; Windtrap.test "external stop on listen" (test_external_stop_on_listen env)
          ; Windtrap.test
              "external stop does not wait out the drain window"
              (test_external_stop_is_prompt env)
          ; Windtrap.test
              "readyz flips to 503 before the listener closes"
              (test_readyz_flips_before_listener_closes env)
          ; Windtrap.test
              "duplicate method+pattern routes are a startup Config error"
              (test_duplicate_routes_are_config_errors env)
          ; Windtrap.test
              "malformed PORT is a startup Config error"
              (test_malformed_port_is_config_error env)
          ]
      ; Windtrap.group
          "metrics"
          [ Windtrap.test "requests counter with route label" (test_metrics_counter env)
          ; Windtrap.test "duration histogram present" (test_metrics_duration env)
          ; Windtrap.test
              "route label uses pattern not path"
              (test_metrics_route_pattern_label env)
          ]
      ; Windtrap.group
          "body_limits"
          [ Windtrap.test
              "external route + oversized body → 413"
              (test_public_oversized_body_gets_413 env)
          ; Windtrap.test
              "body at exactly N accepted, N+1 rejected (BUG-073)"
              (test_body_exactly_at_limit env)
          ; Windtrap.test "empty body accepted (BUG-073)" (test_empty_body_accepted env)
          ; Windtrap.test
              "chunked body at N accepted, N+1 rejected (BUG-073)"
              (test_chunked_body_limit env)
          ]
      ; Windtrap.group
          "failure diagnostics"
          [ Windtrap.test
              "handler failure reported once"
              (test_reports_handler_failure env)
          ; Windtrap.test
              "outer dispatch failure reported once"
              (test_reports_outer_dispatch_failure env)
          ; Windtrap.test
              "fallback returns a generic 500"
              (test_fallback_returns_generic_500 env)
          ]
      ])
;;
