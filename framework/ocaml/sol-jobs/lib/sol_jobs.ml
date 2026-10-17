type retry_policy = Sol_retry.policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

let default_retry_policy = Sol_retry.default_policy

module type JOB = sig
  type t

  val workspace : string
  val kind : t -> string
  val kinds : string list
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Database of string
  ]

let run_error_to_string = function
  | `Config msg -> "sol-jobs: invalid configuration: " ^ msg
  | `Database msg -> "sol-jobs: job table unusable: " ^ msg
;;

let validate_retry_policy policy =
  match Sol_retry.validate policy with
  | Ok () -> Ok ()
  | Error message -> Error (`Config ("retry_policy." ^ message))
;;

let validate_timing ~poll_interval_s ~lease_s =
  let positive_finite name value =
    if Float.is_finite value && value > 0.0
    then Ok ()
    else
      Error
        (`Config
            (Printf.sprintf
               "%s must be a finite number > 0 (got %s)"
               name
               (Float.to_string value)))
  in
  match positive_finite "poll_interval_s" poll_interval_s with
  | Error _ as e -> e
  | Ok () -> positive_finite "lease_s" lease_s
;;

let default_rng = Random.State.make_self_init ()
let default_rng_mutex = Mutex.create ()

let locked_backoff_s policy attempt =
  Mutex.lock default_rng_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock default_rng_mutex)
    (fun () -> Sol_retry.backoff_s ~rng:default_rng policy ~attempt)
;;

let is_kind_char = function
  | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> true
  | _ -> false
;;

let validate_kinds kinds =
  match List.find_opt (fun k -> k = "" || not (String.for_all is_kind_char k)) kinds with
  | _ when kinds = [] ->
    Error (`Config "J.kinds is empty -- a poller that claims no kind would do nothing")
  | Some bad ->
    Error
      (`Config
          (Printf.sprintf
             "J.kinds entry %S is invalid: kinds are non-empty and use only a-z, 0-9, _, \
              ., -"
             bad))
  | None -> Ok ()
;;

let max_workspace_length = 63

let is_workspace_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '-' -> true
  | _ -> false
;;

let validate_workspace workspace =
  if workspace = ""
  then
    Error
      (`Config
          "J.workspace is empty -- a queue with no workspace identity would claim every \
           other workspace's rows")
  else if String.length workspace > max_workspace_length
  then
    Error
      (`Config
          (Printf.sprintf
             "J.workspace is %d bytes, longer than the %d-byte limit"
             (String.length workspace)
             max_workspace_length))
  else if not (String.for_all is_workspace_char workspace)
  then
    Error
      (`Config
          (Printf.sprintf
             "J.workspace %S is invalid: use only a-z, A-Z, 0-9, _, ., -"
             workspace))
  else Ok ()
;;

module For_testing = struct
  let backoff_s = Sol_retry.backoff_s
  let validate_retry_policy = validate_retry_policy
  let validate_timing = validate_timing
  let validate_kinds = validate_kinds
  let validate_workspace = validate_workspace
end

let table = "sol_jobs"

let claim_q =
  Caqti_request.Infix.(
    Caqti_type.(t4 int float string string)
    ->? Caqti_type.(t5 int string string int string))
    (Printf.sprintf
       {|WITH candidate AS (
           SELECT id, attempts, ?::int AS budget, ?::float8 AS lease FROM %s
           WHERE status = 'pending'
             AND workspace = ?
             AND kind = ANY(string_to_array(?, ','))
             AND run_at <= now()
             AND (locked_until IS NULL OR locked_until <= now())
           ORDER BY run_at
           FOR UPDATE SKIP LOCKED
           LIMIT 1
         )
         UPDATE %s AS job
         SET status = CASE WHEN candidate.attempts >= candidate.budget
                                AND candidate.budget >= 0
                           THEN 'failed' ELSE 'pending' END,
             locked_until = CASE WHEN candidate.attempts >= candidate.budget
                                      AND candidate.budget >= 0
                                 THEN NULL ELSE now() + (candidate.lease * interval '1 second') END,
             last_error = CASE WHEN candidate.attempts >= candidate.budget
                                    AND candidate.budget >= 0
                               THEN 'worker stopped before finishing the previous attempt'
                               ELSE job.last_error END,
             finished_at = CASE WHEN candidate.attempts >= candidate.budget
                                     AND candidate.budget >= 0
                                THEN now() ELSE job.finished_at END,
             attempts = CASE WHEN candidate.attempts >= candidate.budget
                                  AND candidate.budget >= 0
                             THEN job.attempts ELSE job.attempts + 1 END
         FROM candidate WHERE job.id = candidate.id
         RETURNING job.id, job.kind, job.payload, job.attempts, job.status|}
       table
       table)
;;

let complete_q =
  Caqti_request.Infix.(Caqti_type.(t3 int int string) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s
         SET status = 'completed', finished_at = now(), locked_until = NULL
         WHERE id = ? AND attempts = ? AND workspace = ? AND status = 'pending'
         RETURNING id|}
       table)
;;

let retry_q =
  Caqti_request.Infix.(Caqti_type.(t5 float string int int string) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s
         SET run_at = now() + (?::float8 * interval '1 second'),
             locked_until = NULL,
             last_error = ?
         WHERE id = ? AND attempts = ? AND workspace = ? AND status = 'pending'
         RETURNING id|}
       table)
;;

let fail_q =
  Caqti_request.Infix.(Caqti_type.(t4 string int int string) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s
         SET status = 'failed', finished_at = now(), locked_until = NULL, last_error = ?
         WHERE id = ? AND attempts = ? AND workspace = ? AND status = 'pending'
         RETURNING id|}
       table)
;;

let renew_q =
  Caqti_request.Infix.(Caqti_type.(t4 float int int string) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s
         SET locked_until = now() + (?::float8 * interval '1 second')
         WHERE id = ? AND attempts = ? AND workspace = ? AND status = 'pending'
         RETURNING id|}
       table)
;;

let sweep_q =
  Caqti_request.Infix.(Caqti_type.(t3 string string float) ->. Caqti_type.unit)
    (Printf.sprintf
       {|DELETE FROM %s
         WHERE status <> 'pending'
           AND workspace = ?
           AND kind = ANY(string_to_array(?, ','))
           AND finished_at IS NOT NULL
           AND finished_at < now() - (?::float8 * interval '1 second')|}
       table)
;;

let table_check_q =
  Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
    (Printf.sprintf "SELECT 1 FROM %s LIMIT 1" table)
;;

let default_max_claim_failures = 30
let default_metrics_port = 9090
let default_poll_interval_s = 1.0
let default_lease_s = 300.0

let with_runtime_unflushed
      ~(env : (_, _, _, _) Sol_env.timed)
      ~ot
      ~metrics_port
      ~stop
      ~max_jobs
      ~body
  =
  let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
  let obs_eio_t = Option.map Sol_obs.obs_eio ot in
  let job_count, job_duration, handler_count, queue_errors =
    match obs_eio_t with
    | None -> None, None, None, None
    | Some o ->
      let c, h =
        Obs_eio.register_counter_and_histogram
          o
          ~counter_name:"sol_jobs_processed_total"
          ~counter_help:"Confirmed durable job transitions by status"
          ~counter_labels:[ "status"; "kind" ]
          ~histogram_name:"sol_jobs_job_duration_seconds"
          ~histogram_help:"Job handler duration in seconds"
          ~histogram_labels:[ "kind" ]
      in
      let handler_count =
        Obs_eio.register_counter
          o
          ~name:"sol_jobs_handler_outcomes_total"
          ~help:"Handler returns before queue finalization"
          ~label_names:[ "status"; "kind" ]
      in
      let queue_errors =
        Obs_eio.register_counter
          o
          ~name:"sol_jobs_queue_errors_total"
          ~help:"Queue operation failures and confirmed claim losses"
          ~label_names:[ "kind"; "action"; "reason" ]
      in
      Some c, Some h, Some handler_count, Some queue_errors
  in
  let signal_stop, signal_stop_r = Eio.Promise.create () in
  let remaining =
    match max_jobs with
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
  let record_terminal () = Option.iter (fun r -> decr r) remaining in
  Eio.Switch.run (fun sw ->
    Sol_runtime.install_signal_handler ~sw signal_stop_r;
    Option.iter
      (fun render ->
         Obs_prometheus.serve
           ~sw
           ~net:env#net
           (`Tcp (Eio.Net.Ipaddr.V4.any, metrics_port))
           render)
      metrics_renderer;
    body
      ~sw
      ~ot:obs_eio_t
      ~job_count
      ~job_duration
      ~handler_count
      ~queue_errors
      ~should_stop
      ~record_terminal)
;;

let with_runtime ~env ~ot ~metrics_port ~stop ~max_jobs ~body =
  let result = with_runtime_unflushed ~env ~ot ~metrics_port ~stop ~max_jobs ~body in
  Option.iter (fun o -> Sol_obs.flush o) ot;
  result
;;

let default_terminal_retention_s = 604800.0
let default_sweep_interval_s = 60.0

let validate_retention ~terminal_retention_s ~sweep_interval_s =
  let non_negative name value =
    if Float.is_finite value && value >= 0.0
    then Ok ()
    else
      Error
        (`Config
            (Printf.sprintf
               "%s must be a finite number >= 0 (got %s)"
               name
               (Float.to_string value)))
  in
  match non_negative "terminal_retention_s" terminal_retention_s with
  | Error _ as e -> e
  | Ok () -> non_negative "sweep_interval_s" sweep_interval_s
;;

module Make (J : JOB) = struct
  let enqueue tx ?run_at ?dedupe_key (job : J.t) =
    let insert_q =
      Caqti_request.Infix.(
        Caqti_type.(t5 string string string float (option string)) ->. Caqti_type.unit)
        (Printf.sprintf
           {|INSERT INTO %s (workspace, kind, payload, run_at, dedupe_key)
             VALUES (?, ?, ?, to_timestamp(?), ?)
             ON CONFLICT (workspace, kind, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING|}
           table)
    in
    let run_at = Option.value run_at ~default:(Unix.gettimeofday ()) in
    let kind = J.kind job in
    if not (List.mem kind J.kinds)
    then
      Error
        (Pg_error.Query_error
           (Printf.sprintf
              "sol-jobs: kind %S is not in J.kinds; nothing would claim it"
              kind))
    else (
      match
        Result.bind (validate_kinds J.kinds) (fun () -> validate_workspace J.workspace)
      with
      | Error (`Config msg) -> Error (Pg_error.Query_error ("sol-jobs: " ^ msg))
      | Error (`Database msg) -> Error (Pg_error.Query_error ("sol-jobs: " ^ msg))
      | Ok () ->
        Pg_db.exec tx insert_q (J.workspace, kind, J.encode job, run_at, dedupe_key))
  ;;

  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~pool
        ?(retry_policy = default_retry_policy)
        ?(poll_interval_s = default_poll_interval_s)
        ?(lease_s = default_lease_s)
        ?ot
        ?(metrics_port = default_metrics_port)
        ?on_ready
        ?stop
        ?max_jobs
        ?(max_claim_failures = default_max_claim_failures)
        ?(terminal_retention_s = default_terminal_retention_s)
        ?(sweep_interval_s = default_sweep_interval_s)
        ()
    =
    let open Result.Syntax in
    let* () = validate_retry_policy retry_policy in
    let* () = validate_timing ~poll_interval_s ~lease_s in
    let* () = validate_kinds J.kinds in
    let* () = validate_workspace J.workspace in
    let* () = validate_retention ~terminal_retention_s ~sweep_interval_s in
    let* () =
      match Pg_db.find pool table_check_q () with
      | Ok _ -> Ok ()
      | Error e ->
        Error
          (`Database
              (Printf.sprintf
                 "cannot read the %s table (an app migration must create it -- see \
                  sol-jobs.md): %s"
                 table
                 (Pg_error.to_string e)))
    in
    let kinds_param = String.concat "," J.kinds in
    with_runtime
      ~env
      ~ot
      ~metrics_port
      ~stop
      ~max_jobs
      ~body:
        (fun
          ~sw:_
          ~ot
          ~job_count
          ~job_duration
          ~handler_count
          ~queue_errors
          ~should_stop
          ~record_terminal
        ->
        Option.iter (fun f -> f ()) on_ready;
        let log_warn fields msg =
          match ot with
          | Some o -> Obs_eio.log_standalone o Obs_eio.Warn ~fields msg
          | None ->
            Printf.eprintf
              "%s %s\n%!"
              msg
              (String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) fields))
        in
        let count status ~kind =
          match job_count with
          | Some c -> c ~labels:[ "status", status; "kind", kind ] 1
          | None -> ()
        in
        let queue_error ~kind ~action ~reason =
          Option.iter
            (fun (c : Obs_eio.counter_fn) ->
               c ~labels:[ "kind", kind; "action", action; "reason", reason ] 1)
            queue_errors
        in
        let lease_lost id ~kind ~attempts ~action =
          queue_error ~kind ~action ~reason:"lease_lost";
          log_warn
            [ "job_id", string_of_int id
            ; "kind", kind
            ; "attempt", string_of_int attempts
            ; "action", action
            ]
            "sol-jobs: lease lost -- the job was re-claimed while this handler ran; this \
             outcome was not recorded and the job may have run concurrently"
        in
        let transition ~id ~kind ~attempts ~action result =
          match result with
          | Ok (Some _) ->
            count
              (match action with
               | "complete" -> "ok"
               | "fail" -> "failed"
               | action -> action)
              ~kind;
            true
          | Ok None ->
            lease_lost id ~kind ~attempts ~action;
            false
          | Error e ->
            queue_error ~kind ~action ~reason:"database_error";
            log_warn
              [ "job_id", string_of_int id
              ; "kind", kind
              ; "attempt", string_of_int attempts
              ; "action", action
              ; "error", Pg_error.to_string e
              ]
              "sol-jobs: failed to persist job transition (the lease may expire and the \
               job may run again)";
            false
        in
        let finalize_success id ~kind ~attempts =
          if
            transition
              ~id
              ~kind
              ~attempts
              ~action:"complete"
              (Pg_db.find pool complete_q (id, attempts, J.workspace))
          then record_terminal ()
        in
        let finalize_failure id ~kind ~attempts ~msg =
          let exhausted =
            retry_policy.max_attempts >= 0 && attempts >= retry_policy.max_attempts
          in
          if exhausted
          then (
            if
              transition
                ~id
                ~kind
                ~attempts
                ~action:"fail"
                (Pg_db.find pool fail_q (msg, id, attempts, J.workspace))
            then record_terminal ())
          else (
            let delay = locked_backoff_s retry_policy attempts in
            ignore
              (transition
                 ~id
                 ~kind
                 ~attempts
                 ~action:"retry"
                 (Pg_db.find pool retry_q (delay, msg, id, attempts, J.workspace))))
        in
        let last_sweep = ref 0.0 in
        let sweep_expired () =
          let now = Eio.Time.now env#clock in
          if now -. !last_sweep >= sweep_interval_s
          then (
            (match
               Pg_db.exec pool sweep_q (J.workspace, kinds_param, terminal_retention_s)
             with
             | Ok () -> ()
             | Error e ->
               log_warn
                 [ "error", Pg_error.to_string e ]
                 "sol-jobs: failed to sweep expired terminal jobs");
            last_sweep := now)
        in
        let rec loop ~failures =
          sweep_expired ();
          if should_stop ()
          then Ok ()
          else (
            match
              Pg_db.find
                pool
                claim_q
                (retry_policy.max_attempts, lease_s, J.workspace, kinds_param)
            with
            | Error e when failures + 1 >= max_claim_failures ->
              Error
                (`Database
                    (Printf.sprintf
                       "%d consecutive claim queries failed; last: %s"
                       (failures + 1)
                       (Pg_error.to_string e)))
            | Error e ->
              log_warn
                [ "error", Pg_error.to_string e
                ; "consecutive_failures", string_of_int (failures + 1)
                ]
                "sol-jobs: claim query failed";
              Eio.Time.sleep env#clock poll_interval_s;
              loop ~failures:(failures + 1)
            | Ok None ->
              Eio.Time.sleep env#clock poll_interval_s;
              loop ~failures:0
            | Ok (Some (_id, kind, _payload, _attempts, "failed")) ->
              count "failed" ~kind;
              record_terminal ();
              loop ~failures:0
            | Ok (Some (id, kind, _payload, attempts, _)) when should_stop () ->
              ignore
                (transition
                   ~id
                   ~kind
                   ~attempts
                   ~action:"retry"
                   (Pg_db.find
                      pool
                      retry_q
                      ( 0.0
                      , "worker stopped before starting handler"
                      , id
                      , attempts
                      , J.workspace )));
              loop ~failures:0
            | Ok (Some (id, kind, payload, attempts, _)) ->
              let t0 = Eio.Time.Mono.now env#mono_clock in
              let outcome =
                Eio.Fiber.first
                  (fun () ->
                     let outcome =
                       try Result.bind (J.decode payload) J.handle with
                       | Eio.Cancel.Cancelled _ as exn -> raise exn
                       | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
                       | exn -> Error (Printexc.to_string exn)
                     in
                     Option.iter
                       (fun (c : Obs_eio.counter_fn) ->
                          c
                            ~labels:
                              [ ("status", if Result.is_ok outcome then "ok" else "error")
                              ; "kind", kind
                              ]
                            1)
                       handler_count;
                     Option.iter
                       (fun (h : Obs_eio.histogram_fn) ->
                          h
                            ~labels:[ "kind", kind ]
                            (Mtime.Span.to_float_ns
                               (Mtime.span t0 (Eio.Time.Mono.now env#mono_clock))
                             /. 1e9))
                       job_duration;
                     `Handled outcome)
                  (fun () ->
                     let rec renew () =
                       Eio.Time.sleep env#clock (lease_s /. 3.0);
                       match
                         Pg_db.find pool renew_q (lease_s, id, attempts, J.workspace)
                       with
                       | Ok (Some _) -> renew ()
                       | Ok None ->
                         lease_lost id ~kind ~attempts ~action:"renew";
                         `Lost_claim
                       | Error e ->
                         queue_error ~kind ~action:"renew" ~reason:"database_error";
                         log_warn
                           [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                           "sol-jobs: lease renewal failed";
                         renew ()
                     in
                     renew ())
              in
              (match outcome with
               | `Lost_claim -> ()
               | `Handled (Ok ()) -> finalize_success id ~kind ~attempts
               | `Handled (Error msg) -> finalize_failure id ~kind ~attempts ~msg);
              loop ~failures:0)
        in
        loop ~failures:0)
  ;;
end
