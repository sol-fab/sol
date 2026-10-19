let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_strings msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

let write_file path content =
  let rec mkdirs path =
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent)
    then (
      mkdirs parent;
      Unix.mkdir parent 0o755)
  in
  mkdirs path;
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_workspace files f =
  let root = Filename.temp_file "sol-local-run-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  write_file (Filename.concat root "sol.yml") "";
  List.iter (fun (rel, content) -> write_file (Filename.concat root rel) content) files;
  Fun.protect ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root)) (fun () -> f root)
;;

let facts_of root =
  match Sol_cli_workspace_model.load ~root with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let services_of facts = Sol_cli_workspace_model.services facts
let sol_yml ~services = services
let dockerfile = "FROM scratch\n"

let test_ocaml_unit_builds_with_dune_and_runs_the_binary () =
  with_workspace
    [ "sol.yml", sol_yml ~services:"services:\n  charge_svc:\n    language: ocaml\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings
         "one merged dune build"
         [ "dune"; "build"; "app/payments/charge_svc/bin/main.exe" ]
         build.argv;
       check_string "in the workspace root" "" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "launches the compiled binary"
         [ "_build/default/app/payments/charge_svc/bin/main.exe" ]
         launch.launch.argv;
       check_string "artifact" "app/payments/charge_svc/bin/main.exe" launch.artifact;
       check_bool "declared OCaml" true (launch.language = Sol_cli_compat.Ocaml);
       check_string
         "carries the injected workspace identity"
         (Filename.basename root)
         (Option.value ~default:"" (List.assoc_opt "SOL_WORKSPACE" launch.env));
       check_string
         "carries the injected domain identity"
         "payments"
         (Option.value ~default:"" (List.assoc_opt "SOL_DOMAIN" launch.env));
       check_string
         "carries the bare Kubernetes service name"
         "charge-svc"
         (Option.value ~default:"" (List.assoc_opt "SOL_SERVICE" launch.env));
       check_string
         "carries the primitive"
         "svc"
         (Option.value ~default:"" (List.assoc_opt "SOL_PRIMITIVE" launch.env));
       check_string
         "carries the local port-forward address"
         "http://localhost:3100"
         (Option.value ~default:"" (List.assoc_opt "LOKI_URL" launch.env));
       check_bool
         "omits env locally by design"
         false
         (List.mem_assoc "SOL_ENV" launch.env)
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let test_local_secret_file_parses_without_shell_evaluation () =
  match
    Sol_cli_local_secret_input.parse
      "# comment\nPAYMENT_API_KEY=abc=123\nQUOTED=\" a value # kept \"\n"
  with
  | Error message -> Windtrap.fail message
  | Ok values ->
    check_strings
      "values preserve equals and quoted content"
      [ "PAYMENT_API_KEY"; "abc=123"; "QUOTED"; " a value # kept " ]
      (List.concat_map (fun (key, value) -> [ key; value ]) values)
;;

let test_local_secret_file_rejects_duplicate_keys_without_values () =
  match
    Sol_cli_local_secret_input.parse
      "PAYMENT_API_KEY=never-print-this\nPAYMENT_API_KEY=second\n"
  with
  | Ok _ -> Windtrap.fail "duplicate secret key was accepted"
  | Error message ->
    check_bool
      "diagnostic names key"
      true
      (Sol_cli_string.contains ~needle:"PAYMENT_API_KEY" message);
    check_bool
      "diagnostic redacts value"
      false
      (Sol_cli_string.contains ~needle:"never-print-this" message)
;;

let test_local_secret_file_loads_by_unit_address () =
  with_workspace
    [ "sol/secrets.local/payments/charge_svc.env", "PAYMENT_API_KEY=unit-value\n"
    ; "sol/secrets.local/notifications/email_svc.env", "PAYMENT_API_KEY=other-unit\n"
    ]
  @@ fun root ->
  let load unit_address =
    Sol_cli_local_secret_input.load ~root ~unit_address |> Result.get_ok
  in
  check_strings
    "first unit gets its own file"
    [ "PAYMENT_API_KEY"; "unit-value" ]
    (List.concat_map (fun (key, value) -> [ key; value ]) (load "payments/charge_svc"));
  check_strings
    "second unit gets a separate file"
    [ "PAYMENT_API_KEY"; "other-unit" ]
    (List.concat_map
       (fun (key, value) -> [ key; value ])
       (load "notifications/email_svc"));
  check_bool
    "invalid unit address refused"
    true
    (Result.is_error (Sol_cli_local_secret_input.load ~root ~unit_address:"../escape"))
;;

let test_local_run_projects_only_declared_secret_keys () =
  with_workspace
    [ "sol.yml", sol_yml ~services:"services:\n  charge_svc:\n    language: ocaml\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", "[infra.env]\nsecrets = [\"PAYMENT_API_KEY\"]\n"
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let facts = facts_of root in
  match
    Sol_cli_local_run.plan
      ~secret_values:
        [ ( "payments/charge_svc"
          , [ "PAYMENT_API_KEY", "sensitive-value"; "UNDECLARED", "do-not-pass" ] )
        ]
      ~root
      ~facts
      (services_of facts)
  with
  | Error errors -> Windtrap.fail (String.concat "; " (List.map snd errors))
  | Ok plan ->
    (match plan.launches with
     | [ recipe ] ->
       check_string
         "declared secret is present in the local service"
         "sensitive-value"
         (Option.value ~default:"" (List.assoc_opt "PAYMENT_API_KEY" recipe.env));
       check_bool
         "undeclared value is not passed to service"
         false
         (List.mem_assoc "UNDECLARED" recipe.env);
       check_bool
         "secret is marked for output redaction"
         true
         (List.mem "sensitive-value" plan.redact)
     | _ -> Windtrap.fail "expected one local service")
;;

let test_local_run_requires_declared_secret_value () =
  with_workspace
    [ "sol.yml", sol_yml ~services:"services:\n  charge_svc:\n    language: ocaml\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", "[infra.env]\nsecrets = [\"PAYMENT_API_KEY\"]\n"
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Ok _ -> Windtrap.fail "missing declared secret was accepted"
  | Error errors ->
    (match errors with
     | (_, message) :: _ ->
       check_bool
         "names missing key"
         true
         (Sol_cli_string.contains ~needle:"PAYMENT_API_KEY" message)
     | [] -> Windtrap.fail "expected missing secret diagnostic")
;;

let test_local_run_scopes_same_secret_key_per_unit_and_filters_ambient_value () =
  with_workspace
    [ ( "sol.yml"
      , "services:\n\
        \  charge_svc:\n\
        \    language: ocaml\n\
        \  email_svc:\n\
        \    language: ocaml\n" )
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", "[infra.env]\nsecrets = [\"API_KEY\"]\n"
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ; "app/notifications/email_svc/Dockerfile", dockerfile
    ; "app/notifications/email_svc/sol.toml", "[infra.env]\nsecrets = [\"API_KEY\"]\n"
    ; "app/notifications/email_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let original = Sys.getenv_opt "API_KEY" in
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some value -> Unix.putenv "API_KEY" value
      | None -> Unix.putenv "API_KEY" "")
    (fun () ->
       Unix.putenv "API_KEY" "ambient-secret-must-not-leak";
       let facts = facts_of root in
       let secret_values =
         [ "payments/charge_svc", [ "API_KEY", "payments-value" ]
         ; "notifications/email_svc", [ "API_KEY", "notifications-value" ]
         ]
       in
       List.iter
         (fun services ->
            match Sol_cli_local_run.plan ~secret_values ~root ~facts services with
            | Error errors -> Windtrap.fail (String.concat "; " (List.map snd errors))
            | Ok plan ->
              (match plan.launches with
               | [ _; _ ] ->
                 let find label =
                   match
                     List.find_opt
                       (fun (r : Sol_cli_local_run.recipe) -> r.label = label)
                       plan.launches
                   with
                   | Some recipe -> recipe
                   | None -> Windtrap.fail ("missing local unit " ^ label)
                 in
                 let payments = find "payments/charge_svc" in
                 let notifications = find "notifications/email_svc" in
                 check_string
                   "payments receives its unit value"
                   "payments-value"
                   (Option.value ~default:"" (List.assoc_opt "API_KEY" payments.env));
                 check_string
                   "notifications receives its unit value"
                   "notifications-value"
                   (Option.value ~default:"" (List.assoc_opt "API_KEY" notifications.env));
                 check_bool
                   "ambient secret is filtered from launches"
                   false
                   (List.exists
                      (fun (_, value) -> value = "ambient-secret-must-not-leak")
                      (payments.env @ notifications.env));
                 check_bool
                   "file values are redacted"
                   true
                   (List.mem "payments-value" plan.redact
                    && List.mem "notifications-value" plan.redact)
               | _ -> Windtrap.fail "expected two local units"))
         [ services_of facts; List.rev (services_of facts) ])
;;

let typescript_unit =
  [ ( "app/demo_ts/package.json"
    , {|{"name": "demo-ts", "private": true, "workspaces": ["order_svc", "fulfillment_worker"]}|}
    )
  ; "app/demo_ts/node_modules/.keep", ""
  ; ( "app/demo_ts/order_svc/package.json"
    , {|{"name": "order-svc", "scripts": {"build": "tsc", "start": "node dist/index.js"}}|}
    )
  ; ( "app/demo_ts/order_svc/tsconfig.json"
    , {|{"compilerOptions": {"outDir": "dist", "rootDir": "src"}}|} )
  ; "app/demo_ts/order_svc/Dockerfile", dockerfile
  ; "app/demo_ts/order_svc/sol.toml", ""
  ]
;;

let ts_workspace =
  ("sol.yml", "services:\n  order_svc:\n    language: typescript\n") :: typescript_unit
;;

let test_typescript_unit_builds_through_npm_and_runs_node () =
  with_workspace ts_workspace
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings
         "builds the npm workspace by package name"
         [ "npm"; "run"; "build"; "--workspace"; "order-svc" ]
         build.argv;
       check_string "in the npm project root" "app/demo_ts" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "runs the built entry directly with node"
         [ "node"; "order_svc/dist/index.js" ]
         launch.launch.argv;
       check_string "in the npm project root" "app/demo_ts" launch.launch.cwd;
       check_string "artifact" "app/demo_ts/order_svc/dist/index.js" launch.artifact;
       check_bool "declared TypeScript" true (launch.language = Sol_cli_compat.Typescript)
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let test_a_standalone_typescript_unit_is_its_own_project () =
  with_workspace
    [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
    ; "app/api/api_svc/package.json", {|{"name": "api", "scripts": {"build": "tsc"}}|}
    ; "app/api/api_svc/tsconfig.json", {|{"compilerOptions": {"outDir": "build"}}|}
    ; "app/api/api_svc/node_modules/.keep", ""
    ; "app/api/api_svc/Dockerfile", dockerfile
    ; "app/api/api_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] ->
       check_strings "no workspace selector" [ "npm"; "run"; "build" ] build.argv;
       check_string "built in the unit" "app/api/api_svc" build.cwd
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)));
    (match plan.launches with
     | [ launch ] ->
       check_strings
         "the tsconfig outDir is honoured"
         [ "node"; "build/index.js" ]
         launch.launch.argv
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let build_of root =
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.builds with
     | [ build ] -> build
     | builds ->
       Windtrap.fail (Printf.sprintf "expected one build, got %d" (List.length builds)))
;;

let api_unit_package_json = {|{"name": "api", "scripts": {"build": "tsc"}}|}
let api_unit_tsconfig = {|{"compilerOptions": {"outDir": "build"}}|}

let api_svc_workspace ~root_package_json =
  [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
  ; "app/package.json", root_package_json
  ; "app/node_modules/.keep", ""
  ; "app/api/api_svc/package.json", api_unit_package_json
  ; "app/api/api_svc/tsconfig.json", api_unit_tsconfig
  ; "app/api/api_svc/node_modules/.keep", ""
  ; "app/api/api_svc/Dockerfile", dockerfile
  ; "app/api/api_svc/sol.toml", ""
  ]
;;

let test_an_unrelated_glob_does_not_capture_a_unit () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "tools/* does not capture app/api/api_svc"
    [ "npm"; "run"; "build" ]
    build.argv;
  check_string "built as its own project" "app/api/api_svc" build.cwd
;;

let test_a_nested_exact_entry_selects_the_ancestor () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["api/api_svc"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "the nested exact entry selects the workspace"
    [ "npm"; "run"; "build"; "--workspace"; "api" ]
    build.argv;
  check_string "built in the npm project root" "app" build.cwd
;;

let test_a_supported_glob_selects_the_ancestor () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["api/*", "tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "api/* matches the single-segment package directory"
    [ "npm"; "run"; "build"; "--workspace"; "api" ]
    build.argv;
  check_string "built in the npm project root" "app" build.cwd
;;

let test_a_glob_does_not_cross_path_segments () =
  with_workspace
    (api_svc_workspace
       ~root_package_json:
         {|{"name": "app-root", "private": true, "workspaces": ["app/*", "tools/*"]}|})
  @@ fun root ->
  let build = build_of root in
  check_strings
    "app/* does not reach app/api/api_svc"
    [ "npm"; "run"; "build" ]
    build.argv;
  check_string "built as its own project" "app/api/api_svc" build.cwd
;;

let test_a_mixed_selection_uses_both_adapters () =
  let files =
    [ ( "sol.yml"
      , "services:\n\
        \  charge_svc:\n\
        \    language: ocaml\n\
        \  order_svc:\n\
        \    language: typescript\n" )
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
    @ typescript_unit
  in
  with_workspace files
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    check_bool "two units" true (List.length plan.launches = 2);
    (match plan.builds with
     | [ dune_build; npm_build ] ->
       check_strings
         "the dune build covers only the OCaml unit"
         [ "dune"; "build"; "app/payments/charge_svc/bin/main.exe" ]
         dune_build.argv;
       check_strings
         "the TypeScript unit builds with npm"
         [ "npm"; "run"; "build"; "--workspace"; "order-svc" ]
         npm_build.argv
     | builds ->
       Windtrap.fail (Printf.sprintf "expected two builds, got %d" (List.length builds)));
    let services = services_of facts in
    check_strings
      "both units are launched, in selection order"
      (List.map Sol_cli_local_run.label services)
      (List.map (fun (r : Sol_cli_local_run.recipe) -> r.label) plan.launches)
;;

let expect_error ~needle = function
  | Ok _ -> Windtrap.fail "expected the plan to refuse"
  | Error errors ->
    let messages = List.map (fun (label, message) -> label ^ " " ^ message) errors in
    check_bool
      (Printf.sprintf "names %S in %s" needle (String.concat "; " messages))
      true
      (List.exists (fun message -> Sol_cli_string.contains ~needle message) messages)
;;

let test_an_undeclared_workload_is_refused () =
  with_workspace
    [ "sol.yml", ""
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"declares no language"
;;

let test_a_typescript_unit_without_a_package_is_refused () =
  with_workspace
    [ "sol.yml", "services:\n  charge_svc:\n    language: typescript\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ]
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"package.json could not be read"
;;

let test_typescript_dependencies_that_are_not_installed_are_refused () =
  let files =
    List.filter
      (fun (rel, _) -> not (String.equal rel "app/demo_ts/node_modules/.keep"))
      ts_workspace
  in
  with_workspace files
  @@ fun root ->
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"run `npm ci` in app/demo_ts"
;;

let test_one_bad_unit_refuses_the_whole_plan () =
  with_workspace
    [ ( "sol.yml"
      , "services:\n\
        \  charge_svc:\n\
        \    language: ocaml\n\
        \  ledger_worker:\n\
        \    language: ocaml\n" )
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ; "app/comms/ledger_worker/Dockerfile", dockerfile
    ; "app/comms/ledger_worker/sol.toml", ""
    ]
  @@ fun root ->
  write_file
    (Filename.concat root "sol.yml")
    "services:\n  charge_svc:\n    language: ocaml\n";
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
  |> expect_error ~needle:"ledger_worker declares no language"
;;

let test_shell_lines () =
  let command argv cwd = { Sol_cli_local_run.argv; cwd } in
  Windtrap.equal
    Windtrap.string
    ~msg:"a root build, under the opam env"
    "eval $(opam env 2>/dev/null) 2>/dev/null; 'dune' 'build' './a b.exe'"
    (Sol_cli_local_run.build_line (command [ "dune"; "build"; "./a b.exe" ] ""));
  Windtrap.equal
    Windtrap.string
    ~msg:"a build in its npm project"
    "eval $(opam env 2>/dev/null) 2>/dev/null; cd 'app/x' && 'npm' 'run' 'build'"
    (Sol_cli_local_run.build_line (command [ "npm"; "run"; "build" ] "app/x"));
  Windtrap.equal
    Windtrap.string
    ~msg:"a launch"
    "'node' 'dist/main.js'"
    (Sol_cli_local_run.launch_line (command [ "node"; "dist/main.js" ] "."))
;;

let index_of haystack needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length haystack
    then None
    else if String.sub haystack i n = needle
    then Some i
    else go (i + 1)
  in
  go 0
;;

let test_command_preserves_build_launch_phases () =
  let sol = Cli_binary.path () in
  let check build_exit expected_phases expected_success =
    with_workspace ts_workspace (fun root ->
      let bin = Filename.concat root "fake-bin" in
      let log = Filename.concat root "phases" in
      let npm = Filename.concat bin "npm" in
      let node = Filename.concat bin "node" in
      write_file
        npm
        "#!/bin/sh\n\
         echo build >> \"$SOL_TEST_PHASE_LOG\"\n\
         exit \"$SOL_TEST_BUILD_EXIT\"\n";
      write_file
        node
        (Printf.sprintf
           "#!/bin/sh\necho launch >> %s\necho child-output\n"
           (Filename.quote log));
      Unix.chmod npm 0o755;
      Unix.chmod node 0o755;
      let path = bin ^ ":" ^ Option.value (Sys.getenv_opt "PATH") ~default:"" in
      let result =
        Sol_cli_process.run
          ~echo:false
          (Sol_cli_process.cmd
             ~timeout_s:10.
             ~env:
               [ "PATH", path
               ; "SOL_TEST_PHASE_LOG", log
               ; "SOL_TEST_BUILD_EXIT", string_of_int build_exit
               ]
             [ sol; "local"; "run"; "--workspace"; root ])
      in
      check_bool "command success" expected_success (Result.is_ok result);
      let phases = In_channel.with_open_text log In_channel.input_all in
      check_bool
        (Printf.sprintf "build gates launch: expected %S, got %S" expected_phases phases)
        true
        (expected_phases = phases);
      let stdout =
        match result with
        | Ok completed -> completed.stdout
        | Error (Sol_cli_process.Non_zero failure) -> failure.stdout
        | Error _ -> ""
      in
      let precedes before after =
        match index_of stdout before, index_of stdout after with
        | Some i, Some j -> i < j
        | _ -> false
      in
      check_bool
        "the plan report precedes the build"
        true
        (precedes "Starting 1 service(s)" "Building...");
      check_bool
        "Build done. is reported only on success"
        expected_success
        (Option.is_some (index_of stdout "Build done."));
      check_bool
        "the build precedes the launch"
        expected_success
        (precedes "Building..." "Services running"))
  in
  check 0 "build\nlaunch\n" true;
  check 7 "build\n" false
;;

let%test "adapters: an OCaml unit builds with dune and runs the binary" =
  test_ocaml_unit_builds_with_dune_and_runs_the_binary ()
;;

let%test "adapters: a TypeScript unit builds through npm and runs node" =
  test_typescript_unit_builds_through_npm_and_runs_node ()
;;

let%test "adapters: a standalone TypeScript unit is its own project" =
  test_a_standalone_typescript_unit_is_its_own_project ()
;;

let%test "adapters: a mixed selection uses both adapters" =
  test_a_mixed_selection_uses_both_adapters ()
;;

let%test "adapters: an unrelated glob does not capture a unit (BUG-076)" =
  test_an_unrelated_glob_does_not_capture_a_unit ()
;;

let%test "adapters: a nested exact entry selects the ancestor (BUG-076)" =
  test_a_nested_exact_entry_selects_the_ancestor ()
;;

let%test "adapters: a supported glob selects the ancestor (BUG-076)" =
  test_a_supported_glob_selects_the_ancestor ()
;;

let%test "adapters: a glob does not cross path segments (BUG-076)" =
  test_a_glob_does_not_cross_path_segments ()
;;

let%test "adapters: build and launch" = test_shell_lines ()

let%test "command phases: build gates launch" =
  test_command_preserves_build_launch_phases ()
;;

let%test "refusals: an undeclared workload" = test_an_undeclared_workload_is_refused ()

let%test "refusals: a TypeScript unit with no package.json" =
  test_a_typescript_unit_without_a_package_is_refused ()
;;

let%test "refusals: TypeScript dependencies that are not installed" =
  test_typescript_dependencies_that_are_not_installed_are_refused ()
;;

let%test "refusals: one undrivable unit refuses the whole plan" =
  test_one_bad_unit_refuses_the_whole_plan ()
;;

let standalone_ts_unit ~package_json ?tsconfig () =
  [ "sol.yml", "services:\n  api_svc:\n    language: typescript\n"
  ; "app/api/api_svc/package.json", package_json
  ; "app/api/api_svc/node_modules/.keep", ""
  ; "app/api/api_svc/Dockerfile", dockerfile
  ; "app/api/api_svc/sol.toml", ""
  ]
  @
  match tsconfig with
  | None -> []
  | Some content -> [ "app/api/api_svc/tsconfig.json", content ]
;;

let plan_of root =
  let facts = facts_of root in
  Sol_cli_local_run.plan ~root ~facts (services_of facts)
;;

let test_an_absent_tsconfig_keeps_the_documented_default () =
  with_workspace (standalone_ts_unit ~package_json:{|{"name": "api"}|} ())
  @@ fun root ->
  match plan_of root with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.launches with
     | [ launch ] ->
       check_strings "the dist default" [ "node"; "dist/index.js" ] launch.launch.argv;
       check_string "artifact under dist" "app/api/api_svc/dist/index.js" launch.artifact
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let%test "metadata: an absent tsconfig keeps the dist default" =
  test_an_absent_tsconfig_keeps_the_documented_default ()
;;

let test_a_malformed_tsconfig_is_refused () =
  with_workspace
    (standalone_ts_unit ~package_json:{|{"name": "api"}|} ~tsconfig:"{ not json" ())
  @@ fun root -> plan_of root |> expect_error ~needle:"tsconfig.json"
;;

let%test "metadata: a malformed tsconfig is refused" =
  test_a_malformed_tsconfig_is_refused ()
;;

let test_an_unreadable_tsconfig_is_refused () =
  if Unix.geteuid () = 0
  then ()
  else
    with_workspace
      (standalone_ts_unit ~package_json:{|{"name": "api"}|} ~tsconfig:"{}" ())
    @@ fun root ->
    let path = Filename.concat root "app/api/api_svc/tsconfig.json" in
    Unix.chmod path 0o000;
    let result =
      Fun.protect (fun () -> plan_of root) ~finally:(fun () -> Unix.chmod path 0o644)
    in
    result |> expect_error ~needle:"tsconfig.json"
;;

let%test "metadata: an unreadable tsconfig is refused" =
  test_an_unreadable_tsconfig_is_refused ()
;;

let test_an_outdir_of_the_wrong_type_is_refused () =
  with_workspace
    (standalone_ts_unit
       ~package_json:{|{"name": "api"}|}
       ~tsconfig:{|{"compilerOptions": {"outDir": 5}}|}
       ())
  @@ fun root ->
  plan_of root |> expect_error ~needle:"compilerOptions.outDir must be text"
;;

let%test "metadata: a non-text outDir is refused" =
  test_an_outdir_of_the_wrong_type_is_refused ()
;;

let test_compiler_options_of_the_wrong_type_is_refused () =
  with_workspace
    (standalone_ts_unit
       ~package_json:{|{"name": "api"}|}
       ~tsconfig:{|{"compilerOptions": "nope"}|}
       ())
  @@ fun root -> plan_of root |> expect_error ~needle:"compilerOptions must be an object"
;;

let%test "metadata: non-object compilerOptions is refused" =
  test_compiler_options_of_the_wrong_type_is_refused ()
;;

let test_a_non_text_main_is_refused () =
  with_workspace (standalone_ts_unit ~package_json:{|{"name": "api", "main": 123}|} ())
  @@ fun root -> plan_of root |> expect_error ~needle:"main must be text"
;;

let%test "metadata: a non-text main is refused" = test_a_non_text_main_is_refused ()

let test_a_malformed_ancestor_package_is_refused () =
  with_workspace (api_svc_workspace ~root_package_json:"{ not json")
  @@ fun root -> plan_of root |> expect_error ~needle:"app/package.json"
;;

let%test "metadata: a malformed ancestor package.json is refused" =
  test_a_malformed_ancestor_package_is_refused ()
;;

let test_malformed_workspaces_is_refused () =
  with_workspace
    (api_svc_workspace ~root_package_json:{|{"name": "app-root", "workspaces": "api/*"}|})
  @@ fun root ->
  plan_of root |> expect_error ~needle:"workspaces must be a list of strings"
;;

let%test "metadata: a non-list workspaces field is refused" =
  test_malformed_workspaces_is_refused ()
;;

let test_workspaces_with_non_string_entries_is_refused () =
  with_workspace
    (api_svc_workspace ~root_package_json:{|{"name": "app-root", "workspaces": [1, 2]}|})
  @@ fun root ->
  plan_of root |> expect_error ~needle:"workspaces must be a list of strings"
;;

let%test "metadata: non-string workspaces entries are refused" =
  test_workspaces_with_non_string_entries_is_refused ()
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let launch_recipe ?(label = "probe") ?(cwd = "") ?(env = []) argv =
  { Sol_cli_local_run.label
  ; language = Sol_cli_compat.Ocaml
  ; build = None
  ; launch = { Sol_cli_local_run.argv; cwd }
  ; artifact = ""
  ; env
  }
;;

let devnull () = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0
let to_devnull (_ : Sol_cli_local_run.recipe) = devnull ()

let alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
;;

let wait_gone ?(tries = 100) pid =
  let rec go remaining =
    if not (alive pid)
    then true
    else if remaining = 0
    then false
    else (
      Unix.sleepf 0.02;
      go (remaining - 1))
  in
  go tries
;;

let cleanup_tree dir = ignore (Sol_cli_fs.remove_tree dir)

let test_launch_uses_literal_argv_and_cwd () =
  let sandbox = temp_dir "sol-launch-literal-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree sandbox)
    (fun () ->
       let dir = Filename.concat sandbox "a dir with spaces" in
       Unix.mkdir dir 0o755;
       let script = Filename.concat dir "probe;script.sh" in
       let marker = Filename.concat sandbox "marker" in
       write_file
         script
         (Printf.sprintf
            "#!/bin/sh\nprintf '%%s\\n' \"$PWD\" > %s\nprintf '%%s\\n' \"$1\" >> %s\n"
            (Filename.quote marker)
            (Filename.quote marker));
       Unix.chmod script 0o755;
       let recipe = launch_recipe ~cwd:dir [ script; "arg with $meta;chars" ] in
       let run =
         match Sol_cli_local_run.launch_all ~output:to_devnull [ recipe ] with
         | Error failure -> Error failure
         | Ok children -> Sol_cli_local_run.supervise children
       in
       (match run with
        | Ok () -> ()
        | Error failure ->
          Windtrap.fail (Sol_cli_local_run.child_failure_to_string failure));
       let lines =
         In_channel.with_open_text marker In_channel.input_all
         |> String.split_on_char '\n'
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"the child ran in the literal cwd"
         true
         (List.mem dir lines);
       Windtrap.equal
         Windtrap.bool
         ~msg:"the argument reached the child unexpanded"
         true
         (List.mem "arg with $meta;chars" lines))
;;

let%test "runtime: launch uses literal argv and cwd" =
  test_launch_uses_literal_argv_and_cwd ()
;;

let test_a_failed_launch_stops_owned_children () =
  let sandbox = temp_dir "sol-partial-launch-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree sandbox)
    (fun () ->
       let marker = Filename.concat sandbox "pid" in
       let script = Filename.concat sandbox "sleeper.sh" in
       write_file
         script
         (Printf.sprintf "#!/bin/sh\necho $$ > %s\nsleep 30\n" (Filename.quote marker));
       Unix.chmod script 0o755;
       let sleeper = launch_recipe ~label:"sleeper" [ script ] in
       let missing =
         launch_recipe ~label:"missing" [ "/nonexistent/sol-probe-program" ]
       in
       let output = function
         | recipe when String.equal recipe.Sol_cli_local_run.label "sleeper" -> devnull ()
         | _ ->
           Unix.sleepf 0.3;
           devnull ()
       in
       (match Sol_cli_local_run.launch_all ~output [ sleeper; missing ] with
        | Ok _ -> Windtrap.fail "a missing program must fail the launch"
        | Error (Sol_cli_local_run.Spawn_failed { label; _ }) ->
          Windtrap.equal
            Windtrap.string
            ~msg:"names the recipe that failed"
            "missing"
            label
        | Error failure ->
          Windtrap.fail
            ("unexpected failure: " ^ Sol_cli_local_run.child_failure_to_string failure));
       let pid =
         int_of_string
           (String.trim (In_channel.with_open_text marker In_channel.input_all))
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"the started child was stopped"
         true
         (wait_gone pid))
;;

let%test "runtime: a failed launch stops owned children" =
  test_a_failed_launch_stops_owned_children ()
;;

let test_supervise_refuses_a_nonzero_exit () =
  let recipe = launch_recipe ~label:"bad" [ "sh"; "-c"; "exit 3" ] in
  match Sol_cli_local_run.launch_all ~output:to_devnull [ recipe ] with
  | Error failure -> Windtrap.fail (Sol_cli_local_run.child_failure_to_string failure)
  | Ok children ->
    (match Sol_cli_local_run.supervise children with
     | Error (Sol_cli_local_run.Exited { label; code }) ->
       Windtrap.equal Windtrap.string ~msg:"names the child" "bad" label;
       Windtrap.equal Windtrap.int ~msg:"keeps the code" 3 code
     | Error failure ->
       Windtrap.fail
         ("wrong failure: " ^ Sol_cli_local_run.child_failure_to_string failure)
     | Ok () -> Windtrap.fail "a nonzero exit must not complete successfully")
;;

let%test "runtime: a nonzero child exit fails the run" =
  test_supervise_refuses_a_nonzero_exit ()
;;

let test_supervise_refuses_a_signalled_child () =
  let recipe = launch_recipe ~label:"killed" [ "sh"; "-c"; "kill -TERM $$" ] in
  match Sol_cli_local_run.launch_all ~output:to_devnull [ recipe ] with
  | Error failure -> Windtrap.fail (Sol_cli_local_run.child_failure_to_string failure)
  | Ok children ->
    (match Sol_cli_local_run.supervise children with
     | Error (Sol_cli_local_run.Signaled { label; signal }) ->
       Windtrap.equal Windtrap.string ~msg:"names the child" "killed" label;
       Windtrap.equal Windtrap.int ~msg:"keeps the signal" Sys.sigterm signal
     | Error failure ->
       Windtrap.fail
         ("wrong failure: " ^ Sol_cli_local_run.child_failure_to_string failure)
     | Ok () -> Windtrap.fail "a signalled child must not complete successfully")
;;

let%test "runtime: a signalled child fails the run" =
  test_supervise_refuses_a_signalled_child ()
;;

let test_supervise_reaps_only_owned_children () =
  let unrelated =
    Sol_cli_process.spawn (Sol_cli_process.cmd [ "sleep"; "0.05" ])
    |> Result.get_ok
    |> Sol_cli_process.pid
  in
  let owned = launch_recipe ~label:"owned" [ "sh"; "-c"; "sleep 0.3" ] in
  let supervised =
    match Sol_cli_local_run.launch_all ~output:to_devnull [ owned ] with
    | Error failure -> Error failure
    | Ok children -> Sol_cli_local_run.supervise children
  in
  let not_reaped =
    match Unix.waitpid [ Unix.WNOHANG ] unrelated with
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false
    | _ -> true
  in
  (match supervised with
   | Ok () -> ()
   | Error failure -> Windtrap.fail (Sol_cli_local_run.child_failure_to_string failure));
  Windtrap.equal
    Windtrap.bool
    ~msg:"supervise never reaps an unrelated child"
    true
    not_reaped;
  (try Unix.kill unrelated Sys.sigkill with
   | Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] unrelated) with
  | Unix.Unix_error _ -> ()
;;

let%test "runtime: supervise reaps only its own children" =
  test_supervise_reaps_only_owned_children ()
;;

let test_sigterm_stops_owned_children () =
  let ready_read, ready_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    (try
       Unix.close ready_read;
       let recipe = launch_recipe ~label:"sleeper" [ "sleep"; "30" ] in
       match Sol_cli_local_run.launch ~output:(devnull ()) recipe with
       | Error _ -> Unix._exit 8
       | Ok child ->
         let text = string_of_int child.Sol_cli_local_run.child_pid in
         ignore (Unix.write_substring ready_write text 0 (String.length text));
         Unix.close ready_write;
         (match Sol_cli_local_run.supervise [ child ] with
          | Error (Sol_cli_local_run.Interrupted signal) ->
            Unix._exit (Sol_cli_local_run.interrupt_exit_code signal)
          | _ -> Unix._exit 9)
     with
     | _ -> Unix._exit 7)
  | helper ->
    Unix.close ready_write;
    let buffer = Bytes.create 32 in
    let count = Unix.read ready_read buffer 0 32 in
    Unix.close ready_read;
    let child_pid = int_of_string (Bytes.sub_string buffer 0 count) in
    Unix.sleepf 0.2;
    Unix.kill helper Sys.sigterm;
    let _, status = Unix.waitpid [] helper in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the interrupted run exits 143"
      true
      (status = Unix.WEXITED 143);
    Windtrap.equal Windtrap.bool ~msg:"the owned child is gone" false (alive child_pid)
;;

let%test "runtime: SIGTERM stops owned children and restores the run" =
  test_sigterm_stops_owned_children ()
;;

let read_all fd =
  let buffer = Buffer.create 64 in
  let chunk = Bytes.create 4096 in
  let rec go () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count ->
      Buffer.add_subbytes buffer chunk 0 count;
      go ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ()
;;

let test_ocaml_launch_recipe_runs () =
  with_workspace
    [ "sol.yml", "services:\n  charge_svc:\n    language: ocaml\n"
    ; "app/payments/charge_svc/Dockerfile", dockerfile
    ; "app/payments/charge_svc/sol.toml", ""
    ; "app/payments/charge_svc/bin/dune", "(executable (name main))\n"
    ]
  @@ fun root ->
  let facts = facts_of root in
  match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
  | Error errors ->
    Windtrap.fail
      ("plan failed: " ^ String.concat "; " (List.map (fun (l, m) -> l ^ " " ^ m) errors))
  | Ok plan ->
    (match plan.launches with
     | [ recipe ] ->
       let artifact = Filename.concat root (List.hd recipe.launch.argv) in
       write_file artifact "#!/bin/sh\necho ocaml-launched\n";
       Unix.chmod artifact 0o755;
       let read_fd, write_fd = Unix.pipe ~cloexec:true () in
       let recipe = { recipe with launch = { recipe.launch with cwd = root } } in
       let result =
         match Sol_cli_local_run.launch ~output:write_fd recipe with
         | Error failure -> Error failure
         | Ok child ->
           (match Sol_cli_local_run.supervise [ child ] with
            | Ok () -> Ok ()
            | Error failure -> Error failure)
       in
       let output = read_all read_fd in
       Unix.close read_fd;
       (match result with
        | Ok () -> ()
        | Error failure ->
          Windtrap.fail (Sol_cli_local_run.child_failure_to_string failure));
       Windtrap.equal
         Windtrap.bool
         ~msg:"the planned OCaml binary ran"
         true
         (Sol_cli_string.contains ~needle:"ocaml-launched" output)
     | launches ->
       Windtrap.fail (Printf.sprintf "expected one launch, got %d" (List.length launches)))
;;

let%test "runtime: an OCaml launch recipe runs without a shell" =
  test_ocaml_launch_recipe_runs ()
;;

let%test "secrets: local input is scoped to a unit" =
  test_local_secret_file_parses_without_shell_evaluation ();
  test_local_secret_file_rejects_duplicate_keys_without_values ();
  test_local_secret_file_loads_by_unit_address ();
  test_local_run_projects_only_declared_secret_keys ();
  test_local_run_requires_declared_secret_value ();
  test_local_run_scopes_same_secret_key_per_unit_and_filters_ambient_value ()
;;

let%test
    "local resource inputs follow declared dependencies for every primitive and language"
  =
  let cases =
    [ "none", [], false, false
    ; "database", [ "app_db" ], true, false
    ; "kafka", [ "events" ], false, true
    ; "both", [ "app_db"; "events" ], true, true
    ]
  in
  let units =
    [ "ocaml"; "typescript" ]
    |> List.concat_map (fun language ->
      [ "svc", "http"; "worker", "worker"; "fn", "fn" ]
      |> List.concat_map (fun (suffix, kind) ->
        List.map
          (fun (tag, uses, database, kafka) ->
             language, tag ^ "_" ^ language ^ "_" ^ suffix, kind, uses, database, kafka)
          cases))
  in
  let declarations =
    units
    |> List.map (fun (language, name, kind, uses, _, _) ->
      Printf.sprintf
        "  %s:\n    type: %s\n    language: %s\n    path: app/test/%s\n    uses: [%s]\n"
        name
        kind
        language
        name
        (String.concat ", " uses))
    |> String.concat ""
  in
  let files =
    [ ( "sol.yml"
      , "resources:\n\
        \  app_db:\n\
        \    type: postgres\n\
        \  events:\n\
        \    type: kafka\n\
         services:\n"
        ^ declarations )
    ]
    @ (units
       |> List.concat_map (fun (language, name, _, _, _, _) ->
         let directory = "app/test/" ^ name ^ "/" in
         [ directory ^ "Dockerfile", dockerfile
         ; directory ^ "sol.toml", "[infra.env]\nsecrets = [\"UNIT_API_KEY\"]\n"
         ]
         @
         if language = "typescript"
         then
           [ ( directory ^ "package.json"
             , Printf.sprintf {|{"name":"%s","main":"index.js"}|} name )
           ; directory ^ "node_modules/.keep", ""
           ]
         else []))
  in
  with_workspace files (fun root ->
    let facts = facts_of root in
    let secret_values =
      units
      |> List.map (fun (_, name, _, _, _, _) ->
        ( "test/" ^ name
        , [ "UNIT_API_KEY", "declared-app-value"
          ; "POSTGRES_URL", "postgresql://local-file-value/db"
          ; "SOL_API_KEY", "undeclared-peer-value"
          ; "KAFKA_SASL_PASSWORD", "unused-local-auth"
          ; "KAFKA_SSL_CA_CERT", "unused-local-trust"
          ] ))
    in
    match Sol_cli_local_run.plan ~secret_values ~root ~facts (services_of facts) with
    | Error errors -> Windtrap.fail (String.concat "; " (List.map snd errors))
    | Ok plan ->
      List.iter
        (fun (_, name, _, _, database, kafka) ->
           let recipe =
             List.find
               (fun (recipe : Sol_cli_local_run.recipe) -> recipe.label = "test/" ^ name)
               plan.launches
           in
           check_bool
             (name ^ ": database input follows uses")
             database
             (List.mem_assoc "POSTGRES_URL" recipe.env);
           List.iter
             (fun key ->
                check_bool
                  (name ^ ": " ^ key ^ " follows Kafka dependency")
                  kafka
                  (List.mem_assoc key recipe.env))
             [ "KAFKA_BROKERS"
             ; "SCHEMA_REGISTRY_URL"
             ; "REDPANDA_ADMIN_URL"
             ; "KAFKA_SECURITY_PROTOCOL"
             ];
           List.iter
             (fun key ->
                check_bool
                  (name ^ ": unrelated file key stays private")
                  false
                  (List.mem_assoc key recipe.env))
             [ "SOL_API_KEY"; "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ];
           if database
           then
             check_bool
               (name ^ ": local file override preserved")
               true
               (List.assoc_opt "POSTGRES_URL" recipe.env
                = Some "postgresql://local-file-value/db");
           check_bool
             (name ^ ": declared application secret remains delivered")
             true
             (List.mem_assoc "UNIT_API_KEY" recipe.env))
        units)
;;

let%test
    "a topic declaration remains a local Kafka dependency without guessing from workload \
     kind"
  =
  with_workspace
    [ ( "sol.yml"
      , "services:\n\
        \  producer_svc:\n\
        \    language: ocaml\n\
        \  idle_worker:\n\
        \    language: ocaml\n" )
    ; "app/test/producer_svc/Dockerfile", dockerfile
    ; "app/test/producer_svc/sol.toml", "[service]\ntopics = [\"events\"]\n"
    ; "app/test/idle_worker/Dockerfile", dockerfile
    ; "app/test/idle_worker/sol.toml", ""
    ]
    (fun root ->
       let facts = facts_of root in
       match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
       | Error errors -> Windtrap.fail (String.concat "; " (List.map snd errors))
       | Ok plan ->
         List.iter
           (fun (recipe : Sol_cli_local_run.recipe) ->
              check_bool
                "topic producer receives Kafka; idle worker does not"
                (recipe.label = "test/producer_svc")
                (List.mem_assoc "KAFKA_BROKERS" recipe.env))
           plan.launches)
;;

let%test "local application secret declarations cannot bypass resource ownership" =
  List.iter
    (fun key ->
       with_workspace
         [ "sol.yml", "services:\n  consumer_svc:\n    language: ocaml\n"
         ; "app/test/consumer_svc/Dockerfile", dockerfile
         ; ( "app/test/consumer_svc/sol.toml"
           , Printf.sprintf "[infra.env]\nsecrets = [%S]\n" key )
         ]
         (fun root ->
            let facts = facts_of root in
            match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
            | Error errors ->
              check_bool
                "refusal explains resource ownership"
                true
                (List.exists
                   (fun (_, message) ->
                      Sol_cli_string.contains ~needle:"resource connection input" message)
                   errors)
            | Ok _ ->
              Windtrap.fail "reserved resource input accepted as application secret"))
    [ "POSTGRES_URL"; "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ]
;;

let%test "omitted local resources do not authorize connection delivery" =
  with_workspace
    [ ( "sol.yml"
      , "resources:\n\
        \  app_db:\n\
        \    type: postgres\n\
        \    omit: true\n\
        \  events:\n\
        \    type: kafka\n\
        \    omit: true\n\
         services:\n\
        \  consumer_svc:\n\
        \    language: ocaml\n\
        \    uses: [app_db, events]\n" )
    ; "app/test/consumer_svc/Dockerfile", dockerfile
    ; "app/test/consumer_svc/sol.toml", ""
    ]
    (fun root ->
       let facts = facts_of root in
       match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
       | Error errors ->
         check_bool
           "omitted dependency is refused"
           true
           (List.exists
              (fun (_, message) ->
                 Sol_cli_string.contains ~needle:"undeclared resource" message)
              errors)
       | Ok _ -> Windtrap.fail "omitted required resource accepted")
;;

let%test "local dependency references are validated before connection projection" =
  List.iter
    (fun reference ->
       with_workspace
         [ ( "sol.yml"
           , Printf.sprintf
               "resources:\n\
               \  app_db:\n\
               \    type: postgres\n\
                services:\n\
               \  consumer_svc:\n\
               \    language: ocaml\n\
               \    uses: [%s]\n"
               reference )
         ; "app/test/consumer_svc/Dockerfile", dockerfile
         ; "app/test/consumer_svc/sol.toml", ""
         ]
         (fun root ->
            let facts = facts_of root in
            match Sol_cli_local_run.plan ~root ~facts (services_of facts) with
            | Error errors ->
              check_bool
                "invalid reference identifies workspace"
                true
                (List.exists (fun (scope, _) -> scope = "workspace") errors)
            | Ok _ -> Windtrap.fail ("invalid dependency accepted: " ^ reference)))
    [ "missing_db"; "typo/app_db"; "/broken"; "/aws/app_db" ]
;;
