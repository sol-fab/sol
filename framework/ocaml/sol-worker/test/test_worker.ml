module TestMsg = struct
  type t = { id : string }

  let topic_name = Kafka_service.topic_name_exn "sol-worker-unit-test"

  let schema =
    {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  ;;

  let partitions = 1
  let key t = Some t.id
  let encode t = `Assoc [ "id", `String t.id ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
  ;;
end

let fake_config : Kafka_service.config =
  { brokers = [ "localhost:9092" ]
  ; schema_registry_url = "http://127.0.0.1:1"
  ; admin_url = "http://127.0.0.1:1"
  ; linger_ms = 5
  ; topic_durability = Kafka_service.Broker_default
  ; security = Kafka.Security.default
  }
;;

module OkWorker = struct
  module Message = TestMsg

  let group_id = "test-ok"

  let handle msg ~trace_ctx:_ =
    ignore msg;
    Worker.Ack
  ;;
end

module FailWorker = struct
  module Message = TestMsg

  let group_id = "test-fail"
  let handle _msg ~trace_ctx:_ = Worker.Fail
end

let one_message msg ~handler () =
  let result = handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  match result with
  | Kafka.Consumer.Continue | Kafka.Consumer.Stop -> ()
  | Kafka.Consumer.Error _ -> ()
;;

let two_messages msgs ~handler () =
  List.iter
    (fun msg ->
       match handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None with
       | Kafka.Consumer.Continue | Kafka.Consumer.Stop -> ()
       | Kafka.Consumer.Error _ -> ())
    msgs
;;

let one_message_with_ack msg ~ack ~result_r ~handler () =
  result_r := Some (handler msg ~ack ~trace_ctx:None)
;;

let run_ok result =
  match result with
  | Ok () -> ()
  | Error e -> Windtrap.fail (Worker.run_error_to_string e)
;;

let test_handle_ok () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-1" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    W.run ~env ~config:fake_config ~test_consume_loop:(one_message msg) () |> run_ok)
;;

let test_handle_fail_stops_without_acking () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-fail" } in
    let module W = Worker.For_testing.Make (FailWorker) in
    let acked = ref false in
    let result_r = ref None in
    W.run
      ~env
      ~config:fake_config
      ~test_consume_loop:(fun ~handler () ->
        result_r
        := Some
             (handler
                msg
                ~ack:(fun () ->
                  acked := true;
                  Ok ())
                ~trace_ctx:None))
      ()
    |> run_ok;
    Windtrap.equal
      Windtrap.bool
      ~msg:"a fact the handler declined to apply is not acknowledged"
      false
      !acked;
    match !result_r with
    | Some Kafka.Consumer.Stop -> ()
    | _ -> Windtrap.fail "expected Fail to stop the consumer")
;;

let test_metrics_ok_counter () =
  Eio_main.run (fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let obs =
      Sol_obs.of_env
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~service:"test-worker"
        ()
    in
    let render = Sol_obs.metrics_renderer obs in
    let msg = TestMsg.{ id = "msg-metrics" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    W.run
      ~env
      ~config:fake_config
      ~ot:obs
      ~metrics_port:0
      ~test_consume_loop:(one_message msg)
      ()
    |> run_ok;
    let output = render () in
    Windtrap.equal
      Windtrap.bool
      ~msg:"messages_total counter present"
      true
      (let needle = "sol_worker_messages_total" in
       let n = String.length needle
       and s = String.length output in
       let found = ref false in
       for i = 0 to s - n do
         if String.sub output i n = needle then found := true
       done;
       !found);
    Windtrap.equal
      Windtrap.bool
      ~msg:"status=ok label present"
      true
      (let needle = {|status="ok"|} in
       let n = String.length needle
       and s = String.length output in
       let found = ref false in
       for i = 0 to s - n do
         if String.sub output i n = needle then found := true
       done;
       !found))
;;

let test_metrics_fail_counter () =
  Eio_main.run (fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let obs =
      Sol_obs.of_env
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~service:"test-worker"
        ()
    in
    let render = Sol_obs.metrics_renderer obs in
    let msg = TestMsg.{ id = "msg-err-metrics" } in
    let module W = Worker.For_testing.Make (FailWorker) in
    W.run
      ~env
      ~config:fake_config
      ~ot:obs
      ~metrics_port:0
      ~test_consume_loop:(one_message msg)
      ()
    |> run_ok;
    let output = render () in
    Windtrap.equal
      Windtrap.bool
      ~msg:"status=fail label present"
      true
      (let needle = {|status="fail"|} in
       let n = String.length needle
       and s = String.length output in
       let found = ref false in
       for i = 0 to s - n do
         if String.sub output i n = needle then found := true
       done;
       !found))
;;

let test_metrics_duration () =
  Eio_main.run (fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let obs =
      Sol_obs.of_env
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~service:"test-worker"
        ()
    in
    let render = Sol_obs.metrics_renderer obs in
    let msg = TestMsg.{ id = "msg-dur" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    W.run
      ~env
      ~config:fake_config
      ~ot:obs
      ~metrics_port:0
      ~test_consume_loop:(one_message msg)
      ()
    |> run_ok;
    let output = render () in
    Windtrap.equal
      Windtrap.bool
      ~msg:"duration histogram present"
      true
      (let needle = "sol_worker_message_duration_seconds" in
       let n = String.length needle
       and s = String.length output in
       let found = ref false in
       for i = 0 to s - n do
         if String.sub output i n = needle then found := true
       done;
       !found))
;;

let test_metrics_endpoint_served () =
  Eio_main.run (fun env ->
    Eio.Switch.run
    @@ fun sw ->
    match
      Eio.Net.listen ~backlog:1 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    with
    | exception Unix.Unix_error (Unix.EPERM, "bind", _) ->
      Windtrap.fail
        "this host forbids binding a loopback socket (EPERM at bind); the /metrics \
         endpoint contract cannot be established here, so run the suite on a host that \
         permits bind()"
    | socket ->
      let port =
        Eio.Net.listening_addr socket
        |> function
        | `Tcp (_, p) -> p
        | _ -> failwith "unexpected address family"
      in
      Eio.Flow.close socket;
      let obs =
        Sol_obs.of_env
          ~sw
          ~net:env#net
          ~clock:env#clock
          ~mono_clock:env#mono_clock
          ~service:"test-worker"
          ()
      in
      let msg = TestMsg.{ id = "msg-http-metrics" } in
      let module W = Worker.For_testing.Make (OkWorker) in
      W.run
        ~env
        ~config:fake_config
        ~ot:obs
        ~metrics_port:port
        ~test_consume_loop:(fun ~handler () ->
          ignore (handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None);
          let client = Cohttp_eio.Client.make ~https:None env#net in
          Eio.Switch.run
          @@ fun sw ->
          let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/metrics" port) in
          let resp, body = Cohttp_eio.Client.call client ~sw `GET uri in
          let body = Eio.Buf_read.(parse_exn take_all) body ~max_size:(64 * 1024) in
          Windtrap.equal
            Windtrap.int
            ~msg:"GET /metrics status"
            200
            (Http.Status.to_int (Http.Response.status resp));
          Windtrap.equal
            Windtrap.bool
            ~msg:"serves worker metric"
            true
            (let needle = "sol_worker_messages_total" in
             let n = String.length needle
             and s = String.length body in
             let found = ref false in
             for i = 0 to s - n do
               if String.sub body i n = needle then found := true
             done;
             !found))
        ()
      |> run_ok)
;;

let test_stop_requested_after_a_message_stops_before_the_next () =
  Eio_main.run (fun env ->
    let processed = ref 0 in
    let stop_p, stop_r = Eio.Promise.create () in
    let module StopWorker = struct
      module Message = TestMsg

      let group_id = "test-stop"

      let handle _msg ~trace_ctx:_ =
        incr processed;
        Eio.Promise.resolve stop_r ();
        Worker.Ack
      ;;
    end
    in
    let msgs = [ TestMsg.{ id = "msg-a" }; TestMsg.{ id = "msg-b" } ] in
    let module W = Worker.For_testing.Make (StopWorker) in
    W.run ~env ~config:fake_config ~stop:stop_p ~test_consume_loop:(two_messages msgs) ()
    |> run_ok;
    Windtrap.equal
      Windtrap.int
      ~msg:"the in-flight message completed and the next one never started"
      1
      !processed)
;;

let test_stop_handle_wakes_from_either_source () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let handle_of ?signal ?caller () =
        Worker.For_testing.join_stop ~sw ?signal ?caller ()
      in
      let signal, signal_r = Eio.Promise.create () in
      let caller, caller_r = Eio.Promise.create () in
      let handle = handle_of ~signal ~caller () in
      Eio.Fiber.yield ();
      Windtrap.equal
        Windtrap.bool
        ~msg:"unresolved while neither source has fired"
        false
        (Eio.Promise.is_resolved handle);
      Eio.Promise.resolve caller_r ();
      Eio.Fiber.yield ();
      Windtrap.equal
        Windtrap.bool
        ~msg:"the caller's promise wakes the handle"
        true
        (Eio.Promise.is_resolved handle);
      Eio.Promise.resolve signal_r ();
      Eio.Fiber.yield ();
      Windtrap.equal
        Windtrap.bool
        ~msg:"a second source firing is harmless"
        true
        (Eio.Promise.is_resolved handle);
      let signal_only, signal_only_r = Eio.Promise.create () in
      let handle_signal = handle_of ~signal:signal_only () in
      Eio.Fiber.yield ();
      Windtrap.equal
        Windtrap.bool
        ~msg:"the signal source alone starts unresolved"
        false
        (Eio.Promise.is_resolved handle_signal);
      Eio.Promise.resolve signal_only_r ();
      Eio.Fiber.yield ();
      Windtrap.equal
        Windtrap.bool
        ~msg:"the signal source wakes the handle"
        true
        (Eio.Promise.is_resolved handle_signal)))
;;

let test_no_metrics_without_ot () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-no-ot" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    W.run ~env ~config:fake_config ~test_consume_loop:(one_message msg) () |> run_ok)
;;

let test_max_messages_stops_cleanly () =
  Eio_main.run (fun env ->
    let processed = ref 0 in
    let module CountWorker = struct
      module Message = TestMsg

      let group_id = "test-max"

      let handle _msg ~trace_ctx:_ =
        incr processed;
        Worker.Ack
      ;;
    end
    in
    let msgs = List.init 5 (fun i -> TestMsg.{ id = Printf.sprintf "m%d" i }) in
    let module W = Worker.For_testing.Make (CountWorker) in
    W.run
      ~env
      ~config:fake_config
      ~max_messages:3
      ~test_consume_loop:(fun ~handler () ->
        List.iter
          (fun msg -> ignore (handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None))
          msgs)
      ()
    |> run_ok;
    Windtrap.equal
      Windtrap.int
      ~msg:"stops after max_messages successful messages"
      3
      !processed)
;;

let test_ack_failure_non_fatal_stops_and_is_metered () =
  Eio_main.run (fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let obs =
      Sol_obs.of_env
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~service:"test-worker"
        ()
    in
    let render = Sol_obs.metrics_renderer obs in
    let msg = TestMsg.{ id = "msg-ack-fail" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    let result_r = ref None in
    W.run
      ~env
      ~config:fake_config
      ~ot:obs
      ~metrics_port:0
      ~test_consume_loop:
        (one_message_with_ack
           msg
           ~ack:(fun () -> Error Kafka.Error.Application)
           ~result_r)
      ()
    |> run_ok;
    (match !result_r with
     | Some Kafka.Consumer.Stop -> ()
     | _ -> Windtrap.fail "expected Stop after a non-fatal ack failure");
    let output = render () in
    Windtrap.equal
      Windtrap.bool
      ~msg:"status=ack_failed label present"
      true
      (let needle = {|status="ack_failed"|} in
       let n = String.length needle
       and s = String.length output in
       let found = ref false in
       for i = 0 to s - n do
         if String.sub output i n = needle then found := true
       done;
       !found))
;;

let test_ack_failure_fatal_escalates () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-ack-fatal" } in
    let module W = Worker.For_testing.Make (OkWorker) in
    let result_r = ref None in
    W.run
      ~env
      ~config:fake_config
      ~test_consume_loop:
        (one_message_with_ack msg ~ack:(fun () -> Error Kafka.Error.Fatal) ~result_r)
      ()
    |> run_ok;
    match !result_r with
    | Some (Kafka.Consumer.Error e) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"escalated error is fatal"
        true
        (Kafka.Error.is_fatal e)
    | _ -> Windtrap.fail "expected the handler to return Error for a fatal ack failure")
;;

let test_external_stop_flag_skips_messages () =
  Eio_main.run (fun env ->
    let stop = Eio.Promise.create_resolved () in
    let processed = ref 0 in
    let module StopWorker = struct
      module Message = TestMsg

      let group_id = "test-ext-stop"

      let handle _msg ~trace_ctx:_ =
        incr processed;
        Worker.Ack
      ;;
    end
    in
    let msgs = [ TestMsg.{ id = "m1" }; TestMsg.{ id = "m2" } ] in
    let module W = Worker.For_testing.Make (StopWorker) in
    W.run ~env ~config:fake_config ~stop ~test_consume_loop:(two_messages msgs) ()
    |> run_ok;
    Windtrap.equal
      Windtrap.int
      ~msg:"W.handle never called when stop pre-set"
      0
      !processed)
;;

let test_ready_without_owning_a_partition () =
  let now = ref 0.0 in
  let health = Worker_health.create ~now:(fun () -> !now) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ready before joining"
    false
    (Worker_health.is_ready health);
  Worker_health.on_assignment health 0;
  Windtrap.equal
    Windtrap.bool
    ~msg:"a member owning no partition is ready"
    true
    (Worker_health.is_ready health);
  Worker_health.on_assignment health 2;
  Worker_health.on_assignment health 0;
  Windtrap.equal
    Windtrap.bool
    ~msg:"a rebalance that takes the partitions away stays ready"
    true
    (Worker_health.is_ready health)
;;

let test_owned_partitions_are_observable () =
  let now = ref 0.0 in
  let health = Worker_health.create ~now:(fun () -> !now) in
  Windtrap.equal
    Windtrap.int
    ~msg:"nothing owned before joining"
    0
    (Worker_health.assigned_partitions health);
  Worker_health.on_assignment health 3;
  Windtrap.equal
    Windtrap.int
    ~msg:"the owned count follows the assignment"
    3
    (Worker_health.assigned_partitions health);
  Worker_health.on_assignment health 0;
  Windtrap.equal
    Windtrap.int
    ~msg:"an idle standby reports zero"
    0
    (Worker_health.assigned_partitions health)
;;

let test_liveness_is_poll_cadence () =
  let now = ref 0.0 in
  let health = Worker_health.create ~now:(fun () -> !now) in
  Windtrap.equal Windtrap.bool ~msg:"fresh is live" true (Worker_health.is_live health);
  now := Worker_health.liveness_bound_s +. 1.0;
  Windtrap.equal
    Windtrap.bool
    ~msg:"a stalled poll loop is not live"
    false
    (Worker_health.is_live health);
  Worker_health.on_poll health;
  Windtrap.equal
    Windtrap.bool
    ~msg:"a successful poll restores liveness"
    true
    (Worker_health.is_live health)
;;

let () =
  Windtrap.run
    "sol_worker"
    [ Windtrap.group
        "lifecycle"
        [ Windtrap.test "handle ok returns normally" test_handle_ok
        ; Windtrap.test
            "Fail stops without acking the fact"
            test_handle_fail_stops_without_acking
        ; Windtrap.test "no ot — no crash" test_no_metrics_without_ot
        ; Windtrap.test
            "a stop request after a message stops before the next"
            test_stop_requested_after_a_message_stops_before_the_next
        ; Windtrap.test
            "stop handle wakes from the signal or the caller"
            test_stop_handle_wakes_from_either_source
        ; Windtrap.test "max_messages stops cleanly" test_max_messages_stops_cleanly
        ; Windtrap.test
            "external stop flag skips messages"
            test_external_stop_flag_skips_messages
        ; Windtrap.test
            "non-fatal ack failure stops for redelivery"
            test_ack_failure_non_fatal_stops_and_is_metered
        ; Windtrap.test
            "fatal ack failure escalates to Error"
            test_ack_failure_fatal_escalates
        ]
    ; Windtrap.group
        "metrics"
        [ Windtrap.test "ok counter emitted" test_metrics_ok_counter
        ; Windtrap.test "fail counter emitted" test_metrics_fail_counter
        ; Windtrap.test "duration histogram emitted" test_metrics_duration
        ; Windtrap.test "metrics endpoint served" test_metrics_endpoint_served
        ]
    ; Windtrap.group
        "readiness follows membership, not ownership"
        [ Windtrap.test "an idle standby is ready" test_ready_without_owning_a_partition
        ; Windtrap.test
            "the owned count is observable"
            test_owned_partitions_are_observable
        ; Windtrap.test "liveness is poll cadence" test_liveness_is_poll_cadence
        ]
    ]
;;
