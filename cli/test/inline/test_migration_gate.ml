let temp_dir () =
  let dir = Filename.temp_file "sol-migration-gate-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write dir name content =
  Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
    output_string oc content)
;;

let test_files_are_sql_only_and_sorted () =
  let dir = temp_dir () in
  write dir "002_b.sql" "b";
  write dir "001_a.sql" "a";
  write dir "README.md" "not a migration";
  match Sol_cli_migration_gate.migration_files dir with
  | Error e -> Windtrap.fail e
  | Ok files ->
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"sorted .sql files"
      [ "001_a.sql", "a"; "002_b.sql", "b" ]
      files
;;

let test_nul_is_refused_by_name () =
  let dir = temp_dir () in
  write dir "001_a.sql" "a\000b";
  match Sol_cli_migration_gate.migration_files dir with
  | Ok _ -> Windtrap.fail "expected a NUL character to be refused"
  | Error e ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the file"
      true
      (Sol_cli_string.contains ~needle:"001_a.sql" e)
;;

let test_oversized_set_is_refused () =
  let dir = temp_dir () in
  let oversized = (1024 * 1024) + 1 in
  write dir "001_big.sql" (String.make oversized 'x');
  match Sol_cli_migration_gate.migration_files dir with
  | Ok _ -> Windtrap.fail "expected a set past the 1 MiB ConfigMap limit to be refused"
  | Error e ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the limit"
      true
      (Sol_cli_string.contains ~needle:"1 MiB" e);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the total"
      true
      (Sol_cli_string.contains ~needle:(string_of_int oversized) e)
;;

let test_missing_dir_is_an_error () =
  match Sol_cli_migration_gate.migration_files "/nonexistent/sol-migrations" with
  | Ok _ -> Windtrap.fail "expected a missing directory to be an error"
  | Error _ -> ()
;;

let verify dir =
  Sol_cli_migration_gate.verify
    ~ctx:Sol_cli_kube_destination.local_context
    ~workspace:"pluto"
    ~dir
    ~database:
      (Sol_cli_database_setup_render.database_identity
         ~workspace:"pluto"
         ~target:"qualreg-aws-us-east-1"
         ~resource:"app_db")
    ~ddl_creds_name:"pluto-ddl-creds"
    ()
;;

let test_verify_absent_and_empty_dirs_are_no_migrations () =
  let empty = temp_dir () in
  (match verify (Filename.concat empty "never-created") with
   | Sol_cli_migration_gate.No_migrations -> ()
   | _ -> Windtrap.fail "an absent migrations directory must mean no migrations");
  match verify empty with
  | Sol_cli_migration_gate.No_migrations -> ()
  | _ -> Windtrap.fail "an empty migrations directory must mean no migrations"
;;

let test_verify_refuses_a_file_at_the_migrations_path () =
  let dir = temp_dir () in
  let path = Filename.concat dir "db-migrations" in
  write dir "db-migrations" "";
  match verify path with
  | Sol_cli_migration_gate.Unavailable message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the path"
      true
      (Sol_cli_string.contains ~needle:path message)
  | Sol_cli_migration_gate.No_migrations ->
    Windtrap.fail "a file at the migrations path must not read as 'no migrations'"
  | Sol_cli_migration_gate.Satisfied _
  | Sol_cli_migration_gate.Unsatisfied _
  | Sol_cli_migration_gate.Drifted _ ->
    Windtrap.fail "a file at the migrations path must not be verified"
;;

let test_verify_refuses_an_unreadable_migrations_dir () =
  let dir = temp_dir () in
  Unix.chmod dir 0o000;
  Fun.protect
    ~finally:(fun () -> Unix.chmod dir 0o755)
    (fun () ->
       if Unix.geteuid () = 0
       then ()
       else (
         match verify dir with
         | Sol_cli_migration_gate.Unavailable message ->
           Windtrap.equal
             Windtrap.bool
             ~msg:"names the path"
             true
             (Sol_cli_string.contains ~needle:dir message)
         | Sol_cli_migration_gate.No_migrations ->
           Windtrap.fail
             "an unreadable migrations directory must not read as 'no migrations'"
         | Sol_cli_migration_gate.Satisfied _
         | Sol_cli_migration_gate.Unsatisfied _
         | Sol_cli_migration_gate.Drifted _ ->
           Windtrap.fail "an unreadable migrations directory must not be verified"))
;;

let%test "migration files: sql only, sorted" = test_files_are_sql_only_and_sorted ()
let%test "migration files: NUL refused" = test_nul_is_refused_by_name ()
let%test "migration files: oversized set refused" = test_oversized_set_is_refused ()
let%test "migration files: missing dir" = test_missing_dir_is_an_error ()

let%test "verification gate: absent and empty dirs mean no migrations" =
  test_verify_absent_and_empty_dirs_are_no_migrations ()
;;

let%test "verification gate: a file at the migrations path refuses (BUG-082)" =
  test_verify_refuses_a_file_at_the_migrations_path ()
;;

let%test "verification gate: an unreadable migrations dir refuses (BUG-082)" =
  test_verify_refuses_an_unreadable_migrations_dir ()
;;
