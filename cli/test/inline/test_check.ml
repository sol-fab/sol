let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path)

let with_tmp f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("sol-check-" ^ string_of_int (Random.bits ()))
  in
  mkdir_p root;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let cwd = Sys.getcwd () in
       Fun.protect
         ~finally:(fun () -> Sys.chdir cwd)
         (fun () ->
            Sys.chdir root;
            write "sol.yml" "";
            f root))
;;

let has_msg needle findings =
  findings
  |> List.exists (fun (f : Sol_cli_check.finding) ->
    Sol_cli_string.contains ~needle f.message)
;;

let facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let test_missing_app_result () =
  with_tmp (fun _ ->
    match Sol_cli_manifest.discover_services () with
    | Error Sol_cli_manifest.Missing_app_dir -> ()
    | Error (Sol_cli_manifest.Workspace_error _) ->
      Windtrap.fail "expected Missing_app_dir, got a workspace error"
    | Ok _ -> Windtrap.fail "expected missing app error")
;;

let test_not_in_workspace_result () =
  with_tmp (fun _ ->
    Sys.remove "sol.yml";
    match Sol_cli_manifest.discover_services () with
    | Error (Sol_cli_manifest.Workspace_error Sol_cli_workspace.Not_in_workspace) -> ()
    | Error e ->
      Windtrap.fail
        ("expected not-in-workspace, got: " ^ Sol_cli_manifest.discover_error_to_string e)
    | Ok _ -> Windtrap.fail "expected discovery to fail outside a workspace")
;;

let test_discover_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    match Sol_cli_manifest.discover_services () with
    | Error e -> Windtrap.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok [ svc ] ->
      Windtrap.equal Windtrap.string ~msg:"domain" "payments" svc.domain;
      Windtrap.equal Windtrap.string ~msg:"name" "charge_svc" svc.name
    | Ok _ -> Windtrap.fail "expected one service")
;;

let test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    mkdir_p "app/payments/helpers";
    match Sol_cli_manifest.scan_workspace () with
    | Error e -> Windtrap.fail (Sol_cli_manifest.discover_error_to_string e)
    | Ok scan ->
      Windtrap.equal Windtrap.int ~msg:"workload count" 1 (List.length scan.workloads);
      let _, has_dockerfile = List.hd scan.workloads in
      Windtrap.equal Windtrap.bool ~msg:"has dockerfile false" false has_dockerfile;
      Windtrap.equal Windtrap.int ~msg:"unexpected count" 1 (List.length scan.unexpected);
      let _, unexpected_name, _ = List.hd scan.unexpected in
      Windtrap.equal Windtrap.string ~msg:"unexpected name" "helpers" unexpected_name)
;;

let test_check_valid_service () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no errors"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_check_bad_secret_key () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"mentions invalid secret"
      true
      (has_msg "invalid runtime secret key" findings))
;;

let test_check_bad_build_secret_key () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write
      "app/payments/charge_svc/sol.toml"
      "[infra.env]\nbuild_secrets = [\"bad-key\"]\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the build-time scope"
      true
      (has_msg "invalid build-time secret key" findings))
;;

let test_check_missing_dockerfile () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"has errors"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"mentions Dockerfile"
      true
      (has_msg "Dockerfile is missing" findings))
;;

let test_run_services_scopes_the_check () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    write "app/comms/notify_worker/sol.toml" "[infra.env]\nsecrets = [\"bad-key\"]\n";
    let services = Result.get_ok (Sol_cli_manifest.discover_services ()) in
    let charge =
      List.filter (fun (s : Sol_cli_manifest.service) -> s.name = "charge_svc") services
    in
    let findings = Sol_cli_check.run_services ~facts:(facts ()) charge in
    Windtrap.equal
      Windtrap.bool
      ~msg:"only the selected workload is checked"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_undeclared_workload_warns () =
  with_tmp (fun _ ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"warns that the workload declares no language"
      true
      (has_msg "declares no language" findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"a warning, not an error"
      false
      (Sol_cli_check.has_errors findings))
;;

let test_declared_workload_does_not_warn () =
  with_tmp (fun _ ->
    write "sol.yml" "services:\n  charge_svc:\n    language: ocaml\n";
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no declaration warning"
      false
      (has_msg "declares no language" findings))
;;

let test_declared_unit_without_directory_fails () =
  with_tmp (fun _ ->
    write
      "sol.yml"
      "services:\n  ghost_svc:\n    type: http\n    path: app/core/ghost_svc\n";
    mkdir_p "app";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a declared unit with no directory is an error"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and names the missing unit"
      true
      (has_msg "no unit directory exists there" findings))
;;

let test_declared_unit_wrong_leaf_fails () =
  with_tmp (fun _ ->
    write
      "sol.yml"
      "services:\n  charge_svc:\n    type: http\n    path: app/core/other_svc\n";
    mkdir_p "app/core/other_svc";
    write "app/core/other_svc/Dockerfile" "FROM scratch\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a declared path whose leaf is not the service name is an error"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and says which directory it found"
      true
      (has_msg "its directory is named other_svc" findings))
;;

let test_declared_unit_without_suffix_fails () =
  with_tmp (fun _ ->
    write "sol.yml" "services:\n  api:\n    type: http\n    path: app/core/api\n";
    mkdir_p "app/core/api";
    write "app/core/api/Dockerfile" "FROM scratch\n";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a declared path with no workload suffix is an error"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and says the suffix is missing"
      true
      (has_msg "carries no *_svc, *_worker or *_fn suffix" findings))
;;

let test_declared_name_only_without_directory_fails () =
  with_tmp (fun _ ->
    write "sol.yml" "services:\n  ghost_svc:\n    language: ocaml\n";
    mkdir_p "app";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a declared service with no unit anywhere is an error"
      true
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and names the service"
      true
      (has_msg "declares service ghost_svc" findings))
;;

let test_declared_type_mismatch_warns () =
  with_tmp (fun _ ->
    write
      "sol.yml"
      "services:\n\
      \  notify_worker:\n\
      \    type: http\n\
      \    path: app/comms/notify_worker\n\
      \    language: ocaml\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    write "app/comms/notify_worker/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a declared type that disagrees with the suffix is a warning, not an error"
      false
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and the warning names the mismatch"
      true
      (has_msg "declares type \"http\"" findings))
;;

let test_omitted_declared_unit_without_directory_is_ignored () =
  with_tmp (fun _ ->
    write
      "sol.yml"
      "services:\n\
      \  real_svc:\n\
      \    type: http\n\
      \    path: app/core/real_svc\n\
      \    language: ocaml\n\
      \  ignored_svc:\n\
      \    type: http\n\
      \    path: app/core/ignored_svc\n\
      \    omit: true\n";
    mkdir_p "app/core/real_svc";
    write "app/core/real_svc/Dockerfile" "FROM scratch\n";
    write "app/core/real_svc/sol.toml" "";
    let findings = Sol_cli_check.run ~facts:(facts ()) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"an omitted declaration need not have a directory"
      false
      (Sol_cli_check.has_errors findings);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and it is not reported"
      false
      (has_msg "ignored_svc" findings))
;;

let test_scoped_check_reports_declaration_issues_in_domain () =
  with_tmp (fun _ ->
    write
      "sol.yml"
      "services:\n\
      \  real_svc:\n\
      \    type: http\n\
      \    path: app/payments/real_svc\n\
      \    language: ocaml\n\
      \  ghost_svc:\n\
      \    type: http\n\
      \    path: app/comms/ghost_svc\n";
    mkdir_p "app/payments/real_svc";
    write "app/payments/real_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/real_svc/sol.toml" "";
    let facts = facts () in
    let comms =
      Sol_cli_check.declaration_findings_in_scope
        ~facts
        (Sol_cli_deployment_scope.Whole_domain "comms")
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the phantom unit is reported in its own domain"
      true
      (Sol_cli_check.has_errors comms);
    let payments =
      Sol_cli_check.declaration_findings_in_scope
        ~facts
        (Sol_cli_deployment_scope.Whole_domain "payments")
    in
    Windtrap.equal
      Windtrap.int
      ~msg:"and not in a domain that implements everything it declares"
      0
      (List.length payments))
;;

let run_sol ?(path = Sys.getenv "PATH") ~root args =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let command =
    "PATH="
    ^ Filename.quote path
    ^ " "
    ^ String.concat " " (List.map Filename.quote (Cli_binary.path () :: args))
    ^ " > "
    ^ Filename.quote stdout_path
    ^ " 2> "
    ^ Filename.quote stderr_path
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  match
    Sol_cli_process.run
      ~echo:false
      (Sol_cli_process.cmd ~cwd:root [ "sh"; "-c"; command ])
  with
  | Ok _ -> 0, read stdout_path, read stderr_path
  | Error (Non_zero failure) -> failure.exit_code, read stdout_path, read stderr_path
  | Error error -> Windtrap.fail (Sol_cli_process.error_to_string error)
;;

let with_subprocess_workspace f =
  let root = Filename.temp_dir "sol-check-exit-" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       Result.get_ok
         (Sol_cli_fs.write_atomic
            (Filename.concat root "sol.yml")
            "services:\n  charge_svc:\n    language: ocaml\n");
       f root)
;;

let with_contract_subprocess_workspace f =
  let root = Filename.temp_dir "sol-check-contract-" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let write rel body =
         let path = Filename.concat root rel in
         Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
         Result.get_ok (Sol_cli_fs.write_atomic path body)
       in
       write
         "sol.yml"
         "services:\n\
         \  charge_svc:\n\
         \    type: http\n\
         \    path: app/payments/charge_svc\n\
         \    language: ocaml\n\
         \  notify_worker:\n\
         \    type: worker\n\
         \    path: app/comms/notify_worker\n\
         \    language: typescript\n";
       write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
       write "app/payments/charge_svc/sol.toml" "";
       write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
       write "app/comms/notify_worker/sol.toml" "";
       write
         "events/payments/sol.toml"
         "[contract]\n\
          language = \"ocaml\"\n\n\
          [[events]]\n\
          name = \"Charged\"\n\
          topic = \"payments.charges\"\n\
          partitions = 3\n\
          schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n";
       write
         "events/comms/sol.toml"
         "[contract]\n\
          language = \"typescript\"\n\n\
          [[events]]\n\
          name = \"Notified\"\n\
          topic = \"comms.notifications\"\n\
          partitions = 3\n\
          schema = '{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}'\n";
       (match Sol_cli_contract_gen.generate ~root ~check:false with
        | Ok _ -> ()
        | Error error -> Windtrap.fail ("could not prepare contract fixture: " ^ error));
       f root)
;;

let test_failed_check_exits_two () =
  with_subprocess_workspace (fun root ->
    let unit = Filename.concat root "app/payments/charge_svc" in
    ignore (Sol_cli_fs.mkdir_p unit);
    ignore (Sol_cli_fs.write_atomic (Filename.concat unit "sol.toml") "");
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"a failed check exits 2" 2 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"and still names the failure"
      true
      (Sol_cli_string.contains ~needle:"Dockerfile is missing" stderr))
;;

let test_check_accepts_current_ocaml_and_typescript_projections () =
  with_contract_subprocess_workspace (fun root ->
    let code, stdout, stderr = run_sol ~path:"/nonexistent" ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"check succeeds without infrastructure" 0 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"success is reported"
      true
      (Sol_cli_string.contains ~needle:"sol check: ok" stdout);
    Windtrap.equal
      Windtrap.bool
      ~msg:"no stale projection error is printed"
      false
      (Sol_cli_string.contains ~needle:"is stale" stderr))
;;

let test_check_reports_stale_projection_without_writing () =
  with_contract_subprocess_workspace (fun root ->
    let generated = Filename.concat root "events/payments/payments_contract.ml" in
    write generated "hand-edited\n";
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"stale binding fails check" 2 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"diagnostic identifies the generated path"
      true
      (Sol_cli_string.contains ~needle:"events/payments/payments_contract.ml" stderr);
    Windtrap.equal
      Windtrap.bool
      ~msg:"diagnostic gives the explicit repair command"
      true
      (Sol_cli_string.contains ~needle:"sol contract generate" stderr);
    Windtrap.equal
      Windtrap.string
      ~msg:"check does not rewrite stale output"
      "hand-edited\n"
      (In_channel.with_open_bin generated In_channel.input_all))
;;

let test_check_reports_missing_projection_without_writing () =
  with_contract_subprocess_workspace (fun root ->
    let generated = Filename.concat root "app/comms/contract/src/comms_contract.ts" in
    Sys.remove generated;
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"missing binding fails check" 2 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"diagnostic identifies the missing path"
      true
      (Sol_cli_string.contains ~needle:"app/comms/contract/src/comms_contract.ts" stderr);
    Windtrap.equal
      Windtrap.bool
      ~msg:"diagnostic gives the explicit repair command"
      true
      (Sol_cli_string.contains ~needle:"sol contract generate" stderr);
    Windtrap.equal
      Windtrap.bool
      ~msg:"check does not create missing output"
      false
      (Sys.file_exists generated))
;;

let test_scoped_check_validates_workspace_generated_projections () =
  with_contract_subprocess_workspace (fun root ->
    let payments = Filename.concat root "events/payments/payments_contract.ml" in
    let payments_current = In_channel.with_open_bin payments In_channel.input_all in
    write payments "stale selected-domain projection\n";
    let code, _stdout, stderr = run_sol ~root [ "check"; "--scope"; "payments" ] in
    Windtrap.equal
      Windtrap.int
      ~msg:"a stale projection in the selected domain fails scoped check"
      2
      code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"the selected stale projection is identified"
      true
      (Sol_cli_string.contains ~needle:"payments_contract.ml" stderr);
    Windtrap.equal
      Windtrap.string
      ~msg:"the scoped check does not rewrite it"
      "stale selected-domain projection\n"
      (In_channel.with_open_bin payments In_channel.input_all);
    write payments payments_current;
    let comms = Filename.concat root "app/comms/contract/src/comms_contract.ts" in
    write comms "stale unrelated projection\n";
    let code, _stdout, stderr = run_sol ~root [ "check"; "--scope"; "payments" ] in
    Windtrap.equal
      Windtrap.int
      ~msg:"an unrelated stale projection also fails scoped check"
      2
      code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"the unrelated stale projection is identified"
      true
      (Sol_cli_string.contains ~needle:"comms_contract.ts" stderr);
    Windtrap.equal
      Windtrap.string
      ~msg:"the workspace-wide scoped check does not rewrite unrelated output"
      "stale unrelated projection\n"
      (In_channel.with_open_bin comms In_channel.input_all))
;;

let test_check_requires_and_accepts_explicit_secret_authorities () =
  with_contract_subprocess_workspace (fun root ->
    let write rel body =
      let path = Filename.concat root rel in
      ignore (Sol_cli_fs.mkdir_p (Filename.dirname path));
      Result.get_ok (Sol_cli_fs.write_atomic path body)
    in
    (* 2b: POSTGRES_URL is supplied by the database binding, not an authority mapping, so
       these units declare the application secret whose authority the check must demand. *)
    let declare_api_key rel = write rel "[infra.env]\nsecrets = [\"SOL_API_KEY\"]\n" in
    declare_api_key "app/payments/charge_svc/sol.toml";
    declare_api_key "app/comms/notify_worker/sol.toml";
    write
      "sol/environments.yml"
      "prod:\n  targets:\n    aws/us-east-1:\n      shape: local\n      secrets: {}\n";
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal Windtrap.int ~msg:"unmapped required keys fail check" 2 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"check identifies the exact unit and missing mapping"
      true
      (Sol_cli_string.contains ~needle:"payments/charge_svc/SOL_API_KEY" stderr);
    write
      "sol/environments.yml"
      "prod:\n\
      \  targets:\n\
      \    aws/us-east-1:\n\
      \      shape: local\n\
      \      secrets:\n\
      \        payments/charge_svc:\n\
      \          POSTGRES_URL:\n\
      \            authority: external\n\
      \            store: payments-store\n\
      \            key: payments/database-url\n\
      \          SOL_API_KEY:\n\
      \            authority: sol\n\
      \        comms/notify_worker:\n\
      \          POSTGRES_URL:\n\
      \            authority: sol\n\
      \          SOL_API_KEY:\n\
      \            authority: sol\n";
    let code, stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal
      Windtrap.int
      ~msg:"valid Sol and external mappings pass offline check"
      0
      code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"check remains offline and succeeds without provider access"
      true
      (Sol_cli_string.contains ~needle:"sol check: ok" stdout);
    Windtrap.equal
      Windtrap.bool
      ~msg:"valid declared keys produce no authority errors"
      false
      (Sol_cli_string.contains ~needle:"has no authority mapping" stderr))
;;

let test_unreadable_workspace_exits_one () =
  with_subprocess_workspace (fun root ->
    let path = Filename.concat root "sol.yml" in
    let denied =
      if Unix.geteuid () = 0
      then (
        Sys.remove path;
        Unix.mkdir path 0o755;
        false)
      else (
        Unix.chmod path 0o000;
        true)
    in
    let code, _stdout, stderr = run_sol ~root [ "check" ] in
    Windtrap.equal
      Windtrap.int
      ~msg:"an unreadable workspace exits 1, not an internal error"
      1
      code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"never prints an uncaught exception"
      false
      (Sol_cli_string.contains ~needle:"uncaught exception" stderr);
    if denied
    then
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the file whose read was denied"
        true
        (Sol_cli_string.contains ~needle:"sol.yml" stderr))
;;

let test_unreadable_config_is_an_error () =
  with_tmp (fun _ ->
    Sys.remove "sol.yml";
    Unix.mkdir "sol.yml" 0o755;
    match Sol_cli_config.sol_yml_services ~root:(Sys.getcwd ()) with
    | Ok _ -> Windtrap.fail "expected an error for a sol.yml that cannot be read"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the unreadable file"
        true
        (Sol_cli_string.contains ~needle:"sol.yml" (Sol_cli_config.error_to_string e)))
;;

let with_plan_workspace f =
  let root = Filename.temp_dir "sol-plan-" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let write rel body =
         let path = Filename.concat root rel in
         ignore (Sol_cli_fs.mkdir_p (Filename.dirname path));
         Result.get_ok (Sol_cli_fs.write_atomic path body)
       in
       write "sol.yml" "services:\n  charge_svc:\n    language: ocaml\n";
       write
         "sol/environments.yml"
         "prod:\n\
         \  targets:\n\
         \    aws/us-east-1:\n\
         \      shape: local\n\
         \      cluster_name: probe\n\
         \      secrets:\n\
         \        payments/charge_svc:\n\
         \          POSTGRES_URL:\n\
         \            authority: sol\n\
         \          SOL_API_KEY:\n\
         \            authority: sol\n";
       f root ~write)
;;

let test_plan_refuses_declared_unit_without_directory () =
  with_plan_workspace (fun root ~write ->
    ignore write;
    let code, _stdout, stderr = run_sol ~root [ "plan"; "prod/aws/us-east-1" ] in
    Windtrap.equal Windtrap.int ~msg:"plan refuses an unimplemented declaration" 1 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"and names the declared service"
      true
      (Sol_cli_string.contains ~needle:"charge_svc" stderr))
;;

let test_plan_accepts_implemented_unit () =
  with_plan_workspace (fun root ~write ->
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    let code, stdout, _stderr =
      run_sol
        ~root
        [ "plan"
        ; "prod/aws/us-east-1"
        ; "--image-ref"
        ; "charge_svc=registry.example/charge@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ]
    in
    Windtrap.equal Windtrap.int ~msg:"plan succeeds" 0 code;
    Windtrap.equal
      Windtrap.bool
      ~msg:"and prints the plan"
      true
      (Sol_cli_string.contains ~needle:"Project:" stdout))
;;

let%test "discover: missing app returns error" = test_missing_app_result ()
let%test "discover: outside a workspace returns error" = test_not_in_workspace_result ()
let%test "discover: valid service" = test_discover_valid_service ()

let%test "discover: typed scan facts" =
  test_typed_scan_reports_missing_dockerfile_and_unexpected_dirs ()
;;

let%test "check: valid service" = test_check_valid_service ()
let%test "check: bad secret key" = test_check_bad_secret_key ()
let%test "check: bad build secret key" = test_check_bad_build_secret_key ()
let%test "check: missing Dockerfile" = test_check_missing_dockerfile ()

let%test "check: run_services checks only the selected set" =
  test_run_services_scopes_the_check ()
;;

let%test "check: an undeclared workload warns" = test_undeclared_workload_warns ()

let%test "check: a declared workload does not warn" =
  test_declared_workload_does_not_warn ()
;;

let%test "check: a declared unit with no directory fails" =
  test_declared_unit_without_directory_fails ()
;;

let%test "check: a declared path whose leaf is another unit fails" =
  test_declared_unit_wrong_leaf_fails ()
;;

let%test "check: a declared path with no workload suffix fails" =
  test_declared_unit_without_suffix_fails ()
;;

let%test "check: a declared service with no unit fails" =
  test_declared_name_only_without_directory_fails ()
;;

let%test "check: a declared type that disagrees warns but does not fail" =
  test_declared_type_mismatch_warns ()
;;

let%test "check: an omitted declaration needs no directory" =
  test_omitted_declared_unit_without_directory_is_ignored ()
;;

let%test "check: scoped declaration findings stay in their domain" =
  test_scoped_check_reports_declaration_issues_in_domain ()
;;

let%test "check: a failed check exits 2" = test_failed_check_exits_two ()

let%test "check: current OCaml and TypeScript projections pass" =
  test_check_accepts_current_ocaml_and_typescript_projections ()
;;

let%test "check: stale generated projection fails without writing" =
  test_check_reports_stale_projection_without_writing ()
;;

let%test "check: missing generated projection fails without writing" =
  test_check_reports_missing_projection_without_writing ()
;;

let%test "check: scoped checks validate workspace generated projections" =
  test_scoped_check_validates_workspace_generated_projections ()
;;

let%test "check: secret authority mappings are explicit and offline" =
  test_check_requires_and_accepts_explicit_secret_authorities ()
;;

let%test "check: an unreadable workspace exits 1" = test_unreadable_workspace_exits_one ()

let%test "plan: refuses an unimplemented declaration" =
  test_plan_refuses_declared_unit_without_directory ()
;;

let%test "plan: accepts an implemented unit" = test_plan_accepts_implemented_unit ()

let%test "check: an unreadable sol.yml is an error, not an exception" =
  test_unreadable_config_is_an_error ()
;;
