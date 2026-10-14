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
    let facts =
      Sol_cli_workspace_model.load ~root:(Sys.getcwd ())
      |> fail_on_error "workspace model"
    in
    let declared =
      Sol_cli_config.load_declared ~root:(Sys.getcwd ())
      |> Result.map_error Sol_cli_config.error_to_string
      |> fail_on_error "load_declared"
    in
    (* The stand-in target is the workspace name; the underscore in a scaffolded workspace's
       name must not reach the Secret name, which is an RFC 1123 subdomain. *)
    let local =
      Sol_cli_up_execution.local_plan
        ~requested_scope:"workspace"
        ~workspace:"ci_smoke"
        ~sha:"sha"
        ~facts
        ~declared
        (Sol_cli_workspace_model.services facts)
      |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
      |> fail_on_error "local_plan"
    in
    let charge_svc = spec_named local "charge_svc" in
    check_bool
      "the local plan's consumer carries the sanitized stand-in target"
      true
      (charge_svc.Sol_cli_deployment_plan.db_uses_target = Some "ci-smoke");
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"ci_smoke"
          ~release_id:
            (Sol_cli_release_id.of_content
               { workspace = "ci_smoke"
               ; environment = None
               ; workloads = []
               ; contract = []
               })
          charge_svc
      with
      | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
      | Error e -> Windtrap.fail ("render_spec: " ^ e)
    in
    let class_secret = Sol_cli_database_setup_render.dml_creds_name "ci-smoke" in
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

(* #1425: planning, `sol secret set` and the delivery reader must agree on which inputs a
   unit carries and who owns each. The case that separates them is a unit that both consumes
   the target's database and declares `POSTGRES_URL`: the plan always knew the binding
   supplies it, but `sol secret set` did not, so it could write a unit Secret the workload
   never reads. *)
let db_consumer_ownership_workspace =
  [ ( "sol.yml"
    , {|project: ws

resources:
  app_db:
    type: postgres

services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db]
    language: ocaml
|}
    )
  ; ( "sol/environments.yml"
    , {|prod:
  targets:
    aws/us-east-1:
      cluster_name: ws-prod
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          AUDIT_KEY:
            authority: external
            store: audit-store
            key: production/audit
|}
    )
  ; "app/payments/charge_svc/Dockerfile", "FROM scratch\n"
  ; ( "app/payments/charge_svc/sol.toml"
    , "[infra.env]\nsecrets = [\"POSTGRES_URL\", \"SOL_API_KEY\", \"AUDIT_KEY\"]\n" )
  ]
;;

let test_input_ownership_is_one_decision () =
  with_workspace db_consumer_ownership_workspace (fun () ->
    let facts =
      Sol_cli_workspace_model.load ~root:(Sys.getcwd ())
      |> fail_on_error "workspace model"
    in
    let declared =
      Sol_cli_config.load_declared ~root:(Sys.getcwd ())
      |> Result.map_error Sol_cli_config.error_to_string
      |> fail_on_error "load_declared"
    in
    let config =
      Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1"
      |> Result.map_error Sol_cli_config.error_to_string
      |> fail_on_error "load_for_target"
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
    let charge = spec_named plan "charge_svc" in
    check_bool
      "the plan routes POSTGRES_URL from the target's database"
      true
      (charge.Sol_cli_deployment_plan.db_uses_target = Some "ws");
    (* The two callers must reach the one decision with the *same* declared set. The plan
       gate reads [spec.secrets], which is built from the unit's `sol.toml`; `sol secret set`
       reads that same `sol.toml` through the workspace model. Assert the plan's set is the
       set the test hands to both callers. *)
    let declared_keys = [ "POSTGRES_URL"; "SOL_API_KEY"; "AUDIT_KEY" ] in
    check_strings
      "the plan's declared keys are the unit's declared keys"
      (List.sort String.compare declared_keys)
      (List.sort String.compare (List.map fst charge.secrets));
    (* The one ownership decision, on a declared set that exercises every owner. *)
    let owners =
      Sol_cli_deploy_selection.unit_input_owners
        ~config
        ~unit_address:"payments/charge_svc"
        ~transport:Sol_cli_manifest.Plaintext
        ~db_uses_target:true
        ~declared:declared_keys
    in
    let owns expected key =
      check_bool
        (Printf.sprintf "the shared decision owns %s as %s" key expected)
        true
        (match List.assoc_opt key owners with
         | Some Sol_cli_deploy_selection.Unit_secret ->
           String.equal expected "the unit's own Secret"
         | Some Sol_cli_deploy_selection.Target_database ->
           String.equal expected "the target's database input"
         | Some (Sol_cli_deploy_selection.External_secret _) ->
           String.equal expected "an external authority"
         | Some Sol_cli_deploy_selection.Unmapped -> String.equal expected "unmapped"
         | None -> false)
    in
    owns "the target's database input" "POSTGRES_URL";
    owns "the unit's own Secret" "SOL_API_KEY";
    owns "an external authority" "AUDIT_KEY";
    (* The plan gate and `sol secret set` must project identical owners from that one
       decision. Compare the two maps as text so a divergence names the key and the source. *)
    let owner_text = function
      | Sol_cli_deploy_selection.Unit_secret -> Some "sol"
      | Sol_cli_deploy_selection.External_secret { store; key } ->
        Some (Printf.sprintf "external:%s:%s" store key)
      | Sol_cli_deploy_selection.Target_database | Sol_cli_deploy_selection.Unmapped ->
        None
    in
    let authority_text = function
      | Sol_cli_config.Sol_managed -> "sol"
      | Sol_cli_config.External { store; key } ->
        Printf.sprintf "external:%s:%s" store key
    in
    let from_owners =
      owners
      |> List.filter_map (fun (key, owner) ->
        Option.map (fun text -> Printf.sprintf "%s=%s" key text) (owner_text owner))
      |> List.sort String.compare
    in
    let authorities =
      Sol_cli_deploy_selection.secret_authorities_for_plan ~config plan
      |> fail_on_error "secret_authorities_for_plan"
    in
    let from_plan =
      authorities
      |> List.filter_map (fun (unit, key, authority) ->
        if String.equal unit "payments/charge_svc"
        then Some (Printf.sprintf "%s=%s" key (authority_text authority))
        else None)
      |> List.sort String.compare
    in
    check_strings
      "the plan gate and sol secret set resolve the same ownership map"
      from_owners
      from_plan;
    (* `sol secret set` is the caller the old split got wrong: it must refuse the write
       whose value the workload would read from the class Secret instead, while still
       accepting a key the unit owns. *)
    (match
       Sol_cli_deploy_selection.check_unit_secret_write
         ~config
         ~unit_address:"payments/charge_svc"
         ~unit_name:"charge_svc"
         ~declared:declared_keys
         ~key:"POSTGRES_URL"
     with
     | Ok () ->
       Windtrap.fail "sol secret set accepted a POSTGRES_URL the binding supplies"
     | Error message ->
       check_bool
         "the refusal names the class Secret delivery"
         true
         (Sol_cli_string.contains ~needle:"DML class Secret" message));
    match
      Sol_cli_deploy_selection.check_unit_secret_write
        ~config
        ~unit_address:"payments/charge_svc"
        ~unit_name:"charge_svc"
        ~declared:declared_keys
        ~key:"SOL_API_KEY"
    with
    | Ok () -> ()
    | Error message ->
      Windtrap.fail ("sol secret set refused a unit-owned key: " ^ message))
;;

let%test "1425: one input-ownership decision drives the plan gate and secret set" =
  test_input_ownership_is_one_decision ()
;;

(* #1425: the combinations delivery cannot represent, and an external binding that cannot
   deliver every class, are refused while planning — before any write or apply. *)
let charge_workspace ~resources ~target_extra =
  [ ( "sol.yml"
    , Printf.sprintf
        {|project: ws

resources:
%s
services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db]
    language: ocaml
|}
        resources )
  ; ( "sol/environments.yml"
    , Printf.sprintf
        {|prod:
  targets:
    aws/us-east-1:
      cluster_name: ws-prod
%s|}
        target_extra )
  ; "app/payments/charge_svc/Dockerfile", "FROM scratch\n"
  ; "app/payments/charge_svc/sol.toml", ""
  ]
;;

let plan_for ?(emit_to = None) files =
  with_workspace files (fun () ->
    let facts =
      Sol_cli_workspace_model.load ~root:(Sys.getcwd ())
      |> fail_on_error "workspace model"
    in
    let services = Sol_cli_workspace_model.services facts in
    let config =
      Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1"
      |> Result.map_error Sol_cli_config.error_to_string
      |> fail_on_error "load_for_target"
    in
    Sol_cli_deploy_selection.plan
      { Sol_cli_deploy_selection.Planning_input.workspace = "ws"
      ; registry = "registry.example"
      ; sha = "sha-under-test"
      ; emit_to
      ; config
      ; facts
      ; inventory = services
      ; requested_scope = "target"
      ; image_refs = []
      ; services
      })
;;

let plan_refuses ?emit_to what files =
  match plan_for ?emit_to files with
  | Ok _ -> Windtrap.fail (what ^ ": expected the plan to be refused")
  | Error (Sol_cli_deploy_selection.Refused message) -> message
  | Error (Sol_cli_deploy_selection.Preflight _) ->
    Windtrap.fail (what ^ ": expected a refusal, not a preflight finding")
;;

let test_two_external_databases_are_refused_at_plan () =
  let message =
    plan_refuses
      "two external databases"
      (charge_workspace
         ~resources:"  app_db:\n    type: postgres\n  analytics_db:\n    type: postgres\n"
         ~target_extra:
           "      resources:\n\
           \        app_db:\n\
           \          binding:\n\
           \            ownership: external\n\
           \            store: vault\n\
           \            credentials:\n\
           \              ddl: secret/app-db-migrator\n\
           \              dml: secret/app-db-app\n\
           \        analytics_db:\n\
           \          binding:\n\
           \            ownership: external\n\
           \            store: vault\n\
           \            credentials:\n\
           \              ddl: secret/analytics-migrator\n\
           \              dml: secret/analytics-app\n")
  in
  check_bool
    "the refusal names app_db"
    true
    (Sol_cli_string.contains ~needle:"app_db" message);
  check_bool
    "the refusal names analytics_db"
    true
    (Sol_cli_string.contains ~needle:"analytics_db" message)
;;

let test_missing_external_class_is_refused_at_plan () =
  let message =
    plan_refuses
      "an external binding with no per-class paths"
      (charge_workspace
         ~resources:"  app_db:\n    type: postgres\n"
         ~target_extra:
           "      resources:\n\
           \        app_db:\n\
           \          binding:\n\
           \            ownership: external\n\
           \            store: vault\n\
           \            keys:\n\
           \              POSTGRES_URL: secret/app-db\n")
  in
  check_bool
    "the refusal names the credential class"
    true
    (Sol_cli_string.contains ~needle:"credential class" message)
;;

let%test "1425: two external databases are refused at plan" =
  test_two_external_databases_are_refused_at_plan ()
;;

let%test "1425: an external binding missing a credential class is refused at plan" =
  test_missing_external_class_is_refused_at_plan ()
;;

(* #1423: the ownership matrix is established by the binding, not by the profile. A database
   Sol provisions cannot be emitted to GitOps (the setup step that writes its class Secrets
   runs only in a direct apply), and an externally bound database now plans and carries the
   delivery the emit renders. *)
let test_sol_provisioned_gitops_is_refused_at_plan () =
  let message =
    plan_refuses
      ~emit_to:(Some "/tmp/gitops")
      "a Sol-provisioned database emitted to GitOps"
      (charge_workspace ~resources:"  app_db:\n    type: postgres\n" ~target_extra:"")
  in
  check_bool
    "the refusal names the database"
    true
    (Sol_cli_string.contains ~needle:"app_db" message);
  check_bool
    "the refusal names the emit path"
    true
    (Sol_cli_string.contains ~needle:"GitOps" message)
;;

let test_external_database_plans_for_gitops_with_a_delivery () =
  match
    plan_for
      ~emit_to:(Some "/tmp/gitops")
      (charge_workspace
         ~resources:"  app_db:\n    type: postgres\n"
         ~target_extra:
           "      resources:\n\
           \        app_db:\n\
           \          binding:\n\
           \            ownership: external\n\
           \            store: vault\n\
           \            credentials:\n\
           \              ddl: secret/app-db-migrator\n\
           \              dml: secret/app-db-app\n")
  with
  | Error (Sol_cli_deploy_selection.Refused message) ->
    Windtrap.fail (Printf.sprintf "an externally bound database must emit: %s" message)
  | Error (Sol_cli_deploy_selection.Preflight _) ->
    Windtrap.fail "an externally bound database must not raise a preflight finding"
  | Ok plan ->
    (match plan.Sol_cli_deployment_plan.resource_delivery with
     | None -> Windtrap.fail "an external database must carry a delivery to emit"
     | Some delivery ->
       Windtrap.equal
         Windtrap.string
         ~msg:"the delivery names the target"
         "prod-aws-us-east-1"
         delivery.target;
       Windtrap.equal Windtrap.string ~msg:"and the resource" "app_db" delivery.resource;
       Windtrap.equal
         Windtrap.int
         ~msg:"with both class paths"
         2
         (List.length delivery.credentials))
;;

let%test "1423: a Sol-provisioned database emitted to GitOps is refused at plan" =
  test_sol_provisioned_gitops_is_refused_at_plan ()
;;

let%test "1423: an external database plans for GitOps with its delivery" =
  test_external_database_plans_for_gitops_with_a_delivery ()
;;
