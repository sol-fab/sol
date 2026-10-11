module M = Sol_cli_migration

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_tmp_dir f =
  let dir = Filename.temp_file "sol-migration-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir dir
      |> Array.iter (fun entry ->
        try Sys.remove (Filename.concat dir entry) with
        | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f dir)
;;

let test_table_name () =
  Windtrap.equal
    Windtrap.string
    ~msg:"per-workspace, same naming as sol migrate"
    "sol_pluto_schema_migrations"
    (M.table_name ~workspace:"pluto");
  Windtrap.equal
    Windtrap.string
    ~msg:"punctuation becomes an underscore"
    "sol_my_ws_schema_migrations"
    (M.table_name ~workspace:"My-WS")
;;

let test_table_name_is_bounded () =
  let at_limit = String.make 41 'a' in
  let over_limit = String.make 42 'a' in
  Windtrap.equal
    Windtrap.string
    ~msg:"a name that lands exactly on the limit keeps the readable form"
    (Printf.sprintf "sol_%s_schema_migrations" at_limit)
    (M.table_name ~workspace:at_limit);
  let shortened = M.table_name ~workspace:over_limit in
  Windtrap.equal
    Windtrap.bool
    ~msg:"one byte past the limit is shortened"
    true
    (String.length shortened <= M.postgres_identifier_max_bytes && shortened <> over_limit);
  List.iter
    (fun workspace ->
       let table = M.table_name ~workspace in
       Windtrap.equal
         Windtrap.bool
         ~msg:
           (Printf.sprintf
              "a %d-byte workspace name stays within the identifier limit"
              (String.length workspace))
         true
         (String.length table <= M.postgres_identifier_max_bytes))
    [ ""; "pluto"; String.make 300 'a'; "wörk"; "My-WS"; over_limit ]
;;

let test_long_workspace_names_stay_distinct () =
  let table workspace = M.table_name ~workspace in
  let fifty_nine suffix = String.make 59 'a' ^ suffix in
  let fifty_eight suffix = String.make 58 'a' ^ suffix in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two 60-byte workspace names no longer share a truncated table"
    true
    (String.compare (table (fifty_nine "x")) (table (fifty_nine "y")) <> 0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the 59-byte control stays distinct too"
    true
    (String.compare (table (fifty_eight "x")) (table (fifty_eight "y")) <> 0);
  Windtrap.equal
    Windtrap.string
    ~msg:"the shortened name is stable across calls"
    (table (fifty_nine "x"))
    (table (fifty_nine "x"))
;;

let test_table_length_error () =
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a normal override is accepted"
    None
    (M.table_length_error ~table:"sol_pluto_schema_migrations");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an override exactly on the limit is accepted"
    None
    (M.table_length_error ~table:(String.make M.postgres_identifier_max_bytes 'a'));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an override PostgreSQL would truncate is refused"
    true
    (Option.is_some
       (M.table_length_error
          ~table:(String.make (M.postgres_identifier_max_bytes + 1) 'a')))
;;

let test_parse_version () =
  let check msg expected actual =
    Windtrap.equal
      (Windtrap.option (Windtrap.pair Windtrap.int Windtrap.string))
      ~msg
      expected
      actual
  in
  check "standard" (Some (1, "create_orders")) (M.parse_version "001_create_orders.sql");
  check "no underscore" None (M.parse_version "0001.sql");
  check "non-numeric" None (M.parse_version "init_db.sql")
;;

let test_required () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "002_add_index.sql") "";
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "notes.md") "";
    match M.required ~dir with
    | Error e -> Windtrap.fail e
    | Ok required ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"every .sql, ordered by version"
        [ "001_create_orders"; "002_add_index" ]
        (List.map M.to_string required))
;;

let test_required_rejects_unnumbered () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "init_db.sql") "";
    match M.required ~dir with
    | Ok _ -> Windtrap.fail "expected an error for a migration without a version"
    | Error msg ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the offending file"
        true
        (Sol_cli_string.contains ~needle:"init_db.sql" msg))
;;

let test_required_rejects_a_shared_version () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "004_add_refunds.sql") "";
    write_file (Filename.concat dir "004_add_invoices.sql") "";
    match M.required ~dir with
    | Ok _ -> Windtrap.fail "expected an error for two migrations sharing version 4"
    | Error msg ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names first file"
        true
        (Sol_cli_string.contains ~needle:"004_add_invoices.sql" msg);
      Windtrap.equal
        Windtrap.bool
        ~msg:"names second file"
        true
        (Sol_cli_string.contains ~needle:"004_add_refunds.sql" msg))
;;

let test_shared_version_names_four_digit_files () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "0004_a.sql") "";
    write_file (Filename.concat dir "0004_b.sql") "";
    match M.required ~dir with
    | Ok _ -> Windtrap.fail "expected an error for two migrations sharing version 4"
    | Error msg ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names first file"
        true
        (Sol_cli_string.contains ~needle:"0004_a.sql" msg);
      Windtrap.equal
        Windtrap.bool
        ~msg:"names second file"
        true
        (Sol_cli_string.contains ~needle:"0004_b.sql" msg))
;;

let test_required_ignores_down_files () =
  with_tmp_dir (fun dir ->
    write_file (Filename.concat dir "001_create_orders.sql") "";
    write_file (Filename.concat dir "001_create_orders.down.sql") "";
    match M.required ~dir with
    | Error e -> Windtrap.fail e
    | Ok required ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"the down file is not a required migration"
        [ "001_create_orders" ]
        (List.map M.to_string required))
;;

let test_required_missing_dir_is_an_error () =
  match M.required ~dir:"/nonexistent/migrations" with
  | Ok _ -> Windtrap.fail "expected a missing migrations directory to be refused"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the path"
      true
      (Sol_cli_string.contains ~needle:"/nonexistent/migrations" message)
;;

let test_required_if_present_missing_dir_is_empty () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"a workspace with no migrations requires nothing"
    true
    (match M.required_if_present ~dir:"/nonexistent/migrations" with
     | Ok [] -> true
     | _ -> false)
;;

let test_required_file_instead_of_dir_is_an_error () =
  with_tmp_dir (fun dir ->
    let path = Filename.concat dir "db-migrations" in
    write_file path "";
    match M.required ~dir:path with
    | Ok _ -> Windtrap.fail "expected a regular file at the migrations path to be refused"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the distinct path"
        true
        (Sol_cli_string.contains ~needle:path message))
;;

let test_required_unreadable_dir_is_an_error () =
  with_tmp_dir (fun dir ->
    Unix.chmod dir 0o000;
    Fun.protect
      ~finally:(fun () -> Unix.chmod dir 0o755)
      (fun () ->
         if Unix.geteuid () = 0
         then ()
         else (
           match M.required ~dir with
           | Ok _ ->
             Windtrap.fail "expected an unreadable migrations directory to be refused"
           | Error message ->
             Windtrap.equal
               Windtrap.bool
               ~msg:"names the path"
               true
               (Sol_cli_string.contains ~needle:dir message))))
;;

let test_unsatisfied () =
  let required : M.prerequisite list =
    [ { version = 1; name = "a" }; { version = 2; name = "b" } ]
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the unapplied one is missing"
    [ "002_b" ]
    (List.map M.to_string (M.unsatisfied ~required ~applied:[ 1 ]));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"a superset is satisfied"
    []
    (List.map M.to_string (M.unsatisfied ~required ~applied:[ 1; 2; 3 ]));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing applied means everything is missing"
    [ "001_a"; "002_b" ]
    (List.map M.to_string (M.unsatisfied ~required ~applied:[]))
;;

let parse_ok msg body =
  match M.parse_status_json body with
  | Ok status -> status
  | Error e -> Windtrap.fail (msg ^ ": " ^ e)
;;

let test_parse_status_json () =
  let body =
    {|{"table":"sol_pluto_schema_migrations","migrations":[{"version":1,"name":"a","applied":true,"applied_at":"2026-01-01T00:00:00Z"},{"version":2,"name":"b","applied":false,"applied_at":null}]}|}
  in
  Windtrap.equal
    (Windtrap.list Windtrap.int)
    ~msg:"only the applied versions"
    [ 1 ]
    (parse_ok "status" body).applied;
  Windtrap.equal
    Windtrap.int
    ~msg:"a matching record is not drift"
    0
    (List.length (parse_ok "status" body).drifted);
  Windtrap.equal
    Windtrap.bool
    ~msg:"malformed input is an error"
    true
    (match M.parse_status_json "not json" with
     | Error _ -> true
     | Ok _ -> false);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a report without the migrations array is an error"
    true
    (match M.parse_status_json {|{"table":"t"}|} with
     | Error _ -> true
     | Ok _ -> false)
;;

let test_parse_status_json_reports_drift () =
  let body =
    {|{"table":"t","migrations":[{"version":1,"name":"a","applied":true,"applied_at":"2026-01-01T00:00:00Z","recorded_checksum":"aaaa","content_checksum":"bbbb"},{"version":2,"name":"b","applied":false,"recorded_checksum":null,"content_checksum":"cccc"},{"version":3,"name":"c","applied":true,"recorded_checksum":null,"content_checksum":"dddd"}]}|}
  in
  let status = parse_ok "drift" body in
  Windtrap.equal
    (Windtrap.list Windtrap.int)
    ~msg:"only the applied versions"
    [ 1; 3 ]
    status.applied;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only the changed applied migration is drift"
    [ "001_a" ]
    (List.map
       (fun (d : M.drift) -> Printf.sprintf "%03d_%s" d.version d.name)
       status.drifted);
  match status.drifted with
  | [ d ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"names the checksum applied"
      "aaaa"
      d.recorded_checksum;
    Windtrap.equal
      Windtrap.string
      ~msg:"names the checksum read"
      "bbbb"
      d.content_checksum
  | _ -> Windtrap.fail "expected exactly one drifted migration"
;;

let test_status_json_roundtrip () =
  let rows =
    [ { M.version = 1
      ; name = "a"
      ; applied = true
      ; applied_at = Some "2026-01-01T00:00:00Z"
      ; recorded_checksum = Some "aaaa"
      ; content_checksum = Some "aaaa"
      }
    ; { M.version = 2
      ; name = "b"
      ; applied = false
      ; applied_at = None
      ; recorded_checksum = None
      ; content_checksum = Some "bbbb"
      }
    ]
  in
  let body = M.status_json ~table:"t" rows in
  Windtrap.equal
    (Windtrap.list Windtrap.int)
    ~msg:"the writer and reader share one encoding"
    [ 1 ]
    (parse_ok "round-trip" body).applied;
  Windtrap.equal
    Windtrap.int
    ~msg:"a consistent table has no drift"
    0
    (List.length (parse_ok "round-trip" body).drifted);
  Windtrap.equal
    Windtrap.bool
    ~msg:"carries the table"
    true
    (Sol_cli_string.contains ~needle:"\"table\":\"t\"" body)
;;

let connection_url =
  "postgresql://postgres:known-password@db.internal:5432/app?sslmode=require"
;;

let test_runner_error_redacts_password_and_keeps_shape () =
  let raw = "create migrations table: Failed to connect to <" ^ connection_url ^ ">" in
  let rendered = Sol_cli_redaction.connection_error ~url:connection_url raw in
  Windtrap.equal
    Windtrap.bool
    ~msg:"password absent"
    false
    (Sol_cli_string.contains ~needle:"known-password" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"placeholder present"
    true
    (Sol_cli_string.contains ~needle:"postgres:<redacted>@" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"host and database remain"
    true
    (Sol_cli_string.contains ~needle:"db.internal:5432/app" rendered)
;;

let test_job_log_boundary_redacts_repeated_secret_values () =
  let raw =
    "migration error: " ^ connection_url ^ "\nretry failed; password=known-password\n"
  in
  let rendered = Sol_cli_redaction.connection_error ~url:connection_url raw in
  Windtrap.equal
    Windtrap.bool
    ~msg:"password absent everywhere"
    false
    (Sol_cli_string.contains ~needle:"known-password" rendered);
  Windtrap.equal
    Windtrap.bool
    ~msg:"diagnosis retained"
    true
    (Sol_cli_string.contains ~needle:"retry failed" rendered)
;;

let test_passwordless_and_non_uri_inputs_are_unchanged () =
  Windtrap.equal
    Windtrap.string
    ~msg:"passwordless"
    "connection refused"
    (Sol_cli_redaction.connection_error
       ~url:"postgresql://db.internal/app"
       "connection refused");
  Windtrap.equal
    Windtrap.string
    ~msg:"not a URI"
    "bad input"
    (Sol_cli_redaction.connection_error ~url:"opaque" "bad input")
;;

let test_evidence_report_unstartable_names_the_reason () =
  let report =
    M.evidence_report
      ~waiting:
        (Some ("CreateContainerConfigError", Some "secret \"sol-secrets\" not found"))
      ~logs:None
    |> Option.get
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"waiting reason"
    true
    (Sol_cli_string.contains ~needle:"CreateContainerConfigError" report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"waiting message"
    true
    (Sol_cli_string.contains ~needle:"secret \"sol-secrets\" not found" report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"no empty logs section is invented"
    false
    (Sol_cli_string.contains ~needle:"job logs:" report)
;;

let test_evidence_report_failed_job_carries_its_logs () =
  let report =
    M.evidence_report ~waiting:None ~logs:(Some "error: migration 003 failed\nline two")
    |> Option.get
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"first line"
    true
    (Sol_cli_string.contains ~needle:"migration 003 failed" report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"second line"
    true
    (Sol_cli_string.contains ~needle:"line two" report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"no waiting section is invented"
    false
    (Sol_cli_string.contains ~needle:"container waiting" report)
;;

let test_evidence_report_carries_both () =
  let report =
    M.evidence_report ~waiting:(Some ("CrashLoopBackOff", None)) ~logs:(Some "boom")
    |> Option.get
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"reason"
    true
    (Sol_cli_string.contains ~needle:"CrashLoopBackOff" report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"logs"
    true
    (Sol_cli_string.contains ~needle:"boom" report)
;;

let test_evidence_report_is_empty_without_observations () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"no observations, no report"
    true
    (M.evidence_report ~waiting:None ~logs:None = None)
;;

let%test "prerequisite: table name" = test_table_name ()
let%test "prerequisite: table name stays bounded" = test_table_name_is_bounded ()

let%test "prerequisite: long workspace names stay distinct" =
  test_long_workspace_names_stay_distinct ()
;;

let%test "prerequisite: table override length" = test_table_length_error ()
let%test "prerequisite: parse version" = test_parse_version ()
let%test "prerequisite: required set" = test_required ()

let%test "prerequisite: unnumbered migration is an error" =
  test_required_rejects_unnumbered ()
;;

let%test "prerequisite: shared version is an error" =
  test_required_rejects_a_shared_version ()
;;

let%test "prerequisite: down files are not migrations" =
  test_required_ignores_down_files ()
;;

let%test "prerequisite: shared version names four-digit files" =
  test_shared_version_names_four_digit_files ()
;;

let%test "prerequisite: missing directory is an error" =
  test_required_missing_dir_is_an_error ()
;;

let%test "prerequisite: missing directory requires nothing when absence is allowed" =
  test_required_if_present_missing_dir_is_empty ()
;;

let%test "prerequisite: a file at the migrations path is an error (BUG-082)" =
  test_required_file_instead_of_dir_is_an_error ()
;;

let%test "prerequisite: an unreadable migrations directory is an error (BUG-082)" =
  test_required_unreadable_dir_is_an_error ()
;;

let%test "prerequisite: unsatisfied subset" = test_unsatisfied ()
let%test "encoding: parse status json" = test_parse_status_json ()

let%test "encoding: a changed applied migration reads as drift" =
  test_parse_status_json_reports_drift ()
;;

let%test "encoding: status json round-trip" = test_status_json_roundtrip ()

let%test "connection redaction: runner error hides password" =
  test_runner_error_redacts_password_and_keeps_shape ()
;;

let%test "connection redaction: Job logs hide every password occurrence" =
  test_job_log_boundary_redacts_repeated_secret_values ()
;;

let%test "connection redaction: non-credential inputs unchanged" =
  test_passwordless_and_non_uri_inputs_are_unchanged ()
;;

let%test "failure evidence (INFRA-040): unstartable Job names its reason" =
  test_evidence_report_unstartable_names_the_reason ()
;;

let%test "failure evidence (INFRA-040): failed Job carries its logs" =
  test_evidence_report_failed_job_carries_its_logs ()
;;

let%test "failure evidence (INFRA-040): both observations together" =
  test_evidence_report_carries_both ()
;;

let%test "failure evidence (INFRA-040): nothing observed, nothing reported" =
  test_evidence_report_is_empty_without_observations ()
;;

(* 2b: `sol migrate apply <target> --dry-run` reads the applied set with an in-cluster
   status Job and prints exactly the local files that set does not name. This filter
   decides what it prints, so a mutation that keeps an applied file or drops a pending
   one fails here. The down-migration is excluded by the filename authority. *)
let%test "2b: a dry run lists only migrations the applied set does not name" =
  let files =
    [ "0001_notifications.sql", "select 1"
    ; "0002_sol_outbox.sql", "select 2"
    ; "0003_later.sql", "select 3"
    ; "0002_sol_outbox.down.sql", "select down"
    ]
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"only the unapplied up-migrations, in file order"
    [ "0002_sol_outbox.sql", "select 2"; "0003_later.sql", "select 3" ]
    (M.pending_files ~applied:[ 1 ] files)
;;
