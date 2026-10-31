let last_request_headers : (string * string) list ref = ref []

let with_mock_server env f =
  Eio.Switch.run
  @@ fun sw ->
  let body_p, body_r = Eio.Promise.create () in
  let stop, stop_r = Eio.Promise.create () in
  let callback _conn req body =
    last_request_headers := Cohttp.Header.to_list (Cohttp.Request.headers req);
    let captured =
      let buf = Eio.Buf_read.of_flow body ~max_size:(256 * 1024) in
      Eio.Buf_read.take_all buf
    in
    if not (Eio.Promise.is_resolved body_p) then Eio.Promise.resolve body_r captured;
    Cohttp_eio.Server.respond ~status:`No_content ~body:(Cohttp_eio.Body.of_string "") ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  match Eio.Net.listen ~backlog:5 ~sw env#net addr with
  | exception Unix.Unix_error (Unix.EPERM, "bind", _) ->
    Windtrap.fail
      "this host forbids binding a loopback socket (EPERM at bind); the mock-server \
       contract cannot be established here, so run the suite on a host that permits \
       bind()"
  | socket ->
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, p) -> p
      | _ -> failwith "unexpected address family"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
      `Stop_daemon);
    let result = f ~port ~body_promise:body_p in
    Eio.Promise.resolve stop_r ();
    result
;;

let local_url port = Printf.sprintf "http://127.0.0.1:%d" port

let taxonomy_env_names =
  [ "SOL_WORKSPACE"
  ; "SOL_ENV"
  ; "SOL_DOMAIN"
  ; "SOL_SERVICE"
  ; "SOL_PRIMITIVE"
  ; "SOL_RELEASE"
  ]
;;

let with_env pairs f =
  let pairs = List.map (fun name -> name, "") taxonomy_env_names @ pairs in
  let saved =
    List.map (fun (k, _) -> k, Option.value (Sys.getenv_opt k) ~default:"") pairs
  in
  List.iter (fun (k, v) -> Unix.putenv k v) pairs;
  Fun.protect ~finally:(fun () -> List.iter (fun (k, v) -> Unix.putenv k v) saved) f
;;

let sol_identity_env =
  [ "SOL_WORKSPACE", "obsdemo"
  ; "SOL_ENV", "prod"
  ; "SOL_DOMAIN", "payments"
  ; "SOL_SERVICE", "charge-svc"
  ; "SOL_PRIMITIVE", "svc"
  ; "SOL_RELEASE", "r-0123456789abcdef"
  ]
;;

let test_default_env_logs_and_counts_without_network () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       Sol_obs.log_info obs "hello";
       Sol_obs.with_span obs "op" (fun sp -> Sol_obs.log sp Sol_obs.Info "inside span");
       let reqs =
         Sol_obs.counter obs ~name:"requests_total" ~help:"total requests" ~label_names:[]
       in
       reqs 1;
       let rendered = Sol_obs.metrics_renderer obs () in
       Windtrap.equal
         Windtrap.bool
         ~msg:"rendered output mentions the registered counter"
         true
         (Sol_runtime.contains_substring ~needle:"requests_total" rendered))
;;

let test_gauge_and_histogram_round_trip () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       let queue_depth =
         Sol_obs.gauge obs ~name:"queue_depth" ~help:"items queued" ~label_names:[]
       in
       queue_depth 3.0;
       let latency =
         Sol_obs.histogram obs ~name:"op_seconds" ~help:"op latency" ~label_names:[]
       in
       latency 0.05;
       let rendered = Sol_obs.metrics_renderer obs () in
       Windtrap.equal
         Windtrap.bool
         ~msg:"gauge present"
         true
         (Sol_runtime.contains_substring ~needle:"queue_depth" rendered);
       Windtrap.equal
         Windtrap.bool
         ~msg:"histogram present"
         true
         (Sol_runtime.contains_substring ~needle:"op_seconds" rendered))
;;

let test_loki_url_wires_loki_backend () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", local_url port; "TEMPO_URL", "" ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ()
         in
         Sol_obs.log_info obs "pushed to loki";
         let body = Eio.Promise.await body_promise in
         Windtrap.equal
           Windtrap.bool
           ~msg:"push body mentions the log message"
           true
           (Sol_runtime.contains_substring ~needle:"pushed to loki" body)))
;;

let capture_stdout f =
  let path = Filename.temp_file "sol-obs-stdout-" ".log" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stdout in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let restore () =
    flush stdout;
    Unix.dup2 saved Unix.stdout;
    Unix.close saved
  in
  (match f () with
   | () -> restore ()
   | exception e ->
     restore ();
     raise e);
  let out = In_channel.with_open_text path In_channel.input_all in
  Sys.remove path;
  out
;;

let test_loki_url_keeps_a_stdout_copy () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", local_url port; "TEMPO_URL", "" ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ()
         in
         let out =
           capture_stdout (fun () ->
             Sol_obs.log_info obs "also on stdout";
             Sol_obs.counter obs ~name:"test_total" ~help:"h" ~label_names:[] 1)
         in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the line is on stdout"
           true
           (Sol_runtime.contains_substring ~needle:"also on stdout" out);
         Windtrap.equal
           Windtrap.bool
           ~msg:"metrics are not"
           false
           (Sol_runtime.contains_substring ~needle:"METRIC" out);
         Windtrap.equal
           Windtrap.bool
           ~msg:"and still pushed to Loki"
           true
           (Sol_runtime.contains_substring
              ~needle:"also on stdout"
              (Eio.Promise.await body_promise))))
;;

let test_flush_delivers_queued_lines () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", local_url port; "TEMPO_URL", "" ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ()
         in
         let (_ : string) =
           capture_stdout (fun () -> Sol_obs.log_info obs "queued then flushed")
         in
         Sol_obs.flush obs;
         Windtrap.equal
           Windtrap.bool
           ~msg:"delivered by the time flush returns"
           true
           (Eio.Promise.is_resolved body_promise);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the line"
           true
           (Sol_runtime.contains_substring
              ~needle:"queued then flushed"
              (Eio.Promise.await body_promise))))
;;

let test_context_promoted_to_loki_stream_labels () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", local_url port; "TEMPO_URL", "" ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ~context:[ "team", "payments" ]
             ()
         in
         Sol_obs.log_info obs "hi";
         let body = Eio.Promise.await body_promise in
         Windtrap.equal
           Windtrap.bool
           ~msg:"push body carries the team stream label"
           true
           (Sol_runtime.contains_substring ~needle:"\"team\":\"payments\"" body)))
;;

let test_tempo_url_wires_tempo_backend () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", ""; "TEMPO_URL", local_url port ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ()
         in
         Sol_obs.with_span obs "op" (fun _sp -> ());
         let body = Eio.Promise.await body_promise in
         Windtrap.equal
           Windtrap.bool
           ~msg:"OTLP push body is non-empty"
           true
           (String.length body > 0)))
;;

let test_tempo_headers_are_forwarded () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      [ "LOKI_URL", ""
      ; "TEMPO_URL", local_url port
      ; "TEMPO_HEADERS", "dd-api-key=secret, X-Scope-OrgID=tenant"
      ]
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"test-svc"
             ()
         in
         Sol_obs.with_span obs "op" (fun _sp -> ());
         let _ = Eio.Promise.await body_promise in
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"API-key header reaches the OTLP receiver"
           (Some "secret")
           (List.assoc_opt "dd-api-key" !last_request_headers);
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"tenant header reaches the OTLP receiver"
           (Some "tenant")
           (List.assoc_opt "X-Scope-OrgID" !last_request_headers)))
;;

let test_metrics_renderer_matches_backend_and_renderer () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       let reqs = Sol_obs.counter obs ~name:"acc_total" ~help:"h" ~label_names:[] in
       reqs 1;
       let _backend, renderer_from_pair = Sol_obs.backend_and_renderer obs in
       Windtrap.equal
         Windtrap.string
         ~msg:"same renderer output both ways"
         (Sol_obs.metrics_renderer obs ())
         (renderer_from_pair ()))
;;

let test_with_context_does_not_mutate_original () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       let derived = Sol_obs.with_context obs [ "req", "r-1" ] in
       Windtrap.equal
         Windtrap.bool
         ~msg:"obs_eio handles are distinct values"
         true
         (Sol_obs.obs_eio obs != Sol_obs.obs_eio derived))
;;

let test_current_trace_context_links_child_span () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       let parent_ctx = Sol_obs.with_span obs "parent" Sol_obs.current_trace_context in
       Sol_obs.with_span obs ~parent:parent_ctx "child" (fun child_span ->
         let child_ctx = Sol_obs.current_trace_context child_span in
         Windtrap.equal
           Windtrap.string
           ~msg:"child inherits the parent's trace id"
           (Sol_obs.trace_id_string parent_ctx)
           (Sol_obs.trace_id_string child_ctx)))
;;

let test_trace_id_string_is_32_hex_chars () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_env
    [ "LOKI_URL", ""; "TEMPO_URL", "" ]
    (fun () ->
       let obs =
         Sol_obs.of_env
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~mono_clock:env#mono_clock
           ~service:"test-svc"
           ()
       in
       let ctx = Sol_obs.with_span obs "op" Sol_obs.current_trace_context in
       let s = Sol_obs.trace_id_string ctx in
       Windtrap.equal Windtrap.int ~msg:"32 lowercase hex characters" 32 (String.length s);
       Windtrap.equal
         Windtrap.bool
         ~msg:"every character is lowercase hex"
         true
         (String.for_all
            (function
              | '0' .. '9' | 'a' .. 'f' -> true
              | _ -> false)
            s))
;;

let test_taxonomy_env_reaches_tempo_resource_attributes () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      ([ "LOKI_URL", ""; "TEMPO_URL", local_url port ] @ sol_identity_env)
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"ignored-standalone"
             ()
         in
         Sol_obs.with_span obs "op" (fun _ -> ());
         let body = Eio.Promise.await body_promise in
         [ "workspace"; "env"; "domain"; "service"; "primitive"; "release" ]
         |> List.iter (fun label ->
           Windtrap.equal
             Windtrap.bool
             ~msg:("OTLP resource carries the " ^ label ^ " attribute name")
             true
             (Sol_runtime.contains_substring ~needle:label body));
         [ "obsdemo"; "prod"; "payments"; "charge-svc"; "svc"; "r-0123456789abcdef" ]
         |> List.iter (fun value ->
           Windtrap.equal
             Windtrap.bool
             ~msg:("OTLP resource carries the value " ^ value)
             true
             (Sol_runtime.contains_substring ~needle:value body));
         Windtrap.equal
           Windtrap.bool
           ~msg:"SOL_SERVICE replaces the standalone ~service argument"
           false
           (Sol_runtime.contains_substring ~needle:"ignored-standalone" body)))
;;

let test_taxonomy_env_becomes_loki_stream_labels () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      ([ "LOKI_URL", local_url port; "TEMPO_URL", "" ] @ sol_identity_env)
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"ignored-standalone"
             ()
         in
         Sol_obs.log_info obs "taxonomy line";
         let body = Eio.Promise.await body_promise in
         [ "\"service\":\"charge-svc\""
         ; "\"workspace\":\"obsdemo\""
         ; "\"env\":\"prod\""
         ; "\"domain\":\"payments\""
         ; "\"primitive\":\"svc\""
         ; "\"release\":\"r-0123456789abcdef\""
         ]
         |> List.iter (fun pair ->
           Windtrap.equal
             Windtrap.bool
             ~msg:("Loki stream carries " ^ pair)
             true
             (Sol_runtime.contains_substring ~needle:pair body))))
;;

let test_platform_identity_overrides_application_context () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  with_mock_server env (fun ~port ~body_promise ->
    with_env
      ([ "LOKI_URL", local_url port; "TEMPO_URL", "" ] @ sol_identity_env)
      (fun () ->
         let obs =
           Sol_obs.of_env
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~mono_clock:env#mono_clock
             ~service:"standalone"
             ~context:[ "domain", "spoofed"; "team", "payments" ]
             ()
         in
         Sol_obs.log_info obs "context line";
         let body = Eio.Promise.await body_promise in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the injected domain wins over the application context"
           true
           (Sol_runtime.contains_substring ~needle:"\"domain\":\"payments\"" body);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the spoofed domain is absent"
           false
           (Sol_runtime.contains_substring ~needle:"spoofed" body);
         Windtrap.equal
           Windtrap.bool
           ~msg:"an app-owned field still reaches the stream"
           true
           (Sol_runtime.contains_substring ~needle:"\"team\":\"payments\"" body)))
;;

let test_taxonomy_labels_are_the_documented_six () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"Sol_obs.taxonomy_labels is the canonical order"
    [ "workspace"; "env"; "domain"; "service"; "primitive"; "release" ]
    Sol_obs.taxonomy_labels
;;

let () =
  let open Windtrap in
  run
    "sol_obs"
    [ Windtrap.group
        "defaults"
        [ test
            "logs and counts without any network backend"
            test_default_env_logs_and_counts_without_network
        ; test "gauge and histogram round trip" test_gauge_and_histogram_round_trip
        ]
    ; Windtrap.group
        "env-driven backends"
        [ test "LOKI_URL wires the Loki backend" test_loki_url_wires_loki_backend
        ; test
            "LOKI_URL keeps a stdout copy of log lines"
            test_loki_url_keeps_a_stdout_copy
        ; test "flush delivers queued lines" test_flush_delivers_queued_lines
        ; test
            "?context is promoted to Loki stream labels"
            test_context_promoted_to_loki_stream_labels
        ; test "TEMPO_URL wires the Tempo backend" test_tempo_url_wires_tempo_backend
        ; test "TEMPO_HEADERS forwards OTLP auth headers" test_tempo_headers_are_forwarded
        ]
    ; Windtrap.group
        "workload identity (DEC-064)"
        [ test
            "the injected taxonomy reaches the OTLP resource attributes"
            test_taxonomy_env_reaches_tempo_resource_attributes
        ; test
            "the injected taxonomy becomes Loki stream labels"
            test_taxonomy_env_becomes_loki_stream_labels
        ; test
            "the platform identity overrides application context"
            test_platform_identity_overrides_application_context
        ; test
            "Sol_obs.taxonomy_labels is the documented six"
            test_taxonomy_labels_are_the_documented_six
        ]
    ; Windtrap.group
        "accessors"
        [ test
            "metrics_renderer matches backend_and_renderer's renderer"
            test_metrics_renderer_matches_backend_and_renderer
        ; test
            "with_context derives without mutating the original"
            test_with_context_does_not_mutate_original
        ]
    ; Windtrap.group
        "trace context"
        [ test
            "current_trace_context links a child span to its parent"
            test_current_trace_context_links_child_span
        ; test
            "trace_id_string is 32 lowercase hex characters"
            test_trace_id_string_is_32_hex_chars
        ]
    ]
;;
