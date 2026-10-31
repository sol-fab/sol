let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> namespace
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Windtrap.fail message
;;

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Windtrap.fail message
;;

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "registry.example.com/myapp/charge-svc:abc123"
  ; config = []
  ; secrets = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; schedule_timezone = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  ; uses = []
  ; database = Sol_cli_resource_binding.No_postgres_use
  }
;;

let worker_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "comms"
  ; source_name = "notify_worker"
  ; k8s_name = k8s_name "notify-worker"
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = "app/comms/notify_worker"
  ; image = "registry.example.com/myapp/notify-worker:abc123"
  ; config = []
  ; secrets = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; schedule_timezone = None
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  ; uses = []
  ; database = Sol_cli_resource_binding.No_postgres_use
  }
;;

let env_config : Sol_cli_deployment_plan.env_config =
  { name = "myapp"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "registry.example.com"
  ; image_tag = "abc123"
  ; env = None
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let make_plan services =
  { Sol_cli_deployment_plan.workspace = "myapp"
  ; environment = env_config
  ; services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id = release_id_of_test
  ; requested_scope = "workspace"
  ; platform_shape = Sol_cli_profile.Local
  ; profile = None
  ; contract = []
  ; contract_changes = []
  ; database = Sol_cli_resource_binding.No_postgres
  ; kafka = Sol_cli_resource_binding.No_kafka
  ; resource_delivery = None
  }
;;

let run_ok ~mode plan =
  match
    Sol_cli_executor.run_plan
      (Sol_cli_execution.context
         ~cluster:Sol_cli_kube_destination.local_context
         ~workspace:plan.Sol_cli_deployment_plan.workspace
         ())
      ~mode
      plan
  with
  | Ok rs -> rs
  | Error e -> Windtrap.fail ("run_plan unexpectedly failed: " ^ e)
;;

let test_dry_run_result_count () =
  let plan = make_plan [ svc_spec; worker_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  Windtrap.equal Windtrap.int ~msg:"result count" 2 (List.length results)
;;

let test_dry_run_result_fields () =
  let plan = make_plan [ svc_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Windtrap.equal Windtrap.string ~msg:"namespace" "myapp-payments" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"name" "charge-svc" r.name
;;

let test_dry_run_worker () =
  let plan = make_plan [ worker_spec ] in
  let results = run_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Windtrap.equal Windtrap.string ~msg:"worker namespace" "myapp-comms" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"worker name" "notify-worker" r.name
;;

let test_emit_to_writes_file () =
  let dir = Filename.temp_file "sol-cs-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ svc_spec ] in
  let _results = run_ok ~mode:(Sol_cli_executor.Emit_to dir) plan in
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  Windtrap.equal Windtrap.bool ~msg:"emit_to file created" true exists
;;

let test_emit_to_result_fields () =
  let dir = Filename.temp_file "sol-cs-emit-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan = make_plan [ worker_spec ] in
  let results = run_ok ~mode:(Sol_cli_executor.Emit_to dir) plan in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  Windtrap.equal Windtrap.int ~msg:"result count" 1 (List.length results);
  let r = List.hd results in
  Windtrap.equal Windtrap.string ~msg:"namespace" "myapp-comms" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"name" "notify-worker" r.name
;;

(* #1423: the plan's resource delivery is written by the emit as its own target-scoped file,
   beside the per-workload bundles, so a fresh external-database GitOps deployment carries
   the class Secrets its units read. A plan with no delivery writes no such file. *)
let resource_delivery : Sol_cli_deployment_plan.resource_delivery =
  { target = "payments"
  ; resource = "app_db"
  ; store = "vault-production"
  ; credentials =
      { Sol_cli_resource_binding.ddl = "secret/production/app-db-migrator"
      ; dml = "secret/production/app-db-app"
      }
  ; migration_namespace = "myapp-payments"
  ; dml_namespaces = [ "myapp-comms" ]
  }
;;

let test_emit_to_writes_resource_prerequisites () =
  let dir = Filename.temp_file "sol-cs-prereq-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let plan =
    { (make_plan [ worker_spec ]) with
      Sol_cli_deployment_plan.resource_delivery = Some resource_delivery
    }
  in
  let _results = run_ok ~mode:(Sol_cli_executor.Emit_to dir) plan in
  let name =
    Sol_cli_database_setup_render.resource_prerequisites_file_name ~target:"payments"
  in
  let path = Filename.concat dir name in
  let present msg needle =
    Windtrap.equal
      Windtrap.bool
      ~msg
      true
      (Sys.file_exists path
       && Sol_cli_string.contains
            ~needle
            (In_channel.with_open_bin path In_channel.input_all))
  in
  present
    "the file names the reader's DDL class"
    (Sol_cli_database_setup_render.ddl_creds_name "payments");
  present
    "and the reader's DML class"
    (Sol_cli_database_setup_render.dml_creds_name "payments");
  present "the DDL lands where migrations run" "namespace: myapp-payments";
  present "the DML lands where it is consumed" "namespace: myapp-comms";
  present "the store is the delivery's" "name: vault-production";
  present
    "the key is the reader's"
    ("secretKey: " ^ Sol_cli_database_setup_render.postgres_url_key);
  let empty = Filename.temp_file "sol-cs-prereq-none-" "" in
  Sys.remove empty;
  Unix.mkdir empty 0o755;
  let _ = run_ok ~mode:(Sol_cli_executor.Emit_to empty) (make_plan [ worker_spec ]) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a plan with no delivery writes no prerequisite file"
    false
    (Sys.file_exists (Filename.concat empty name));
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  try Unix.rmdir empty with
  | _ -> ()
;;

let%test "dry_run: result count" = test_dry_run_result_count ()
let%test "dry_run: result fields (svc)" = test_dry_run_result_fields ()
let%test "dry_run: result fields (worker)" = test_dry_run_worker ()
let%test "emit_to: file written" = test_emit_to_writes_file ()
let%test "emit_to: result fields" = test_emit_to_result_fields ()

let%test "emit_to: resource prerequisites written" =
  test_emit_to_writes_resource_prerequisites ()
;;
