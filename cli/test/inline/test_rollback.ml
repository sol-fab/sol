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

let hostname s =
  match Sol_cli_toml.hostname_of_string s with
  | Ok host -> host
  | Error message -> Windtrap.fail message
;;

let ingress_path s =
  match Sol_cli_toml.ingress_path_of_string s with
  | Ok path -> path
  | Error message -> Windtrap.fail message
;;

let matches_regex re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let gate_env : Sol_cli_deployment_plan.env_config =
  { name = "production"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "123.dkr.ecr.us-east-1.amazonaws.com"
  ; image_tag = "abc1234"
  ; env = Some "prod"
  ; region = Some "us-east-1"
  ; base_domain = Some "example.com"
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let ledger_namespace = namespace ~workspace:"myapp" ~domain:"payments"
let ledger_name = k8s_name "ledger-svc"
let billing_namespace = namespace ~workspace:"myapp" ~domain:"payments"
let billing_name = k8s_name "billing-svc"

let billing_call : Sol_cli_deployment_plan.service_call =
  { env_var = Sol_cli_kubernetes_name.call_env_var "ledger_svc"
  ; unit_id = "payments/" ^ Sol_cli_kubernetes_name.k8s_name_to_string ledger_name
  ; url =
      Sol_cli_kubernetes_name.service_url
        ~namespace:ledger_namespace
        ~k8s_name:ledger_name
  ; target_domain = "payments"
  ; target_name = ledger_name
  ; target_namespace = ledger_namespace
  }
;;

let billing_as_caller : Sol_cli_deployment_plan.service_call =
  { env_var = Sol_cli_kubernetes_name.call_env_var "billing_svc"
  ; unit_id = "payments/" ^ Sol_cli_kubernetes_name.k8s_name_to_string billing_name
  ; url =
      Sol_cli_kubernetes_name.service_url
        ~namespace:billing_namespace
        ~k8s_name:billing_name
  ; target_domain = "payments"
  ; target_name = billing_name
  ; target_namespace = billing_namespace
  }
;;

let ledger_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "ledger_svc"
  ; k8s_name = ledger_name
  ; namespace = ledger_namespace
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = ""
  ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myapp/ledger-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DB_PASSWORD", "" ]
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 2
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "250m"
  ; memory = memory "256Mi"
  ; rollout_strategy = Some Sol_cli_toml.Recreate
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = [ billing_as_caller ]
  ; extra_labels = [ "team", "payments" ]
  ; progressive_delivery = None
  ; db_ca_target = None
  }
;;

let billing_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "billing_svc"
  ; k8s_name = billing_name
  ; namespace = billing_namespace
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = ""
  ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myapp/billing-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "STRIPE_KEY", "" ]
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes =
      [ { Sol_cli_toml.name = "cache"
        ; mount_path = "/var/cache"
        ; size = "1Gi"
        ; access_mode = Sol_cli_toml.ReadWriteOnce
        }
      ; { Sol_cli_toml.name = "shared"
        ; mount_path = "/var/shared"
        ; size = "5Gi"
        ; access_mode = Sol_cli_toml.ReadOnlyMany
        }
      ]
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu = cpu "500m"
  ; memory = memory "512Mi"
  ; rollout_strategy = None
  ; ingress_host = Some (hostname "billing.example.com")
  ; ingress_path = Some (ingress_path "/api")
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = [ billing_call ]
  ; called_by = []
  ; extra_labels = [ "team", "payments" ]
  ; progressive_delivery =
      Some
        (Sol_cli_toml.Canary
           { steps =
               [ Sol_cli_toml.Weight 20
               ; Sol_cli_toml.Pause (Some 60)
               ; Sol_cli_toml.Weight 100
               ]
           })
  ; db_ca_target = None
  }
;;

let gate_services = [ billing_spec; ledger_spec ]

let gate_release_id =
  Sol_cli_release_id.of_content
    { workspace = "myapp"
    ; environment = gate_env.env
    ; workloads = List.map Sol_cli_deployment_plan.release_workload_of_spec gate_services
    ; contract = []
    }
;;

let gate_plan : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; release_id = gate_release_id
  ; environment = gate_env
  ; services = gate_services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; requested_scope = "workspace"
  ; platform_shape = Sol_cli_profile.Local
  ; profile = None
  ; contract = []
  ; contract_changes = []
  }
;;

let gate_release = Sol_cli_release.of_plan ~apply_mode:Sol_cli_release.Direct gate_plan

let reconstruct_ok () =
  match Sol_cli_rollback.service_specs_of_release gate_release with
  | Ok specs -> specs
  | Error msg -> Windtrap.failf "expected reconstruction to succeed: %s" msg
;;

(* The `release` label a workload's objects carry: its own immutable identity, derived
   from its effective spec, not the recorded deploy id
   ([Sol_cli_deployment_plan.workload_release_id]). *)
let workload_identity ~(release : Sol_cli_release.t) spec =
  Sol_cli_release_id.to_string
    (Sol_cli_deployment_plan.workload_release_id
       ~workspace:release.Sol_cli_release.workspace
       ~environment:release.Sol_cli_release.environment
       spec)
;;

let call_eq
      (c1 : Sol_cli_deployment_plan.service_call)
      (c2 : Sol_cli_deployment_plan.service_call)
  =
  c1.env_var = c2.env_var
  && c1.url = c2.url
  && c1.target_domain = c2.target_domain
  && Sol_cli_deployment_plan.k8s_name_to_string c1.target_name
     = Sol_cli_deployment_plan.k8s_name_to_string c2.target_name
  && Sol_cli_deployment_plan.namespace_to_string c1.target_namespace
     = Sol_cli_deployment_plan.namespace_to_string c2.target_namespace
;;

let calls_eq a b = List.length a = List.length b && List.for_all2 call_eq a b

let assert_spec_equal ~label (expected : Sol_cli_deployment_plan.service_spec) got =
  let k8s = Sol_cli_deployment_plan.k8s_name_to_string in
  let ns = Sol_cli_deployment_plan.namespace_to_string in
  let field name = Printf.sprintf "%s: %s" label name in
  Windtrap.equal
    Windtrap.string
    ~msg:(field "domain")
    expected.domain
    got.Sol_cli_deployment_plan.domain;
  Windtrap.equal
    Windtrap.string
    ~msg:(field "source_name")
    expected.source_name
    got.source_name;
  Windtrap.equal
    Windtrap.string
    ~msg:(field "k8s_name")
    (k8s expected.k8s_name)
    (k8s got.k8s_name);
  Windtrap.equal
    Windtrap.string
    ~msg:(field "namespace")
    (ns expected.namespace)
    (ns got.namespace);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "primitive")
    true
    (expected.primitive = got.primitive);
  Windtrap.equal Windtrap.string ~msg:(field "image") expected.image got.image;
  Windtrap.equal Windtrap.bool ~msg:(field "config") true (expected.config = got.config);
  Windtrap.equal Windtrap.bool ~msg:(field "secrets") true (expected.secrets = got.secrets);
  Windtrap.equal Windtrap.bool ~msg:(field "volumes") true (expected.volumes = got.volumes);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "schedule")
    true
    (expected.schedule = got.schedule);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "scheduled_concurrency")
    true
    (expected.scheduled_concurrency = got.scheduled_concurrency);
  Windtrap.equal
    Windtrap.int
    ~msg:(field "backoff_limit")
    expected.backoff_limit
    got.backoff_limit;
  Windtrap.equal Windtrap.int ~msg:(field "replicas") expected.replicas got.replicas;
  Windtrap.equal
    Windtrap.string
    ~msg:(field "cpu")
    (Sol_cli_toml.cpu_quantity_to_string expected.cpu)
    (Sol_cli_toml.cpu_quantity_to_string got.cpu);
  Windtrap.equal
    Windtrap.string
    ~msg:(field "memory")
    (Sol_cli_toml.memory_quantity_to_string expected.memory)
    (Sol_cli_toml.memory_quantity_to_string got.memory);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "rollout_strategy")
    true
    (expected.rollout_strategy = got.rollout_strategy);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "ingress_host")
    true
    (Option.map Sol_cli_toml.hostname_to_string expected.ingress_host
     = Option.map Sol_cli_toml.hostname_to_string got.ingress_host);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "ingress_path")
    true
    (Option.map Sol_cli_toml.ingress_path_to_string expected.ingress_path
     = Option.map Sol_cli_toml.ingress_path_to_string got.ingress_path);
  Windtrap.equal
    Windtrap.string
    ~msg:(field "cluster_issuer")
    expected.cluster_issuer
    got.cluster_issuer;
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "calls")
    true
    (calls_eq expected.calls got.calls);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "called_by")
    true
    (calls_eq expected.called_by got.called_by);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "extra_labels")
    true
    (expected.extra_labels = got.extra_labels);
  Windtrap.equal
    Windtrap.bool
    ~msg:(field "progressive_delivery")
    true
    (expected.progressive_delivery = got.progressive_delivery)
;;

let test_gate_a_decode_correctness () =
  match reconstruct_ok () with
  | [ (got_billing, billing_by); (got_ledger, ledger_by) ] ->
    assert_spec_equal ~label:"billing_svc" billing_spec got_billing;
    assert_spec_equal ~label:"ledger_svc" ledger_spec got_ledger;
    Windtrap.equal
      Windtrap.string
      ~msg:"billing identity"
      (workload_identity ~release:gate_release billing_spec)
      billing_by;
    Windtrap.equal
      Windtrap.string
      ~msg:"ledger identity"
      (workload_identity ~release:gate_release ledger_spec)
      ledger_by
  | specs -> Windtrap.failf "expected 2 reconstructed specs, got %d" (List.length specs)
;;

let test_gate_b_identity_correctness () =
  let specs = reconstruct_ok () in
  let reconstructed_id =
    Sol_cli_release.derived_release_id gate_release |> Sol_cli_release_id.to_string
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"reconstructed release id matches the record"
    gate_release.release_id
    reconstructed_id;
  Windtrap.equal
    Windtrap.int
    ~msg:"every reconstructed workload carries observable provenance"
    (List.length specs)
    (List.length gate_release.workloads)
;;

let render_by_identity ~release_id apply_specs =
  List.map
    (fun ((s : Sol_cli_deployment_plan.service_spec), _) ->
       let key =
         ( Sol_cli_deployment_plan.namespace_to_string s.namespace
         , Sol_cli_deployment_plan.k8s_name_to_string s.k8s_name )
       in
       let rendered =
         match
           Sol_cli_deployment_render.render_spec
             ~workspace:gate_plan.workspace
             ?env:gate_plan.environment.env
             ~release_id
             s
         with
         | Ok bundle ->
           bundle.namespace_yaml ^ bundle.prerequisites_yaml ^ bundle.workload_yaml
         | Error msg -> Windtrap.fail msg
       in
       key, rendered)
    apply_specs
  |> List.sort (fun (a, _) (b, _) -> compare a b)
;;

let test_gate_c_render_correctness () =
  let specs = reconstruct_ok () in
  let release_id =
    match Sol_cli_release_id.of_string gate_release.release_id with
    | Ok id -> id
    | Error msg -> Windtrap.fail msg
  in
  let original =
    render_by_identity
      ~release_id
      (List.map (fun s -> s, gate_release.release_id) gate_plan.services)
  in
  let reconstructed = render_by_identity ~release_id specs in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"same object identity set"
    (List.map fst original)
    (List.map fst reconstructed);
  List.iter2
    (fun (key, original_bytes) (_, reconstructed_bytes) ->
       Windtrap.equal
         Windtrap.string
         ~msg:(Printf.sprintf "%s/%s canonical bytes" (fst key) (snd key))
         original_bytes
         reconstructed_bytes)
    original
    reconstructed
;;

let bad_workload_release update : Sol_cli_release.t =
  let record_id = "r-0000000000000000" in
  { release_id = record_id
  ; workspace = "myapp"
  ; environment = Some "prod"
  ; workloads =
      [ Sol_cli_release.applied_by
          record_id
          (update (Sol_cli_deployment_plan.release_workload_of_spec ledger_spec))
      ]
  ; migrations = []
  ; contract = []
  ; apply_mode = Sol_cli_release.Direct
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let test_gate_failure_unknown_rollout_encoding () =
  let release = bad_workload_release (fun w -> { w with rollout = "canary:bogus" }) in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Windtrap.fail "expected reconstruction to fail on an unknown rollout encoding"
  | Error msg ->
    assert (matches_regex (Str.regexp "r-0000000000000000") msg);
    assert (matches_regex (Str.regexp "ledger_svc") msg);
    assert (matches_regex (Str.regexp (Str.quote "canary:bogus")) msg)
;;

let test_gate_failure_invalid_cpu () =
  let release = bad_workload_release (fun w -> { w with cpu = "not-a-cpu-quantity" }) in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Windtrap.fail "expected reconstruction to fail on an invalid cpu quantity"
  | Error msg ->
    assert (matches_regex (Str.regexp "ledger_svc") msg);
    assert (matches_regex (Str.regexp (Str.quote "not-a-cpu-quantity")) msg)
;;

let test_gate_failure_invalid_availability () =
  let release = bad_workload_release (fun w -> { w with availability = "sometimes" }) in
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok _ -> Windtrap.fail "expected reconstruction to fail on an invalid availability"
  | Error msg ->
    assert (matches_regex (Str.regexp "ledger_svc") msg);
    assert (matches_regex (Str.regexp (Str.quote "sometimes")) msg)
;;

let with_migrations_dir files f =
  let dir = Filename.temp_file "sol-migrations-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, _) -> Sys.remove (Filename.concat dir name)) files;
      Unix.rmdir dir)
    (fun () ->
       files
       |> List.iter (fun (name, content) ->
         let oc = open_out (Filename.concat dir name) in
         output_string oc content;
         close_out oc);
       f dir)
;;

let migration_release ~migrations : Sol_cli_release.t =
  { release_id = "r-1111111111111111"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations
  ; contract = []
  ; apply_mode = Sol_cli_release.Direct
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let expand_sql = "-- sol:disposition expand\nALTER TABLE t ADD COLUMN c INT;"
let contract_sql = "-- sol:disposition contract\nALTER TABLE t DROP COLUMN c;"
let undeclared_sql = "ALTER TABLE t ADD COLUMN c INT;"

let test_migration_boundary_no_new_migrations_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Ok [ 1 ])
       with
       | Ok () -> ()
       | Error e -> Windtrap.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_new_expand_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_add_col.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_add_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> ()
       | Error e -> Windtrap.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_new_contract_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_drop_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> Windtrap.fail "expected a contracting migration to block the rollback"
       | Error (Sol_cli_rollback.Contracting_migration { release_id; migration }) ->
         Windtrap.equal Windtrap.string ~msg:"release_id" "r-1111111111111111" release_id;
         Windtrap.equal Windtrap.string ~msg:"migration" "0002_drop_col.sql" migration
       | Error e ->
         Windtrap.failf
           "expected Contracting_migration, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_undeclared_new_migration_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_mystery.sql", undeclared_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_mystery.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () ->
         Windtrap.fail "expected an undeclared disposition to block the rollback closed"
       | Error (Sol_cli_rollback.Undeclared_disposition { release_id; migration; reason })
         ->
         Windtrap.equal Windtrap.string ~msg:"release_id" "r-1111111111111111" release_id;
         Windtrap.equal Windtrap.string ~msg:"migration" "0002_mystery.sql" migration;
         assert (matches_regex (Str.regexp "sol:disposition") reason)
       | Error e ->
         Windtrap.failf
           "expected Undeclared_disposition, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_ignores_already_recorded_contract () =
  with_migrations_dir
    [ "0001_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_drop_col.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_drop_col.sql" ]
           ~applied:(fun () -> Ok [ 1 ])
       with
       | Ok () -> ()
       | Error e -> Windtrap.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_beyond_release_absent_locally_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () ->
         Windtrap.fail
           "expected a migration applied to the target but absent from this checkout to \
            block the rollback"
       | Error (Sol_cli_rollback.Applied_migration_absent { release_id; version }) ->
         Windtrap.equal Windtrap.string ~msg:"release_id" "r-1111111111111111" release_id;
         Windtrap.equal Windtrap.int ~msg:"version" 2 version
       | Error e ->
         Windtrap.failf
           "expected Applied_migration_absent, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_expansion_beyond_release_passes () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_add_col.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_add_col.sql" ]
           ~applied:(fun () -> Ok [ 1; 2 ])
       with
       | Ok () -> ()
       | Error e -> Windtrap.fail (Sol_cli_rollback.migration_check_error_to_string e))
;;

let test_migration_boundary_applied_state_unavailable_blocks () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql ]
    (fun migrations_dir ->
       let release = migration_release ~migrations:[ "0001_init.sql" ] in
       match
         Sol_cli_rollback.check_migration_boundary
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql" ]
           ~applied:(fun () -> Error "migration-status Job cannot start")
       with
       | Ok () ->
         Windtrap.fail "expected an unreadable applied state to block the rollback"
       | Error (Sol_cli_rollback.Applied_state_unavailable { release_id; reason }) ->
         Windtrap.equal Windtrap.string ~msg:"release_id" "r-1111111111111111" release_id;
         assert (matches_regex (Str.regexp "migration-status Job cannot start") reason)
       | Error e ->
         Windtrap.failf
           "expected Applied_state_unavailable, got: %s"
           (Sol_cli_rollback.migration_check_error_to_string e))
;;

let progressive_canary = Some (Sol_cli_toml.Canary { steps = [] })
let progressive_blue_green = Some Sol_cli_toml.Blue_green

let live_kind_cases =
  [ ( "svc, no progressive delivery"
    , Sol_cli_deployment_plan.Svc
    , None
    , Sol_cli_rollback.Live_deployment )
  ; ( "svc, canary"
    , Sol_cli_deployment_plan.Svc
    , progressive_canary
    , Sol_cli_rollback.Live_rollout )
  ; ( "svc, blue_green"
    , Sol_cli_deployment_plan.Svc
    , progressive_blue_green
    , Sol_cli_rollback.Live_rollout )
  ; ( "worker, no progressive delivery"
    , Sol_cli_deployment_plan.Worker
    , None
    , Sol_cli_rollback.Live_deployment )
  ; ( "worker, canary"
    , Sol_cli_deployment_plan.Worker
    , progressive_canary
    , Sol_cli_rollback.Live_rollout )
  ; ( "fn, no progressive delivery"
    , Sol_cli_deployment_plan.Fn
    , None
    , Sol_cli_rollback.Live_cronjob )
  ; ( "fn, canary (ignored)"
    , Sol_cli_deployment_plan.Fn
    , progressive_canary
    , Sol_cli_rollback.Live_cronjob )
  ]
;;

let test_live_kind_of_service_table () =
  live_kind_cases
  |> List.iter (fun (label, primitive, progressive_delivery, expected) ->
    let spec = { ledger_spec with primitive; progressive_delivery } in
    let got = Sol_cli_rollback.live_kind_of_service spec in
    Windtrap.equal Windtrap.bool ~msg:label true (got = expected);
    (* A workload's ownership identity is (kind, namespace, name), so the kind a
       live observation uses must be the same [resource] the plan projects. *)
    Windtrap.equal
      Windtrap.string
      ~msg:(label ^ ": resource agrees with the plan projection")
      (Sol_cli_deployment_plan.resource_of_spec spec)
      (Sol_cli_rollback.kind_resource got))
;;

let live_kind_label = function
  | Sol_cli_rollback.Live_deployment -> "deployment"
  | Sol_cli_rollback.Live_rollout -> "rollout"
  | Sol_cli_rollback.Live_cronjob -> "cronjob"
;;

let test_live_resource_and_jsonpath_table () =
  List.iter
    (fun (kind, expected_resource, expected_jsonpath) ->
       let resource, jsonpath = Sol_cli_rollback.live_resource_and_jsonpath kind in
       Windtrap.equal
         Windtrap.string
         ~msg:(live_kind_label kind ^ " resource")
         expected_resource
         resource;
       Windtrap.equal
         Windtrap.string
         ~msg:(live_kind_label kind ^ " jsonpath")
         expected_jsonpath
         jsonpath)
    [ ( Sol_cli_rollback.Live_deployment
      , "deployment"
      , "{.spec.template.metadata.labels.release}" )
    ; Sol_cli_rollback.Live_rollout, "rollout", "{.spec.template.metadata.labels.release}"
    ; ( Sol_cli_rollback.Live_cronjob
      , "cronjob"
      , "{.spec.jobTemplate.spec.template.metadata.labels.release}" )
    ]
;;

let verify_release : Sol_cli_release.t =
  { release_id = "r-2222222222222222"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; contract = []
  ; apply_mode = Sol_cli_release.Direct
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let test_check_apply_mode_allows_direct () =
  Sol_cli_rollback.check_apply_mode ~release:verify_release
  |> Result.iter_error (fun e ->
    Windtrap.fail (Sol_cli_rollback.apply_mode_check_error_to_string e))
;;

let test_check_apply_mode_refuses_gitops () =
  let release = { verify_release with apply_mode = Sol_cli_release.Gitops } in
  match Sol_cli_rollback.check_apply_mode ~release with
  | Ok () -> Windtrap.fail "expected a GitOps-owned release to be refused"
  | Error e ->
    let msg = Sol_cli_rollback.apply_mode_check_error_to_string e in
    assert (matches_regex (Str.regexp "GitOps") msg);
    assert (matches_regex (Str.regexp release.release_id) msg)
;;

let id kind namespace name : Sol_cli_rollback.workload_identity =
  { kind; namespace; name }
;;

let expected_specs = [ ledger_spec; billing_spec ]

let expected_applied =
  List.map (fun spec -> spec, verify_release.release_id) expected_specs
;;

let ledger_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "ledger-svc"
let billing_id = id Sol_cli_rollback.Live_rollout "myapp-payments" "billing-svc"

let test_verify_workloads_ok_when_set_matches () =
  let live =
    [ ledger_id, verify_release.release_id; billing_id, verify_release.release_id ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Windtrap.equal
    Windtrap.bool
    ~msg:"workload set matches"
    true
    (Sol_cli_rollback.workload_report_ok report)
;;

let test_verify_workloads_reports_unexpected () =
  let stale_id = id Sol_cli_rollback.Live_deployment "myapp-payments" "fraud-svc" in
  let live =
    [ ledger_id, verify_release.release_id
    ; billing_id, verify_release.release_id
    ; stale_id, "r-9999999999999999"
    ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ok"
    false
    (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "unexpected workload") msg);
  assert (matches_regex (Str.regexp "fraud-svc") msg)
;;

let test_verify_workloads_reports_missing () =
  let live = [ billing_id, verify_release.release_id ] in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ok"
    false
    (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "workload missing") msg);
  assert (matches_regex (Str.regexp "ledger-svc") msg)
;;

let test_verify_workloads_reports_label_mismatch () =
  let live = [ ledger_id, "r-9999999999999999"; billing_id, verify_release.release_id ] in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ok"
    false
    (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "workload state mismatch") msg);
  assert (matches_regex (Str.regexp "r-9999999999999999") msg)
;;

let test_verify_workloads_distinguishes_kind () =
  let ledger_as_rollout =
    id Sol_cli_rollback.Live_rollout "myapp-payments" "ledger-svc"
  in
  let live =
    [ ledger_as_rollout, verify_release.release_id
    ; billing_id, verify_release.release_id
    ]
  in
  let report = Sol_cli_rollback.verify_workloads ~expected:expected_applied ~live in
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ok"
    false
    (Sol_cli_rollback.workload_report_ok report);
  let msg = Sol_cli_rollback.workload_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "workload missing") msg);
  assert (matches_regex (Str.regexp "unexpected workload") msg)
;;

let fn_spec : Sol_cli_deployment_plan.service_spec =
  { ledger_spec with
    source_name = "invoice_fn"
  ; k8s_name = k8s_name "invoice-fn"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; schedule = Some "0 * * * *"
  ; scheduled_concurrency = Sol_cli_toml.Forbid
  ; backoff_limit = 0
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; rollout_strategy = None
  ; progressive_delivery = None
  }
;;

let fn_release : Sol_cli_release.t =
  { release_id = "r-3333333333333333"
  ; workspace = "myapp"
  ; environment = None
  ; workloads =
      [ Sol_cli_release.applied_by
          "r-3333333333333333"
          (Sol_cli_deployment_plan.release_workload_of_spec fn_spec)
      ]
  ; migrations = []
  ; contract = []
  ; apply_mode = Sol_cli_release.Direct
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let test_fn_reconstructs_and_verifies_as_cronjob () =
  match Sol_cli_rollback.service_specs_of_release fn_release with
  | Error msg -> Windtrap.fail msg
  | Ok [ (got, applied_by) ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"identity"
      (workload_identity ~release:fn_release got)
      applied_by;
    Windtrap.equal
      Windtrap.bool
      ~msg:"primitive is still Fn"
      true
      (got.primitive = Sol_cli_deployment_plan.Fn);
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"schedule preserved"
      fn_spec.schedule
      got.schedule;
    Windtrap.equal
      Windtrap.bool
      ~msg:"scheduled concurrency preserved"
      true
      (got.scheduled_concurrency = Sol_cli_toml.Forbid);
    Windtrap.equal Windtrap.int ~msg:"backoff limit preserved" 0 got.backoff_limit;
    let rendered =
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"myapp"
          ~release_id:
            (match Sol_cli_release_id.of_string fn_release.release_id with
             | Ok id -> id
             | Error msg -> Windtrap.fail msg)
          got
      with
      | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
      | Error msg -> Windtrap.fail msg
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"rendered CronJob keeps concurrencyPolicy: Forbid"
      true
      (matches_regex (Str.regexp_string "concurrencyPolicy: Forbid") rendered);
    Windtrap.equal
      Windtrap.bool
      ~msg:"rendered CronJob keeps backoffLimit: 0"
      true
      (matches_regex (Str.regexp_string "backoffLimit: 0") rendered);
    Windtrap.equal
      Windtrap.bool
      ~msg:"live kind is CronJob"
      true
      (Sol_cli_rollback.live_kind_of_service got = Sol_cli_rollback.Live_cronjob);
    let live =
      [ ( id Sol_cli_rollback.Live_cronjob "myapp-payments" "invoice-fn"
        , workload_identity ~release:fn_release got )
      ]
    in
    let report =
      Sol_cli_rollback.verify_workloads
        ~expected:[ got, workload_identity ~release:fn_release got ]
        ~live
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a CronJob is part of the verified set, not skipped"
      true
      (Sol_cli_rollback.workload_report_ok report)
  | Ok specs -> Windtrap.failf "expected 1 reconstructed spec, got %d" (List.length specs)
;;

let test_reconstruction_rejects_invalid_persistence () =
  let workload = List.hd gate_release.workloads in
  let invalid_workload =
    { workload with
      Sol_cli_release_id.spec =
        { workload.Sol_cli_release_id.spec with
          replicas = 2
        ; volumes = [ "data", "/data", "10Gi", "ReadWriteOnce" ]
        }
    }
  in
  let invalid = { gate_release with workloads = [ invalid_workload ] } in
  match Sol_cli_rollback.service_specs_of_release invalid with
  | Ok _ -> Windtrap.fail "expected rollback reconstruction to reject persistence"
  | Error msg -> assert (matches_regex (Str.regexp "set replicas = 1") msg)
;;

let test_recreate_strategy_reconstructs () =
  let specs = reconstruct_ok () in
  let ledger =
    List.find
      (fun ((s : Sol_cli_deployment_plan.service_spec), _) ->
         s.source_name = "ledger_svc")
      specs
    |> fst
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"recreate preserved"
    true
    (ledger.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

let deployment_payload =
  `Assoc
    [ ( "items"
      , `List
          [ `Assoc
              [ ( "metadata"
                , `Assoc
                    [ "namespace", `String "myapp-payments"
                    ; "name", `String "ledger-svc"
                    ] )
              ; ( "spec"
                , `Assoc
                    [ ( "template"
                      , `Assoc
                          [ ( "metadata"
                            , `Assoc
                                [ ( "labels"
                                  , `Assoc
                                      [ "workspace", `String "myapp"
                                      ; "release", `String "r-1"
                                      ] )
                                ] )
                          ] )
                    ] )
              ]
          ; `Assoc
              [ ( "metadata"
                , `Assoc
                    [ "namespace", `String "myapp-payments"; "name", `String "other-svc" ]
                )
              ; ( "spec"
                , `Assoc
                    [ ( "template"
                      , `Assoc
                          [ ( "metadata"
                            , `Assoc
                                [ ( "labels"
                                  , `Assoc
                                      [ "workspace", `String "someoneelse"
                                      ; "release", `String "r-9"
                                      ] )
                                ] )
                          ] )
                    ] )
              ]
          ; `Assoc
              [ ( "metadata"
                , `Assoc [ "namespace", `String "kube-system"; "name", `String "coredns" ]
                )
              ]
          ] )
    ]
;;

let test_workload_rows_of_payload_deployment () =
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_deployment
      ~workspace:"myapp"
      deployment_payload
    |> Result.get_ok
  in
  Windtrap.equal Windtrap.int ~msg:"only the workspace-matching item" 1 (List.length rows);
  let identity, release = List.hd rows in
  Windtrap.equal
    Windtrap.bool
    ~msg:"kind"
    true
    (identity.kind = Sol_cli_rollback.Live_deployment);
  Windtrap.equal Windtrap.string ~msg:"namespace" "myapp-payments" identity.namespace;
  Windtrap.equal Windtrap.string ~msg:"name" "ledger-svc" identity.name;
  Windtrap.equal Windtrap.string ~msg:"release label" "r-1" release
;;

let test_workload_rows_of_payload_cronjob_path () =
  let as_deployment =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_cronjob
      ~workspace:"myapp"
      deployment_payload
    |> Result.get_ok
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"deployment payload has no cronjob pod template"
    0
    (List.length as_deployment)
;;

let test_workload_rows_of_payload_requires_items () =
  (match
     Sol_cli_rollback.workload_rows_of_payload
       ~kind:Sol_cli_rollback.Live_deployment
       ~workspace:"myapp"
       (`Assoc [ "kind", `String "List" ])
   with
   | Ok _ -> Windtrap.fail "a payload without items read as an answer"
   | Error _ -> ());
  Windtrap.equal
    Windtrap.int
    ~msg:"an empty items list is the empty answer"
    0
    (Sol_cli_rollback.workload_rows_of_payload
       ~kind:Sol_cli_rollback.Live_deployment
       ~workspace:"myapp"
       (`Assoc [ "items", `List [] ])
     |> Result.get_ok
     |> List.length)
;;

let test_workload_rows_of_payload_sanitizes_workspace () =
  let payload =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "namespace", `String "myapp-payments"
                      ; "name", `String "ledger-svc"
                      ] )
                ; ( "spec"
                  , `Assoc
                      [ ( "template"
                        , `Assoc
                            [ ( "metadata"
                              , `Assoc
                                  [ ( "labels"
                                    , `Assoc
                                        [ "workspace", `String "my-app"
                                        ; "release", `String "r-1"
                                        ] )
                                  ] )
                            ] )
                      ] )
                ]
            ] )
      ]
  in
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_deployment
      ~workspace:"My_App"
      payload
    |> Result.get_ok
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"matches the sanitized workspace label"
    1
    (List.length rows)
;;

let test_workload_rows_of_payload_cronjob () =
  let payload =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "namespace", `String "myapp-billing"
                      ; "name", `String "invoice-fn"
                      ] )
                ; ( "spec"
                  , `Assoc
                      [ ( "jobTemplate"
                        , `Assoc
                            [ ( "spec"
                              , `Assoc
                                  [ ( "template"
                                    , `Assoc
                                        [ ( "metadata"
                                          , `Assoc
                                              [ ( "labels"
                                                , `Assoc
                                                    [ "workspace", `String "myapp"
                                                    ; "release", `String "r-2"
                                                    ] )
                                              ] )
                                        ] )
                                  ] )
                            ] )
                      ] )
                ]
            ] )
      ]
  in
  let rows =
    Sol_cli_rollback.workload_rows_of_payload
      ~kind:Sol_cli_rollback.Live_cronjob
      ~workspace:"myapp"
      payload
    |> Result.get_ok
  in
  Windtrap.equal Windtrap.int ~msg:"one cronjob row" 1 (List.length rows);
  let identity, release = List.hd rows in
  Windtrap.equal Windtrap.string ~msg:"name" "invoice-fn" identity.name;
  Windtrap.equal Windtrap.string ~msg:"release label" "r-2" release
;;

let test_pointer_report_ok () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"ok"
    true
    (Sol_cli_rollback.pointer_report_ok Sol_cli_rollback.Pointer_confirmed);
  Windtrap.equal
    Windtrap.bool
    ~msg:"not ok"
    false
    (Sol_cli_rollback.pointer_report_ok (Sol_cli_rollback.Pointer_names "r-x"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unreadable pointer fails closed too"
    false
    (Sol_cli_rollback.pointer_report_ok
       (Sol_cli_rollback.Pointer_unreadable "exited with code 1: forbidden"))
;;

let test_pointer_report_to_string_uses_canonical_name () =
  let report = Sol_cli_rollback.Pointer_names "" in
  let msg = Sol_cli_rollback.pointer_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "sol-release-current-myapp") msg);
  assert (matches_regex (Str.regexp "<none>") msg);
  let release = { verify_release with workspace = "CI_Smoke" } in
  let msg = Sol_cli_rollback.pointer_report_to_string ~release report in
  assert (matches_regex (Str.regexp "sol-release-current-ci-smoke") msg);
  assert (not (matches_regex (Str.regexp_string "CI_Smoke") msg))
;;

let test_pointer_report_unreadable_names_the_reason () =
  let report =
    Sol_cli_rollback.Pointer_unreadable
      "exited with code 1: Error from server (Forbidden): configmaps is forbidden"
  in
  let msg = Sol_cli_rollback.pointer_report_to_string ~release:verify_release report in
  assert (matches_regex (Str.regexp "sol-release-current-myapp") msg);
  assert (matches_regex (Str.regexp_string "could not be read") msg);
  assert (matches_regex (Str.regexp_string "Forbidden") msg);
  assert (not (matches_regex (Str.regexp_string "<none>") msg));
  assert (not (matches_regex (Str.regexp_string "pointer mismatch") msg))
;;

let with_fake_kubectl script f =
  let dir = Filename.temp_file "sol-rollback-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let test_verify_pointer_reports_an_unreadable_read () =
  with_fake_kubectl
    {|#!/bin/sh
printf 'Error from server (Forbidden): configmaps "sol-release-current-myapp" is forbidden\n' >&2
exit 1
|}
    (fun () ->
       let report =
         Sol_cli_rollback.verify_pointer
           ~ctx:Sol_cli_kube_destination.local_context
           ~release:verify_release
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"an unreadable pointer is not a success"
         false
         (Sol_cli_rollback.pointer_report_ok report);
       match report with
       | Sol_cli_rollback.Pointer_unreadable reason ->
         assert (matches_regex (Str.regexp_string "Forbidden") reason)
       | _ -> Windtrap.fail "an unreadable read must not be reported as a named release")
;;

let test_verify_pointer_confirms_the_read_release () =
  with_fake_kubectl
    (Printf.sprintf "#!/bin/sh\nprintf '%%s' '%s'\n" verify_release.release_id)
    (fun () ->
       let report =
         Sol_cli_rollback.verify_pointer
           ~ctx:Sol_cli_kube_destination.local_context
           ~release:verify_release
       in
       Windtrap.equal
         Windtrap.bool
         ~msg:"a read-back pointer is ok"
         true
         (Sol_cli_rollback.pointer_report_ok report))
;;

let test_verify_pointer_reports_a_read_mismatch () =
  with_fake_kubectl "#!/bin/sh\nprintf 'r-9999999999999999'\n" (fun () ->
    let report =
      Sol_cli_rollback.verify_pointer
        ~ctx:Sol_cli_kube_destination.local_context
        ~release:verify_release
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a mismatched pointer fails"
      false
      (Sol_cli_rollback.pointer_report_ok report);
    let msg = Sol_cli_rollback.pointer_report_to_string ~release:verify_release report in
    assert (matches_regex (Str.regexp_string "pointer mismatch") msg))
;;

let transaction_release ~apply_mode : Sol_cli_release.t =
  { release_id = "r-3333333333333333"
  ; workspace = "myapp"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; contract = []
  ; apply_mode
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let recording_deps
      ?(live = [])
      ?(prune_result = Ok ())
      ?(apply_result = Ok ())
      ?(retained = [])
      ?ensure_held
      ?applied_migrations
      ?(record_consumer_groups = fun _ -> Ok ())
      ()
  =
  let calls = ref [] in
  let pruned = ref None in
  let record name = calls := name :: !calls in
  let ensure_held =
    match ensure_held with
    | Some f ->
      fun () ->
        record "ensure_held";
        f ()
    | None ->
      fun () ->
        record "ensure_held";
        Ok ()
  in
  let applied_migrations =
    match applied_migrations with
    | Some f ->
      fun () ->
        record "applied_migrations";
        f ()
    | None ->
      fun () ->
        record "applied_migrations";
        Ok []
  in
  let deps : Sol_cli_rollback.transaction_deps =
    { ensure_held
    ; applied_migrations
    ; apply =
        (fun _specs ->
          record "apply";
          apply_result)
    ; live_workloads =
        (fun () ->
          record "live_workloads";
          Ok live)
    ; prune =
        (fun ~live:_ ~surplus ->
          record "prune";
          pruned := Some surplus;
          match prune_result with
          | Ok () -> Ok { Sol_cli_rollback.removed = []; retained; unowned = [] }
          | Error _ as e -> e)
    ; move_pointer =
        (fun () ->
          record "move_pointer";
          Ok ())
    ; verify_pointer =
        (fun () ->
          record "verify_pointer";
          Sol_cli_rollback.Pointer_confirmed)
    ; record_consumer_groups =
        (fun groups ->
          record (Printf.sprintf "record_consumer_groups:%s" (String.concat "," groups));
          record_consumer_groups groups)
    }
  in
  calls, pruned, deps
;;

let test_execute_success_calls_every_dep_in_order () =
  let calls, pruned, deps = recording_deps () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Error msg -> Windtrap.fail msg
  | Ok () ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"ownership is re-verified before each mutation"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ; "move_pointer"
      ; "verify_pointer"
      ; "record_consumer_groups:"
      ]
      (List.rev !calls);
    Windtrap.equal
      Windtrap.int
      ~msg:"prune ran with no surplus"
      0
      (List.length (Option.get !pruned))
;;

let worker_spec ?(domain = "comms") ?(name = "notify_worker") ()
  : Sol_cli_deployment_plan.service_spec
  =
  { ledger_spec with
    domain
  ; source_name = name
  ; k8s_name = k8s_name (String.concat "-" (String.split_on_char '_' name))
  ; namespace = namespace ~workspace:"myapp" ~domain
  ; primitive = Sol_cli_deployment_plan.Worker
  ; consumes_kafka = true
  }
;;

let release_with_workloads ~apply_mode specs : Sol_cli_release.t =
  let base = transaction_release ~apply_mode in
  { base with
    workloads =
      List.map
        (fun spec ->
           Sol_cli_release.applied_by
             base.release_id
             (Sol_cli_deployment_plan.release_workload_of_spec spec))
        specs
  }
;;

(* The live workload set as the release's own workloads: each object carries the
   workload's immutable identity as its `release` label, which is what the deploy that
   applied this boundary rendered. *)
let live_for ~release specs =
  List.map
    (fun spec -> Sol_cli_rollback.identity_of_spec spec, workload_identity ~release spec)
    specs
;;

let test_execute_records_the_restored_consumer_groups () =
  let groups_for specs =
    let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct specs in
    let calls, _pruned, deps = recording_deps ~live:(live_for ~release specs) () in
    match
      Sol_cli_rollback.execute
        ~release
        ~migrations_dir:"unused"
        ~current_migrations:[]
        ~deps
    with
    | Error msg -> Windtrap.fail msg
    | Ok () ->
      (match !calls with
       | last :: _ -> last
       | [] -> Windtrap.fail "no deps were called")
  in
  let notify = worker_spec () in
  let fulfill = worker_spec ~domain:"logistics" ~name:"fulfillment_worker" () in
  Windtrap.equal
    Windtrap.string
    ~msg:
      "rolling back to A+B records both workers' groups, last, after the pointer verified"
    "record_consumer_groups:myapp.comms.notify_worker,myapp.logistics.fulfillment_worker"
    (groups_for [ notify; fulfill ]);
  Windtrap.equal
    Windtrap.string
    ~msg:
      "rolling back to A records only A, so the next deploy's removal check describes \
       the restored set"
    "record_consumer_groups:myapp.comms.notify_worker"
    (groups_for [ notify ]);
  Windtrap.equal
    Windtrap.string
    ~msg:"a non-worker release records no groups"
    "record_consumer_groups:"
    (groups_for [ ledger_spec ])
;;

let test_execute_leaves_the_guard_alone_when_verification_fails () =
  let calls, _pruned, deps = recording_deps ~live:[] () in
  let release =
    release_with_workloads ~apply_mode:Sol_cli_release.Direct [ worker_spec () ]
  in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the missing workload to block the rollback"
  | Error _ ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the guard record still describes the release that is still live"
      true
      (List.for_all
         (fun call -> not (Sol_cli_string.contains ~needle:"record_consumer_groups" call))
         !calls)
;;

let test_execute_reports_an_uncorrected_guard_record () =
  let notify = worker_spec () in
  let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct [ notify ] in
  let calls, _pruned, deps =
    recording_deps
      ~live:(live_for ~release [ notify ])
      ~record_consumer_groups:(fun _ -> Error "the ConfigMap is forbidden")
      ()
  in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "an uncorrected guard record must be reported"
  | Error msg ->
    assert (matches_regex (Str.regexp_string "rollback incomplete") msg);
    assert (matches_regex (Str.regexp_string "could not be corrected") msg);
    assert (matches_regex (Str.regexp_string "the ConfigMap is forbidden") msg);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the rollback itself did happen, so the pointer was moved"
      true
      (List.exists (fun call -> String.equal call "move_pointer") !calls)
;;

let test_execute_apply_mode_refusal_calls_no_deps () =
  let calls, _pruned, deps = recording_deps () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Gitops in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected a GitOps-owned release to be refused"
  | Error msg ->
    assert (matches_regex (Str.regexp "GitOps") msg);
    Windtrap.equal (Windtrap.list Windtrap.string) ~msg:"no dep was ever called" [] !calls
;;

let test_execute_migration_boundary_refusal_calls_no_deps () =
  with_migrations_dir
    [ "0001_init.sql", expand_sql; "0002_drop_col.sql", contract_sql ]
    (fun migrations_dir ->
       let calls, _pruned, deps = recording_deps () in
       let release =
         { (transaction_release ~apply_mode:Sol_cli_release.Direct) with
           migrations = [ "0001_init.sql" ]
         }
       in
       match
         Sol_cli_rollback.execute
           ~release
           ~migrations_dir
           ~current_migrations:[ "0001_init.sql"; "0002_drop_col.sql" ]
           ~deps
       with
       | Ok () -> Windtrap.fail "expected a contracting migration to block the rollback"
       | Error msg ->
         assert (matches_regex (Str.regexp "0002_drop_col.sql") msg);
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"no dep was ever called"
           []
           !calls)
;;

let test_execute_unexpected_workload_triggers_prune_then_completes () =
  let bogus_live : Sol_cli_rollback.workload_identity * string =
    ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "ghost-svc"
      }
    , "r-3333333333333333" )
  in
  let calls, pruned, deps = recording_deps ~live:[ bogus_live ] () in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Error msg -> Windtrap.fail msg
  | Ok () ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"apply, live_workloads, prune, move_pointer, verify_pointer all ran"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ; "move_pointer"
      ; "verify_pointer"
      ; "record_consumer_groups:"
      ]
      (List.rev !calls);
    (match !pruned with
     | None -> Windtrap.fail "prune was never called"
     | Some surplus ->
       Windtrap.equal
         Windtrap.int
         ~msg:"exactly the bogus workload was pruned"
         1
         (List.length surplus);
       let id, _ = List.hd surplus in
       Windtrap.equal Windtrap.string ~msg:"pruned name" "ghost-svc" id.name)
;;

let test_execute_prune_failure_skips_pointer_move () =
  let bogus_live : Sol_cli_rollback.workload_identity * string =
    ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "ghost-svc"
      }
    , "r-3333333333333333" )
  in
  let calls, _pruned, deps =
    recording_deps ~live:[ bogus_live ] ~prune_result:(Error "boom") ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the prune failure to block the pointer move"
  | Error msg ->
    assert (matches_regex (Str.regexp "boom") msg);
    assert (matches_regex (Str.regexp "pointer was left unchanged") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"apply, live_workloads, prune ran; move_pointer/verify_pointer never did"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ]
      (List.rev !calls)
;;

let test_execute_applied_state_unavailable_skips_every_mutation () =
  let calls, pruned, deps =
    recording_deps ~applied_migrations:(fun () -> Error "no cluster") ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the unreadable applied state to block the rollback"
  | Error msg ->
    assert (matches_regex (Str.regexp "applied migration state") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"only the applied-state read ran"
      [ "applied_migrations" ]
      (List.rev !calls);
    Windtrap.equal Windtrap.bool ~msg:"prune never called" true (!pruned = None)
;;

let ghost_live : Sol_cli_rollback.workload_identity * string =
  ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
    ; namespace = "myapp-payments"
    ; name = "ghost-svc"
    }
  , "r-3333333333333333" )
;;

let ownership_lost_after n =
  let calls = ref 0 in
  fun () ->
    incr calls;
    if !calls >= n
    then Error "lost the boundary lease to rollback run-takeover (BUG-071)"
    else Ok ()
;;

let test_execute_lost_ownership_after_apply_skips_prune_and_pointer () =
  let calls, pruned, deps =
    recording_deps ~live:[ ghost_live ] ~ensure_held:(ownership_lost_after 2) ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the lost lease to stop the transaction"
  | Error msg ->
    assert (matches_regex (Str.regexp "lost the boundary lease") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the takeover stopped the transaction before prune"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads"; "ensure_held" ]
      (List.rev !calls);
    Windtrap.equal Windtrap.bool ~msg:"prune never called" true (!pruned = None)
;;

let test_execute_lost_ownership_after_prune_skips_pointer_move () =
  let calls, _pruned, deps =
    recording_deps ~live:[ ghost_live ] ~ensure_held:(ownership_lost_after 3) ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the lost lease to block the pointer move"
  | Error msg ->
    assert (matches_regex (Str.regexp "lost the boundary lease") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"apply and prune ran; the pointer was never moved"
      [ "applied_migrations"
      ; "ensure_held"
      ; "apply"
      ; "live_workloads"
      ; "ensure_held"
      ; "prune"
      ; "ensure_held"
      ]
      (List.rev !calls)
;;

let transaction_release_with_ledger ~apply_mode : Sol_cli_release.t =
  let base = transaction_release ~apply_mode in
  { base with
    workloads =
      [ Sol_cli_release.applied_by
          base.release_id
          (Sol_cli_deployment_plan.release_workload_of_spec ledger_spec)
      ]
  }
;;

let test_execute_missing_workload_skips_prune_and_pointer_move () =
  let calls, pruned, deps = recording_deps ~live:[] () in
  let release = transaction_release_with_ledger ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the missing workload to block the pointer move"
  | Error msg ->
    assert (matches_regex (Str.regexp "ledger-svc") msg);
    assert (matches_regex (Str.regexp "pointer was left unchanged") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"apply and live_workloads ran; prune/move_pointer/verify_pointer never did"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads" ]
      (List.rev !calls);
    Windtrap.equal Windtrap.bool ~msg:"prune never called" true (!pruned = None)
;;

let test_execute_apply_failure_reports_the_incomplete_rollback () =
  let calls, pruned, deps =
    recording_deps ~apply_result:(Error "kubectl apply failed on notify-worker") ()
  in
  let release = transaction_release ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "a failed apply must fail the rollback"
  | Error msg ->
    assert (matches_regex (Str.regexp "kubectl apply failed on notify-worker") msg);
    assert (matches_regex (Str.regexp "pointer") msg);
    assert (matches_regex (Str.regexp "still names the previous release") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the failure stopped before verifying, pruning or moving the pointer"
      [ "applied_migrations"; "ensure_held"; "apply" ]
      (List.rev !calls);
    Windtrap.equal Windtrap.bool ~msg:"prune never called" true (!pruned = None)
;;

let test_execute_mismatched_workload_skips_prune_and_pointer_move () =
  let calls, pruned, deps = recording_deps ~live:[ ledger_id, "r-9999999999999999" ] () in
  let release = transaction_release_with_ledger ~apply_mode:Sol_cli_release.Direct in
  match
    Sol_cli_rollback.execute
      ~release
      ~migrations_dir:"unused"
      ~current_migrations:[]
      ~deps
  with
  | Ok () -> Windtrap.fail "expected the label mismatch to block the pointer move"
  | Error msg ->
    assert (matches_regex (Str.regexp "ledger-svc") msg);
    assert (matches_regex (Str.regexp "pointer was left unchanged") msg);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"apply and live_workloads ran; prune/move_pointer/verify_pointer never did"
      [ "applied_migrations"; "ensure_held"; "apply"; "live_workloads" ]
      (List.rev !calls);
    Windtrap.equal Windtrap.bool ~msg:"prune never called" true (!pruned = None)
;;

let test_sequential_application_stops_on_error () =
  let visited = ref [] in
  let apply spec =
    visited := spec :: !visited;
    if spec = 2 then Error "apply failed" else Ok ()
  in
  let result = [ 1; 2; 3 ] |> Sol_cli_result.map_list apply |> Result.map ignore in
  Windtrap.equal
    (Windtrap.result Windtrap.unit Windtrap.string)
    ~msg:"first error"
    (Error "apply failed")
    result;
  Windtrap.equal
    (Windtrap.list Windtrap.int)
    ~msg:"sequential, stops before third"
    [ 1; 2 ]
    (List.rev !visited)
;;

let test_plan_prune_prunes_stateless_auxiliaries_and_retains_volumes () =
  let id : Sol_cli_rollback.workload_identity =
    { kind = Sol_cli_rollback.Live_deployment
    ; namespace = "myapp-payments"
    ; name = "ghost-svc"
    }
  in
  let report =
    Sol_cli_rollback.plan_prune
      ~removable:[ id ]
      ~unowned:[]
      ~live_names:[ "ledger-svc"; "ghost-svc" ]
      ~claims:(fun _ -> [ "ghost-svc-data" ])
  in
  let named (t : Sol_cli_rollback.prune_target) = t.resource, t.name in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the workload and its stateless auxiliaries are pruned"
    [ "deployment", "ghost-svc"
    ; "serviceaccount", "ghost-svc"
    ; "configmap", "ghost-svc-env"
    ; "networkpolicy", "ghost-svc"
    ; "service", "ghost-svc"
    ; "ingress", "ghost-svc"
    ; "poddisruptionbudget", "ghost-svc"
    ]
    (List.map named report.removed);
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the volume claim is retained, never pruned"
    [ "persistentvolumeclaim", "ghost-svc-data" ]
    (List.map named report.retained)
;;

let test_plan_prune_guards_blue_green_names_against_a_sibling () =
  let id : Sol_cli_rollback.workload_identity =
    { kind = Sol_cli_rollback.Live_rollout
    ; namespace = "myapp-payments"
    ; name = "ghost-svc"
    }
  in
  let names ~live_names =
    let report =
      Sol_cli_rollback.plan_prune
        ~removable:[ id ]
        ~unowned:[]
        ~live_names
        ~claims:(fun _ -> [])
    in
    List.map (fun (t : Sol_cli_rollback.prune_target) -> t.name) report.removed
  in
  let free = names ~live_names:[ "ghost-svc" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a free blue-green name is pruned"
    true
    (List.mem "ghost-svc-active" free && List.mem "ghost-svc-preview" free);
  let occupied =
    names ~live_names:[ "ghost-svc"; "ghost-svc-active"; "ghost-svc-preview" ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a sibling's -active/-preview names are left alone"
    false
    (List.mem "ghost-svc-active" occupied || List.mem "ghost-svc-preview" occupied);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the base names are still pruned"
    true
    (List.mem "ghost-svc" occupied)
;;

(* The removal path deletes a surplus workload only while its live UID equals the UID the
   release recorded at apply; a different UID, a missing object, or no recorded UID is
   retained and reported. *)
let test_prune_removes_only_the_workload_whose_uid_matches () =
  let evidence =
    [ { Sol_cli_release_id.resource = "deployment"
      ; namespace = "myapp-payments"
      ; name = "owned-svc"
      ; uid = "uid-1"
      }
    ]
  in
  let live =
    [ ( { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
        ; namespace = "myapp-payments"
        ; name = "owned-svc"
        }
      , "r-1" )
    ]
  in
  let surplus =
    [ { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "owned-svc"
      }
    ; { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
      ; namespace = "myapp-payments"
      ; name = "gone-svc"
      }
    ]
  in
  with_fake_kubectl
    {|#!/bin/sh
case "$3" in
  get)
    case "$*" in
      *jsonpath*)
        case "$5" in
          owned-svc) printf '%s' uid-1 ;;
          *) printf '%s\n' 'Error from server (NotFound): deployments "gone-svc" not found' >&2; exit 1 ;;
        esac ;;
      *) printf '%s' '{"spec":{"template":{"spec":{"volumes":[]}}}}' ;;
    esac ;;
  delete) exit 0 ;;
  *) exit 1 ;;
esac
|}
    (fun () ->
       match
         Sol_cli_rollback.prune_workloads
           ~ctx:Sol_cli_kube_destination.local_context
           ~evidence
           ~live
           ~surplus:(List.map (fun id -> id, "r-1") surplus)
       with
       | Error msg -> Windtrap.fail msg
       | Ok report ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the workload whose live UID matches is removed"
           true
           (List.exists
              (fun (t : Sol_cli_rollback.prune_target) ->
                 String.equal t.resource "deployment" && String.equal t.name "owned-svc")
              report.removed);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the workload whose object is gone is retained, not removed"
           false
           (List.exists
              (fun (t : Sol_cli_rollback.prune_target) -> String.equal t.name "gone-svc")
              report.removed);
         Windtrap.equal
           Windtrap.int
           ~msg:"the retained workload is reported as not owned"
           1
           (List.length report.unowned))
;;

type modelled_cluster =
  { mutable live : (Sol_cli_rollback.workload_identity * string) list
  ; mutable pointer : string
  ; mutable secret : (string * string) list
  ; mutable manifests : string list
  ; mutable objects : Sol_cli_rollback.prune_target list
  ; claims : Sol_cli_rollback.workload_identity -> string list
  }

let same_target (a : Sol_cli_rollback.prune_target) (b : Sol_cli_rollback.prune_target) =
  String.equal a.resource b.resource
  && String.equal a.namespace b.namespace
  && String.equal a.name b.name
;;

let same_identity
      (a : Sol_cli_rollback.workload_identity)
      (b : Sol_cli_rollback.workload_identity)
  =
  a.kind = b.kind && String.equal a.namespace b.namespace && String.equal a.name b.name
;;

let upsert_live cluster id label =
  if List.exists (fun (existing, _) -> same_identity existing id) cluster.live
  then
    cluster.live
    <- List.map
         (fun (existing, current) ->
            if same_identity existing id then existing, label else existing, current)
         cluster.live
  else cluster.live <- cluster.live @ [ id, label ]
;;

let render_for_release ~(release : Sol_cli_release.t) spec applied_by =
  match Sol_cli_release_id.of_string applied_by with
  | Error msg -> Error msg
  | Ok id ->
    (match
       Sol_cli_deployment_render.render_spec
         ~workspace:release.Sol_cli_release.workspace
         ?env:release.Sol_cli_release.environment
         ~release_id:id
         spec
     with
     | Error msg -> Error msg
     | Ok bundle ->
       Ok (bundle.namespace_yaml ^ bundle.prerequisites_yaml ^ bundle.workload_yaml))
;;

let modelled_deps ~release ~cluster ?(fail_at = None) ()
  : Sol_cli_rollback.transaction_deps
  =
  let release_id = release.Sol_cli_release.release_id in
  let apply_one index (spec, applied_by) =
    match fail_at with
    | Some n when n = index -> Error "apply failed"
    | _ ->
      (match render_for_release ~release spec applied_by with
       | Error msg -> Error msg
       | Ok manifest ->
         cluster.manifests <- cluster.manifests @ [ manifest ];
         upsert_live cluster (Sol_cli_rollback.identity_of_spec spec) applied_by;
         Ok ())
  in
  let rec apply_all index = function
    | [] -> Ok ()
    | spec :: rest ->
      (match apply_one index spec with
       | Error _ as e -> e
       | Ok () -> apply_all (index + 1) rest)
  in
  { Sol_cli_rollback.ensure_held = (fun () -> Ok ())
  ; applied_migrations = (fun () -> Ok [])
  ; apply = apply_all 0
  ; live_workloads = (fun () -> Ok cluster.live)
  ; prune =
      (fun ~live ~surplus ->
        let live_names =
          List.map (fun ((id : Sol_cli_rollback.workload_identity), _) -> id.name) live
        in
        let report =
          Sol_cli_rollback.plan_prune
            ~removable:(List.map fst surplus)
            ~unowned:[]
            ~live_names
            ~claims:cluster.claims
        in
        let removed = List.map fst surplus in
        cluster.live
        <- List.filter
             (fun (id, _) -> not (List.exists (same_identity id) removed))
             cluster.live;
        cluster.objects
        <- List.filter
             (fun object_ ->
                not
                  (List.exists (fun target -> same_target target object_) report.removed))
             cluster.objects;
        Ok report)
  ; move_pointer =
      (fun () ->
        cluster.pointer <- release_id;
        Ok ())
  ; verify_pointer =
      (fun () ->
        if String.equal cluster.pointer release_id
        then Sol_cli_rollback.Pointer_confirmed
        else Sol_cli_rollback.Pointer_names cluster.pointer)
  ; record_consumer_groups = (fun _ -> Ok ())
  }
;;

let qualification_ghost : Sol_cli_rollback.workload_identity =
  { Sol_cli_rollback.kind = Sol_cli_rollback.Live_deployment
  ; namespace = "myapp-payments"
  ; name = "ghost-svc"
  }
;;

let test_qualification_restores_after_a_bad_deploy () =
  let target = [ ledger_spec; worker_spec () ] in
  let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct target in
  let bad = "r-9999999999999999" in
  let initial_secret =
    [ "POSTGRES_URL", "postgresql://prod"; "SOL_API_KEY", "api-key-material" ]
  in
  let ghost_object resource name =
    { Sol_cli_rollback.resource; namespace = qualification_ghost.namespace; name }
  in
  let cluster =
    { live =
        List.map (fun spec -> Sol_cli_rollback.identity_of_spec spec, bad) target
        @ [ qualification_ghost, bad ]
    ; pointer = bad
    ; secret = initial_secret
    ; manifests = []
    ; objects =
        [ ghost_object "deployment" "ghost-svc"
        ; ghost_object "serviceaccount" "ghost-svc"
        ; ghost_object "configmap" "ghost-svc-env"
        ; ghost_object "networkpolicy" "ghost-svc"
        ; ghost_object "service" "ghost-svc"
        ; ghost_object "ingress" "ghost-svc"
        ; ghost_object "poddisruptionbudget" "ghost-svc"
        ; ghost_object "persistentvolumeclaim" "ghost-svc-data"
        ]
    ; claims =
        (fun (id : Sol_cli_rollback.workload_identity) ->
          if same_identity id qualification_ghost then [ "ghost-svc-data" ] else [])
    }
  in
  let deps = modelled_deps ~release ~cluster () in
  (match
     Sol_cli_rollback.execute
       ~release
       ~migrations_dir:"unused"
       ~current_migrations:[]
       ~deps
   with
   | Error msg -> Windtrap.fail ("rollback of a bad deploy must succeed: " ^ msg)
   | Ok () -> ());
  Windtrap.equal
    Windtrap.string
    ~msg:"the pointer names the restored release"
    release.release_id
    cluster.pointer;
  Windtrap.equal
    Windtrap.int
    ~msg:"the surplus workload is pruned"
    (List.length target)
    (List.length cluster.live);
  List.iter
    (fun spec ->
       let id = Sol_cli_rollback.identity_of_spec spec in
       let expected = workload_identity ~release spec in
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "restored %s/%s" id.namespace id.name)
         true
         (List.exists
            (fun (live_id, label) ->
               same_identity live_id id && String.equal label expected)
            cluster.live))
    target;
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the live secret was never touched"
    initial_secret
    cluster.secret;
  Windtrap.equal
    Windtrap.int
    ~msg:"every restored workload was re-rendered and applied"
    2
    (List.length cluster.manifests);
  List.iter
    (fun manifest ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"no Secret object"
         false
         (Sol_cli_string.contains ~needle:"kind: Secret" manifest);
       Windtrap.equal
         Windtrap.bool
         ~msg:"no stringData"
         false
         (Sol_cli_string.contains ~needle:"stringData" manifest);
       Windtrap.equal
         Windtrap.bool
         ~msg:"secret referenced by key"
         true
         (Sol_cli_string.contains ~needle:"secretKeyRef" manifest))
    cluster.manifests;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "a dropped workload's stateless auxiliaries are pruned and its volume is retained"
    [ "persistentvolumeclaim" ]
    (List.map (fun (t : Sol_cli_rollback.prune_target) -> t.resource) cluster.objects);
  Windtrap.equal
    Windtrap.string
    ~msg:"the retained object is the dropped workload's volume claim"
    "ghost-svc-data"
    (match cluster.objects with
     | [ t ] -> t.name
     | _ -> "<none>")
;;

let test_qualification_partial_apply_leaves_the_pointer () =
  let target = [ ledger_spec; worker_spec () ] in
  let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct target in
  let bad = "r-9999999999999999" in
  let initial_secret = [ "POSTGRES_URL", "postgresql://prod" ] in
  let cluster =
    { live = List.map (fun spec -> Sol_cli_rollback.identity_of_spec spec, bad) target
    ; pointer = bad
    ; secret = initial_secret
    ; manifests = []
    ; objects = []
    ; claims = (fun _ -> [])
    }
  in
  let deps = modelled_deps ~release ~cluster ~fail_at:(Some 1) () in
  (match
     Sol_cli_rollback.execute
       ~release
       ~migrations_dir:"unused"
       ~current_migrations:[]
       ~deps
   with
   | Ok () -> Windtrap.fail "a partial apply must fail the rollback"
   | Error msg ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the apply failure is reported"
       true
       (Sol_cli_string.contains ~needle:"apply failed" msg));
  Windtrap.equal
    Windtrap.string
    ~msg:"the pointer still names the bad release"
    bad
    cluster.pointer;
  Windtrap.equal
    Windtrap.int
    ~msg:"the second workload was never applied"
    1
    (List.length cluster.manifests);
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the live secret was never touched"
    initial_secret
    cluster.secret
;;

let test_qualification_render_never_carries_secret_material () =
  let spec = { ledger_spec with secrets = [ "DB_PASSWORD", "super-secret-material" ] } in
  let release = release_with_workloads ~apply_mode:Sol_cli_release.Direct [ spec ] in
  match Sol_cli_rollback.service_specs_of_release release with
  | Error msg -> Windtrap.fail msg
  | Ok reconstructed ->
    List.iter
      (fun ((spec, applied_by) : Sol_cli_deployment_plan.service_spec * string) ->
         match render_for_release ~release spec applied_by with
         | Error msg -> Windtrap.fail msg
         | Ok manifest ->
           Windtrap.equal
             Windtrap.bool
             ~msg:"secret material is never rendered"
             false
             (Sol_cli_string.contains ~needle:"super-secret-material" manifest);
           Windtrap.equal
             Windtrap.bool
             ~msg:"no Secret object is rendered"
             false
             (Sol_cli_string.contains ~needle:"kind: Secret" manifest);
           Windtrap.equal
             Windtrap.bool
             ~msg:"no stringData is rendered"
             false
             (Sol_cli_string.contains ~needle:"stringData" manifest);
           Windtrap.equal
             Windtrap.bool
             ~msg:"the key is still referenced"
             true
             (Sol_cli_string.contains ~needle:"DB_PASSWORD" manifest))
      reconstructed
;;

let%test "qualification: a bad deploy is restored and the live secret is untouched" =
  test_qualification_restores_after_a_bad_deploy ()
;;

let%test "qualification: a partial apply leaves the pointer and secrets alone" =
  test_qualification_partial_apply_leaves_the_pointer ()
;;

let%test "qualification: rollback render never carries secret material" =
  test_qualification_render_never_carries_secret_material ()
;;

let%test "prune_plan: stateless auxiliaries pruned, volumes retained (BUG-120)" =
  test_plan_prune_prunes_stateless_auxiliaries_and_retains_volumes ()
;;

let%test "prune_plan: blue-green names are left when a sibling owns them (BUG-120)" =
  test_plan_prune_guards_blue_green_names_against_a_sibling ()
;;

let%test "prune: a surplus workload is removed only on an exact recorded-UID match" =
  test_prune_removes_only_the_workload_whose_uid_matches ()
;;

let%test "reconstruction_gate: A: decode correctness" = test_gate_a_decode_correctness ()

let%test "reconstruction_gate: B: identity correctness" =
  test_gate_b_identity_correctness ()
;;

let%test "reconstruction_gate: C: render correctness" = test_gate_c_render_correctness ()

let%test "reconstruction_gate: failure: unknown rollout encoding" =
  test_gate_failure_unknown_rollout_encoding ()
;;

let%test "reconstruction_gate: failure: invalid cpu quantity" =
  test_gate_failure_invalid_cpu ()
;;

let%test "reconstruction_gate: failure: invalid availability (BUG-118)" =
  test_gate_failure_invalid_availability ()
;;

let%test "reconstruction_gate: failure: invalid persistence" =
  test_reconstruction_rejects_invalid_persistence ()
;;

let%test "migration_boundary_check: no new migrations passes" =
  test_migration_boundary_no_new_migrations_passes ()
;;

let%test "migration_boundary_check: new expand migration passes" =
  test_migration_boundary_new_expand_passes ()
;;

let%test "migration_boundary_check: new contract migration blocks" =
  test_migration_boundary_new_contract_blocks ()
;;

let%test "migration_boundary_check: new undeclared migration blocks" =
  test_migration_boundary_undeclared_new_migration_blocks ()
;;

let%test "migration_boundary_check: already-recorded contract is ignored" =
  test_migration_boundary_ignores_already_recorded_contract ()
;;

let%test
    "migration_boundary_check: applied migration absent from the checkout blocks \
     (BUG-078)"
  =
  test_migration_boundary_applied_beyond_release_absent_locally_blocks ()
;;

let%test "migration_boundary_check: applied expansion beyond the release passes (BUG-078)"
  =
  test_migration_boundary_applied_expansion_beyond_release_passes ()
;;

let%test "migration_boundary_check: unreadable applied state blocks (BUG-078)" =
  test_migration_boundary_applied_state_unavailable_blocks ()
;;

let%test "live_kind_of_service: primitive/progressive_delivery table" =
  test_live_kind_of_service_table ()
;;

let%test "live_kind_of_service: resource + jsonpath table" =
  test_live_resource_and_jsonpath_table ()
;;

let%test "sequential_application: stops on first error" =
  test_sequential_application_stops_on_error ()
;;

let%test "apply_mode_refusal: allows Direct" = test_check_apply_mode_allows_direct ()
let%test "apply_mode_refusal: refuses Gitops" = test_check_apply_mode_refuses_gitops ()

let%test "workload_set_verification: ok when the set matches" =
  test_verify_workloads_ok_when_set_matches ()
;;

let%test "workload_set_verification: reports an unexpected workload" =
  test_verify_workloads_reports_unexpected ()
;;

let%test "workload_set_verification: reports a missing workload" =
  test_verify_workloads_reports_missing ()
;;

let%test "workload_set_verification: reports a label mismatch" =
  test_verify_workloads_reports_label_mismatch ()
;;

let%test "workload_set_verification: distinguishes Deployment from Rollout" =
  test_verify_workloads_distinguishes_kind ()
;;

let%test "workload_set_verification: wire path: deployment pod template" =
  test_workload_rows_of_payload_deployment ()
;;

let%test "workload_set_verification: wire path: cronjob pod template" =
  test_workload_rows_of_payload_cronjob ()
;;

let%test "workload_set_verification: wire path: cronjob path is load-bearing" =
  test_workload_rows_of_payload_cronjob_path ()
;;

let%test "workload_set_verification: wire path: workspace label is sanitized" =
  test_workload_rows_of_payload_sanitizes_workspace ()
;;

let%test "workload_set_verification: a payload without items is an error" =
  test_workload_rows_of_payload_requires_items ()
;;

let%test
    "workload_set_verification: Fn is reconstructed and verified as a CronJob, not \
     skipped"
  =
  test_fn_reconstructs_and_verifies_as_cronjob ()
;;

let%test "workload_set_verification: recreate strategy survives reconstruction" =
  test_recreate_strategy_reconstructs ()
;;

let%test "pointer_report: ok flag" = test_pointer_report_ok ()

let%test "pointer_report: names the canonical pointer ConfigMap" =
  test_pointer_report_to_string_uses_canonical_name ()
;;

let%test "pointer_report: an unreadable pointer names the reason, not <none>" =
  test_pointer_report_unreadable_names_the_reason ()
;;

let%test "pointer_report: an unreadable read is not reported as a named release" =
  test_verify_pointer_reports_an_unreadable_read ()
;;

let%test "pointer_report: a read-back release is confirmed" =
  test_verify_pointer_confirms_the_read_release ()
;;

let%test "pointer_report: a read release that differs is a mismatch" =
  test_verify_pointer_reports_a_read_mismatch ()
;;

let%test "rollback_transaction: unreadable applied state skips every mutation (BUG-078)" =
  test_execute_applied_state_unavailable_skips_every_mutation ()
;;

let%test
    "rollback_transaction: lost ownership after apply skips prune and pointer (BUG-071)"
  =
  test_execute_lost_ownership_after_apply_skips_prune_and_pointer ()
;;

let%test "rollback_transaction: lost ownership after prune skips pointer move (BUG-071)" =
  test_execute_lost_ownership_after_prune_skips_pointer_move ()
;;

let%test "rollback_transaction: success calls every dep in order" =
  test_execute_success_calls_every_dep_in_order ()
;;

let%test "rollback_transaction: apply-mode refusal calls no dep" =
  test_execute_apply_mode_refusal_calls_no_deps ()
;;

let%test "rollback_transaction: migration boundary refusal calls no dep" =
  test_execute_migration_boundary_refusal_calls_no_deps ()
;;

let%test "rollback_transaction: unexpected workload triggers prune then completes" =
  test_execute_unexpected_workload_triggers_prune_then_completes ()
;;

let%test "rollback_transaction: prune failure skips pointer move" =
  test_execute_prune_failure_skips_pointer_move ()
;;

let%test "rollback_transaction: missing workload skips prune and pointer move" =
  test_execute_missing_workload_skips_prune_and_pointer_move ()
;;

let%test "rollback_transaction: a failed apply reports the incomplete rollback (BUG-119)" =
  test_execute_apply_failure_reports_the_incomplete_rollback ()
;;

let%test "rollback_transaction: mismatched workload skips prune and pointer move" =
  test_execute_mismatched_workload_skips_prune_and_pointer_move ()
;;

let%test
    "rollback_transaction: the restored release's consumer groups are recorded last \
     (BUG-090)"
  =
  test_execute_records_the_restored_consumer_groups ()
;;

let%test
    "rollback_transaction: a failed verification leaves the guard record alone (BUG-090)"
  =
  test_execute_leaves_the_guard_alone_when_verification_fails ()
;;

let%test "rollback_transaction: an uncorrected guard record is reported (BUG-090)" =
  test_execute_reports_an_uncorrected_guard_record ()
;;

(* #4: a recorded ExternalSecret the plan no longer declares is an orphan — whether its
   workload is gone or its last external key was removed. *)
let test_orphaned_external_secrets_are_the_undeclared_ones () =
  let evidence =
    [ { Sol_cli_release_id.resource = "deployment"
      ; namespace = "myapp-payments"
      ; name = "charge-svc"
      ; uid = "d-1"
      }
    ; { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "charge-svc-external-secrets"
      ; uid = "es-1"
      }
    ; { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "orders-svc-external-secrets"
      ; uid = "es-2"
      }
    ]
  in
  let declared =
    [ { Sol_cli_workload_ownership.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "charge-svc-external-secrets"
      }
    ]
  in
  let orphans = Sol_cli_rollback.orphaned_external_secret_evidence ~evidence ~declared in
  Windtrap.equal
    Windtrap.int
    ~msg:"only the ExternalSecret the plan does not declare is an orphan"
    1
    (List.length orphans);
  Windtrap.equal
    Windtrap.string
    ~msg:"the orphan is the undeclared ExternalSecret"
    "orders-svc-external-secrets"
    (List.hd orphans).name
;;

let test_prune_external_secrets_removes_only_the_uid_match () =
  let evidence =
    [ { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "charge-svc-external-secrets"
      ; uid = "es-1"
      }
    ; { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "orders-svc-external-secrets"
      ; uid = "es-2"
      }
    ; { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "refund-svc-external-secrets"
      ; uid = "es-3"
      }
    ]
  in
  with_fake_kubectl
    {|#!/bin/sh
case "$3" in
  get)
    case "$5" in
      charge-svc-external-secrets) printf '%s' es-1 ;;
      orders-svc-external-secrets) printf '%s' something-else ;;
      *) printf '%s\n' 'Error from server (Forbidden): externalsecrets "refund-svc-external-secrets" is forbidden' >&2; exit 1 ;;
    esac ;;
  delete) exit 0 ;;
  *) exit 1 ;;
esac
|}
    (fun () ->
       match
         Sol_cli_rollback.prune_external_secrets
           ~ctx:Sol_cli_kube_destination.local_context
           ~evidence
           ~declared:[]
       with
       | Error msg -> Windtrap.fail msg
       | Ok report ->
         let removed name =
           List.exists
             (fun (t : Sol_cli_rollback.prune_target) -> String.equal t.name name)
             report.removed_external_secrets
         in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the ExternalSecret whose live UID matches is removed"
           true
           (removed "charge-svc-external-secrets");
         Windtrap.equal
           Windtrap.bool
           ~msg:"a foreign ExternalSecret (live UID differs) is retained"
           false
           (removed "orders-svc-external-secrets");
         Windtrap.equal
           Windtrap.bool
           ~msg:"an unobservable ExternalSecret is retained"
           false
           (removed "refund-svc-external-secrets"))
;;

let%test "external_secret_prune: an undeclared ExternalSecret is an orphan" =
  test_orphaned_external_secrets_are_the_undeclared_ones ()
;;

let%test "external_secret_prune: only the UID match is removed" =
  test_prune_external_secrets_removes_only_the_uid_match ()
;;
