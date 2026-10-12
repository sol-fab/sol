let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual

let check_strings msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

let mkdirs path =
  let rec go path =
    if path <> "" && path <> "." && path <> "/" && not (Sys.file_exists path)
    then (
      go (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  go path
;;

let write_file path body =
  mkdirs (Filename.dirname path);
  let oc = open_out path in
  output_string oc body;
  close_out oc
;;

let with_workspace files f =
  let dir = Filename.temp_file "sol_test_up_plan" "" in
  Sys.remove dir;
  mkdirs dir;
  List.iter (fun (rel, body) -> write_file (Filename.concat dir rel) body) files;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir cwd;
      ignore (Sol_cli_fs.remove_tree dir))
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let sol_yml =
  {|project: ws

resources:
  app_db:
    type: postgres
  events:
    type: kafka

services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db]
    language: ocaml
    scale: { min: 3 }

  notify_worker:
    type: worker
    path: app/comms/notify_worker
    uses: [events]
    language: ocaml
    scale: { max: 4 }
|}
;;

let environments_yml =
  {|prod:
  targets:
    aws/us-east-1:
      cluster_name: ws-prod
|}
;;

let workspace =
  [ "sol.yml", sol_yml
  ; "sol/environments.yml", environments_yml
  ; "app/payments/charge_svc/Dockerfile", "FROM scratch\n"
  ; "app/payments/charge_svc/sol.toml", "[infra.scale]\nreplicas = 2\n"
  ; "app/comms/notify_worker/Dockerfile", "FROM scratch\n"
  ; "app/comms/notify_worker/sol.toml", "[infra.scale]\nreplicas = 2\n"
  ]
;;

let fail_on_error what = function
  | Ok value -> value
  | Error message -> Windtrap.fail (Printf.sprintf "%s: %s" what message)
;;

let plans () =
  let facts =
    Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) |> fail_on_error "workspace model"
  in
  let services = Sol_cli_workspace_model.services facts in
  let declared =
    Sol_cli_config.load_declared ~root:(Sys.getcwd ())
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_declared"
  in
  let local =
    Sol_cli_up_execution.local_plan
      ~requested_scope:"workspace"
      ~workspace:"ws"
      ~sha:"sha-under-test"
      ~facts
      ~declared
      services
    |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
    |> fail_on_error "local_plan"
  in
  let target_config =
    Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1"
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_for_target"
  in
  let env =
    Sol_cli_env_target.to_env_config
      ~name:"ws"
      (Sol_cli_env_target.local_defaults ~image_tag:"sha-under-test")
  in
  let target =
    Sol_cli_deployment_plan.of_services_result
      ~workspace:"ws"
      ~env
      ~facts
      ~declared:(Sol_cli_config.declared_of_config target_config)
      services
    |> fun result ->
    match result with
    | Ok plan -> plan
    | Error e ->
      Windtrap.fail
        (Printf.sprintf
           "of_services_result: %s"
           (Sol_cli_deployment_plan.plan_error_to_string e))
  in
  local, target
;;

let spec_named plan name =
  match
    List.find_opt
      (fun (s : Sol_cli_deployment_plan.service_spec) -> String.equal s.source_name name)
      plan.Sol_cli_deployment_plan.services
  with
  | Some spec -> spec
  | None -> Windtrap.fail (Printf.sprintf "no spec for %s" name)
;;

let test_up_and_target_plans_agree () =
  with_workspace workspace (fun () ->
    let local, target = plans () in
    List.iter
      (fun name ->
         let from_local = spec_named local name in
         let from_target = spec_named target name in
         check_string
           (name ^ " language")
           (Option.fold
              ~none:"<none>"
              ~some:Sol_cli_compat.to_string
              from_target.Sol_cli_deployment_plan.language)
           (Option.fold
              ~none:"<none>"
              ~some:Sol_cli_compat.to_string
              from_local.Sol_cli_deployment_plan.language);
         check_int
           (name ^ " replicas")
           from_target.Sol_cli_deployment_plan.replicas
           from_local.Sol_cli_deployment_plan.replicas)
      [ "charge_svc"; "notify_worker" ];
    check_strings
      "consumer groups"
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         target.Sol_cli_deployment_plan.consumer_groups)
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         local.Sol_cli_deployment_plan.consumer_groups))
;;

let test_local_plan_carries_the_declared_facts () =
  with_workspace workspace (fun () ->
    let local, _ = plans () in
    let charge_svc = spec_named local "charge_svc" in
    let notify_worker = spec_named local "notify_worker" in
    check_string
      "charge_svc declares OCaml"
      "ocaml"
      (Option.fold
         ~none:"<none>"
         ~some:Sol_cli_compat.to_string
         charge_svc.Sol_cli_deployment_plan.language);
    check_int "charge_svc takes sol.yml's scale floor over sol.toml" 3 charge_svc.replicas;
    check_int
      "notify_worker takes sol.yml's scale ceiling over sol.toml"
      4
      notify_worker.replicas;
    check_strings
      "the kafka consumer group is derived locally too"
      [ "ws.comms.notify_worker" ]
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         local.Sol_cli_deployment_plan.consumer_groups))
;;

let test_local_plan_renders_readyz () =
  with_workspace workspace (fun () ->
    let local, _ = plans () in
    let charge_svc = spec_named local "charge_svc" in
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"ws"
          ~release_id:
            (Sol_cli_release_id.of_content
               { workspace = "ws"; environment = None; workloads = []; contract = [] })
          charge_svc
      with
      | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
      | Error e -> Windtrap.fail ("render_spec: " ^ e)
    in
    check_bool
      "readinessProbe points at /readyz"
      true
      (Sol_cli_string.contains
         ~needle:"readinessProbe:\n          httpGet:\n            path: /readyz"
         rendered);
    check_bool
      "livenessProbe stays on /healthz"
      true
      (Sol_cli_string.contains
         ~needle:"livenessProbe:\n          httpGet:\n            path: /healthz"
         rendered))
;;

let test_undeclared_workloads_still_plan () =
  with_workspace
    [ "sol.yml", "resources:\n  events:\n    type: kafka\n"
    ; "app/comms/notify_worker/Dockerfile", "FROM scratch\n"
    ; "app/comms/notify_worker/sol.toml", "[infra.scale]\nreplicas = 1\n"
    ]
  @@ fun () ->
  let facts =
    Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) |> fail_on_error "workspace model"
  in
  let declared =
    Sol_cli_config.load_declared ~root:(Sys.getcwd ())
    |> Result.map_error Sol_cli_config.error_to_string
    |> fail_on_error "load_declared"
  in
  let plan =
    Sol_cli_up_execution.local_plan
      ~requested_scope:"workspace"
      ~workspace:"ws"
      ~sha:"sha"
      ~facts
      ~declared
      (Sol_cli_workspace_model.services facts)
    |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
    |> fail_on_error "local_plan"
  in
  let worker = spec_named plan "notify_worker" in
  check_string
    "an undeclared language stays unknown"
    "<none>"
    (Option.fold
       ~none:"<none>"
       ~some:Sol_cli_compat.to_string
       worker.Sol_cli_deployment_plan.language);
  check_strings
    "an undeclared resource use yields no consumer group"
    []
    (List.map
       Sol_cli_plan_ids.Consumer_group.to_string
       plan.Sol_cli_deployment_plan.consumer_groups)
;;

(* 2b: local development routes the database credential exactly as the cloud does. A unit
   whose sol.yml declares `uses: [app_db]` reads `POSTGRES_URL` from the *class* Secret the
   renderer names -- produced by the same function from the same target string -- and the
   local deploy writes that Secret. The unit's own Secret is not the source on any target. *)
let test_local_plan_routes_the_database_credential_like_the_cloud () =
  with_workspace workspace (fun () ->
    let local, _ = plans () in
    let charge_svc = spec_named local "charge_svc" in
    check_bool
      "the local plan's consumer carries the stand-in target, so it has a class Secret"
      true
      (charge_svc.Sol_cli_deployment_plan.db_uses_target = Some "ws");
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"ws"
          ~release_id:
            (Sol_cli_release_id.of_content
               { workspace = "ws"; environment = None; workloads = []; contract = [] })
          charge_svc
      with
      | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
      | Error e -> Windtrap.fail ("render_spec: " ^ e)
    in
    let class_secret = Sol_cli_database_setup_render.dml_creds_name "ws" in
    check_bool
      (Printf.sprintf "the pod reads POSTGRES_URL from the class Secret %s" class_secret)
      true
      (Sol_cli_string.contains ~needle:(Printf.sprintf "name: %s" class_secret) rendered))
;;

let%test
    "sol local deploy and sol deploy plan the same workspace (BUG-056): the two plans \
     agree on language, replicas and consumer groups"
  =
  test_up_and_target_plans_agree ()
;;

let%test
    "sol local deploy and sol deploy plan the same workspace (BUG-056): the local plan \
     carries the declared facts"
  =
  test_local_plan_carries_the_declared_facts ()
;;

let%test
    "sol local deploy and sol deploy plan the same workspace (BUG-056): a local plan \
     renders /readyz for a declared OCaml service"
  =
  test_local_plan_renders_readyz ()
;;

let%test
    "sol local deploy and sol deploy plan the same workspace (BUG-056): an undeclared \
     workspace still plans, as unknown"
  =
  test_undeclared_workloads_still_plan ()
;;

let%test "2b: the local plan routes POSTGRES_URL through the class Secret" =
  test_local_plan_routes_the_database_credential_like_the_cloud ()
;;
