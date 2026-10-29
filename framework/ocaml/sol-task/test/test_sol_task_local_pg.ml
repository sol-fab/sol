open Result.Syntax

let postgres_url =
  match Array.to_list Sys.argv with
  | _ :: url :: _ when String.trim url <> "" -> url
  | _ -> failwith "usage: test_sol_task_local_pg.exe POSTGRES_URL"
;;

let schema = "sol_test_sol_task_local_pg"

let exec_sql pool sql =
  match
    Pg_db.exec
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql)
      ()
  with
  | Ok () -> ()
  | Error error -> failwith (sql ^ ": " ^ Pg_error.to_string error)
;;

let ddl =
  [ "SET search_path TO " ^ schema
  ; {|CREATE TABLE sol_jobs (
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
  ]
;;

let setup = [ "DROP SCHEMA IF EXISTS " ^ schema ^ " CASCADE"; "CREATE SCHEMA " ^ schema ]

type task =
  | Ok of string
  | Retry of string
  | Flaky of string

let seen = ref []
let effects : (string, unit) Hashtbl.t = Hashtbl.create 8

module T = struct
  type t = task

  let workspace = "task-test"

  let kind = function
    | Ok _ -> "ok"
    | Retry _ -> "retry"
    | Flaky _ -> "flaky"
  ;;

  let kinds = [ "ok"; "retry"; "flaky" ]

  let encode = function
    | Ok value -> "ok:" ^ value
    | Retry value -> "retry:" ^ value
    | Flaky value -> "flaky:" ^ value
  ;;

  let decode text =
    match String.index_opt text ':' with
    | None -> Error "missing separator"
    | Some at ->
      let prefix = String.sub text 0 at in
      let value = String.sub text (at + 1) (String.length text - at - 1) in
      (match prefix with
       | "ok" -> Ok (Ok value)
       | "retry" -> Ok (Retry value)
       | "flaky" -> Ok (Flaky value)
       | _ -> Error ("unknown kind " ^ prefix))
  ;;

  let handle ~task_id ?idempotency_key task =
    seen := (task_id, idempotency_key, task) :: !seen;
    match task with
    | Ok _ -> Sol_task.Ack
    | Retry message -> Sol_task.Retry message
    | Flaky _ ->
      (* The side effect is idempotent on the stable task_id. The first delivery
         commits it and asks for a retry; the redelivery sees it and acknowledges. *)
      if Hashtbl.mem effects task_id
      then Sol_task.Ack
      else (
        Hashtbl.replace effects task_id ();
        Sol_task.Retry "first delivery")
  ;;
end

module Runtime = Sol_task_local.Make (T)

let retry_once =
  { Sol_jobs.base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 1; jitter_ratio = 0.0 }
;;

let retry_twice = { retry_once with max_attempts = 2 }

let row pool =
  match
    Pg_db.find
      pool
      (Caqti_request.Infix.(
         Caqti_type.unit ->! Caqti_type.(t4 string int (option string) int))
         "SELECT status, attempts, last_error, id FROM sol_jobs ORDER BY id DESC LIMIT 1")
      ()
  with
  | Ok (Some row) -> row
  | Ok None -> failwith "no job row"
  | Error error -> failwith ("select: " ^ Pg_error.to_string error)
;;

let run_one ?(retry_policy = retry_once) env pool =
  match
    Runtime.run ~env ~pool ~retry_policy ~poll_interval_s:0.01 ~lease_s:5.0 ~max_jobs:1 ()
  with
  | Ok () -> ()
  | Error error -> failwith (Sol_jobs.run_error_to_string error)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match
    Pg_db.create_pool
      ~url:postgres_url
      ~pool_size:1
      ~sw
      ~stdenv:(env :> Caqti_eio.stdenv)
      ()
  with
  | Error error -> failwith (Pg_error.to_string error)
  | Ok pool ->
    List.iter (exec_sql pool) setup;
    List.iter (exec_sql pool) ddl;
    (match Pg_db.transaction pool (fun tx -> Runtime.enqueue tx (Ok "one")) with
     | Ok () -> ()
     | Error error -> failwith (Pg_error.to_string error));
    run_one env pool;
    (match row pool with
     | "completed", 1, _, _ -> ()
     | status, attempts, error, _ ->
       failwith
         (Printf.sprintf
            "ack task: status=%s attempts=%d error=%s"
            status
            attempts
            (Option.value error ~default:"")));
    (match Pg_db.transaction pool (fun tx -> Runtime.enqueue tx (Retry "nope")) with
     | Ok () -> ()
     | Error error -> failwith (Pg_error.to_string error));
    run_one env pool;
    (match row pool with
     | "failed", 1, Some "nope", _ -> ()
     | status, attempts, error, _ ->
       failwith
         (Printf.sprintf
            "retry task: status=%s attempts=%d error=%s"
            status
            attempts
            (Option.value error ~default:"")));
    (* Duplicate delivery: the handler sees the same task_id on the retry, and its
       side effect is applied once because it is keyed by that stable identity. *)
    (match Pg_db.transaction pool (fun tx -> Runtime.enqueue tx (Flaky "once")) with
     | Ok () -> ()
     | Error error -> failwith (Pg_error.to_string error));
    run_one ~retry_policy:retry_twice env pool;
    (match row pool with
     | "completed", 2, _, _ -> ()
     | status, attempts, error, _ ->
       failwith
         (Printf.sprintf
            "flaky task: status=%s attempts=%d error=%s"
            status
            attempts
            (Option.value error ~default:"")));
    (match Hashtbl.length effects with
     | 1 -> ()
     | count -> failwith (Printf.sprintf "expected one idempotent effect, got %d" count));
    let flaky_attempts =
      !seen
      |> List.filter_map (fun (task_id, _, task) ->
        match task with
        | Flaky _ -> Some task_id
        | _ -> None)
    in
    (match flaky_attempts with
     | [ first; second ] when String.equal first second -> ()
     | _ ->
       failwith
         (Printf.sprintf
            "expected two deliveries with one task_id, got [%s]"
            (String.concat ", " flaky_attempts)));
    (* Idempotent enqueue: the same key inserts once, even across calls. *)
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Runtime.enqueue tx ~idempotency_key:"dedupe-1" (Ok "first") in
         Runtime.enqueue tx ~idempotency_key:"dedupe-1" (Ok "second"))
     with
     | Ok () -> ()
     | Error error -> failwith (Pg_error.to_string error));
    (match
       Pg_db.find
         pool
         (Caqti_request.Infix.(Caqti_type.string ->! Caqti_type.int)
            "SELECT count(*)::int FROM sol_jobs WHERE workspace = ?")
         T.workspace
     with
     | Ok (Some 4) -> ()
     | Ok (Some count) -> failwith (Printf.sprintf "expected 4 rows, got %d" count)
     | Ok None -> failwith "no count row"
     | Error error -> failwith (Pg_error.to_string error));
    ignore !seen;
    print_endline "sol-task local Postgres integration passed"
;;
