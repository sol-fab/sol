let facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let matches_regex re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
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

let namespace_string ~workspace ~domain =
  namespace ~workspace ~domain |> Sol_cli_deployment_plan.namespace_to_string
;;

let topic_name_exn s =
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Ok t -> t
  | Error e -> Windtrap.fail (Printf.sprintf "invalid topic name %S: %s" s e)
;;

let migration_file_exn s =
  match Sol_cli_plan_ids.Migration_file.of_string s with
  | Ok t -> t
  | Error e -> Windtrap.fail (Printf.sprintf "invalid migration file %S: %s" s e)
;;

let schema_subject_exn s =
  match Sol_cli_plan_ids.Schema_subject.of_string s with
  | Ok t -> t
  | Error e -> Windtrap.fail (Printf.sprintf "invalid schema subject %S: %s" s e)
;;

let consumer_group_exn s =
  match Sol_cli_plan_ids.Consumer_group.of_string s with
  | Ok t -> t
  | Error e -> Windtrap.fail (Printf.sprintf "invalid consumer group %S: %s" s e)
;;

let check_ids label stringify expected got =
  let expected_strs = List.map stringify expected in
  let got_strs = List.map stringify got in
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg:label expected_strs got_strs
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

let test_k8s_name_underscores () =
  check_string
    "underscore to hyphen"
    "charge-svc"
    (Sol_cli_kubernetes_name.normalize "charge_svc")
;;

let test_k8s_name_worker () =
  check_string
    "worker suffix"
    "notify-worker"
    (Sol_cli_kubernetes_name.normalize "notify_worker")
;;

let test_k8s_name_no_underscores () =
  check_string
    "no underscores unchanged"
    "ordersvc"
    (Sol_cli_kubernetes_name.normalize "ordersvc")
;;

let test_namespace () =
  check_string
    "namespace format"
    "myapp-payments"
    (namespace_string ~workspace:"myapp" ~domain:"payments")
;;

let test_namespace_comms () =
  check_string
    "namespace comms domain"
    "pluto-comms"
    (namespace_string ~workspace:"pluto" ~domain:"comms")
;;

let test_namespace_sanitizes_workspace () =
  check_string
    "namespace sanitizes workspace"
    "comet-kafka-comms"
    (namespace_string ~workspace:"comet_kafka" ~domain:"comms")
;;

let test_namespace_uppercased_workspace () =
  check_string
    "uppercase workspace lowercased"
    "myapp-payments"
    (namespace_string ~workspace:"MyApp" ~domain:"payments")
;;

let test_k8s_name_rejects_invalid_characters () =
  match Sol_cli_deployment_plan.k8s_name_result "charge.svc" with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; value; message }) ->
    check_string "field" "k8s_name" field;
    check_string "value" "charge.svc" value;
    assert (matches_regex (Str.regexp "lowercase alphanumeric") message)
  | Ok _ -> Windtrap.fail "expected invalid k8s name"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
    Windtrap.fail "expected name error"
;;

let test_k8s_name_rejects_empty () =
  match Sol_cli_deployment_plan.k8s_name_result "" with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { message; _ }) ->
    assert (matches_regex (Str.regexp "1 and 63") message)
  | Ok _ -> Windtrap.fail "expected empty k8s name to fail"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
    Windtrap.fail "expected name error"
;;

let test_k8s_name_rejects_overlong () =
  let name = String.make 64 'a' in
  match Sol_cli_deployment_plan.k8s_name_result name with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { value; message; _ }) ->
    check_string "value" name value;
    assert (matches_regex (Str.regexp "1 and 63") message)
  | Ok _ -> Windtrap.fail "expected overlong k8s name to fail"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
    Windtrap.fail "expected name error"
;;

let test_namespace_rejects_invalid_domain () =
  match
    Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain:"payments.api"
  with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; value; message }) ->
    check_string "field" "namespace" field;
    check_string "value" "myapp-payments.api" value;
    assert (matches_regex (Str.regexp "lowercase alphanumeric") message)
  | Ok _ -> Windtrap.fail "expected invalid namespace"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
    Windtrap.fail "expected name error"
;;

let test_namespace_rejects_overlong () =
  match
    Sol_cli_deployment_plan.namespace_result
      ~workspace:(String.make 40 'a')
      ~domain:(String.make 30 'b')
  with
  | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name { field; message; _ }) ->
    check_string "field" "namespace" field;
    assert (matches_regex (Str.regexp "1 and 63") message)
  | Ok _ -> Windtrap.fail "expected overlong namespace"
  | Error (Sol_cli_deployment_plan.Toml_error _) -> Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
    Windtrap.fail "expected name error"
  | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
    Windtrap.fail "expected name error"
;;

let test_image_ref_local () =
  check_string
    "local k3d image ref"
    "sol-registry:5000/myapp/charge-svc:abc123"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"sol-registry:5000"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"abc123")
;;

let test_image_ref_ecr () =
  check_string
    "ECR image ref"
    "123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/charge-svc:sha-deadbeef"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"sha-deadbeef")
;;

let test_image_ref_push_registry () =
  check_string
    "localhost push registry"
    "localhost:5000/myapp/charge-svc:dev"
    (Sol_cli_deployment_plan.image_ref
       ~registry:"localhost:5000"
       ~workspace:"myapp"
       ~k8s_name:(k8s_name "charge-svc")
       ~tag:"dev")
;;

let sample_plan () : Sol_cli_deployment_plan.t =
  let env : Sol_cli_deployment_plan.env_config =
    { name = "production"
    ; mode = Sol_cli_deployment_plan.Customer_cloud
    ; registry = "123.dkr.ecr.us-east-1.amazonaws.com"
    ; image_tag = "abc1234"
    ; env = Some "prod"
    ; region = Some "us-east-1"
    ; base_domain = Some "example.com"
    ; cluster_issuer = "letsencrypt-prod"
    }
  in
  let svc : Sol_cli_deployment_plan.service_spec =
    { domain = "orders"
    ; source_name = "charge_svc"
    ; k8s_name = k8s_name "charge-svc"
    ; namespace = namespace ~workspace:"myworkspace" ~domain:"orders"
    ; primitive = Sol_cli_deployment_plan.Svc
    ; source_dir = "/tmp/app/orders/charge_svc"
    ; image = "123.dkr.ecr.us-east-1.amazonaws.com/myworkspace/charge-svc:abc1234"
    ; config = [ "LOG_LEVEL", "info"; "REGION", "us-east-1" ]
    ; secrets = [ "DB_PASSWORD", "super-secret-value"; "API_KEY", "also-secret" ]
    ; secret_sources = []
    ; build_secret_keys = [ "BUILD_REGISTRY_TOKEN" ]
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
    ; rollout_strategy = None
    ; ingress_host = None
    ; ingress_path = None
    ; cluster_issuer = "letsencrypt-prod"
    ; calls = []
    ; called_by = []
    ; extra_labels = []
    ; progressive_delivery = None
    ; db_uses_target = None
    ; db_ca_target = None
    }
  in
  { workspace = "myworkspace"
  ; environment = env
  ; services = [ svc ]
  ; topics = [ topic_name_exn "sol-demo-orders" ]
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id = release_id_of_test
  ; requested_scope = "workspace"
  ; platform_shape = Sol_cli_profile.Local
  ; profile = None
  ; contract = []
  ; contract_changes = []
  }
;;

let test_to_json_valid_json () =
  let plan = sample_plan () in
  let json = Sol_cli_deployment_plan.to_json plan in
  let s = Yojson.Safe.to_string json in
  let _ = Yojson.Safe.from_string s in
  ()
;;

let test_to_json_deterministic () =
  let plan = sample_plan () in
  let s1 = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  let s2 = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  Windtrap.equal Windtrap.string ~msg:"byte-identical" s1 s2
;;

let test_to_json_no_secret_values () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  if
    String.length (Str.global_replace (Str.regexp "super-secret-value") "" s)
    < String.length s
  then Windtrap.fail "secret value 'super-secret-value' leaked into plan JSON";
  if String.length (Str.global_replace (Str.regexp "also-secret") "" s) < String.length s
  then Windtrap.fail "secret value 'also-secret' leaked into plan JSON"
;;

let test_to_json_env_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"env":"prod"|} in
    matches_regex re s)
;;

let test_to_json_secret_keys_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp "DB_PASSWORD" in
    matches_regex re s);
  assert (
    let re = Str.regexp "API_KEY" in
    matches_regex re s)
;;

let test_to_json_build_secret_keys_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp "BUILD_REGISTRY_TOKEN" in
    matches_regex re s)
;;

let test_to_json_config_values_present () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp "us-east-1" in
    matches_regex re s)
;;

let test_to_json_mode_strings () =
  let check_mode mode expected =
    let env : Sol_cli_deployment_plan.env_config =
      { name = "env"
      ; mode
      ; registry = "r"
      ; image_tag = "t"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      }
    in
    let plan : Sol_cli_deployment_plan.t =
      { workspace = "ws"
      ; environment = env
      ; services = []
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
      }
    in
    let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
    assert (
      let re = Str.regexp (Printf.sprintf {|"mode":"%s"|} expected) in
      matches_regex re s)
  in
  check_mode Sol_cli_deployment_plan.Local "local";
  check_mode Sol_cli_deployment_plan.Customer_cloud "customer_cloud";
  check_mode Sol_cli_deployment_plan.Sol_hosted "sol_hosted"
;;

let with_cwd dir f =
  let orig = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect f ~finally:(fun () -> Sys.chdir orig)
;;

let mkdirs path =
  let parts = String.split_on_char '/' path in
  let _ =
    List.fold_left
      (fun acc part ->
         let p = if acc = "" then part else acc ^ "/" ^ part in
         if p <> "" && not (Sys.file_exists p) then Unix.mkdir p 0o755;
         p)
      ""
      parts
  in
  ()
;;

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let loaded_facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let discover_topics_ok () = (loaded_facts ()).Sol_cli_workspace_model.topics

let test_discover_topics_rejects_misspelled_event_toml () =
  let tmp = Filename.temp_dir "sol_test_topics" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topic = ["payments.charged"]
|};
    match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
    | Ok _ -> Windtrap.fail "expected a misspelled event sol.toml to be an error"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the unknown key"
        true
        (Sol_cli_string.contains ~needle:"\"topic\"" e);
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the file"
        true
        (Sol_cli_string.contains ~needle:"events/payments/sol.toml" e))
;;

let test_discover_topics_finds_topic () =
  let tmp = Filename.temp_dir "sol_test_topics" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "topic found"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged" ]
      topics)
;;

let test_discover_topics_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_topics_nodir" "" in
  with_cwd tmp (fun () ->
    let topics = discover_topics_ok () in
    Windtrap.equal Windtrap.int ~msg:"empty without events dir" 0 (List.length topics))
;;

let test_discover_topics_multiple_topics_in_toml () =
  let tmp = Filename.temp_dir "sol_test_topics_multi" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged", "payments.refunded"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "multiple topics in one toml"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged"; topic_name_exn "payments.refunded" ]
      topics)
;;

let test_discover_topics_deduplicates () =
  let tmp = Filename.temp_dir "sol_test_topics_dedup" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/a";
    mkdirs "events/b";
    write_file
      "events/a/sol.toml"
      {|[service]
topics = ["dup.topic"]
|};
    write_file
      "events/b/sol.toml"
      {|[service]
topics = ["dup.topic"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "deduplicates"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "dup.topic" ]
      topics)
;;

let test_discover_topics_subdirectory () =
  let tmp = Filename.temp_dir "sol_test_topics_subdir" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "subdirectory topic found"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "payments.charged" ]
      topics)
;;

let test_discover_topics_top_level_toml () =
  let tmp = Filename.temp_dir "sol_test_topics_toplevel" "" in
  with_cwd tmp (fun () ->
    mkdirs "events";
    write_file
      "events/sol.toml"
      {|[service]
topics = ["top.event"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "top-level events/sol.toml"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "top.event" ]
      topics)
;;

let test_discover_topics_mixed_levels () =
  let tmp = Filename.temp_dir "sol_test_topics_mixed" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    mkdirs "events/orders";
    write_file
      "events/sol.toml"
      {|[service]
topics = ["top.event"]
|};
    write_file
      "events/payments/sol.toml"
      {|[service]
topics = ["payments.charged"]
|};
    write_file
      "events/orders/sol.toml"
      {|[service]
topics = ["orders.placed"]
|};
    let topics = discover_topics_ok () in
    check_ids
      "mixed top-level and subdir topics"
      Sol_cli_plan_ids.Topic_name.to_string
      [ topic_name_exn "orders.placed"
      ; topic_name_exn "payments.charged"
      ; topic_name_exn "top.event"
      ]
      topics)
;;

let test_discover_topics_no_false_positives_from_ml_files () =
  let tmp = Filename.temp_dir "sol_test_topics_fp" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file
      "events/payments/charged.ml"
      "(* let topic_name = \"commented.out.topic\" *)\n\
       let topic_name = Kafka_service.topic_name_exn \"payments.charged\"\n\
       let s = \"let topic_name = not-a-real-topic\"\n";
    let topics = discover_topics_ok () in
    Windtrap.equal
      Windtrap.int
      ~msg:"ml files are not scanned — no false positives from comments or strings"
      0
      (List.length topics))
;;

let test_discover_migrations_finds_sql () =
  let tmp = Filename.temp_dir "sol_test_mig" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/001_init.sql" "CREATE TABLE foo (id INT);";
    let migs = Sol_cli_workspace_model.migration_files (loaded_facts ()) in
    check_ids
      "migration found"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql" ]
      migs)
;;

let test_discover_migrations_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_mig_nodir" "" in
  with_cwd tmp (fun () ->
    let migs = Sol_cli_workspace_model.migration_files (loaded_facts ()) in
    Windtrap.equal
      Windtrap.int
      ~msg:"empty without db/migrations dir"
      0
      (List.length migs))
;;

let test_discover_migrations_sorted () =
  let tmp = Filename.temp_dir "sol_test_mig_sorted" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/003_add_index.sql" "";
    write_file "db/migrations/001_init.sql" "";
    write_file "db/migrations/002_add_col.sql" "";
    let migs = Sol_cli_workspace_model.migration_files (loaded_facts ()) in
    check_ids
      "migrations sorted"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql"
      ; migration_file_exn "002_add_col.sql"
      ; migration_file_exn "003_add_index.sql"
      ]
      migs)
;;

let test_discover_migrations_ignores_non_sql () =
  let tmp = Filename.temp_dir "sol_test_mig_nosql" "" in
  with_cwd tmp (fun () ->
    mkdirs "db/migrations";
    write_file "db/migrations/001_init.sql" "";
    write_file "db/migrations/README.md" "";
    write_file "db/migrations/seed.sh" "";
    let migs = Sol_cli_workspace_model.migration_files (loaded_facts ()) in
    check_ids
      "only sql files"
      Sol_cli_plan_ids.Migration_file.to_string
      [ migration_file_exn "001_init.sql" ]
      migs)
;;

let test_schema_subjects_derived () =
  let tmp = Filename.temp_dir "sol_test_subjects" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    write_file "events/payments/charged.ml" "(* stub *)";
    let subjects = (loaded_facts ()).Sol_cli_workspace_model.schema_subjects in
    let strs = List.map Sol_cli_plan_ids.Schema_subject.to_string subjects in
    Windtrap.equal
      Windtrap.bool
      ~msg:"payments.Charged present"
      true
      (List.mem "payments.Charged" strs))
;;

let test_schema_subjects_multiple_domains () =
  let tmp = Filename.temp_dir "sol_test_subjects_multi" "" in
  with_cwd tmp (fun () ->
    mkdirs "events/payments";
    mkdirs "events/comms";
    write_file "events/payments/charged.ml" "(* stub *)";
    write_file "events/comms/notification.ml" "(* stub *)";
    let subjects = (loaded_facts ()).Sol_cli_workspace_model.schema_subjects in
    check_ids
      "sorted multi-domain"
      Sol_cli_plan_ids.Schema_subject.to_string
      [ schema_subject_exn "comms.Notification"; schema_subject_exn "payments.Charged" ]
      subjects)
;;

let test_schema_subjects_top_level_ml () =
  let tmp = Filename.temp_dir "sol_test_subjects_top" "" in
  with_cwd tmp (fun () ->
    mkdirs "events";
    write_file "events/order.ml" "(* stub *)";
    let subjects = (loaded_facts ()).Sol_cli_workspace_model.schema_subjects in
    let strs = List.map Sol_cli_plan_ids.Schema_subject.to_string subjects in
    Windtrap.equal
      Windtrap.bool
      ~msg:"top-level file as stem"
      true
      (List.mem "order" strs))
;;

let test_schema_subjects_empty_when_no_dir () =
  let tmp = Filename.temp_dir "sol_test_subjects_nodir" "" in
  with_cwd tmp (fun () ->
    let subjects = (loaded_facts ()).Sol_cli_workspace_model.schema_subjects in
    Windtrap.equal Windtrap.int ~msg:"empty without events dir" 0 (List.length subjects))
;;

let make_worker_spec name domain =
  { Sol_cli_deployment_plan.domain
  ; source_name = name
  ; k8s_name = k8s_name name
  ; namespace = namespace ~workspace:"ws" ~domain
  ; primitive = Sol_cli_deployment_plan.Worker
  ; source_dir = domain ^ "/" ^ name
  ; image = "reg/ws/" ^ name ^ ":t"
  ; config = []
  ; secrets = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
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
  ; db_uses_target = None
  ; db_ca_target = None
  }
;;

let make_svc_spec name domain =
  { (make_worker_spec name domain) with primitive = Sol_cli_deployment_plan.Svc }
;;

let kafka_config service_names : Sol_cli_config.t =
  { project = Some "ws"
  ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
  ; resources =
      [ { name = "events"
        ; typ = Some "kafka"
        ; partition_key = None
        ; sort_key = None
        ; indexes = []
        ; size = None
        ; omit = false
        ; binding = None
        }
      ]
  ; services =
      service_names
      |> List.map (fun name ->
        { Sol_cli_config.name
        ; typ = None
        ; path = None
        ; uses = [ "events" ]
        ; scale_min = None
        ; scale_max = None
        ; language = None
        ; omit = false
        })
  }
;;

let test_consumer_groups_derived () =
  let worker = make_worker_spec "notify_worker" "comms" in
  let groups =
    Sol_cli_deployment_plan.derive_consumer_groups
      ~declared:(Sol_cli_config.declared_of_config (kafka_config [ "notify_worker" ]))
      "myworkspace"
      [ worker ]
  in
  check_ids
    "worker produces consumer group"
    Sol_cli_plan_ids.Consumer_group.to_string
    [ consumer_group_exn "myworkspace.comms.notify_worker" ]
    groups
;;

let test_consumer_groups_excludes_svc () =
  let worker = make_worker_spec "notify_worker" "comms" in
  let svc = make_svc_spec "charge_svc" "payments" in
  let groups =
    Sol_cli_deployment_plan.derive_consumer_groups
      ~declared:
        (Sol_cli_config.declared_of_config
           (kafka_config [ "notify_worker"; "charge_svc" ]))
      "ws"
      [ worker; svc ]
  in
  Windtrap.equal Windtrap.int ~msg:"only one group (worker only)" 1 (List.length groups)
;;

let test_consumer_groups_sorted () =
  let w1 = make_worker_spec "b_worker" "comms" in
  let w2 = make_worker_spec "a_worker" "comms" in
  let groups =
    Sol_cli_deployment_plan.derive_consumer_groups
      ~declared:
        (Sol_cli_config.declared_of_config (kafka_config [ "a_worker"; "b_worker" ]))
      "ws"
      [ w1; w2 ]
  in
  check_ids
    "consumer groups sorted"
    Sol_cli_plan_ids.Consumer_group.to_string
    [ consumer_group_exn "ws.comms.a_worker"; consumer_group_exn "ws.comms.b_worker" ]
    groups
;;

let test_to_json_rollout_strategy () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"rolling_update"|} in
    matches_regex re s)
;;

let test_to_json_rollout_strategy_recreate () =
  let plan = sample_plan () in
  let svc_recreate =
    { (List.hd plan.services) with rollout_strategy = Some Sol_cli_toml.Recreate }
  in
  let plan2 = { plan with services = [ svc_recreate ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"recreate"|} in
    matches_regex re s)
;;

let test_to_json_rollout_strategy_canary () =
  let plan = sample_plan () in
  let svc_canary =
    { (List.hd plan.services) with
      progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  let plan2 = { plan with services = [ svc_canary ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"canary"|} in
    matches_regex re s)
;;

let test_to_json_rollout_strategy_blue_green () =
  let plan = sample_plan () in
  let svc_bg =
    { (List.hd plan.services) with progressive_delivery = Some Sol_cli_toml.Blue_green }
  in
  let plan2 = { plan with services = [ svc_bg ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  assert (
    let re = Str.regexp {|"rollout_strategy":"blue_green"|} in
    matches_regex re s)
;;

let check_effective_rollout_strategy label expected svc =
  let strategy =
    svc
    |> Sol_cli_deployment_plan.effective_rollout_strategy
    |> Sol_cli_deployment_plan.effective_rollout_strategy_to_string
  in
  check_string label expected strategy
;;

let test_effective_rollout_strategy_defaults_to_rolling_update () =
  let svc = List.hd (sample_plan ()).services in
  check_effective_rollout_strategy "default" "rolling_update" svc
;;

let test_effective_rollout_strategy_recreate () =
  let svc =
    { (List.hd (sample_plan ()).services) with
      rollout_strategy = Some Sol_cli_toml.Recreate
    }
  in
  check_effective_rollout_strategy "recreate" "recreate" svc
;;

let test_effective_rollout_strategy_progressive_delivery_precedence () =
  let svc =
    { (List.hd (sample_plan ()).services) with
      rollout_strategy = Some Sol_cli_toml.Recreate
    ; progressive_delivery = Some Sol_cli_toml.Blue_green
    }
  in
  check_effective_rollout_strategy "progressive precedence" "blue_green" svc
;;

let test_summary_uses_effective_rollout_strategy () =
  let plan = sample_plan () in
  let svc =
    { (List.hd plan.services) with
      progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  let plan = { plan with services = [ svc ] } in
  let summary = Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan in
  assert (
    let re = Str.regexp {|rollout=canary|} in
    matches_regex re summary)
;;

let fact ?(key = None) ?(schema_digest = "d1") ~topic ~partitions subject =
  { Sol_cli_release_id.subject; topic; partitions; key; schema_digest }
;;

let check_no_change label plan observed =
  match Sol_cli_deployment_plan.with_observed_contract ~observed plan with
  | Error e ->
    Windtrap.fail
      (Printf.sprintf
         "%s: unexpected refusal: %s"
         label
         (Sol_cli_deployment_plan.plan_error_to_string e))
  | Ok enriched ->
    Windtrap.equal Windtrap.int ~msg:label 0 (List.length enriched.contract_changes)
;;

let test_contract_change_is_rendered_observed_to_desired () =
  let desired =
    [ fact ~topic:"orders-charges" ~partitions:6 ~key:(Some "id") "orders.Charged" ]
  in
  let observed =
    [ fact ~topic:"orders-charges" ~partitions:3 ~key:(Some "id") "orders.Charged" ]
  in
  let plan = { (sample_plan ()) with contract = desired } in
  match Sol_cli_deployment_plan.with_observed_contract ~observed plan with
  | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e)
  | Ok enriched ->
    Windtrap.equal
      Windtrap.int
      ~msg:"one change"
      1
      (List.length enriched.contract_changes);
    let rendered =
      Sol_cli_deployment_plan.contract_change_to_string
        (List.hd enriched.contract_changes)
    in
    assert (Sol_cli_string.contains ~needle:"partitions 3 → 6" rendered);
    let summary = Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary enriched in
    assert (Sol_cli_string.contains ~needle:"contract changes:" summary);
    assert (Sol_cli_string.contains ~needle:"partitions 3 → 6" summary);
    let json = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json enriched) in
    assert (Sol_cli_string.contains ~needle:"partitions 3 → 6" json)
;;

let test_contract_noop_reports_nothing () =
  let plan =
    { (sample_plan ()) with contract = [ fact ~topic:"t" ~partitions:3 "t.A" ] }
  in
  check_no_change
    "an unchanged contract reports no change"
    plan
    [ fact ~topic:"t" ~partitions:3 "t.A" ]
;;

let test_contract_fails_closed_on_incompatible_change () =
  let base ?(contract = [ fact ~topic:"t" ~partitions:3 "t.A" ]) () =
    { (sample_plan ()) with contract }
  in
  let refused label plan observed needle =
    match Sol_cli_deployment_plan.with_observed_contract ~observed plan with
    | Ok _ -> Windtrap.fail (label ^ ": expected a refusal")
    | Error e ->
      let message = Sol_cli_deployment_plan.plan_error_to_string e in
      assert (Sol_cli_string.contains ~needle message)
  in
  refused
    "partition reduction"
    (base ())
    [ fact ~topic:"t" ~partitions:6 "t.A" ]
    "can only grow";
  refused
    "key change"
    (base ~contract:[ fact ~topic:"t" ~partitions:3 ~key:(Some "order_id") "t.A" ] ())
    [ fact ~topic:"t" ~partitions:3 ~key:(Some "id") "t.A" ]
    "record key changed";
  refused
    "topic rename"
    (base ~contract:[ fact ~topic:"t-new" ~partitions:3 "t.A" ] ())
    [ fact ~topic:"t-old" ~partitions:3 "t.A" ]
    "topic was renamed"
;;

let test_contract_added_removed_and_schema_are_reported () =
  let plan =
    { (sample_plan ()) with
      contract =
        [ fact ~topic:"b" ~partitions:3 ~schema_digest:"new" "t.B"
        ; fact ~topic:"c" ~partitions:1 "t.C"
        ]
    }
  in
  let observed =
    [ fact ~topic:"a" ~partitions:3 "t.A"
    ; fact ~topic:"b" ~partitions:3 ~schema_digest:"old" "t.B"
    ]
  in
  match Sol_cli_deployment_plan.with_observed_contract ~observed plan with
  | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e)
  | Ok enriched ->
    let rendered =
      List.map Sol_cli_deployment_plan.contract_change_to_string enriched.contract_changes
    in
    assert (
      List.exists
        (fun line -> Sol_cli_string.contains ~needle:"t.C  new topic c" line)
        rendered);
    assert (
      List.exists
        (fun line ->
           Sol_cli_string.contains ~needle:"t.A  topic a is no longer declared" line)
        rendered);
    assert (
      List.exists
        (fun line -> Sol_cli_string.contains ~needle:"schema old → new" line)
        rendered)
;;

let test_to_json_ingress_null_when_absent () =
  let plan = sample_plan () in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"ingress":null|} in
    matches_regex re s)
;;

let test_to_json_ingress_present () =
  let plan = sample_plan () in
  let svc_with_ingress =
    { (List.hd plan.services) with
      ingress_host = Some (hostname "example.com")
    ; ingress_path = Some (ingress_path "/api")
    }
  in
  let plan2 = { plan with services = [ svc_with_ingress ] } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan2) in
  List.iter
    (fun fragment -> assert (matches_regex (Str.regexp_string fragment) s))
    [ {|"ingress":{"host":"example.com","path":"/api"|}
    ; {|"tls":{"hosts":["example.com"],"secretName":"charge-svc-tls"}|}
    ; {|"cluster_issuer":"letsencrypt-prod"|}
    ; {|"cert-manager.io/cluster-issuer":"letsencrypt-prod"|}
    ; {|"nginx.ingress.kubernetes.io/ssl-redirect":"true"|}
    ]
;;

let test_to_json_schema_subjects_present () =
  let plan =
    { (sample_plan ()) with
      schema_subjects =
        [ schema_subject_exn "payments.Charged"; schema_subject_exn "comms.Notification" ]
    }
  in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"schema_subjects"|} in
    matches_regex re s);
  assert (
    let re = Str.regexp "payments.Charged" in
    matches_regex re s)
;;

let test_to_json_requested_scope_and_resolved_workloads () =
  let plan = { (sample_plan ()) with requested_scope = "payments" } in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp_string {|"requested_scope":"payments"|} in
    matches_regex re s);
  assert (
    let re =
      Str.regexp_string {|"resolved_workloads":[{"domain":"orders","name":"charge_svc"}]|}
    in
    matches_regex re s)
;;

let test_to_json_consumer_groups_present () =
  let plan =
    { (sample_plan ()) with
      consumer_groups = [ consumer_group_exn "myworkspace.comms.notify_worker" ]
    }
  in
  let s = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
  assert (
    let re = Str.regexp {|"consumer_groups"|} in
    matches_regex re s);
  assert (
    let re = Str.regexp "myworkspace.comms.notify_worker" in
    matches_regex re s)
;;

let test_of_services_result_surfaces_toml_parse_error () =
  let tmp = Filename.temp_dir "sol_test_plan_toml_error" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
    let env : Sol_cli_deployment_plan.env_config =
      { name = "local"
      ; mode = Sol_cli_deployment_plan.Local
      ; registry = "sol-registry:5000"
      ; image_tag = "dev"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      }
    in
    let service : Sol_cli_manifest.service =
      { domain = "payments"
      ; name = "charge_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/payments/charge_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env
        ~facts:(facts ())
        [ service ]
    with
    | Error
        (Sol_cli_deployment_plan.Toml_error (Sol_cli_toml.Validation { path; message }))
      ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"error path names the workload's sol.toml"
        true
        (Sol_cli_string.contains ~needle:"app/payments/charge_svc/sol.toml" path);
      assert (matches_regex (Str.regexp "unsupported rollout_strategy") message)
    | Ok _ -> Windtrap.fail "expected deployment-plan construction to return TOML error"
    | Error (Sol_cli_deployment_plan.Toml_error (Sol_cli_toml.Toml_syntax _)) ->
      Windtrap.fail "expected validation error, got syntax error"
    | Error (Sol_cli_deployment_plan.Invalid_kubernetes_name _) ->
      Windtrap.fail "expected TOML error, got Kubernetes name error"
    | Error (Sol_cli_deployment_plan.Invalid_service_call _) ->
      Windtrap.fail "expected TOML error, got service call error"
    | Error (Sol_cli_deployment_plan.Invalid_persistence _) ->
      Windtrap.fail "expected TOML error, got persistence error"
    | Error (Sol_cli_deployment_plan.Unsupported_availability _) ->
      Windtrap.fail "expected TOML error, got availability error"
    | Error (Sol_cli_deployment_plan.Incompatible_contract_change _) ->
      Windtrap.fail "expected TOML error, got contract-change error")
;;

let deploy_env : Sol_cli_deployment_plan.env_config =
  { name = "local"
  ; mode = Sol_cli_deployment_plan.Local
  ; registry = "sol-registry:5000"
  ; image_tag = "dev"
  ; env = None
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let charge_svc_service : Sol_cli_manifest.service =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = Sol_cli_manifest.Svc
  ; dir = "app/payments/charge_svc"
  }
;;

let worker_unit ~domain ~name : Sol_cli_manifest.service =
  { domain
  ; name
  ; primitive = Sol_cli_manifest.Worker
  ; dir = Printf.sprintf "app/%s/%s" domain name
  }
;;

let test_a_scoped_plan_carries_the_whole_workspace_group_set () =
  let tmp = Filename.temp_dir "sol_test_plan_scoped_groups" "" in
  with_cwd tmp (fun () ->
    let notify = worker_unit ~domain:"comms" ~name:"notify_worker" in
    let charge = worker_unit ~domain:"payments" ~name:"charge_worker" in
    List.iter
      (fun (s : Sol_cli_manifest.service) ->
         mkdirs s.dir;
         write_file (Filename.concat s.dir "sol.toml") "")
      [ notify; charge ];
    let declared =
      Sol_cli_config.declared_of_config
        (kafka_config [ "notify_worker"; "charge_worker" ])
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~facts:(facts ())
        ~declared
        ~inventory:[ notify; charge ]
        ~requested_scope:"comms"
        [ notify ]
    with
    | Ok plan ->
      check_ids
        "a scoped plan reports the workspace's complete group set, so the units it does \
         not deploy are not read as removals"
        Sol_cli_plan_ids.Consumer_group.to_string
        [ consumer_group_exn "myworkspace.comms.notify_worker"
        ; consumer_group_exn "myworkspace.payments.charge_worker"
        ]
        plan.Sol_cli_deployment_plan.consumer_groups
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_a_group_the_workspace_no_longer_declares_is_not_reported () =
  let tmp = Filename.temp_dir "sol_test_plan_removed_group" "" in
  with_cwd tmp (fun () ->
    let notify = worker_unit ~domain:"comms" ~name:"notify_worker" in
    mkdirs notify.dir;
    write_file (Filename.concat notify.dir "sol.toml") "";
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~facts:(facts ())
        ~declared:(Sol_cli_config.declared_of_config (kafka_config [ "notify_worker" ]))
        [ notify ]
    with
    | Ok plan ->
      check_ids
        "a group whose worker is gone from the workspace is reported as removed, which \
         is what the confirmation asks about"
        Sol_cli_plan_ids.Consumer_group.to_string
        [ consumer_group_exn "myworkspace.comms.notify_worker" ]
        plan.Sol_cli_deployment_plan.consumer_groups
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let resolved_config_with_scale ~name ~scale_min ~scale_max : Sol_cli_config.t =
  { project = None
  ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
  ; resources = []
  ; services =
      [ { name
        ; typ = None
        ; path = None
        ; uses = []
        ; scale_min
        ; scale_max
        ; language = None
        ; omit = false
        }
      ]
  }
;;

let replicas_of_sole_service plan =
  match plan.Sol_cli_deployment_plan.services with
  | [ s ] -> s.replicas
  | _ -> Windtrap.fail "expected exactly one service in plan"
;;

let test_sol_yml_scale_overrides_toml_replicas_on_resolved_target () =
  let tmp = Filename.temp_dir "sol_test_plan_scale_override" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"charge_svc" ~scale_min:None ~scale_max:(Some 5)
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~declared:(Sol_cli_config.declared_of_config resolved_config)
        [ charge_svc_service ]
    with
    | Ok plan ->
      Windtrap.equal
        Windtrap.int
        ~msg:"sol.yml scale_max wins"
        5
        (replicas_of_sole_service plan)
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_sol_yml_scale_falls_back_to_scale_min_when_no_max () =
  let tmp = Filename.temp_dir "sol_test_plan_scale_min" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"charge_svc" ~scale_min:(Some 3) ~scale_max:None
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~declared:(Sol_cli_config.declared_of_config resolved_config)
        [ charge_svc_service ]
    with
    | Ok plan ->
      Windtrap.equal
        Windtrap.int
        ~msg:"sol.yml scale_min used when no scale_max"
        3
        (replicas_of_sole_service plan)
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_no_resolved_config_uses_toml_replicas () =
  let tmp = Filename.temp_dir "sol_test_plan_no_resolved_config" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Ok plan ->
      Windtrap.equal
        Windtrap.int
        ~msg:"sol.toml replicas unchanged"
        2
        (replicas_of_sole_service plan)
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_no_matching_sol_yml_service_uses_toml_replicas () =
  let tmp = Filename.temp_dir "sol_test_plan_no_matching_service" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "[infra.scale]\nreplicas = 2\n";
    let resolved_config =
      resolved_config_with_scale ~name:"other_svc" ~scale_min:None ~scale_max:(Some 9)
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~declared:(Sol_cli_config.declared_of_config resolved_config)
        [ charge_svc_service ]
    with
    | Ok plan ->
      Windtrap.equal
        Windtrap.int
        ~msg:"no matching sol.yml service falls back to sol.toml"
        2
        (replicas_of_sole_service plan)
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_toml_volumes_carry_into_service_spec () =
  let tmp = Filename.temp_dir "sol_test_plan_volumes" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.volumes.data]\n\
       mount_path = \"/var/lib/data\"\n\
       size = \"10Gi\"\n\
       access_mode = \"ReadWriteOnce\"\n";
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    | Ok plan ->
      (match plan.services with
       | [ spec ] ->
         (match spec.volumes with
          | [ volume ] ->
            Windtrap.equal Windtrap.string ~msg:"volume name" "data" volume.name;
            Windtrap.equal
              Windtrap.string
              ~msg:"mount path"
              "/var/lib/data"
              volume.mount_path;
            Windtrap.equal Windtrap.string ~msg:"size" "10Gi" volume.size;
            Windtrap.equal
              Windtrap.bool
              ~msg:"access mode"
              true
              (volume.access_mode = Sol_cli_toml.ReadWriteOnce)
          | _ -> Windtrap.fail "expected exactly one volume")
       | _ -> Windtrap.fail "expected exactly one service"))
;;

let test_multi_replica_volume_fails_after_scale_resolution () =
  let tmp = Filename.temp_dir "sol_test_plan_volume_replicas" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.volumes.data]\nmount_path = \"/data\"\nsize = \"10Gi\"\n";
    let resolved_config =
      resolved_config_with_scale ~name:"charge_svc" ~scale_min:None ~scale_max:(Some 2)
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~declared:(Sol_cli_config.declared_of_config resolved_config)
        [ charge_svc_service ]
    with
    | Ok _ -> Windtrap.fail "expected a multi-replica volume to fail"
    | Error err ->
      Windtrap.equal
        Windtrap.string
        ~msg:"names the valid alternatives"
        "workload \"charge_svc\" has invalid persistence: volumes belong to one \
         interchangeable workload instance; set replicas = 1, or use managed storage \
         shared outside the workload"
        (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_zero_replica_volume_fails () =
  let tmp = Filename.temp_dir "sol_test_plan_zero_volume_replicas" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      "[infra.scale]\n\
       replicas = 0\n\
       [infra.volumes.data]\n\
       mount_path = \"/data\"\n\
       size = \"10Gi\"\n";
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Ok _ -> Windtrap.fail "expected a zero-replica volume to fail"
    | Error (Sol_cli_deployment_plan.Invalid_persistence _) -> ()
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let plan_for_fn toml =
  let tmp = Filename.temp_dir "sol_test_fn_sched" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/cron/report_fn";
    Option.iter (write_file "app/cron/report_fn/sol.toml") toml;
    let fn =
      { Sol_cli_manifest.domain = "cron"
      ; name = "report_fn"
      ; primitive = Sol_cli_manifest.Fn
      ; dir = "app/cron/report_fn"
      }
    in
    Sol_cli_deployment_plan.of_services_result
      ~facts:(facts ())
      ~workspace:"myworkspace"
      ~env:deploy_env
      [ fn ])
;;

let test_fn_schedule_comes_from_sol_toml () =
  match plan_for_fn (Some "[service]\nschedule = \"30 6 * * 1\"\n") with
  | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e)
  | Ok plan ->
    Windtrap.equal
      (Windtrap.list (Windtrap.option Windtrap.string))
      ~msg:"schedule from sol.toml"
      [ Some "30 6 * * 1" ]
      (plan.services
       |> List.map (fun (s : Sol_cli_deployment_plan.service_spec) -> s.schedule))
;;

let test_fn_without_schedule_is_a_plan_error toml () =
  match plan_for_fn toml with
  | Ok _ ->
    Windtrap.fail "a -fn without [service] schedule must not plan (hourly default)"
  | Error e ->
    let msg = Sol_cli_deployment_plan.plan_error_to_string e in
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the missing key"
      true
      (matches_regex (Str.regexp_string "[service] schedule is required") msg)
;;

let test_function_volume_fails () =
  let tmp = Filename.temp_dir "sol_test_plan_fn_volume" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_fn";
    write_file
      "app/payments/charge_fn/sol.toml"
      "[service]\n\
       schedule = \"0 3 * * *\"\n\n\
       [infra.volumes.data]\n\
       mount_path = \"/data\"\n\
       size = \"10Gi\"\n";
    let fn =
      { charge_svc_service with
        name = "charge_fn"
      ; primitive = Sol_cli_manifest.Fn
      ; dir = "app/payments/charge_fn"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ fn ]
    with
    | Ok _ -> Windtrap.fail "expected a function volume to fail"
    | Error err ->
      Windtrap.equal
        Windtrap.string
        ~msg:"names the supported alternative"
        "workload \"charge_fn\" has invalid persistence: function volumes are \
         unsupported; use managed storage"
        (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_service_calls_resolve_to_env_and_reverse_edge () =
  let tmp = Filename.temp_dir "sol_test_plan_calls" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    mkdirs "app/checkout/checkout_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      {|[service]
calls = ["checkout/checkout_svc"]
|};
    write_file "app/checkout/checkout_svc/sol.toml" "";
    let checkout_service : Sol_cli_manifest.service =
      { domain = "checkout"
      ; name = "checkout_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/checkout/checkout_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service; checkout_service ]
    with
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    | Ok plan ->
      (match plan.services with
       | [ caller; callee ] ->
         Windtrap.equal
           (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
           ~msg:"caller config"
           [ ( "CHECKOUT_SVC_URL"
             , "http://checkout-svc.myworkspace-checkout.svc.cluster.local" )
           ]
           caller.config;
         Windtrap.equal
           Windtrap.string
           ~msg:"the call names the callee's canonical unit as the token audience"
           "checkout/checkout-svc"
           (List.hd caller.calls).unit_id;
         Windtrap.equal Windtrap.int ~msg:"caller calls" 1 (List.length caller.calls);
         Windtrap.equal
           Windtrap.string
           ~msg:"the reverse edge names the caller's canonical unit for authorization"
           "payments/charge-svc"
           (List.hd callee.called_by).unit_id;
         Windtrap.equal
           Windtrap.int
           ~msg:"callee called_by"
           1
           (List.length callee.called_by)
       | _ -> Windtrap.fail "expected two service specs"))
;;

let test_unknown_service_call_fails () =
  let tmp = Filename.temp_dir "sol_test_plan_bad_call" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      {|[service]
calls = ["checkout/missing_svc"]
|};
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service ]
    with
    | Error (Sol_cli_deployment_plan.Invalid_service_call { message; _ }) ->
      assert (matches_regex (Str.regexp "target service not found") message)
    | Ok _ -> Windtrap.fail "expected invalid service call"
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_scoped_call_resolves_from_the_inventory () =
  let tmp = Filename.temp_dir "sol_test_plan_inventory_call" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    mkdirs "app/checkout/checkout_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      {|[service]
calls = ["checkout/checkout_svc"]
|};
    write_file "app/checkout/checkout_svc/sol.toml" "";
    let checkout_service : Sol_cli_manifest.service =
      { domain = "checkout"
      ; name = "checkout_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/checkout/checkout_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~inventory:[ charge_svc_service; checkout_service ]
        [ charge_svc_service ]
    with
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    | Ok plan ->
      Windtrap.equal
        Windtrap.int
        ~msg:"the selection is deployed unchanged -- no transitive widening"
        1
        (List.length plan.services);
      (match plan.services with
       | [ caller ] ->
         Windtrap.equal
           (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
           ~msg:"the caller resolves the URL of the callee it did not select"
           [ ( "CHECKOUT_SVC_URL"
             , "http://checkout-svc.myworkspace-checkout.svc.cluster.local" )
           ]
           caller.config
       | _ -> Windtrap.fail "expected exactly one service spec"))
;;

let test_unknown_service_call_fails_and_names_the_units () =
  let tmp = Filename.temp_dir "sol_test_plan_inventory_bad_call" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    mkdirs "app/checkout/checkout_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      {|[service]
calls = ["checkout/checkout_svcc"]
|};
    write_file "app/checkout/checkout_svc/sol.toml" "";
    let checkout_service : Sol_cli_manifest.service =
      { domain = "checkout"
      ; name = "checkout_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/checkout/checkout_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~inventory:[ charge_svc_service; checkout_service ]
        [ charge_svc_service ]
    with
    | Error (Sol_cli_deployment_plan.Invalid_service_call { ref; message; _ }) ->
      Windtrap.equal
        Windtrap.string
        ~msg:"the reference as written"
        "checkout/checkout_svcc"
        ref;
      assert (matches_regex (Str.regexp_string "target service not found") message);
      assert (matches_regex (Str.regexp_string "checkout_svcc") message);
      assert (matches_regex (Str.regexp_string "workspace units:") message);
      assert (matches_regex (Str.regexp_string "checkout/checkout_svc") message)
    | Ok _ -> Windtrap.fail "expected a misspelled call target to fail"
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let network_policy_doc workload =
  Str.split (Str.regexp_string "\n---") workload
  |> List.find_opt (fun block ->
    matches_regex (Str.regexp_string "kind: NetworkPolicy") block)
  |> Option.value ~default:""
;;

let rendered_workload spec =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myworkspace"
      ~release_id:release_id_of_test
      spec
  with
  | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
  | Error message -> Windtrap.fail ("render_spec failed: " ^ message)
;;

let test_a_scoped_callee_keeps_its_cross_domain_caller_ingress () =
  let tmp = Filename.temp_dir "sol_test_plan_caller_ingress" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    mkdirs "app/orders/order_svc";
    write_file "app/payments/charge_svc/sol.toml" "";
    write_file
      "app/orders/order_svc/sol.toml"
      {|[service]
calls = ["payments/charge_svc"]
|};
    let order_service : Sol_cli_manifest.service =
      { domain = "orders"
      ; name = "order_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/orders/order_svc"
      }
    in
    let plan ?(selected = [ charge_svc_service ]) () =
      match
        Sol_cli_deployment_plan.of_services_result
          ~facts:(facts ())
          ~workspace:"myworkspace"
          ~env:deploy_env
          ~inventory:[ charge_svc_service; order_service ]
          ~requested_scope:"payments"
          selected
      with
      | Ok plan -> plan
      | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    in
    let callee plan =
      match
        List.find_opt
          (fun (spec : Sol_cli_deployment_plan.service_spec) ->
             spec.source_name = "charge_svc")
          plan.Sol_cli_deployment_plan.services
      with
      | Some callee -> callee
      | None -> Windtrap.fail "the plan did not deploy the callee"
    in
    let ingress_of plan =
      let callee = callee plan in
      let policy = network_policy_doc (rendered_workload callee) in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the rendered network policy allows the caller's namespace"
        true
        (matches_regex
           (Str.regexp_string "kubernetes.io/metadata.name: myworkspace-orders")
           policy);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and the caller's pod selector"
        true
        (matches_regex (Str.regexp_string "app: order-svc") policy);
      Windtrap.equal
        Windtrap.int
        ~msg:"the callee keeps the cross-domain caller that was not selected"
        1
        (List.length callee.Sol_cli_deployment_plan.called_by);
      policy
    in
    let scoped_plan = plan () in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"a scoped deploy still deploys only the callee"
      [ "charge_svc" ]
      (List.map
         (fun (spec : Sol_cli_deployment_plan.service_spec) -> spec.source_name)
         scoped_plan.Sol_cli_deployment_plan.services);
    let scoped = ingress_of scoped_plan in
    let full = ingress_of (plan ~selected:[ charge_svc_service; order_service ] ()) in
    Windtrap.equal
      Windtrap.string
      ~msg:"a full plan renders the same ingress edge"
      full
      scoped)
;;

let test_service_call_env_conflict_fails () =
  let tmp = Filename.temp_dir "sol_test_plan_call_env_conflict" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    mkdirs "app/checkout/checkout_svc";
    write_file
      "app/payments/charge_svc/sol.toml"
      {|[service]
calls = ["checkout/checkout_svc"]

[infra.env]
config = { CHECKOUT_SVC_URL = "http://example.invalid" }
|};
    write_file "app/checkout/checkout_svc/sol.toml" "";
    let checkout_service : Sol_cli_manifest.service =
      { domain = "checkout"
      ; name = "checkout_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/checkout/checkout_svc"
      }
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:deploy_env
        [ charge_svc_service; checkout_service ]
    with
    | Error (Sol_cli_deployment_plan.Invalid_service_call { message; _ }) ->
      assert (matches_regex (Str.regexp "conflicts") message)
    | Ok _ -> Windtrap.fail "expected invalid service call"
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
;;

let test_topic_name_valid () =
  match Sol_cli_plan_ids.Topic_name.of_string "payments.charged" with
  | Ok t ->
    check_string
      "round-trips"
      "payments.charged"
      (Sol_cli_plan_ids.Topic_name.to_string t)
  | Error e -> Windtrap.fail e
;;

let test_topic_name_empty_fails () =
  match Sol_cli_plan_ids.Topic_name.of_string "" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected empty topic name to fail"
;;

let test_topic_name_too_long_fails () =
  let s = String.make 250 'a' in
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected overlong topic name to fail"
;;

let test_topic_name_invalid_char_fails () =
  match Sol_cli_plan_ids.Topic_name.of_string "bad name!" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected topic name with space/bang to fail"
;;

let test_topic_name_max_length_ok () =
  let s = String.make 249 'a' in
  match Sol_cli_plan_ids.Topic_name.of_string s with
  | Ok _ -> ()
  | Error e -> Windtrap.fail e
;;

let test_migration_file_valid () =
  match Sol_cli_plan_ids.Migration_file.of_string "001_init.sql" with
  | Ok t ->
    check_string
      "round-trips"
      "001_init.sql"
      (Sol_cli_plan_ids.Migration_file.to_string t)
  | Error e -> Windtrap.fail e
;;

let test_migration_file_empty_fails () =
  match Sol_cli_plan_ids.Migration_file.of_string "" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected empty migration file to fail"
;;

let test_migration_file_not_sql_fails () =
  match Sol_cli_plan_ids.Migration_file.of_string "001_init.sh" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected non-.sql migration file to fail"
;;

let test_schema_subject_valid () =
  match Sol_cli_plan_ids.Schema_subject.of_string "payments.Charged" with
  | Ok t ->
    check_string
      "round-trips"
      "payments.Charged"
      (Sol_cli_plan_ids.Schema_subject.to_string t)
  | Error e -> Windtrap.fail e
;;

let test_schema_subject_empty_fails () =
  match Sol_cli_plan_ids.Schema_subject.of_string "" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected empty schema subject to fail"
;;

let test_consumer_group_valid () =
  match Sol_cli_plan_ids.Consumer_group.of_string "ws.comms.notify_worker" with
  | Ok t ->
    check_string
      "round-trips"
      "ws.comms.notify_worker"
      (Sol_cli_plan_ids.Consumer_group.to_string t)
  | Error e -> Windtrap.fail e
;;

let test_consumer_group_empty_fails () =
  match Sol_cli_plan_ids.Consumer_group.of_string "" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "expected empty consumer group to fail"
;;

let%test "k8s_name: underscore to hyphen" = test_k8s_name_underscores ()
let%test "k8s_name: worker suffix" = test_k8s_name_worker ()
let%test "k8s_name: no underscores" = test_k8s_name_no_underscores ()

let%test "k8s_name: invalid characters rejected" =
  test_k8s_name_rejects_invalid_characters ()
;;

let%test "k8s_name: empty rejected" = test_k8s_name_rejects_empty ()
let%test "k8s_name: overlong rejected" = test_k8s_name_rejects_overlong ()
let%test "namespace: workspace-domain" = test_namespace ()
let%test "namespace: comms domain" = test_namespace_comms ()
let%test "namespace: sanitize workspace" = test_namespace_sanitizes_workspace ()
let%test "namespace: uppercase workspace" = test_namespace_uppercased_workspace ()
let%test "namespace: invalid domain rejected" = test_namespace_rejects_invalid_domain ()
let%test "namespace: overlong rejected" = test_namespace_rejects_overlong ()
let%test "image_ref: local k3d" = test_image_ref_local ()
let%test "image_ref: ECR registry" = test_image_ref_ecr ()
let%test "image_ref: localhost push" = test_image_ref_push_registry ()
let%test "to_json: valid JSON" = test_to_json_valid_json ()
let%test "to_json: deterministic" = test_to_json_deterministic ()
let%test "to_json: no secret values" = test_to_json_no_secret_values ()
let%test "to_json: secret keys present" = test_to_json_secret_keys_present ()
let%test "to_json: build secret keys present" = test_to_json_build_secret_keys_present ()
let%test "to_json: env present" = test_to_json_env_present ()
let%test "to_json: config values present" = test_to_json_config_values_present ()
let%test "to_json: mode strings" = test_to_json_mode_strings ()
let%test "to_json: rollout_strategy rolling_update" = test_to_json_rollout_strategy ()
let%test "to_json: rollout_strategy recreate" = test_to_json_rollout_strategy_recreate ()
let%test "to_json: rollout_strategy canary" = test_to_json_rollout_strategy_canary ()

let%test "to_json: rollout_strategy blue_green" =
  test_to_json_rollout_strategy_blue_green ()
;;

let%test "to_json: effective rollout default" =
  test_effective_rollout_strategy_defaults_to_rolling_update ()
;;

let%test "to_json: effective rollout recreate" =
  test_effective_rollout_strategy_recreate ()
;;

let%test "to_json: effective rollout precedence" =
  test_effective_rollout_strategy_progressive_delivery_precedence ()
;;

let%test "to_json: summary rollout strategy" =
  test_summary_uses_effective_rollout_strategy ()
;;

let%test "to_json: ingress null when absent" = test_to_json_ingress_null_when_absent ()
let%test "to_json: ingress host+path present" = test_to_json_ingress_present ()
let%test "to_json: schema_subjects in json" = test_to_json_schema_subjects_present ()
let%test "to_json: consumer_groups in json" = test_to_json_consumer_groups_present ()

let%test "to_json: requested scope and resolved workloads in json" =
  test_to_json_requested_scope_and_resolved_workloads ()
;;

let%test "discover_topics: finds topic from sol.toml" =
  test_discover_topics_finds_topic ()
;;

let%test "discover_topics: empty without events/" =
  test_discover_topics_empty_when_no_dir ()
;;

let%test "discover_topics: multiple topics in one toml" =
  test_discover_topics_multiple_topics_in_toml ()
;;

let%test "discover_topics: deduplicates" = test_discover_topics_deduplicates ()
let%test "discover_topics: subdirectory discovery" = test_discover_topics_subdirectory ()

let%test "discover_topics: misspelled event sol.toml is an error" =
  test_discover_topics_rejects_misspelled_event_toml ()
;;

let%test "discover_topics: top-level events/sol.toml" =
  test_discover_topics_top_level_toml ()
;;

let%test "discover_topics: mixed top-level and subdir" =
  test_discover_topics_mixed_levels ()
;;

let%test "discover_topics: no false positives from .ml files" =
  test_discover_topics_no_false_positives_from_ml_files ()
;;

let%test "fn schedule (BUG-048): comes from sol.toml" =
  test_fn_schedule_comes_from_sol_toml ()
;;

let%test "fn schedule (BUG-048): no sol.toml is a plan error" =
  (test_fn_without_schedule_is_a_plan_error None) ()
;;

let%test "fn schedule (BUG-048): no schedule key is a plan error" =
  (test_fn_without_schedule_is_a_plan_error (Some "[infra.scale]\nreplicas = 1\n")) ()
;;

let%test "discover_migrations: finds sql" = test_discover_migrations_finds_sql ()

let%test "discover_migrations: empty without db/migrations/" =
  test_discover_migrations_empty_when_no_dir ()
;;

let%test "discover_migrations: sorted by name" = test_discover_migrations_sorted ()

let%test "discover_migrations: ignores non-sql" =
  test_discover_migrations_ignores_non_sql ()
;;

let%test "schema_subjects: derived from events/<domain>/<event>.ml" =
  test_schema_subjects_derived ()
;;

let%test "schema_subjects: multiple domains sorted" =
  test_schema_subjects_multiple_domains ()
;;

let%test "schema_subjects: top-level ml file" = test_schema_subjects_top_level_ml ()

let%test "schema_subjects: empty without events dir" =
  test_schema_subjects_empty_when_no_dir ()
;;

let%test "consumer_groups: derived from Worker spec" = test_consumer_groups_derived ()
let%test "consumer_groups: excludes Svc primitives" = test_consumer_groups_excludes_svc ()
let%test "consumer_groups: sorted" = test_consumer_groups_sorted ()

let%test "consumer_groups: a scoped plan carries the whole workspace group set (BUG-088)" =
  test_a_scoped_plan_carries_the_whole_workspace_group_set ()
;;

let%test
    "consumer_groups: a group the workspace no longer declares is not reported (BUG-088)"
  =
  test_a_group_the_workspace_no_longer_declares_is_not_reported ()
;;

let%test "of_services: returns typed TOML parse error" =
  test_of_services_result_surfaces_toml_parse_error ()
;;

let%test "of_services: sol.yml scale_max overrides sol.toml replicas" =
  test_sol_yml_scale_overrides_toml_replicas_on_resolved_target ()
;;

let%test "of_services: sol.yml scale_min used when no scale_max" =
  test_sol_yml_scale_falls_back_to_scale_min_when_no_max ()
;;

let%test "of_services: no resolved config keeps sol.toml replicas" =
  test_no_resolved_config_uses_toml_replicas ()
;;

let%test "of_services: no matching sol.yml service keeps sol.toml replicas" =
  test_no_matching_sol_yml_service_uses_toml_replicas ()
;;

let%test "of_services: sol.toml volumes carry into service spec" =
  test_toml_volumes_carry_into_service_spec ()
;;

let%test "of_services: multi-replica volumes fail after scale resolution" =
  test_multi_replica_volume_fails_after_scale_resolution ()
;;

let%test "of_services: zero-replica volumes fail" = test_zero_replica_volume_fails ()
let%test "of_services: function volumes fail" = test_function_volume_fails ()

let%test "of_services: service calls resolve" =
  test_service_calls_resolve_to_env_and_reverse_edge ()
;;

let%test "of_services: unknown service call fails" = test_unknown_service_call_fails ()

let%test
    "of_services: a scoped call resolves from the inventory, not the selection (DEC-036)"
  =
  test_scoped_call_resolves_from_the_inventory ()
;;

let%test
    "of_services: a misspelled call target still fails, and names the units (DEC-036)"
  =
  test_unknown_service_call_fails_and_names_the_units ()
;;

let%test "of_services: a scoped callee keeps its cross-domain caller ingress (BUG-089)" =
  test_a_scoped_callee_keeps_its_cross_domain_caller_ingress ()
;;

let%test "of_services: service call env conflict fails" =
  test_service_call_env_conflict_fails ()
;;

let%test "plan_ids: Topic_name valid" = test_topic_name_valid ()
let%test "plan_ids: Topic_name empty fails" = test_topic_name_empty_fails ()
let%test "plan_ids: Topic_name too long fails" = test_topic_name_too_long_fails ()
let%test "plan_ids: Topic_name invalid char fails" = test_topic_name_invalid_char_fails ()
let%test "plan_ids: Topic_name max length ok" = test_topic_name_max_length_ok ()
let%test "plan_ids: Migration_file valid" = test_migration_file_valid ()
let%test "plan_ids: Migration_file empty fails" = test_migration_file_empty_fails ()
let%test "plan_ids: Migration_file not-.sql fails" = test_migration_file_not_sql_fails ()
let%test "plan_ids: Schema_subject valid" = test_schema_subject_valid ()
let%test "plan_ids: Schema_subject empty fails" = test_schema_subject_empty_fails ()
let%test "plan_ids: Consumer_group valid" = test_consumer_group_valid ()
let%test "plan_ids: Consumer_group empty fails" = test_consumer_group_empty_fails ()

let%test "contract: a change renders observed to desired" =
  test_contract_change_is_rendered_observed_to_desired ()
;;

let%test "contract: an unchanged contract reports nothing" =
  test_contract_noop_reports_nothing ()
;;

let%test "contract: an incompatible change fails closed" =
  test_contract_fails_closed_on_incompatible_change ()
;;

let%test "contract: added, removed and schema changes are reported" =
  test_contract_added_removed_and_schema_are_reported ()
;;

(* 2d: which units mount the database CA, end to end from the declared `uses:` to the
   rendered pod. The discriminator is the *resource Sol provisions*, named by the caller;
   the resource *type* would put the mount on a unit bound to an external postgres and
   wedge its pod on a ConfigMap the deploy never writes. *)
let postgres_config ~sol_consumers ~external_consumers : Sol_cli_config.t =
  let service name uses =
    { Sol_cli_config.name
    ; typ = None
    ; path = None
    ; uses
    ; scale_min = None
    ; scale_max = None
    ; language = None
    ; omit = false
    }
  in
  let resource name =
    { Sol_cli_config.name
    ; typ = Some "postgres"
    ; partition_key = None
    ; sort_key = None
    ; indexes = []
    ; size = None
    ; omit = false
    ; binding = None
    }
  in
  { project = Some "ws"
  ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
  ; resources = [ resource "app_db"; resource "legacy_db" ]
  ; services =
      List.map (fun name -> service name [ "app_db" ]) sol_consumers
      @ List.map (fun name -> service name [ "legacy_db" ]) external_consumers
      @ [ service "plain_svc" [] ]
  }
;;

let test_the_ca_mount_follows_the_sol_provisioned_resource () =
  let tmp = Filename.temp_dir "sol_test_db_ca_mount" "" in
  with_cwd tmp (fun () ->
    let unit name = worker_unit ~domain:"payments" ~name in
    List.iter
      (fun (s : Sol_cli_manifest.service) ->
         mkdirs s.dir;
         write_file (Filename.concat s.dir "sol.toml") "")
      [ unit "charge_svc"; unit "legacy_svc"; unit "plain_svc" ];
    let declared =
      Sol_cli_config.declared_of_config
        (postgres_config
           ~sol_consumers:[ "charge_svc" ]
           ~external_consumers:[ "legacy_svc" ])
    in
    match
      Sol_cli_deployment_plan.of_services_result
        ~workspace:"myworkspace"
        ~env:deploy_env
        ~facts:(facts ())
        ~declared
        ~target:"prod-aws-us-east-1"
        ~provisioned_database:"app_db"
        [ unit "charge_svc"; unit "legacy_svc"; unit "plain_svc" ]
    with
    | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
    | Ok plan ->
      let spec name =
        List.find
          (fun (s : Sol_cli_deployment_plan.service_spec) -> s.source_name = name)
          plan.Sol_cli_deployment_plan.services
      in
      let workload_yaml spec =
        match
          Sol_cli_deployment_render.render_spec
            ~workspace:"myworkspace"
            ~release_id:release_id_of_test
            spec
        with
        | Ok bundle -> bundle.Sol_cli_manifest.workload_yaml
        | Error e -> Windtrap.fail ("render_spec unexpectedly failed: " ^ e)
      in
      (* The name comes from the one definition the deploy writes with, so a rename moves
         the writer and this renderer together. *)
      let ca_configmap =
        Sol_cli_database_setup_render.ca_configmap_name "prod-aws-us-east-1"
      in
      let mounts = Sol_cli_string.contains ~needle:("name: " ^ ca_configmap) in
      let at_path =
        Sol_cli_string.contains
          ~needle:("mountPath: " ^ Sol_cli_manifest_cluster_env.db_ca_mount_path)
      in
      let charge = workload_yaml (spec "charge_svc") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a consumer of the Sol-provisioned database mounts its CA"
        true
        (mounts charge && at_path charge);
      (* 2b: and reads POSTGRES_URL from the target's DML class Secret. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"a consumer of the Sol-provisioned database reads the DML class Secret"
        true
        (Sol_cli_string.contains
           ~needle:
             ("name: " ^ Sol_cli_database_setup_render.dml_creds_name "prod-aws-us-east-1")
           charge
         && Sol_cli_string.contains ~needle:"key: POSTGRES_URL" charge);
      let legacy = workload_yaml (spec "legacy_svc") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a consumer of an externally bound database mounts no CA"
        false
        (mounts legacy || at_path legacy);
      let plain = workload_yaml (spec "plain_svc") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a unit that consumes no database mounts no CA"
        false
        (mounts plain || at_path plain))
;;

let%test "2d: the CA mount follows the resource Sol provisions, not the resource type" =
  test_the_ca_mount_follows_the_sol_provisioned_resource ()
;;

(* 2b: the reader routes `POSTGRES_URL` on the capability — the unit consumes the target's
   postgres resource — not on the key name and not on the database's ownership. A unit that
   merely declares `POSTGRES_URL` keeps it unit-scoped, and the CA mount stays Sol-only. *)
let test_the_reader_routes_on_the_capability_not_the_key_name () =
  let tmp = Filename.temp_dir "sol_test_db_reader" "" in
  with_cwd tmp (fun () ->
    let unit name = worker_unit ~domain:"payments" ~name in
    let service name uses =
      { Sol_cli_config.name
      ; typ = None
      ; path = None
      ; uses
      ; scale_min = None
      ; scale_max = None
      ; language = None
      ; omit = false
      }
    in
    let resource name =
      { Sol_cli_config.name
      ; typ = Some "postgres"
      ; partition_key = None
      ; sort_key = None
      ; indexes = []
      ; size = None
      ; omit = false
      ; binding = None
      }
    in
    let declared =
      Sol_cli_config.declared_of_config
        { Sol_cli_config.project = Some "ws"
        ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
        ; resources = [ resource "app_db" ]
        ; services =
            [ service "charge_svc" [ "app_db" ]
            ; service "declared_only" []
            ; service "plain_svc" []
            ]
        }
    in
    let units = [ unit "charge_svc"; unit "declared_only"; unit "plain_svc" ] in
    List.iter
      (fun (s : Sol_cli_manifest.service) ->
         mkdirs s.dir;
         let body =
           if String.equal s.name "declared_only"
           then "[infra.env]\nsecrets = [\"POSTGRES_URL\"]\n"
           else ""
         in
         write_file (Filename.concat s.dir "sol.toml") body)
      units;
    let plan ~provisioned_database =
      match
        Sol_cli_deployment_plan.of_services_result
          ~workspace:"myworkspace"
          ~env:deploy_env
          ~facts:(facts ())
          ~declared
          ~target:"prod-aws-us-east-1"
          ~target_database:"app_db"
          ?provisioned_database
          units
      with
      | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
      | Ok plan -> plan
    in
    let workload plan name =
      let spec =
        List.find
          (fun (s : Sol_cli_deployment_plan.service_spec) -> s.source_name = name)
          plan.Sol_cli_deployment_plan.services
      in
      match
        Sol_cli_deployment_render.render_spec
          ~workspace:"myworkspace"
          ~release_id:release_id_of_test
          spec
      with
      | Ok bundle -> bundle.Sol_cli_manifest.workload_yaml
      | Error e -> Windtrap.fail ("render_spec unexpectedly failed: " ^ e)
    in
    let has needle text = Sol_cli_string.contains ~needle text in
    let dml = Sol_cli_database_setup_render.dml_creds_name "prod-aws-us-east-1" in
    let ca = Sol_cli_database_setup_render.ca_configmap_name "prod-aws-us-east-1" in
    (* Sol provisions the target's database: the consumer reads the DML class Secret and
       mounts the CA Sol publishes. *)
    let sol = plan ~provisioned_database:(Some "app_db") in
    let charge = workload sol "charge_svc" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a Sol-provisioned consumer reads the DML class Secret"
      true
      (has ("name: " ^ dml) charge && has "key: POSTGRES_URL" charge);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and mounts the Sol CA ConfigMap"
      true
      (has ("name: " ^ ca) charge);
    let declared_only = workload sol "declared_only" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a unit that merely declares POSTGRES_URL keeps it unit-scoped"
      true
      (has "name: declared-only-secrets" declared_only
       && has "key: POSTGRES_URL" declared_only);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and reads neither class Secret nor CA"
      false
      (has ("name: " ^ dml) declared_only || has ("name: " ^ ca) declared_only);
    let plain = workload sol "plain_svc" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a unit that consumes no database reads neither"
      false
      (has "key: POSTGRES_URL" plain
       || has ("name: " ^ dml) plain
       || has ("name: " ^ ca) plain);
    (* The same target with the database bound externally: the reader is ownership-neutral,
       but Sol publishes no CA ConfigMap for a database it does not own (2d). *)
    let external_plan = plan ~provisioned_database:None in
    let external_charge = workload external_plan "charge_svc" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"an externally bound consumer reads the same DML class Secret"
      true
      (has ("name: " ^ dml) external_charge && has "key: POSTGRES_URL" external_charge);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and mounts no CA the deploy does not publish"
      false
      (has ("name: " ^ ca) external_charge))
;;

let%test "2b: the reader routes on the resource, not the key name or the owner" =
  test_the_reader_routes_on_the_capability_not_the_key_name ()
;;

(* 2b: *which* postgres resource is the target's is selected in one place
   (`Sol_cli_resource_binding.target_database`); the plan test above injects the result and
   would pass even if the selection picked wrong. One externally bound postgres is the
   target's database; two are ambiguous, so no consumer's `POSTGRES_URL` routes and each
   unit keeps its own. *)
let test_target_database_selects_one_external_and_refuses_two () =
  let binding ?(ownership = Sol_cli_config.Ownership_sol) resource =
    { Sol_cli_resource_binding.resource
    ; typ = "postgres"
    ; ownership
    ; store = None
    ; keys = []
    ; connection = []
    ; credentials = []
    }
  in
  let selected bindings =
    Sol_cli_resource_binding.target_database bindings
    |> Option.map (fun (b : Sol_cli_resource_binding.t) -> b.resource)
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"one externally bound postgres is the target's database"
    (Some "legacy_db")
    (selected [ binding ~ownership:Sol_cli_config.Ownership_external "legacy_db" ]);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a Sol-provisioned database is authoritative beside an external one"
    (Some "app_db")
    (selected
       [ binding "app_db"
       ; binding ~ownership:Sol_cli_config.Ownership_external "legacy_db"
       ]);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"two externally bound postgres resources are ambiguous, so nothing routes"
    None
    (selected
       [ binding ~ownership:Sol_cli_config.Ownership_external "first_db"
       ; binding ~ownership:Sol_cli_config.Ownership_external "second_db"
       ]);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"and no postgres resource routes nothing"
    None
    (selected [])
;;

let%test "2b: the target database is the provisioned one, else exactly one external" =
  test_target_database_selects_one_external_and_refuses_two ()
;;
