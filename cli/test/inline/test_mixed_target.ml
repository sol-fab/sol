let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let%test "a target can declare mixed execution" =
  let root = Filename.temp_file "sol-mixed-target" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  write (Filename.concat root "sol.yml") "project: mixed\nservices: {}\n";
  ignore (Sol_cli_fs.mkdir_p (Filename.concat root "sol"));
  write
    (Filename.concat root "sol/environments.yml")
    {|
live:
  targets:
    aws/us-east-1:
      execution: mixed
      state_bucket: state
      aws:
        state_lock_table: locks
|};
  let previous = Sys.getcwd () in
  Sys.chdir root;
  let result = Sol_cli_config.load_for_target ~target:"live/aws/us-east-1" in
  Sys.chdir previous;
  let () =
    let rec remove path =
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun child -> remove (Filename.concat path child));
        Unix.rmdir path)
      else Sys.remove path
    in
    remove root
  in
  match result with
  | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
  | Ok config ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"mixed execution is preserved"
      true
      (Sol_cli_config.execution_of_target config.target = Sol_cli_config.Mixed)
;;

let service name primitive : Sol_cli_manifest.service =
  { domain = "app"; name; primitive; dir = "app/" ^ name }
;;

let with_execution execution target =
  { target with
    Sol_cli_config.provider_fields =
      (target.Sol_cli_config.provider_fields
       |> List.filter (fun (provider, _) -> provider <> "sol"))
      @ [ "sol", [ "execution", execution ] ]
  }
;;

let%test "mixed target splits functions from Kubernetes units" =
  let svc = service "checkout_svc" Sol_cli_manifest.Svc in
  let fn = service "checkout_fn" Sol_cli_manifest.Fn in
  let target =
    Result.get_ok (Sol_cli_config.parse_target "mixed/aws/us-east-1")
    |> with_execution "mixed"
  in
  let serverless, kubernetes =
    Sol_cli_serverless_target_common.services_by_backend target [ svc; fn ]
  in
  Windtrap.equal Windtrap.int ~msg:"one serverless unit" 1 (List.length serverless);
  Windtrap.equal Windtrap.int ~msg:"one Kubernetes unit" 1 (List.length kubernetes);
  Windtrap.equal
    Windtrap.string
    ~msg:"function backend"
    "checkout_fn"
    (List.hd serverless).name;
  Windtrap.equal
    Windtrap.string
    ~msg:"service backend"
    "checkout_svc"
    (List.hd kubernetes).name
;;

let%test
    "mixed lifecycle model combines backend split, authorization units, and inventory"
  =
  let root = Filename.temp_file "sol-mixed-lifecycle" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  ignore (Sol_cli_fs.mkdir_p (Filename.concat root "app/payments"));
  write
    (Filename.concat root "sol.yml")
    {|project: mixed
services:
  orders_svc:
    type: http
    path: app/payments/orders_svc
  notify_fn:
    type: fn
    path: app/payments/notify_fn
|};
  ignore (Sol_cli_fs.mkdir_p (Filename.concat root "app/payments/orders_svc"));
  ignore (Sol_cli_fs.mkdir_p (Filename.concat root "app/payments/notify_fn"));
  write (Filename.concat root "app/payments/orders_svc/Dockerfile") "FROM scratch\n";
  write (Filename.concat root "app/payments/notify_fn/Dockerfile") "FROM scratch\n";
  write (Filename.concat root "app/payments/orders_svc/sol.toml") "[service]\n";
  write (Filename.concat root "app/payments/notify_fn/sol.toml") "[service]\n";
  ignore (Sol_cli_fs.mkdir_p (Filename.concat root "sol"));
  write
    (Filename.concat root "sol/environments.yml")
    {|
live:
  targets:
    aws/us-east-1:
      execution: mixed
      state_bucket: state
      aws:
        state_lock_table: locks
|};
  let previous = Sys.getcwd () in
  Sys.chdir root;
  let result =
    let open Result.Syntax in
    let* config =
      Sol_cli_config.load_for_target ~target:"live/aws/us-east-1"
      |> Result.map_error Sol_cli_config.error_to_string
    in
    let* model = Sol_cli_workspace_model.load ~root in
    let serverless, kubernetes =
      Sol_cli_serverless_target_common.services_by_backend
        config.target
        (Sol_cli_workspace_model.services model)
    in
    let* authorization_units, _scheduler =
      Sol_cli_serverless_lifecycle.complete_units
        ~config
        ~project:"mixed"
        ~target:config.target
        ~model
        ~exclude:None
        ~serverless_all:false
    in
    let* () =
      Sol_cli_serverless_inventory.add
        ~target:"live/aws/us-east-1"
        ~service:"notify_fn"
        ~record:"/tmp/notify.json"
    in
    let* entries = Sol_cli_serverless_inventory.load ~target:"live/aws/us-east-1" in
    Ok (serverless, kubernetes, authorization_units, entries)
  in
  Sys.chdir previous;
  let () =
    let rec remove path =
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun child -> remove (Filename.concat path child));
        Unix.rmdir path)
      else Sys.remove path
    in
    remove root
  in
  match result with
  | Error message -> Windtrap.fail message
  | Ok (serverless, kubernetes, authorization_units, entries) ->
    Windtrap.equal Windtrap.int ~msg:"one serverless unit" 1 (List.length serverless);
    Windtrap.equal Windtrap.int ~msg:"one Kubernetes unit" 1 (List.length kubernetes);
    Windtrap.equal
      Windtrap.int
      ~msg:"one authorization unit"
      1
      (List.length authorization_units);
    Windtrap.equal Windtrap.int ~msg:"one inventory entry" 1 (List.length entries)
;;
