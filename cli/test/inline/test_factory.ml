let facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

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
      ("sol-factory-" ^ string_of_int (Random.bits ()))
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

let env : Sol_cli_deployment_plan.env_config =
  { name = "myapp"
  ; mode = Sol_cli_deployment_plan.Local
  ; registry = "localhost:5000"
  ; image_tag = "abc123"
  ; env = None
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let test_run_without_cmdliner () =
  with_tmp (fun root ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    write "app/payments/charge_svc/sol.toml" "[infra.env]\nsecrets = [\"DATABASE_URL\"]\n";
    let emit_dir = Filename.concat root "out" in
    let services = Result.get_ok (Sol_cli_manifest.discover_services ()) in
    match
      Sol_cli_factory.run
        (Sol_cli_execution.context
           ~cluster:Sol_cli_kube_destination.local_context
           ~workspace:"myapp"
           ())
        ~request:
          { Sol_cli_factory.env
          ; requested_scope = Some "payments"
          ; declared = None
          ; target = None
          ; target_database = None
          ; provisioned_database = None
          }
        ~mode:(Sol_cli_executor.Emit_to emit_dir)
        ~facts:(facts ())
        services
    with
    | Error msg -> Windtrap.fail ("factory run failed: " ^ msg)
    | Ok execution ->
      Windtrap.equal Windtrap.int ~msg:"one result" 1 (List.length execution.results);
      Windtrap.equal
        Windtrap.string
        ~msg:"requested scope recorded"
        "payments"
        execution.plan.requested_scope;
      let facts =
        Sol_cli_factory.affected_services ~plan:execution.plan ~results:execution.results
      in
      Windtrap.equal Windtrap.int ~msg:"one release fact" 1 (List.length facts);
      let emitted = Filename.concat emit_dir "myapp-payments-charge-svc.yaml" in
      Windtrap.equal Windtrap.bool ~msg:"manifest emitted" true (Sys.file_exists emitted))
;;

let test_discover_missing_app () =
  with_tmp (fun _ ->
    match Sol_cli_manifest.discover_services () with
    | Error Sol_cli_manifest.Missing_app_dir -> ()
    | Error (Sol_cli_manifest.Workspace_error _) ->
      Windtrap.fail "expected Missing_app_dir, got a workspace error"
    | Ok _ -> Windtrap.fail "expected missing app error")
;;

let%test "boundary: run without cmdliner" = test_run_without_cmdliner ()
let%test "boundary: discovery missing app" = test_discover_missing_app ()
