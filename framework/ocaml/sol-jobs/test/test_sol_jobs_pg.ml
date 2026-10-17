let postgres_url =
  match Array.to_list Sys.argv with
  | _ :: url :: _ when String.trim url <> "" -> Some url
  | _ -> None
;;

let test_schema = "sol_test_sol_jobs_pg"

let schema_setup =
  [ "DROP SCHEMA IF EXISTS " ^ test_schema ^ " CASCADE"
  ; "CREATE SCHEMA " ^ test_schema
  ; "SET search_path TO " ^ test_schema
  ]
;;

let ddl =
  [ {|CREATE TABLE sol_jobs (
       id           SERIAL      PRIMARY KEY,
       workspace    TEXT        NOT NULL,
       kind         TEXT        NOT NULL,
       payload      TEXT        NOT NULL,
       status       TEXT        NOT NULL DEFAULT 'pending',
       attempts     INT         NOT NULL DEFAULT 0,
       run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
       locked_until TIMESTAMPTZ,
       last_error   TEXT,
       dedupe_key   TEXT,
       inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
       finished_at  TIMESTAMPTZ)|}
  ; "CREATE UNIQUE INDEX sol_jobs_dedupe_idx ON sol_jobs (workspace, kind, dedupe_key) \
     WHERE dedupe_key IS NOT NULL"
  ; "CREATE INDEX sol_jobs_terminal_idx ON sol_jobs (finished_at) WHERE status <> \
     'pending'"
  ]
;;

let exec_sql pool sql =
  match
    Pg_db.exec
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql)
      ()
  with
  | Ok () -> ()
  | Error e -> Windtrap.failf "%s: %s" sql (Pg_error.to_string e)
;;

let rows pool =
  match
    Pg_db.collect
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t3 string string int))
         ~oneshot:true
         "SELECT kind, status, attempts FROM sol_jobs ORDER BY id")
      ()
  with
  | Ok rows -> rows
  | Error e -> Windtrap.failf "select: %s" (Pg_error.to_string e)
;;

module Job (K : sig
    val kind : string
    val workspace : string
  end) =
struct
  type t = string

  let workspace = K.workspace
  let kind (_ : t) = K.kind
  let kinds = [ K.kind ]
  let encode t = K.kind ^ ":" ^ t

  let decode s =
    let prefix = K.kind ^ ":" in
    if String.starts_with ~prefix s
    then Ok (String.sub s (String.length prefix) (String.length s - String.length prefix))
    else Error ("not a " ^ K.kind ^ " payload: " ^ s)
  ;;

  let handled = ref []

  let handle t =
    handled := t :: !handled;
    Ok ()
  ;;
end

module Email = Job (struct
    let kind = "send_email"
    let workspace = "alpha"
  end)

module Report = Job (struct
    let kind = "build_report"
    let workspace = "alpha"
  end)

module Other_workspace_email = Job (struct
    let kind = "send_email"
    let workspace = "beta"
  end)

module Emails = Sol_jobs.Make (Email)
module Reports = Sol_jobs.Make (Report)

let connection_url url =
  Printf.sprintf
    "%s%soptions=-csearch_path%%3D%s"
    url
    (if String.contains url '?' then "&" else "?")
    test_schema
;;

let assert_isolated pool =
  match
    Pg_db.find
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.string)
         "SELECT current_schema()")
      ()
  with
  | Ok (Some schema) when schema = test_schema -> ()
  | Ok (Some other) ->
    Windtrap.failf "schema isolation lost: current_schema=%s, want %s" other test_schema
  | Ok None -> Windtrap.fail "schema isolation lost: current_schema() is null"
  | Error e -> Windtrap.failf "schema isolation check failed: %s" (Pg_error.to_string e)
;;

let with_pool ?(pool_size = 1) f =
  match postgres_url with
  | None ->
    Windtrap.fail
      "no Postgres address: the runtest-integration alias in \
       framework/ocaml/sol-jobs/test/dune pins one, and a run without a database is not \
       a passing run"
  | Some url ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    (match
       Pg_db.create_pool
         ~url:(connection_url url)
         ~pool_size
         ~sw
         ~stdenv:(env :> Caqti_eio.stdenv)
         ()
     with
     | Error e -> Windtrap.failf "pool: %s" (Pg_error.to_string e)
     | Ok pool ->
       List.iter (exec_sql pool) schema_setup;
       assert_isolated pool;
       f env pool)
;;

let test_make_instances_do_not_cross_claim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    (match Pg_db.transaction pool (fun tx -> Reports.enqueue tx "q3") with
     | Ok () -> ()
     | Error e -> Windtrap.failf "enqueue report: %s" (Pg_error.to_string e));
    (match Pg_db.transaction pool (fun tx -> Emails.enqueue tx "alice") with
     | Ok () -> ()
     | Error e -> Windtrap.failf "enqueue email: %s" (Pg_error.to_string e));
    Email.handled := [];
    (match Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_jobs:1 () with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the email poller ran its own job"
      [ "alice" ]
      !Email.handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"the report job was not claimed by the email poller"
      [ "build_report", "pending", 0; "send_email", "completed", 1 ]
      (rows pool))
;;

let test_another_workspace_rows_are_never_claimed () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    let module Other = Sol_jobs.Make (Other_workspace_email) in
    (match
       Pg_db.transaction pool (fun tx -> Other.enqueue tx ~dedupe_key:"evt-1" "bob")
     with
     | Ok () -> ()
     | Error e -> Windtrap.failf "enqueue beta: %s" (Pg_error.to_string e));
    (match
       Pg_db.transaction pool (fun tx -> Emails.enqueue tx ~dedupe_key:"evt-1" "alice")
     with
     | Ok () -> ()
     | Error e -> Windtrap.failf "enqueue alpha: %s" (Pg_error.to_string e));
    Email.handled := [];
    Other_workspace_email.handled := [];
    Eio.Fiber.first
      (fun () ->
         match Emails.run ~env ~pool ~poll_interval_s:0.05 () with
         | Ok () -> ()
         | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e))
      (fun () -> Eio.Time.sleep env#clock 0.4);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the alpha poller ran only its own job"
      [ "alice" ]
      !Email.handled;
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the beta handler never ran"
      []
      !Other_workspace_email.handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"one dedupe key per workspace: the beta row is still pending"
      [ "send_email", "pending", 0; "send_email", "completed", 1 ]
      (rows pool))
;;

let test_a_poller_sweeps_only_its_own_terminal_rows () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    let module Other = Sol_jobs.Make (Other_workspace_email) in
    (match Pg_db.transaction pool (fun tx -> Emails.enqueue tx "alice") with
     | Ok () -> ()
     | Error e -> Windtrap.failf "enqueue alpha: %s" (Pg_error.to_string e));
    (match Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_jobs:1 () with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
    exec_sql
      pool
      "UPDATE sol_jobs SET finished_at = now() - interval '30 days' WHERE workspace = \
       'alpha'";
    Eio.Fiber.first
      (fun () ->
         match
           Other.run
             ~env
             ~pool
             ~poll_interval_s:0.05
             ~terminal_retention_s:0.0
             ~sweep_interval_s:0.0
             ()
         with
         | Ok () -> ()
         | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e))
      (fun () -> Eio.Time.sleep env#clock 0.4);
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"beta's sweep reclaimed nothing alpha still owns"
      [ "send_email", "completed", 1 ]
      (rows pool))
;;

let test_missing_table_is_a_startup_error () =
  with_pool (fun env pool ->
    exec_sql pool "DROP TABLE IF EXISTS sol_jobs";
    match
      Eio.Time.with_timeout env#clock 5.0 (fun () ->
        Ok (Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_claim_failures:1000 ()))
      |> function
      | Ok r -> r
      | Error `Timeout ->
        Windtrap.fail "no startup error: run started polling a missing table"
    with
    | Error (`Database msg) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the sol_jobs table"
        true
        (Sol_runtime.contains_substring ~needle:"sol_jobs" msg)
    | Error (`Config m) -> Windtrap.failf "expected `Database, got `Config %s" m
    | Ok () -> Windtrap.fail "a missing sol_jobs table must not look like an idle queue")
;;

let test_enqueue_refuses_an_undeclared_kind () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    let module Stray = struct
      include Email

      let kind (_ : t) = "not_declared"
    end
    in
    let module Strays = Sol_jobs.Make (Stray) in
    (match Pg_db.transaction pool (fun tx -> Strays.enqueue tx "x") with
     | Error _ -> ()
     | Ok () -> Windtrap.fail "a kind nothing claims must not be enqueued");
    Windtrap.equal Windtrap.int ~msg:"nothing was inserted" 0 (List.length (rows pool)))
;;

let test_persistent_claim_failure_ends_run () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    let result = ref None in
    Eio.Fiber.both
      (fun () ->
         result
         := Some
              (Eio.Time.with_timeout env#clock 20.0 (fun () ->
                 Ok (Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_claim_failures:3 ()))))
      (fun () ->
         Eio.Time.sleep env#clock 0.3;
         exec_sql pool "DROP TABLE sol_jobs");
    match !result with
    | Some (Ok (Error (`Database _))) -> ()
    | Some (Ok (Error (`Config m))) -> Windtrap.failf "unexpected `Config %s" m
    | Some (Ok (Ok ())) -> Windtrap.fail "run returned Ok while every claim failed"
    | Some (Error `Timeout) -> Windtrap.fail "run kept looping on a failing claim"
    | None -> Windtrap.fail "run did not report")
;;

let reclaim_now pool =
  exec_sql
    pool
    "UPDATE sol_jobs SET attempts = attempts + 1, locked_until = now() + interval '1 \
     hour'"
;;

module Slow = struct
  type t = string

  let workspace = "alpha"
  let kind (_ : t) = "slow"
  let kinds = [ "slow" ]
  let encode t = t
  let decode s = Ok s
  let on_handle : (unit -> (unit, string) result) ref = ref (fun () -> Ok ())
  let handle (_ : t) = !on_handle ()
end

module Slows = Sol_jobs.Make (Slow)

let lease_state pool =
  match
    Pg_db.collect
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string int bool bool))
         ~oneshot:true
         "SELECT status, attempts, locked_until IS NOT NULL, last_error IS NOT NULL FROM \
          sol_jobs")
      ()
  with
  | Ok rows -> List.map (fun (st, n, locked, err) -> st, (n, locked, err)) rows
  | Error e -> Windtrap.failf "select: %s" (Pg_error.to_string e)
;;

let capture_stderr f =
  let path = Filename.temp_file "sol-jobs-stderr-" ".log" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let restore () =
    Unix.dup2 saved Unix.stderr;
    Unix.close saved
  in
  let result =
    match f () with
    | v ->
      restore ();
      v
    | exception e ->
      restore ();
      raise e
  in
  let out = In_channel.with_open_text path In_channel.input_all in
  Sys.remove path;
  result, out
;;

let run_slow
      ?retry_policy
      ?stop
      ?lease_s
      ?max_jobs
      ?terminal_retention_s
      ?sweep_interval_s
      env
      pool
  =
  match
    Slows.run
      ~env
      ~pool
      ?retry_policy
      ?stop
      ?lease_s
      ?max_jobs
      ?terminal_retention_s
      ?sweep_interval_s
      ~poll_interval_s:0.05
      ()
  with
  | Ok () -> ()
  | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e)
;;

let enqueue_slow ?dedupe_key pool =
  match Pg_db.transaction pool (fun tx -> Slows.enqueue tx ?dedupe_key "work") with
  | Ok () -> ()
  | Error e -> Windtrap.failf "enqueue: %s" (Pg_error.to_string e)
;;

let test_stale_complete_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          reclaim_now pool;
          Eio.Promise.resolve stop_r ();
          Ok ());
    let (), err = capture_stderr (fun () -> run_slow ~stop env pool) in
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"the new holder's claim survives: not deleted, still locked"
      [ "pending", (2, true, false) ]
      (lease_state pool);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the lost lease is logged"
      true
      (Sol_runtime.contains_substring ~needle:"lease lost" err))
;;

let test_stale_fail_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          reclaim_now pool;
          Eio.Promise.resolve stop_r ();
          Error "boom");
    let retry_policy =
      { Sol_jobs.base_delay_s = 0.0
      ; max_delay_s = 0.0
      ; max_attempts = 1
      ; jitter_ratio = 0.0
      }
    in
    let (), _ = capture_stderr (fun () -> run_slow ~retry_policy ~stop env pool) in
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"not marked failed, lease not cleared"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_stale_retry_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          reclaim_now pool;
          ignore (Eio.Promise.try_resolve stop_r ());
          Error "transient");
    let (), _ = capture_stderr (fun () -> run_slow ~stop env pool) in
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"retry did not clear the new holder's lease"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_long_handler_renews_lease () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let started, started_r = Eio.Promise.create () in
    let stop, stop_r = Eio.Promise.create () in
    let handled = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr handled;
          ignore (Eio.Promise.try_resolve started_r ());
          Eio.Time.sleep env#clock 2.0;
          Ok ());
    (match
       Eio.Time.with_timeout env#clock 10.0 (fun () ->
         Eio.Fiber.both
           (fun () -> run_slow ~lease_s:1.2 ~max_jobs:1 env pool)
           (fun () ->
              Eio.Promise.await started;
              Eio.Fiber.both
                (fun () -> run_slow ~lease_s:1.2 ~stop env pool)
                (fun () ->
                   Eio.Time.sleep env#clock 1.7;
                   ignore (Eio.Promise.try_resolve stop_r ())));
         Ok ())
     with
     | Ok () -> ()
     | Error `Timeout -> Windtrap.fail "pollers did not finish");
    Windtrap.equal Windtrap.int ~msg:"one handler ran" 1 !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"the completed row is retained, not deleted"
      [ "slow", "completed", 1 ]
      (rows pool))
;;

let test_a_late_heartbeat_keeps_an_unclaimed_lease () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let lapsed, lapsed_r = Eio.Promise.create () in
    let stop, stop_r = Eio.Promise.create () in
    let handled = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr handled;
          exec_sql pool "UPDATE sol_jobs SET locked_until = now() - interval '1 second'";
          ignore (Eio.Promise.try_resolve lapsed_r ());
          Eio.Time.sleep env#clock 2.0;
          Ok ());
    (match
       Eio.Time.with_timeout env#clock 8.0 (fun () ->
         Eio.Fiber.both
           (fun () -> run_slow ~lease_s:1.2 ~max_jobs:1 env pool)
           (fun () ->
              Eio.Promise.await lapsed;
              let query =
                Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.bool)
                  "SELECT locked_until > now() FROM sol_jobs"
              in
              let rec await_renewal () =
                match Pg_db.find pool query () with
                | Ok (Some true) -> ()
                | Ok _ ->
                  Eio.Time.sleep env#clock 0.01;
                  await_renewal ()
                | Error e -> Windtrap.fail (Pg_error.to_string e)
              in
              await_renewal ();
              Eio.Fiber.both
                (fun () -> run_slow ~lease_s:1.2 ~stop env pool)
                (fun () ->
                   Eio.Time.sleep env#clock 1.0;
                   ignore (Eio.Promise.try_resolve stop_r ())));
         Ok ())
     with
     | Ok () -> ()
     | Error `Timeout -> Windtrap.fail "pollers did not finish");
    Windtrap.equal Windtrap.int ~msg:"one handler ran" 1 !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"the handler completed the claim it kept"
      [ "slow", "completed", 1 ]
      (rows pool))
;;

let test_lost_renewal_is_logged () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          Fun.protect
            ~finally:(fun () -> Eio.Promise.resolve stop_r ())
            (fun () ->
               reclaim_now pool;
               Eio.Time.sleep env#clock 1.0;
               Ok ()));
    let (), err = capture_stderr (fun () -> run_slow ~lease_s:0.1 ~stop env pool) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"lost renewal logged"
      true
      (Sol_runtime.contains_substring ~needle:"action=renew" err);
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"new holder remains fenced"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_crashed_attempt_is_exhausted_at_claim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "UPDATE sol_jobs SET attempts = 2, locked_until = now() - interval '1 second'";
    let handled = ref false in
    (Slow.on_handle
     := fun () ->
          handled := true;
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = 2 } in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Windtrap.equal Windtrap.bool ~msg:"handler not called" false !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"exhausted row failed without another attempt"
      [ "slow", "failed", 2 ]
      (rows pool);
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"crash failure is recorded without a live lease"
      [ "failed", (2, false, true) ]
      (lease_state pool))
;;

let test_unlimited_attempts_reclaim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "UPDATE sol_jobs SET attempts = 2, locked_until = now() - interval '1 second'";
    let handled = ref false in
    (Slow.on_handle
     := fun () ->
          handled := true;
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = -1 } in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Windtrap.equal Windtrap.bool ~msg:"handler ran again" true !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"job completed and is retained"
      [ "slow", "completed", 3 ]
      (rows pool))
;;

let test_handler_exception_is_a_failed_attempt () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    (Slow.on_handle := fun () -> failwith "handler exploded");
    let retry_policy =
      { Sol_jobs.default_retry_policy with
        max_attempts = 2
      ; base_delay_s = 0.0
      ; max_delay_s = 0.0
      }
    in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"exception used the normal terminal failure path"
      [ "slow", "failed", 2 ]
      (rows pool))
;;

let test_expired_holder_cannot_complete_terminal_row () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          exec_sql
            pool
            "UPDATE sol_jobs SET status = 'failed', locked_until = NULL, last_error = \
             'worker stopped before finishing the previous attempt'";
          Eio.Promise.resolve stop_r ();
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = 1 } in
    let (), err =
      capture_stderr (fun () -> run_slow ~retry_policy ~lease_s:0.1 ~stop env pool)
    in
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"old holder did not delete terminal row"
      [ "slow", "failed", 1 ]
      (rows pool);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the lost lease is logged"
      true
      (Sol_runtime.contains_substring ~needle:"lease lost" err))
;;

let test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-1" pool;
    enqueue_slow ~dedupe_key:"evt-1" pool;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"one row for a repeated dedupe key"
      [ "slow", "pending", 0 ]
      (rows pool))
;;

let test_concurrent_duplicate_enqueue_inserts_one_row () =
  with_pool ~pool_size:2 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    let inserted, inserted_r = Eio.Promise.create () in
    let contending, contending_r = Eio.Promise.create () in
    let pids = ref [] in
    let identify tx =
      match
        Pg_db.find
          tx
          (Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
             "SELECT pg_backend_pid()")
          ()
      with
      | Ok (Some pid) ->
        pids := pid :: !pids;
        Ok ()
      | Ok None -> Windtrap.fail "no backend pid"
      | Error e -> Error e
    in
    let check = function
      | Ok () -> ()
      | Error e -> Windtrap.fail (Pg_error.to_string e)
    in
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
           check
             (Pg_db.transaction pool (fun tx ->
                let open Result.Syntax in
                let* () = identify tx in
                let* () = Slows.enqueue tx ~dedupe_key:"evt-2" "work" in
                Eio.Promise.resolve inserted_r ();
                Eio.Promise.await contending;
                Eio.Time.sleep env#clock 0.05;
                Ok ())))
        (fun () ->
           Eio.Promise.await inserted;
           check
             (Pg_db.transaction pool (fun tx ->
                let open Result.Syntax in
                let* () = identify tx in
                Eio.Promise.resolve contending_r ();
                Slows.enqueue tx ~dedupe_key:"evt-2" "work"))));
    Windtrap.equal
      Windtrap.int
      ~msg:"two independent database connections"
      2
      (List.length (List.sort_uniq Int.compare !pids));
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"the unique index admits one row from overlapping transactions"
      [ "slow", "pending", 0 ]
      (rows pool))
;;

let test_omitted_dedupe_key_keeps_at_least_once () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    enqueue_slow pool;
    Windtrap.equal
      Windtrap.int
      ~msg:"no dedupe key means no deduplication"
      2
      (List.length (rows pool)))
;;

let test_redelivery_after_completion_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-3" pool;
    (Slow.on_handle := fun () -> Ok ());
    run_slow ~max_jobs:1 env pool;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"the finished row is retained while its key is live"
      [ "slow", "completed", 1 ]
      (rows pool);
    enqueue_slow ~dedupe_key:"evt-3" pool;
    Windtrap.equal
      Windtrap.int
      ~msg:"a redelivery after completion enqueues nothing"
      1
      (List.length (rows pool)))
;;

let test_expired_terminal_row_releases_its_key () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-4" pool;
    (Slow.on_handle := fun () -> Ok ());
    run_slow ~terminal_retention_s:0.0 ~sweep_interval_s:0.0 ~max_jobs:1 env pool;
    Windtrap.equal
      Windtrap.int
      ~msg:"the expired terminal row was swept"
      0
      (List.length (rows pool));
    enqueue_slow ~dedupe_key:"evt-4" pool;
    Windtrap.equal
      Windtrap.int
      ~msg:"the key is reusable once its row is gone"
      1
      (List.length (rows pool)))
;;

let test_retention_is_scoped_to_declared_kinds () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"retained" pool;
    (Slow.on_handle := fun () -> Ok ());
    run_slow ~max_jobs:1 env pool;
    exec_sql pool "UPDATE sol_jobs SET finished_at = now() - interval '1 day'";
    (match Pg_db.transaction pool (fun tx -> Reports.enqueue tx "old-report") with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Pg_error.to_string e));
    exec_sql
      pool
      "UPDATE sol_jobs SET status = 'completed', finished_at = now() - interval '1 day' \
       WHERE kind = 'build_report'";
    (match Reports.run ~env ~pool ~max_jobs:0 ~terminal_retention_s:3600.0 () with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
    enqueue_slow ~dedupe_key:"retained" pool;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      ~msg:"report cleanup removes its row but preserves the slow job and its key"
      [ "slow", "completed", 1 ]
      (rows pool))
;;

let test_enqueue_rejects_invalid_declared_kinds () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    List.iter
      (fun invalid ->
         let module Invalid = struct
           include Slow

           let kinds = [ "slow"; invalid ]
         end
         in
         let module Jobs = Sol_jobs.Make (Invalid) in
         match Pg_db.transaction pool (fun tx -> Jobs.enqueue tx "work") with
         | Error _ -> ()
         | Ok () -> Windtrap.fail "invalid kind declaration was accepted")
      [ ""; "Bad Kind"; "a,b" ];
    Windtrap.equal Windtrap.int 0 (List.length (rows pool)))
;;

let test_enqueue_and_domain_write_share_commit_and_rollback () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    exec_sql pool "CREATE TABLE domain_write (id int PRIMARY KEY)";
    let insert =
      Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit)
        "INSERT INTO domain_write VALUES (?)"
    in
    let transaction id rollback =
      Pg_db.transaction pool (fun tx ->
        let open Result.Syntax in
        let* () = Pg_db.exec tx insert id in
        let* () = Slows.enqueue tx "work" in
        if rollback then Error (Pg_error.Query_error "deliberate rollback") else Ok ())
    in
    (match transaction 1 true with
     | Error _ -> ()
     | Ok () -> Windtrap.fail "rollback succeeded");
    Windtrap.equal Windtrap.int 0 (List.length (rows pool));
    (match transaction 2 false with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Pg_error.to_string e));
    Windtrap.equal Windtrap.int 1 (List.length (rows pool));
    match
      Pg_db.collect
        pool
        (Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.int)
           "SELECT id FROM domain_write")
        ()
    with
    | Ok ids -> Windtrap.equal (Windtrap.list Windtrap.int) [ 2 ] ids
    | Error e -> Windtrap.fail (Pg_error.to_string e))
;;

let metric_sum text name labels =
  String.split_on_char '\n' text
  |> List.fold_left
       (fun total line ->
          if
            String.starts_with ~prefix:(name ^ "{") line
            && List.for_all
                 (fun (key, value) ->
                    Sol_runtime.contains_substring
                      ~needle:(key ^ "=\"" ^ value ^ "\"")
                      line)
                 labels
          then
            total +. float_of_string (List.hd (List.rev (String.split_on_char ' ' line)))
          else total)
       0.0
;;

let test_metrics_distinguish_handler_and_queue_outcomes () =
  List.iter
    (fun (action, handler_result, attempts) ->
       List.iter
         (fun failure ->
            let stale = failure = Some true in
            with_pool (fun env pool ->
              List.iter (exec_sql pool) ddl;
              enqueue_slow pool;
              if failure = Some false
              then
                exec_sql
                  pool
                  "CREATE FUNCTION reject_finalize() RETURNS trigger LANGUAGE plpgsql AS \
                   $$ BEGIN RAISE EXCEPTION 'deliberate finalize rejection'; END $$";
              if failure = Some false
              then
                exec_sql
                  pool
                  "CREATE TRIGGER reject_finalize BEFORE UPDATE ON sol_jobs FOR EACH ROW \
                   WHEN (NEW.locked_until IS NULL) EXECUTE FUNCTION reject_finalize()";
              let stop, stop_r = Eio.Promise.create () in
              (Slow.on_handle
               := fun () ->
                    if stale then reclaim_now pool;
                    Eio.Promise.resolve stop_r ();
                    handler_result);
              Eio.Switch.run (fun sw ->
                let obs =
                  Sol_obs.of_env
                    ~sw
                    ~net:env#net
                    ~clock:env#clock
                    ~mono_clock:env#mono_clock
                    ~service:"jobs-metrics-test"
                    ()
                in
                (match
                   Slows.run
                     ~env
                     ~pool
                     ~ot:obs
                     ~metrics_port:0
                     ~stop
                     ~retry_policy:
                       { Sol_jobs.default_retry_policy with max_attempts = attempts }
                     ()
                 with
                 | Ok () -> ()
                 | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
                let metrics = Sol_obs.metrics_renderer obs () in
                let value name labels =
                  metric_sum metrics name (("kind", "slow") :: labels)
                in
                Windtrap.equal
                  (Windtrap.float 0.0)
                  1.0
                  (value
                     "sol_jobs_handler_outcomes_total"
                     [ ("status", if Result.is_ok handler_result then "ok" else "error") ]);
                Windtrap.equal
                  (Windtrap.float 0.0)
                  ~msg:"only confirmed durable transitions are counted"
                  (if failure = None then 1.0 else 0.0)
                  (value "sol_jobs_processed_total" []);
                Windtrap.equal
                  (Windtrap.float 0.0)
                  (if failure = None then 0.0 else 1.0)
                  (value
                     "sol_jobs_queue_errors_total"
                     [ "action", action
                     ; ("reason", if stale then "lease_lost" else "database_error")
                     ]);
                Windtrap.equal
                  (Windtrap.float 0.0)
                  1.0
                  (value "sol_jobs_job_duration_seconds_count" []))))
         [ None; Some false; Some true ])
    [ "complete", Ok (), 2; "retry", Error "transient", 2; "fail", Error "terminal", 1 ]
;;

let test_max_jobs_counts_confirmed_terminal_transitions () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let calls = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr calls;
          if !calls = 1
          then (
            reclaim_now pool;
            enqueue_slow pool);
          Ok ());
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> run_slow ~max_jobs:1 env pool);
    Windtrap.equal Windtrap.int ~msg:"stale success did not consume max_jobs" 2 !calls;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "pending", 2; "slow", "completed", 1 ]
      (rows pool))
;;

let test_confirmed_loss_cancels_and_joins_handler () =
  with_pool ~pool_size:2 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let started, started_r = Eio.Promise.create () in
    let second, second_r = Eio.Promise.create () in
    let old_stop, old_stop_r = Eio.Promise.create () in
    let calls = ref 0 in
    let cancelled = ref false in
    let cleaned = ref false in
    let stale_returned = ref false in
    (Slow.on_handle
     := fun () ->
          incr calls;
          if !calls = 1
          then (
            exec_sql pool "UPDATE sol_jobs SET locked_until = now() - interval '1 second'";
            Eio.Promise.resolve started_r ();
            try
              Eio.Promise.await second;
              Eio.Time.sleep env#clock 10.0;
              Windtrap.fail "stale handler was not cancelled"
            with
            | Eio.Cancel.Cancelled _ ->
              cancelled := true;
              Eio.Cancel.protect (fun () ->
                Eio.Time.sleep env#clock 0.15;
                cleaned := true);
              Eio.Promise.resolve old_stop_r ();
              Ok ())
          else (
            Eio.Promise.resolve second_r ();
            Eio.Time.sleep env#clock 0.3;
            Ok ()));
    Eio.Switch.run (fun sw ->
      let obs =
        Sol_obs.of_env
          ~sw
          ~net:env#net
          ~clock:env#clock
          ~mono_clock:env#mono_clock
          ~service:"claim-loss-test"
          ()
      in
      Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
        Eio.Fiber.both
          (fun () ->
             (match
                Slows.run
                  ~env
                  ~pool
                  ~lease_s:0.3
                  ~execution_timeout_s:5.0
                  ~stop:old_stop
                  ~ot:obs
                  ~metrics_port:0
                  ()
              with
              | Ok () -> ()
              | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
             stale_returned := true;
             Windtrap.equal
               Windtrap.bool
               ~msg:"run joined cancellation cleanup"
               true
               !cleaned)
          (fun () ->
             Eio.Promise.await started;
             run_slow ~lease_s:0.3 ~max_jobs:1 env pool));
      let metrics = Sol_obs.metrics_renderer obs () in
      Windtrap.equal
        (Windtrap.float 0.0)
        1.0
        (metric_sum
           metrics
           "sol_jobs_queue_errors_total"
           [ "action", "renew"; "reason", "lease_lost" ]);
      Windtrap.equal
        (Windtrap.float 0.0)
        ~msg:"late success never attempted finalization"
        0.0
        (metric_sum metrics "sol_jobs_queue_errors_total" [ "action", "complete" ]);
      Windtrap.equal
        (Windtrap.float 0.0)
        0.0
        (metric_sum metrics "sol_jobs_processed_total" []));
    Windtrap.equal Windtrap.bool true !cancelled;
    Windtrap.equal Windtrap.bool true !stale_returned;
    Windtrap.equal Windtrap.int 2 !calls;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "completed", 2 ]
      (rows pool))
;;

let test_renewal_error_does_not_mean_claim_loss () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let finished = ref false in
    (Slow.on_handle
     := fun () ->
          exec_sql pool "ALTER TABLE sol_jobs RENAME TO unavailable_jobs";
          Eio.Time.sleep env#clock 0.15;
          exec_sql pool "ALTER TABLE unavailable_jobs RENAME TO sol_jobs";
          finished := true;
          Ok ());
    let (), err =
      capture_stderr (fun () -> run_slow ~lease_s:0.09 ~max_jobs:1 env pool)
    in
    Windtrap.equal Windtrap.bool true !finished;
    Windtrap.equal
      Windtrap.bool
      true
      (Sol_runtime.contains_substring ~needle:"lease renewal failed" err);
    Windtrap.equal
      Windtrap.bool
      false
      (Sol_runtime.contains_substring ~needle:"lease lost" err))
;;

let await_active_query env pool prefix =
  let query =
    Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.bool)
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND \
       state='active' AND query LIKE ? AND wait_event_type='Lock')"
  in
  let rec wait () =
    match Pg_db.find pool query (prefix ^ "%") with
    | Ok (Some true) -> ()
    | Ok _ ->
      Eio.Time.sleep env#clock 0.01;
      wait ()
    | Error e -> Windtrap.fail (Pg_error.to_string e)
  in
  wait ()
;;

let test_release_cannot_clear_a_newer_claim () =
  with_pool ~pool_size:4 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "CREATE FUNCTION pause_first_claim() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN \
       PERFORM pg_advisory_xact_lock(1518001); RETURN NEW; END $$";
    exec_sql
      pool
      "CREATE TRIGGER pause_first_claim BEFORE UPDATE ON sol_jobs FOR EACH ROW WHEN \
       (NEW.attempts=1) EXECUTE FUNCTION pause_first_claim()";
    let stop, stop_r = Eio.Promise.create () in
    let handled = ref false in
    (Slow.on_handle
     := fun () ->
          handled := true;
          Ok ());
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let tasks =
          Pg_db.transaction pool (fun tx ->
            let query =
              Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
                "SELECT 1 FROM pg_advisory_xact_lock(1518001)"
            in
            match Pg_db.find tx query () with
            | Error e -> Error e
            | Ok _ ->
              let worker =
                Eio.Fiber.fork_promise ~sw (fun () -> run_slow ~stop env pool)
              in
              await_active_query env pool "WITH candidate AS";
              Eio.Promise.resolve stop_r ();
              let newer =
                Eio.Fiber.fork_promise ~sw (fun () ->
                  exec_sql
                    pool
                    "UPDATE sol_jobs SET attempts=attempts+1, \
                     locked_until=now()+interval '1 hour'")
              in
              await_active_query env pool "UPDATE sol_jobs SET attempts=attempts+1";
              Ok (worker, newer))
        in
        match tasks with
        | Error e -> Windtrap.fail (Pg_error.to_string e)
        | Ok (worker, newer) ->
          Eio.Promise.await_exn worker;
          Eio.Promise.await_exn newer));
    Windtrap.equal Windtrap.bool false !handled;
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      ~msg:"fenced pre-start release preserved the newer generation and lease"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_repeated_prestart_release_exhausts_claim_budget () =
  with_pool ~pool_size:3 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "CREATE FUNCTION pause_claim() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN \
       PERFORM pg_advisory_xact_lock(1518002); RETURN NEW; END $$";
    exec_sql
      pool
      "CREATE TRIGGER pause_claim BEFORE UPDATE ON sol_jobs FOR EACH ROW WHEN \
       (NEW.attempts > OLD.attempts) EXECUTE FUNCTION pause_claim()";
    let handled = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr handled;
          Ok ());
    let policy = { Sol_jobs.default_retry_policy with max_attempts = 2 } in
    Eio.Time.with_timeout_exn env#clock 8.0 (fun () ->
      List.iter
        (fun expected ->
           Eio.Switch.run (fun sw ->
             let stop, stop_r = Eio.Promise.create () in
             let worker =
               Pg_db.transaction pool (fun tx ->
                 let query =
                   Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
                     "SELECT 1 FROM pg_advisory_xact_lock(1518002)"
                 in
                 match Pg_db.find tx query () with
                 | Error e -> Error e
                 | Ok _ ->
                   let worker =
                     Eio.Fiber.fork_promise ~sw (fun () ->
                       run_slow ~retry_policy:policy ~stop env pool)
                   in
                   await_active_query env pool "WITH candidate AS";
                   Eio.Promise.resolve stop_r ();
                   Ok worker)
             in
             match worker with
             | Error e -> Windtrap.fail (Pg_error.to_string e)
             | Ok worker -> Eio.Promise.await_exn worker);
           Windtrap.equal
             (Windtrap.list
                (Windtrap.pair
                   Windtrap.string
                   (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
             [ "pending", (expected, false, true) ]
             (lease_state pool))
        [ 1; 2 ];
      run_slow ~retry_policy:policy ~max_jobs:1 env pool);
    Windtrap.equal
      Windtrap.int
      ~msg:"no released generation entered the handler"
      0
      !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "failed", 2 ]
      (rows pool))
;;

let test_released_claim_is_immediately_reclaimable_with_larger_token () =
  with_pool ~pool_size:3 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "CREATE FUNCTION pause_claim() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN \
       PERFORM pg_advisory_xact_lock(1518003); RETURN NEW; END $$";
    exec_sql
      pool
      "CREATE TRIGGER pause_claim BEFORE UPDATE ON sol_jobs FOR EACH ROW WHEN \
       (NEW.attempts=1) EXECUTE FUNCTION pause_claim()";
    let handled = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr handled;
          Ok ());
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let stop, stop_r = Eio.Promise.create () in
        let worker =
          Pg_db.transaction pool (fun tx ->
            let query =
              Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
                "SELECT 1 FROM pg_advisory_xact_lock(1518003)"
            in
            match Pg_db.find tx query () with
            | Error e -> Error e
            | Ok _ ->
              let worker =
                Eio.Fiber.fork_promise ~sw (fun () ->
                  run_slow ~stop ~lease_s:300.0 env pool)
              in
              await_active_query env pool "WITH candidate AS";
              Eio.Promise.resolve stop_r ();
              Ok worker)
        in
        match worker with
        | Error e -> Windtrap.fail (Pg_error.to_string e)
        | Ok worker -> Eio.Promise.await_exn worker);
      Windtrap.equal Windtrap.int 0 !handled;
      Windtrap.equal
        (Windtrap.list
           (Windtrap.pair
              Windtrap.string
              (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
        [ "pending", (1, false, true) ]
        (lease_state pool);
      run_slow ~max_jobs:1 env pool);
    Windtrap.equal Windtrap.int 1 !handled;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "completed", 2 ]
      (rows pool))
;;

let test_deadline_waits_for_cleanup_and_keeps_renewing () =
  with_pool ~pool_size:2 (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let cancelling, cancelling_r = Eio.Promise.create () in
    let clean = ref false in
    (Slow.on_handle
     := fun () ->
          try
            Eio.Time.sleep env#clock 10.0;
            Ok ()
          with
          | Eio.Cancel.Cancelled _ ->
            Eio.Cancel.protect (fun () ->
              Eio.Promise.resolve cancelling_r ();
              Eio.Time.sleep env#clock 0.8;
              clean := true);
            Ok ());
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
           (match
              Slows.run
                ~env
                ~pool
                ~lease_s:0.3
                ~execution_timeout_s:0.1
                ~retry_policy:{ Sol_jobs.default_retry_policy with max_attempts = 1 }
                ~max_jobs:1
                ()
            with
            | Ok () -> ()
            | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
           Windtrap.equal
             Windtrap.bool
             ~msg:"run waited for protected cleanup"
             true
             !clean)
        (fun () ->
           Eio.Promise.await cancelling;
           Eio.Time.sleep env#clock 0.5;
           match
             Pg_db.find
               pool
               (Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.bool)
                  "SELECT attempts=1 AND status='pending' AND locked_until > now() FROM \
                   sol_jobs")
               ()
           with
           | Ok (Some renewed) ->
             Windtrap.equal
               Windtrap.bool
               ~msg:"lease renewed past original expiry during cleanup"
               true
               renewed
           | _ -> Windtrap.fail "no active cleanup lease"));
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "failed", 1 ]
      (rows pool);
    match
      Pg_db.find
        pool
        (Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.string)
           "SELECT last_error FROM sol_jobs")
        ()
    with
    | Ok (Some message) ->
      Windtrap.equal Windtrap.string "cooperative execution deadline exceeded" message
    | _ -> Windtrap.fail "no timeout failure")
;;

let test_deadline_retries_only_after_handler_stops () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let calls = ref 0 in
    let clean = ref false in
    (Slow.on_handle
     := fun () ->
          incr calls;
          if !calls = 1
          then
            Fun.protect
              ~finally:(fun () -> clean := true)
              (fun () ->
                 Eio.Time.sleep env#clock 10.0;
                 Ok ())
          else (
            Windtrap.equal Windtrap.bool true !clean;
            Ok ()));
    (match
       Slows.run
         ~env
         ~pool
         ~lease_s:0.3
         ~execution_timeout_s:0.1
         ~max_jobs:1
         ~retry_policy:
           { Sol_jobs.default_retry_policy with
             base_delay_s = 0.0
           ; max_delay_s = 0.0
           ; max_attempts = 2
           }
         ()
     with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
    Windtrap.equal Windtrap.int 2 !calls;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "completed", 2 ]
      (rows pool))
;;

let test_outer_cancellation_is_not_timeout_failure () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let started, started_r = Eio.Promise.create () in
    let clean = ref false in
    (Slow.on_handle
     := fun () ->
          Eio.Promise.resolve started_r ();
          Fun.protect
            ~finally:(fun () -> clean := true)
            (fun () ->
               Eio.Time.sleep env#clock 10.0;
               Ok ()));
    Eio.Fiber.first
      (fun () -> ignore (Slows.run ~env ~pool ~lease_s:0.3 ~execution_timeout_s:5.0 ()))
      (fun () -> Eio.Promise.await started);
    Windtrap.equal Windtrap.bool true !clean;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "pending", 1 ]
      (rows pool))
;;

let test_late_completion_includes_decode_before_timer_scheduling () =
  List.iter
    (fun block_decode ->
       with_pool (fun env pool ->
         List.iter (exec_sql pool) ddl;
         enqueue_slow pool;
         let module Blocking = struct
           include Slow

           let decode payload =
             if block_decode then Unix.sleepf 0.12;
             Ok payload
           ;;

           let handle _ =
             if not block_decode then Unix.sleepf 0.12;
             Ok ()
           ;;
         end
         in
         let module Jobs = Sol_jobs.Make (Blocking) in
         (match
            Jobs.run
              ~env
              ~pool
              ~execution_timeout_s:0.05
              ~max_jobs:1
              ~retry_policy:{ Sol_jobs.default_retry_policy with max_attempts = 1 }
              ()
          with
          | Ok () -> ()
          | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
         Windtrap.equal
           (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
           [ "slow", "failed", 1 ]
           (rows pool)))
    [ true; false ]
;;

let test_renewal_uncertainty_during_timeout_cleanup () =
  List.iter
    (fun ownership ->
       with_pool ~pool_size:2 (fun env pool ->
         List.iter (exec_sql pool) ddl;
         enqueue_slow pool;
         exec_sql pool "CREATE TABLE renewal_fault (enabled bool NOT NULL)";
         exec_sql pool "INSERT INTO renewal_fault VALUES (false)";
         exec_sql
           pool
           "CREATE FUNCTION reject_renewal() RETURNS trigger LANGUAGE plpgsql AS $$ \
            BEGIN IF (SELECT enabled FROM renewal_fault) THEN RAISE EXCEPTION \
            'deliberate temporary renewal failure'; END IF; RETURN NEW; END $$";
         exec_sql
           pool
           "CREATE TRIGGER reject_renewal BEFORE UPDATE ON sol_jobs FOR EACH ROW WHEN \
            (NEW.attempts=OLD.attempts AND NEW.locked_until IS NOT NULL) EXECUTE \
            FUNCTION reject_renewal()";
         let cleanup, cleanup_r = Eio.Promise.create () in
         let finish, finish_r = Eio.Promise.create () in
         let stop, stop_r = Eio.Promise.create () in
         let cleaned = ref false in
         let calls = ref 0 in
         (Slow.on_handle
          := fun () ->
               incr calls;
               try
                 Eio.Time.sleep env#clock 30.0;
                 Ok ()
               with
               | Eio.Cancel.Cancelled _ ->
                 Eio.Cancel.protect (fun () ->
                   exec_sql pool "UPDATE renewal_fault SET enabled=true";
                   Eio.Promise.resolve cleanup_r ();
                   Eio.Promise.await finish;
                   cleaned := true);
                 Eio.Promise.resolve stop_r ();
                 Ok ());
         Eio.Switch.run (fun sw ->
           let obs =
             Sol_obs.of_env
               ~sw
               ~net:env#net
               ~clock:env#clock
               ~mono_clock:env#mono_clock
               ~service:"cleanup-uncertainty-test"
               ()
           in
           let errors action reason =
             metric_sum
               (Sol_obs.metrics_renderer obs ())
               "sol_jobs_queue_errors_total"
               [ "action", action; "reason", reason ]
           in
           let rec await_error action reason =
             if errors action reason > 0.0
             then ()
             else (
               Eio.Time.sleep env#clock 0.01;
               await_error action reason)
           in
           Eio.Time.with_timeout_exn env#clock 8.0 (fun () ->
             Eio.Fiber.both
               (fun () ->
                  (match
                     Slows.run
                       ~env
                       ~pool
                       ~ot:obs
                       ~metrics_port:0
                       ~stop
                       ~lease_s:3.0
                       ~execution_timeout_s:0.05
                       ~retry_policy:
                         { Sol_jobs.default_retry_policy with max_attempts = 2 }
                       ()
                   with
                   | Ok () -> ()
                   | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
                  Windtrap.equal Windtrap.bool true !cleaned)
               (fun () ->
                  Eio.Promise.await cleanup;
                  await_error "renew" "database_error";
                  Windtrap.equal
                    Windtrap.int
                    ~msg:"no new local attempt during cleanup"
                    1
                    !calls;
                  Windtrap.equal
                    (Windtrap.list
                       (Windtrap.pair
                          Windtrap.string
                          (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
                    ~msg:"renewal error neither released nor finalized the active attempt"
                    [ "pending", (1, true, false) ]
                    (lease_state pool);
                  exec_sql pool "UPDATE renewal_fault SET enabled=false";
                  if ownership <> "original" then reclaim_now pool;
                  if ownership = "confirmed_lost" then await_error "renew" "lease_lost";
                  Eio.Promise.resolve finish_r ()));
           let metrics = Sol_obs.metrics_renderer obs () in
           let retries =
             metric_sum metrics "sol_jobs_processed_total" [ "status", "retry" ]
           in
           if ownership = "original"
           then (
             Windtrap.equal (Windtrap.float 0.0) 1.0 retries;
             Windtrap.equal
               (Windtrap.list
                  (Windtrap.pair
                     Windtrap.string
                     (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
               [ "pending", (1, false, true) ]
               (lease_state pool))
           else (
             Windtrap.equal (Windtrap.float 0.0) 0.0 retries;
             Windtrap.equal
               (Windtrap.list
                  (Windtrap.pair
                     Windtrap.string
                     (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
               [ "pending", (2, true, false) ]
               (lease_state pool);
             Windtrap.equal
               (Windtrap.float 0.0)
               1.0
               (errors
                  (if ownership = "confirmed_lost" then "renew" else "retry")
                  "lease_lost")))))
    [ "original"; "reclaimed_before_finalize"; "confirmed_lost" ]
;;

let test_parent_cancel_during_timeout_cleanup_propagates () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let cleanup, cleanup_r = Eio.Promise.create () in
    let finish, finish_r = Eio.Promise.create () in
    let context, context_r = Eio.Promise.create () in
    let cancelled = ref false in
    (Slow.on_handle
     := fun () ->
          try
            Eio.Time.sleep env#clock 30.0;
            Ok ()
          with
          | Eio.Cancel.Cancelled _ ->
            Eio.Cancel.protect (fun () ->
              Eio.Promise.resolve cleanup_r ();
              Eio.Promise.await finish);
            Ok ());
    let (), diagnostics =
      capture_stderr (fun () ->
        Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
          Eio.Switch.run (fun sw ->
            let worker =
              Eio.Fiber.fork_promise ~sw (fun () ->
                Eio.Cancel.sub (fun cc ->
                  Eio.Promise.resolve context_r cc;
                  try ignore (Slows.run ~env ~pool ~execution_timeout_s:0.05 ()) with
                  | Eio.Cancel.Cancelled _ -> cancelled := true))
            in
            Eio.Promise.await cleanup;
            Eio.Cancel.cancel
              (Eio.Promise.await context)
              (Failure "parent test cancellation");
            Eio.Promise.resolve finish_r ();
            Eio.Promise.await_exn worker)))
    in
    Windtrap.equal Windtrap.bool true !cancelled;
    Windtrap.equal
      Windtrap.bool
      ~msg:"parent cancellation did not enter timeout finalization"
      false
      (Sol_runtime.contains_substring ~needle:"handler cleanup has exited" diagnostics);
    Windtrap.equal
      (Windtrap.list
         (Windtrap.pair
            Windtrap.string
            (Windtrap.triple Windtrap.int Windtrap.bool Windtrap.bool)))
      [ "pending", (1, true, false) ]
      (lease_state pool))
;;

let test_stop_drains_active_handler_with_deadline () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    let finished = ref false in
    (Slow.on_handle
     := fun () ->
          Eio.Promise.resolve stop_r ();
          Eio.Time.sleep env#clock 0.05;
          finished := true;
          Ok ());
    (match Slows.run ~env ~pool ~stop ~execution_timeout_s:2.0 () with
     | Ok () -> ()
     | Error e -> Windtrap.fail (Sol_jobs.run_error_to_string e));
    Windtrap.equal Windtrap.bool true !finished;
    Windtrap.equal
      (Windtrap.list (Windtrap.triple Windtrap.string Windtrap.string Windtrap.int))
      [ "slow", "completed", 1 ]
      (rows pool))
;;

let () =
  Windtrap.run
    ~argv:[||]
    "sol_jobs_pg"
    [ Windtrap.group
        "cooperative execution deadlines"
        [ Windtrap.test
            "parent cancellation during timeout cleanup propagates"
            test_parent_cancel_during_timeout_cleanup_propagates
        ; Windtrap.test
            "stop drains active execution with deadline"
            test_stop_drains_active_handler_with_deadline
        ; Windtrap.test
            "renewal uncertainty during timeout cleanup preserves fences"
            test_renewal_uncertainty_during_timeout_cleanup
        ; Windtrap.test
            "late completion includes decoding before timer scheduling"
            test_late_completion_includes_decode_before_timer_scheduling
        ; Windtrap.test
            "timeout cleanup keeps renewing"
            test_deadline_waits_for_cleanup_and_keeps_renewing
        ; Windtrap.test
            "retry waits for handler quiescence"
            test_deadline_retries_only_after_handler_stops
        ; Windtrap.test
            "parent cancellation remains distinct"
            test_outer_cancellation_is_not_timeout_failure
        ]
    ; Windtrap.group
        "pre-handler shutdown release"
        [ Windtrap.test
            "release cannot clear newer claim"
            test_release_cannot_clear_a_newer_claim
        ; Windtrap.test
            "repeated prestart releases exhaust budget"
            test_repeated_prestart_release_exhausts_claim_budget
        ; Windtrap.test
            "released claim is immediately reclaimed with larger token"
            test_released_claim_is_immediately_reclaimable_with_larger_token
        ]
    ; Windtrap.group
        "confirmed claim loss"
        [ Windtrap.test
            "loss cancels and joins even a handler returning late success"
            test_confirmed_loss_cancels_and_joins_handler
        ; Windtrap.test
            "renewal errors preserve unknown ownership"
            test_renewal_error_does_not_mean_claim_loss
        ]
    ; Windtrap.group
        "durable outcome accounting"
        [ Windtrap.test
            "handler outcomes differ from durable transitions"
            test_metrics_distinguish_handler_and_queue_outcomes
        ; Windtrap.test
            "max_jobs counts confirmed transitions"
            test_max_jobs_counts_confirmed_terminal_transitions
        ]
    ; Windtrap.group
        "enqueue and retention boundaries"
        [ Windtrap.test
            "retention is scoped to kinds"
            test_retention_is_scoped_to_declared_kinds
        ; Windtrap.test
            "invalid declared kinds cannot enqueue"
            test_enqueue_rejects_invalid_declared_kinds
        ; Windtrap.test
            "domain write and enqueue commit or roll back together"
            test_enqueue_and_domain_write_share_commit_and_rollback
        ]
    ; Windtrap.group
        "claim by kind (BUG-044 a)"
        [ Windtrap.test
            "two Make instances do not cross-claim"
            test_make_instances_do_not_cross_claim
        ; Windtrap.test
            "another workspace's rows are never claimed"
            test_another_workspace_rows_are_never_claimed
        ; Windtrap.test
            "a poller sweeps only its own terminal rows"
            test_a_poller_sweeps_only_its_own_terminal_rows
        ; Windtrap.test
            "enqueue refuses an undeclared kind"
            test_enqueue_refuses_an_undeclared_kind
        ]
    ; Windtrap.group
        "database failures are loud (BUG-044 c)"
        [ Windtrap.test
            "missing table is a startup error"
            test_missing_table_is_a_startup_error
        ; Windtrap.test
            "persistent claim failure ends run"
            test_persistent_claim_failure_ends_run
        ]
    ; Windtrap.group
        "lease fencing (BUG-050)"
        [ Windtrap.test "stale complete is a no-op" test_stale_complete_is_a_no_op
        ; Windtrap.test "stale fail is a no-op" test_stale_fail_is_a_no_op
        ; Windtrap.test "stale retry is a no-op" test_stale_retry_is_a_no_op
        ; Windtrap.test "long handler renews its lease" test_long_handler_renews_lease
        ; Windtrap.test
            "a late heartbeat keeps an unclaimed lease"
            test_a_late_heartbeat_keeps_an_unclaimed_lease
        ; Windtrap.test "lost renewal is logged" test_lost_renewal_is_logged
        ]
    ; Windtrap.group
        "bounded attempts (BUG-098)"
        [ Windtrap.test
            "crashed attempts stop at the configured budget"
            test_crashed_attempt_is_exhausted_at_claim
        ; Windtrap.test
            "handler exceptions are failed attempts"
            test_handler_exception_is_a_failed_attempt
        ; Windtrap.test "unlimited attempts still reclaim" test_unlimited_attempts_reclaim
        ; Windtrap.test
            "expired holder cannot complete a terminal row"
            test_expired_holder_cannot_complete_terminal_row
        ]
    ; Windtrap.group
        "idempotent enqueue (FEAT-112)"
        [ Windtrap.test
            "a repeated dedupe key is a no-op"
            test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op
        ; Windtrap.test
            "concurrent duplicates insert one row"
            test_concurrent_duplicate_enqueue_inserts_one_row
        ; Windtrap.test
            "an omitted dedupe key keeps at-least-once"
            test_omitted_dedupe_key_keeps_at_least_once
        ; Windtrap.test
            "a redelivery after completion is a no-op"
            test_redelivery_after_completion_is_a_no_op
        ; Windtrap.test
            "an expired terminal row releases its key"
            test_expired_terminal_row_releases_its_key
        ]
    ]
;;
