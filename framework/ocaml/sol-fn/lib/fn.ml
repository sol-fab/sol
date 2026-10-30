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
