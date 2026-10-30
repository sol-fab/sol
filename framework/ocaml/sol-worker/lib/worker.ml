type outcome =
  | Ack
  | Fail

module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end

type decode_error_policy = Kafka_service.decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

type run_error =
  [ `Create of Kafka_service.error
  | `Register of Kafka_service.error
  | `Consume of Kafka.Error.t
  ]

let run_error_to_string = function
  | `Create e -> "sol-worker: create failed: " ^ Kafka_service.error_to_string e
  | `Register e -> "sol-worker: register failed: " ^ Kafka_service.error_to_string e
  | `Consume e -> "sol-worker: consume error: " ^ Kafka.Error.to_string e
;;

let default_metrics_port = 9090

let join_stop ~sw ?signal ?caller () =
  let handle, handle_r = Eio.Promise.create () in
  let resolve_once () =
    if not (Eio.Promise.is_resolved handle) then Eio.Promise.resolve handle_r ()
  in
  let watch p =
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Promise.await p;
      resolve_once ();
      `Stop_daemon)
  in
  Option.iter watch signal;
  Option.iter watch caller;
  handle
;;

let with_runtime_unflushed
      ~(env : (_, _, _, _) Sol_env.timed)
      ~ot
      ~metrics_port
      ~stop
      ~max_messages
      ~body
  =
  let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
  let ot = Option.map Sol_obs.obs_eio ot in
  let msg_count, msg_duration =
    match ot with
    | None -> None, None
    | Some o ->
      let c, h =
        Obs_eio.register_counter_and_histogram
          o
          ~counter_name:"sol_worker_messages_total"
          ~counter_help:"Total messages processed by status"
          ~counter_labels:[ "status" ]
          ~histogram_name:"sol_worker_message_duration_seconds"
          ~histogram_help:"Message processing latency in seconds"
          ~histogram_labels:[]
      in
      Some c, Some h
  in
  let assigned_partitions =
    match ot with
    | None -> None
    | Some o ->
      Some
        (Obs_eio.register_gauge
           o
           ~name:"sol_worker_assigned_partitions"
           ~help:
             "Partitions this replica owns right now. 0 is a healthy idle standby \
              (readiness follows group membership), not a fault."
           ~label_names:[])
  in
  let signal_stop, signal_stop_r = Eio.Promise.create () in
  let remaining =
    match max_messages with
    | Some n -> Some (ref n)
    | None -> None
  in
  let should_stop () =
    Eio.Promise.is_resolved signal_stop
    || (match stop with
        | Some p -> Eio.Promise.is_resolved p
        | None -> false)
    ||
    match remaining with
    | Some r -> !r <= 0
    | None -> false
  in
  let advance () =
    match remaining with
    | None -> Kafka.Consumer.Continue
    | Some r ->
      decr r;
      if !r <= 0 then Kafka.Consumer.Stop else Kafka.Consumer.Continue
  in
  let stop_handle ~sw = join_stop ~sw ~signal:signal_stop ?caller:stop () in
  let health = Worker_health.create ~now:(fun () -> Eio.Time.now env#clock) in
  Eio.Switch.run (fun sw ->
    Sol_runtime.install_signal_handler ~sw signal_stop_r;
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Worker_health.serve ~sw ~net:env#net ~port:metrics_port health (fun () ->
        match metrics_renderer with
        | Some render -> render ()
        | None -> ""));
    body
      ~sw
      ~ot
      ~msg_count
      ~msg_duration
      ~should_stop
      ~advance
      ~health
      ~assigned_partitions
      ~stop_handle:(stop_handle ~sw))
;;

let with_runtime ~env ~ot ~metrics_port ~stop ~max_messages ~body =
  let result = with_runtime_unflushed ~env ~ot ~metrics_port ~stop ~max_messages ~body in
  Option.iter (fun o -> Sol_obs.flush o) ot;
  result
;;

let handle_ack
      ~env
      ~ot
      ~(msg_count : Obs_eio.counter_fn option)
      ~(msg_duration : Obs_eio.histogram_fn option)
      ~t0
      ~advance
      ~ack
      ~topic
      ~key
  =
  let dt = Eio.Time.now env#clock -. t0 in
  (match msg_duration with
   | Some h -> h dt
   | None -> ());
  match ack () with
  | Ok () ->
    (match msg_count with
     | Some c -> c ~labels:[ "status", "ok" ] 1
     | None -> ());
    advance ()
  | Error e ->
    (match msg_count with
     | Some c -> c ~labels:[ "status", "ack_failed" ] 1
     | None -> ());
    let fields =
      [ "topic", topic; "error", Kafka.Error.to_string e ]
      @
      match key with
      | Some key -> [ "key", key ]
      | None -> []
    in
    (match ot with
     | None ->
       Printf.eprintf
         "sol-worker: ack failed topic=%s key=%s error=%s; offset not committed, \
          stopping for redelivery\n\
          %!"
         topic
         (Option.value key ~default:"-")
         (Kafka.Error.to_string e)
     | Some o ->
       Obs_eio.log_standalone
         o
         (if Kafka.Error.is_fatal e then Obs_eio.Error else Obs_eio.Warn)
         ~fields
         (if Kafka.Error.is_fatal e
          then "sol-worker: fatal ack failure, stopping consumer"
          else
            "sol-worker: ack failed, offset not committed; message eligible for \
             redelivery"));
    (* At-least-once: a failed commit must not be superseded by a later cumulative
       commit. Stop the consumer and let the broker redeliver the uncommitted message;
       advancing here would make the failure silent and lose the fact after restart. *)
    if Kafka.Error.is_fatal e then Kafka.Consumer.Error e else Kafka.Consumer.Stop
;;

module Make_with_test_seam (W : WORKER) = struct
  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~config
        ?decode_error_policy
        ?ot
        ?(metrics_port = default_metrics_port)
        ?on_ready
        ?stop
        ?max_messages
        ?test_consume_loop
        ()
    =
    let result =
      with_runtime
        ~env
        ~ot
        ~metrics_port
        ~stop
        ~max_messages
        ~body:
          (fun
            ~sw
            ~ot
            ~msg_count
            ~msg_duration
            ~should_stop
            ~advance
            ~health
            ~assigned_partitions
            ~stop_handle
          ->
          let handler msg ~ack ~trace_ctx =
            if should_stop ()
            then Kafka.Consumer.Stop
            else (
              let t0 = Eio.Time.now env#clock in
              match W.handle msg ~trace_ctx with
              | Ack ->
                handle_ack
                  ~env
                  ~ot
                  ~msg_count
                  ~msg_duration
                  ~t0
                  ~advance
                  ~ack
                  ~topic:(Kafka_service.topic_name_to_string W.Message.topic_name)
                  ~key:(W.Message.key msg)
              | Fail ->
                (match msg_count with
                 | Some c -> c ~labels:[ "status", "fail" ] 1
                 | None -> ());
                let topic = Kafka_service.topic_name_to_string W.Message.topic_name in
                let key = W.Message.key msg in
                let fields =
                  [ "topic", topic ]
                  @
                  match key with
                  | Some key -> [ "key", key ]
                  | None -> []
                in
                (match ot with
                 | None ->
                   Printf.eprintf
                     "sol-worker: handler failed a fact topic=%s key=%s; the offset is \
                      not committed and the consumer stops\n\
                      %!"
                     topic
                     (Option.value key ~default:"-")
                 | Some o ->
                   Obs_eio.log_standalone
                     o
                     Obs_eio.Error
                     ~fields
                     "sol-worker: handler failed a fact; the offset is not committed and \
                      the consumer stops. This is a contract failure, not a retryable \
                      one: fix the handler or the fact, then restart.");
                Kafka.Consumer.Stop)
          in
          let open Result.Syntax in
          match test_consume_loop with
          | Some f ->
            f ~handler ();
            Ok ()
          | None ->
            let* svc =
              Kafka_service.create config ~sw |> Result.map_error (fun msg -> `Create msg)
            in
            let* topic =
              Kafka_service.register svc ~net:env#net ~clock:env#clock (module W.Message)
              |> Result.map_error (fun msg -> `Register msg)
            in
            let hooks =
              { Kafka.Consumer.default_hooks with
                on_ready = Option.value on_ready ~default:ignore
              ; on_assignment =
                  (fun owned ->
                    Worker_health.on_assignment health owned;
                    match assigned_partitions with
                    | None -> ()
                    | Some (emit : Obs_eio.gauge_fn) -> emit (Float.of_int owned))
              ; on_poll = (fun () -> Worker_health.on_poll health)
              }
            in
            Kafka_service.consume
              svc
              topic
              ~group_id:W.group_id
              ~sw
              ~clock:env#clock
              ~hooks
              ?decode_error_policy
              ?ot
              ~stop:stop_handle
              ~handler
              ()
            |> Result.map_error (fun e -> `Consume e))
    in
    result
  ;;
end

module Make (W : WORKER) = struct
  module Impl = Make_with_test_seam (W)

  let run
        ~env
        ~config
        ?decode_error_policy
        ?ot
        ?metrics_port
        ?on_ready
        ?stop
        ?max_messages
        ()
    =
    Impl.run
      ~env
      ~config
      ?decode_error_policy
      ?ot
      ?metrics_port
      ?on_ready
      ?stop
      ?max_messages
      ()
  ;;
end

module For_testing = struct
  let join_stop = join_stop

  module Make = Make_with_test_seam
end
