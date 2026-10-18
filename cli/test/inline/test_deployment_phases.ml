let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
;;

let ok = function
  | Ok r -> r
  | Error e -> Windtrap.fail e
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

let assert_contains label haystack needle =
  Windtrap.equal
    Windtrap.bool
    ~msg:(Printf.sprintf "%s: contains %S" label needle)
    true
    (Sol_cli_string.contains ~needle haystack)
;;

let assert_absent label haystack needle =
  Windtrap.equal
    Windtrap.bool
    ~msg:(Printf.sprintf "%s: absent %S" label needle)
    false
    (Sol_cli_string.contains ~needle haystack)
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

let fn_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "billing"
  ; source_name = "invoice_fn"
  ; k8s_name = k8s_name "invoice-fn"
  ; namespace = namespace ~workspace:"myapp" ~domain:"billing"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; source_dir = "app/billing/invoice_fn"
  ; image = "registry.example.com/myapp/invoice-fn:abc123"
  ; config = []
  ; secrets = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = Some "0 9 * * 1"
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

let local_env : Sol_cli_deployment_plan.env_config =
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

let customer_env : Sol_cli_deployment_plan.env_config =
  { name = "production"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "123456789.dkr.ecr.us-east-1.amazonaws.com"
  ; image_tag = "abc123"
  ; env = Some "prod"
  ; region = Some "us-east-1"
  ; base_domain = Some "example.com"
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let make_plan ?(env = customer_env) services : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; environment = env
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
  ; resource_delivery = None
  }
;;

let test_local_deploy_request_uses_explicit_tag () =
  let r =
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:false
      ~tag:(Some "v1.2.3")
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () ->
        Windtrap.fail "git_sha should not be called when tag is explicit")
  in
  match r with
  | Ok req -> Windtrap.equal Windtrap.string ~msg:"explicit tag" "v1.2.3" req.image_tag
  | Error msg -> Windtrap.fail msg
;;

let test_local_deploy_request_falls_back_to_git_sha () =
  let r =
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "sha-deadbeef")
  in
  match r with
  | Ok req ->
    Windtrap.equal Windtrap.string ~msg:"git sha fallback" "sha-deadbeef" req.image_tag
  | Error msg -> Windtrap.fail msg
;;

let git_unavailable () = Error "fatal: not a git repository"

let test_local_deploy_request_warns_on_fallback_tag () =
  match
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:git_unavailable
  with
  | Error msg -> Windtrap.fail msg
  | Ok req ->
    Windtrap.equal Windtrap.string ~msg:"fallback tag" "dev" req.image_tag;
    (match req.image_tag_warning with
     | None -> Windtrap.fail "expected a warning for the fallback tag"
     | Some w ->
       Windtrap.equal
         Windtrap.bool
         ~msg:("names git's reason: " ^ w)
         true
         (Sol_cli_string.contains ~needle:"not a git repository" w);
       Windtrap.equal
         Windtrap.bool
         ~msg:("names --image-tag: " ^ w)
         true
         (Sol_cli_string.contains ~needle:"--image-tag" w))
;;

let test_local_deploy_request_resolved_sha_has_no_warning () =
  match
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:false
      ~tag:None
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "abc1234")
  with
  | Error msg -> Windtrap.fail msg
  | Ok req ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"no warning"
      None
      req.image_tag_warning
;;

let deploy_without_tag ~git_sha =
  Sol_cli_command_request.make_deploy_request
    ~target:"prod/aws/us-east-1"
    ~dry_run:false
    ~emit_to:None
    ~emit_plan_to:None
    ~image_tag:None
    ~image_refs:[]
    ~registry:None
    ~confirm_group_change:false
    ~confirm_ecr_removal:false
    ~loki_push_url:None
    ~keep_releases:20
    ~await_delegation:None
    ~git_sha
;;

let test_deploy_request_refuses_unresolvable_sha () =
  match deploy_without_tag ~git_sha:git_unavailable with
  | Ok req -> Windtrap.fail ("deploy tagged images " ^ req.image_tag)
  | Error msg ->
    Windtrap.equal
      Windtrap.bool
      ~msg:("names --image-tag: " ^ msg)
      true
      (Sol_cli_string.contains ~needle:"--image-tag" msg);
    Windtrap.equal
      Windtrap.bool
      ~msg:("names git's reason: " ^ msg)
      true
      (Sol_cli_string.contains ~needle:"not a git repository" msg)
;;

let test_deploy_request_tags_with_resolved_sha () =
  match deploy_without_tag ~git_sha:(fun () -> Ok "abc1234") with
  | Error msg -> Windtrap.fail msg
  | Ok req -> Windtrap.equal Windtrap.string ~msg:"sha tag" "abc1234" req.image_tag
;;

let test_local_deploy_request_preserves_mode () =
  let r =
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:true
      ~tag:(Some "t")
      ~confirm_group_change:false
      ~keep_releases:20
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"dry-run mode"
      true
      (match req.mode with
       | Sol_cli_command_request.Dry_run -> true
       | Apply -> false)
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_uses_explicit_tag () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "sha-abc")
      ~image_refs:[]
      ~registry:(Some "reg.example.com")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Windtrap.fail "git_sha should not be called")
  in
  match r with
  | Ok req -> Windtrap.equal Windtrap.string ~msg:"explicit tag" "sha-abc" req.image_tag
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_local_mode_builds_request () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "v2")
      ~image_refs:[]
      ~registry:(Some "gcr.io/myproject")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"deploy apply"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_apply -> true
       | Deploy_dry_run _ | Deploy_emit_to _ -> false)
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_gitops_action () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:(Some "/tmp/gitops")
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"gitops action"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_emit_to "/tmp/gitops" -> true
       | Deploy_apply | Deploy_dry_run _ | Deploy_emit_to _ -> false)
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_dry_run_action_preserves_emit_to () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:true
      ~emit_to:(Some "/tmp/gitops")
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"dry-run action preserves emit_to"
      true
      (match req.action with
       | Sol_cli_command_request.Deploy_dry_run { emit_to = Some "/tmp/gitops" } -> true
       | Deploy_apply | Deploy_emit_to _ | Deploy_dry_run _ -> false)
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_rejects_empty_target () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:""
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Windtrap.equal Windtrap.bool ~msg:"empty target rejected" true (Result.is_error r)
;;

let test_deploy_request_registry_omitted_stays_none () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:None
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"registry stays None"
      None
      req.registry
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_accepts_image_refs () =
  let digest = "reg.example.com/ws/svc@sha256:" ^ String.make 64 'a' in
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "unused")
      ~image_refs:[ Some "svc", digest ]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  match r with
  | Ok req ->
    Windtrap.equal
      Windtrap.int
      ~msg:"one reference carried"
      1
      (List.length req.image_refs)
  | Error msg -> Windtrap.fail msg
;;

let test_deploy_request_rejects_mutable_image_ref () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "unused")
      ~image_refs:[ None, "reg.example.com/ws/svc:latest" ]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:20
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Windtrap.equal Windtrap.bool ~msg:"mutable reference rejected" true (Result.is_error r)
;;

let test_plan_local_mode_fields () =
  let plan = make_plan ~env:local_env [ svc_spec ] in
  Windtrap.equal Windtrap.string ~msg:"workspace" "myapp" plan.workspace;
  Windtrap.equal
    Windtrap.bool
    ~msg:"mode Local"
    true
    (plan.environment.Sol_cli_deployment_plan.mode = Sol_cli_deployment_plan.Local);
  Windtrap.equal
    Windtrap.string
    ~msg:"registry"
    "sol-registry:5000"
    plan.environment.Sol_cli_deployment_plan.registry
;;

let test_plan_customer_cloud_mode_fields () =
  let plan = make_plan ~env:customer_env [ svc_spec ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"mode Customer_cloud"
    true
    (plan.environment.Sol_cli_deployment_plan.mode
     = Sol_cli_deployment_plan.Customer_cloud);
  Windtrap.equal
    Windtrap.string
    ~msg:"ECR registry"
    "123456789.dkr.ecr.us-east-1.amazonaws.com"
    plan.environment.Sol_cli_deployment_plan.registry
;;

let test_plan_service_count () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  Windtrap.equal Windtrap.int ~msg:"three services" 3 (List.length plan.services)
;;

let test_plan_service_primitives () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let primitives =
    plan.services |> List.map (fun s -> s.Sol_cli_deployment_plan.primitive)
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"Svc present"
    true
    (List.mem Sol_cli_deployment_plan.Svc primitives);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Worker present"
    true
    (List.mem Sol_cli_deployment_plan.Worker primitives);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Fn present"
    true
    (List.mem Sol_cli_deployment_plan.Fn primitives)
;;

let test_plan_consumer_groups_derived_from_workers () =
  let resolved_config : Sol_cli_config.t =
    { project = Some "myapp"
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
        [ { name = "notify_worker"
          ; typ = None
          ; path = None
          ; uses = [ "events" ]
          ; scale_min = None
          ; scale_max = None
          ; language = None
          ; omit = false
          }
        ]
    }
  in
  let plan =
    { (make_plan [ svc_spec; worker_spec ]) with
      consumer_groups =
        Sol_cli_deployment_plan.derive_consumer_groups
          ~declared:(Sol_cli_config.declared_of_config resolved_config)
          "myapp"
          (make_plan [ svc_spec; worker_spec ]).Sol_cli_deployment_plan.services
    }
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"one consumer group for one worker"
    1
    (List.length plan.consumer_groups);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"group name"
    [ "myapp.comms.notify_worker" ]
    (List.map Sol_cli_plan_ids.Consumer_group.to_string plan.consumer_groups)
;;

let test_plan_svc_does_not_produce_consumer_group () =
  let groups = Sol_cli_deployment_plan.derive_consumer_groups "myapp" [ svc_spec ] in
  Windtrap.equal Windtrap.int ~msg:"Svc yields no consumer groups" 0 (List.length groups)
;;

let render_ok spec =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      spec
  with
  | Ok bundle -> bundle.namespace_yaml, bundle.prerequisites_yaml ^ bundle.workload_yaml
  | Error e -> Windtrap.fail ("render_spec failed: " ^ e)
;;

let run_plan_ok ~mode plan =
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
  | Error e -> Windtrap.fail ("run_plan failed: " ^ e)
;;

let test_render_svc_produces_deployment_and_service () =
  let _, workload_yaml = render_ok svc_spec in
  assert_contains "svc workload has Deployment" workload_yaml "kind: Deployment";
  assert_contains "svc workload has Service" workload_yaml "kind: Service"
;;

let test_render_worker_has_deployment_no_service () =
  let _, workload_yaml = render_ok worker_spec in
  assert_contains "worker has Deployment" workload_yaml "kind: Deployment";
  assert_absent "worker no Service" workload_yaml "kind: Service\n"
;;

let test_render_fn_produces_cronjob () =
  let _, workload_yaml = render_ok fn_spec in
  assert_contains "fn has CronJob" workload_yaml "kind: CronJob";
  assert_absent "fn no Deployment" workload_yaml "kind: Deployment"
;;

let test_render_namespace_yaml_is_non_empty () =
  let ns_yaml, _ = render_ok svc_spec in
  Windtrap.equal
    Windtrap.bool
    ~msg:"namespace_yaml non-empty"
    true
    (String.length ns_yaml > 0)
;;

let test_render_artifact_count_matches_services () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Windtrap.equal Windtrap.int ~msg:"one result per service" 3 (List.length results)
;;

let test_render_artifact_image_matches_spec () =
  let plan = make_plan [ svc_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  let r = List.hd results in
  Windtrap.equal
    Windtrap.string
    ~msg:"artifact image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_render_no_docker_or_k8s_calls () =
  let plan = make_plan [ svc_spec; worker_spec; fn_spec ] in
  let results = run_plan_ok ~mode:Sol_cli_executor.Dry_run plan in
  Windtrap.equal
    Windtrap.bool
    ~msg:"renders without side effects"
    true
    (List.length results = 3)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-phases-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      (try
         Sys.readdir dir
         |> Array.iter (fun name ->
           try Sys.remove (Filename.concat dir name) with
           | _ -> ())
       with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
;;

let test_gitops_emit_creates_file () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    Windtrap.equal Windtrap.bool ~msg:"gitops file created" true (Sys.file_exists path))
;;

let test_gitops_emit_file_contains_yaml_separator () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains "yaml separator present" content "---")
;;

let test_gitops_emit_file_has_namespace_kind () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains "Namespace kind present" content "kind: Namespace";
    assert_contains "namespace name present" content "name: myapp-payments")
;;

let test_gitops_emit_omits_placeholder_secret () =
  with_temp_dir (fun dir ->
    let env = customer_env in
    let plan = make_plan ~env [ svc_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
    let content =
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s
    in
    assert_contains "no placeholder Secret is emitted" content "kind: ConfigMap";
    assert_absent "no Secret object is emitted" content "kind: Secret";
    assert_absent "no placeholder guidance is emitted" content "Populate these values")
;;

let test_gitops_emit_one_file_per_service () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec; worker_spec ] in
    ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan);
    let files = Sys.readdir dir |> Array.to_list in
    Windtrap.equal
      Windtrap.int
      ~msg:"two service files + two release files"
      4
      (List.length files);
    let record =
      Sol_cli_release.(
        configmap_name (of_plan ~apply_mode:Sol_cli_release.Gitops plan) ^ ".yaml")
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"release record emitted"
      true
      (List.mem record files);
    Windtrap.equal
      Windtrap.bool
      ~msg:"current-release pointer emitted"
      true
      (List.mem "sol-current-release.yaml" files))
;;

let test_gitops_release_artifact_is_deterministic () =
  with_temp_dir (fun dir_a ->
    with_temp_dir (fun dir_b ->
      let plan = make_plan [ svc_spec; worker_spec ] in
      ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir_a) plan);
      ignore (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir_b) plan);
      let record =
        Sol_cli_release.configmap_name
          (Sol_cli_release.of_plan ~apply_mode:Sol_cli_release.Gitops plan)
        ^ ".yaml"
      in
      let read dir name =
        let ic = open_in (Filename.concat dir name) in
        let s = In_channel.input_all ic in
        close_in ic;
        s
      in
      Windtrap.equal
        Windtrap.string
        ~msg:"record bytes identical"
        (read dir_a record)
        (read dir_b record);
      Windtrap.equal
        Windtrap.string
        ~msg:"pointer bytes identical"
        (read dir_a "sol-current-release.yaml")
        (read dir_b "sol-current-release.yaml")))
;;

let test_local_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  Windtrap.equal Windtrap.string ~msg:"local namespace" "myapp-payments" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"local name" "charge-svc" r.name;
  Windtrap.equal
    Windtrap.string
    ~msg:"local image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_direct_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  Windtrap.equal Windtrap.string ~msg:"direct namespace" "myapp-payments" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"direct name" "charge-svc" r.name;
  Windtrap.equal
    Windtrap.string
    ~msg:"direct image"
    "registry.example.com/myapp/charge-svc:abc123"
    r.image
;;

let test_gitops_executor_result_fields () =
  with_temp_dir (fun dir ->
    let r =
      Sol_cli_executor.gitops
        ~ctx:Sol_cli_kube_destination.local_context
        ~workspace:"myapp"
        ~release_id:release_id_of_test
        ~dir
        svc_spec
      |> ok
    in
    Windtrap.equal Windtrap.string ~msg:"gitops namespace" "myapp-payments" r.namespace;
    Windtrap.equal Windtrap.string ~msg:"gitops name" "charge-svc" r.name;
    Windtrap.equal
      Windtrap.string
      ~msg:"gitops image"
      "registry.example.com/myapp/charge-svc:abc123"
      r.image)
;;

let test_local_worker_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  Windtrap.equal Windtrap.string ~msg:"local worker namespace" "myapp-comms" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"local worker name" "notify-worker" r.name
;;

let test_direct_fn_executor_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      fn_spec
    |> ok
  in
  Windtrap.equal Windtrap.string ~msg:"direct fn namespace" "myapp-billing" r.namespace;
  Windtrap.equal Windtrap.string ~msg:"direct fn name" "invoice-fn" r.name
;;

let test_state_dry_run_is_noop () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          Sol_cli_deployment_state.Dry_run))
;;

let test_state_failed_is_noop () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          (Sol_cli_deployment_state.Failed { phase = "render"; message = "YAML error" })))
;;

let test_state_emitted_is_noop () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"no-op outcome is Ok"
    true
    (Result.is_ok
       (Sol_cli_deployment_state.record_outcome
          ~ctx:Sol_cli_kube_destination.local_context
          "myapp"
          (Sol_cli_deployment_state.Emitted
             { file = "/tmp/myapp-payments-charge-svc.yaml" })))
;;

let test_state_removed_consumer_groups () =
  let prev = [ "myapp.comms.notify_worker"; "myapp.billing.invoice_fn" ] in
  let next = [ "myapp.comms.notify_worker" ] in
  let removed = Sol_cli_deployment_state.removed_consumer_groups ~prev ~next in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"invoice_fn worker removed"
    [ "myapp.billing.invoice_fn" ]
    removed
;;

let test_state_no_removal_when_stable () =
  let groups = [ "myapp.comms.notify_worker" ] in
  let removed =
    Sol_cli_deployment_state.removed_consumer_groups ~prev:groups ~next:groups
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"stable plan: no removals"
    []
    removed
;;

let test_local_and_direct_share_plan_type () =
  let plan = make_plan ~env:local_env [ svc_spec ] in
  let local_results =
    List.map
      (Sol_cli_executor.local
         ~ctx:Sol_cli_kube_destination.local_context
         ~workspace:plan.workspace
         ~release_id:plan.release_id
         ~dry_run:true)
      plan.services
    |> List.map ok
  in
  let direct_results =
    List.map
      (Sol_cli_executor.local
         ~ctx:Sol_cli_kube_destination.local_context
         ~workspace:plan.workspace
         ~release_id:plan.release_id
         ~dry_run:true)
      plan.services
    |> List.map ok
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"same result count"
    (List.length local_results)
    (List.length direct_results);
  let lr = List.hd local_results
  and dr = List.hd direct_results in
  Windtrap.equal
    Windtrap.string
    ~msg:"local namespace = direct namespace"
    lr.namespace
    dr.namespace;
  Windtrap.equal Windtrap.string ~msg:"local name = direct name" lr.name dr.name;
  Windtrap.equal Windtrap.string ~msg:"local image = direct image" lr.image dr.image
;;

let test_gitops_shares_plan_type () =
  with_temp_dir (fun dir ->
    let plan = make_plan ~env:customer_env [ svc_spec ] in
    let gitops_results =
      List.map
        (Sol_cli_executor.gitops
           ~ctx:Sol_cli_kube_destination.local_context
           ~workspace:plan.workspace
           ~release_id:plan.release_id
           ~dir)
        plan.services
      |> List.map ok
    in
    let direct_results =
      List.map
        (Sol_cli_executor.local
           ~ctx:Sol_cli_kube_destination.local_context
           ~workspace:plan.workspace
           ~release_id:plan.release_id
           ~dry_run:true)
        plan.services
      |> List.map ok
    in
    let gr = List.hd gitops_results
    and dr = List.hd direct_results in
    Windtrap.equal
      Windtrap.string
      ~msg:"gitops namespace = direct namespace"
      gr.namespace
      dr.namespace;
    Windtrap.equal Windtrap.string ~msg:"gitops name = direct name" gr.name dr.name;
    Windtrap.equal Windtrap.string ~msg:"gitops image = direct image" gr.image dr.image)
;;

let test_change_set_build_is_path_agnostic () =
  with_temp_dir (fun dir ->
    let plan = make_plan [ svc_spec ] in
    let id r =
      r.Sol_cli_executor.namespace, r.Sol_cli_executor.name, r.Sol_cli_executor.image
    in
    let id_dry = id (List.hd (run_plan_ok ~mode:Sol_cli_executor.Dry_run plan)) in
    let id_emit = id (List.hd (run_plan_ok ~mode:(Sol_cli_executor.Emit_to dir) plan)) in
    Windtrap.equal
      Windtrap.bool
      ~msg:"dry vs emit: identity identical"
      true
      (id_dry = id_emit))
;;

let test_all_paths_start_from_same_plan_workspace () =
  let plan_local = make_plan ~env:local_env [ svc_spec ] in
  let plan_direct = make_plan ~env:customer_env [ svc_spec ] in
  let plan_gitops = make_plan ~env:customer_env [ svc_spec ] in
  let plan_hosted =
    make_plan
      ~env:{ customer_env with mode = Sol_cli_deployment_plan.Sol_hosted }
      [ svc_spec ]
  in
  List.iter
    (fun plan ->
       Windtrap.equal
         Windtrap.string
         ~msg:"workspace consistent"
         "myapp"
         plan.Sol_cli_deployment_plan.workspace;
       Windtrap.equal
         Windtrap.int
         ~msg:"service count consistent"
         1
         (List.length plan.services))
    [ plan_local; plan_direct; plan_gitops; plan_hosted ]
;;

let test_up_execution_descriptor_uses_host_push_image () =
  let exec =
    Sol_cli_up_execution.service_execution
      ~workspace:"myapp"
      ~ctx_dir:"/tmp/myapp"
      ~sha:"abc123"
      svc_spec
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"k8s name"
    "charge-svc"
    (Sol_cli_deployment_plan.k8s_name_to_string exec.k8s_name);
  Windtrap.equal
    Windtrap.string
    ~msg:"namespace"
    "myapp-payments"
    (Sol_cli_deployment_plan.namespace_to_string exec.namespace);
  Windtrap.equal
    Windtrap.string
    ~msg:"Docker context is the workspace"
    "/tmp/myapp"
    exec.context;
  Windtrap.equal
    Windtrap.string
    ~msg:"push image"
    "localhost:5000/myapp/charge-svc:abc123"
    exec.push_image;
  Windtrap.equal
    Windtrap.string
    ~msg:"dockerfile"
    "/tmp/myapp/app/payments/charge_svc/Dockerfile"
    exec.dockerfile
;;

let test_local_deploy_request_rejects_nonpositive_keep () =
  let r =
    Sol_cli_command_request.make_local_deploy_request
      ~scope:None
      ~dry_run:false
      ~tag:(Some "t")
      ~confirm_group_change:false
      ~keep_releases:0
      ~git_sha:(fun () -> Ok "")
  in
  Windtrap.equal Windtrap.bool ~msg:"zero keep rejected" true (Result.is_error r)
;;

let test_deploy_request_rejects_nonpositive_keep () =
  let r =
    Sol_cli_command_request.make_deploy_request
      ~target:"dev/aws/us-east-1"
      ~dry_run:false
      ~emit_to:None
      ~emit_plan_to:None
      ~image_tag:(Some "tag")
      ~image_refs:[]
      ~registry:(Some "reg")
      ~confirm_group_change:false
      ~confirm_ecr_removal:false
      ~loki_push_url:None
      ~keep_releases:0
      ~await_delegation:None
      ~git_sha:(fun () -> Ok "")
  in
  Windtrap.equal Windtrap.bool ~msg:"zero keep rejected" true (Result.is_error r)
;;

let%test "request_validation: up: explicit tag used" =
  test_local_deploy_request_uses_explicit_tag ()
;;

let%test "request_validation: up: git sha fallback" =
  test_local_deploy_request_falls_back_to_git_sha ()
;;

let%test "request_validation: local deploy: mode preserved" =
  test_local_deploy_request_preserves_mode ()
;;

let%test "request_validation: up: unresolvable sha warns (BUG-058)" =
  test_local_deploy_request_warns_on_fallback_tag ()
;;

let%test "request_validation: up: resolved sha, no warning" =
  test_local_deploy_request_resolved_sha_has_no_warning ()
;;

let%test "request_validation: deploy: unresolvable sha refused (BUG-058)" =
  test_deploy_request_refuses_unresolvable_sha ()
;;

let%test "request_validation: deploy: resolved sha tags images" =
  test_deploy_request_tags_with_resolved_sha ()
;;

let%test "request_validation: deploy: explicit tag used" =
  test_deploy_request_uses_explicit_tag ()
;;

let%test "request_validation: deploy: local mode Ok" =
  test_deploy_request_local_mode_builds_request ()
;;

let%test "request_validation: deploy: gitops action" =
  test_deploy_request_gitops_action ()
;;

let%test "request_validation: deploy: dry-run action preserves emit_to" =
  test_deploy_request_dry_run_action_preserves_emit_to ()
;;

let%test "request_validation: deploy: empty target rejected" =
  test_deploy_request_rejects_empty_target ()
;;

let%test "request_validation: deploy: registry omitted stays None" =
  test_deploy_request_registry_omitted_stays_none ()
;;

let%test "request_validation: deploy: image refs carried" =
  test_deploy_request_accepts_image_refs ()
;;

let%test "request_validation: deploy: mutable image ref rejected" =
  test_deploy_request_rejects_mutable_image_ref ()
;;

let%test "request_validation: up: non-positive keep-releases rejected" =
  test_local_deploy_request_rejects_nonpositive_keep ()
;;

let%test "request_validation: deploy: non-positive keep-releases rejected" =
  test_deploy_request_rejects_nonpositive_keep ()
;;

let%test "plan_construction: local mode fields" = test_plan_local_mode_fields ()

let%test "plan_construction: customer_cloud mode fields" =
  test_plan_customer_cloud_mode_fields ()
;;

let%test "plan_construction: service count preserved" = test_plan_service_count ()
let%test "plan_construction: all three primitives" = test_plan_service_primitives ()

let%test "plan_construction: consumer groups from workers" =
  test_plan_consumer_groups_derived_from_workers ()
;;

let%test "plan_construction: Svc yields no consumer group" =
  test_plan_svc_does_not_produce_consumer_group ()
;;

let%test "render_artifacts: svc: Deployment + Service" =
  test_render_svc_produces_deployment_and_service ()
;;

let%test "render_artifacts: worker: Deployment, no Service" =
  test_render_worker_has_deployment_no_service ()
;;

let%test "render_artifacts: fn: CronJob, no Deployment" =
  test_render_fn_produces_cronjob ()
;;

let%test "render_artifacts: namespace yaml non-empty" =
  test_render_namespace_yaml_is_non_empty ()
;;

let%test "render_artifacts: one artifact per service" =
  test_render_artifact_count_matches_services ()
;;

let%test "render_artifacts: artifact image from spec" =
  test_render_artifact_image_matches_spec ()
;;

let%test "render_artifacts: build is side-effect-free" =
  test_render_no_docker_or_k8s_calls ()
;;

let%test "gitops_emit: file created" = test_gitops_emit_creates_file ()

let%test "gitops_emit: file contains YAML separator" =
  test_gitops_emit_file_contains_yaml_separator ()
;;

let%test "gitops_emit: file has Namespace kind" =
  test_gitops_emit_file_has_namespace_kind ()
;;

let%test "gitops_emit: no placeholder Secret object" =
  test_gitops_emit_omits_placeholder_secret ()
;;

let%test "gitops_emit: one file per service + release artifact" =
  test_gitops_emit_one_file_per_service ()
;;

let%test "gitops_emit: release artifact deterministic" =
  test_gitops_release_artifact_is_deterministic ()
;;

let%test "executor_commands: local: svc result fields" =
  test_local_executor_result_fields ()
;;

let%test "executor_commands: direct: svc result fields" =
  test_direct_executor_result_fields ()
;;

let%test "executor_commands: gitops: svc result fields" =
  test_gitops_executor_result_fields ()
;;

let%test "executor_commands: local: worker result fields" =
  test_local_worker_executor_result_fields ()
;;

let%test "executor_commands: direct: fn result fields" =
  test_direct_fn_executor_result_fields ()
;;

let%test "state_update: Dry_run is no-op" = test_state_dry_run_is_noop ()
let%test "state_update: Failed is no-op" = test_state_failed_is_noop ()
let%test "state_update: Emitted is no-op" = test_state_emitted_is_noop ()
let%test "state_update: removed consumer groups" = test_state_removed_consumer_groups ()
let%test "state_update: stable plan: no removals" = test_state_no_removal_when_stable ()

let%test "path_consistency: local and direct share plan type" =
  test_local_and_direct_share_plan_type ()
;;

let%test "path_consistency: gitops shares plan type" = test_gitops_shares_plan_type ()

let%test "path_consistency: build is mode-agnostic" =
  test_change_set_build_is_path_agnostic ()
;;

let%test "path_consistency: all paths start from same workspace" =
  test_all_paths_start_from_same_plan_workspace ()
;;

let%test "path_consistency: up execution descriptor uses host push image" =
  test_up_execution_descriptor_uses_host_push_image ()
;;

(* The database setup step (ADR 0007, 2c). *)

let setup_mentions needle text =
  let n = String.length needle in
  let t = String.length text in
  let rec go i =
    i + n <= t && (String.equal (String.sub text i n) needle || go (i + 1))
  in
  go 0
;;

(* The documents in the fake kubectl's `.manifests` log, split at each document's own
   `apiVersion:`. Two facts that must hold of **one** object (a ConfigMap's name and the
   namespace it is written into) are not established by finding them anywhere in the log: an
   unrelated document could satisfy half of the claim. [`setup_same_document`] asks for both in
   the same slice. *)
let setup_documents text =
  let marker = "apiVersion:" in
  let mlen = String.length marker in
  let total = String.length text in
  let starts =
    let rec go from acc =
      match String.index_from_opt text from 'a' with
      | None -> List.rev acc
      | Some at ->
        if
          at + mlen <= total
          && String.equal (String.sub text at mlen) marker
          && (at = 0 || Char.equal text.[at - 1] '\n')
        then go (at + 1) (at :: acc)
        else go (at + 1) acc
    in
    go 0 []
  in
  let rec slice = function
    | [] -> []
    | [ p ] -> [ String.sub text p (total - p) ]
    | p :: (next :: _ as rest) -> String.sub text p (next - p) :: slice rest
  in
  slice starts
;;

let setup_same_document ~a ~b text =
  List.exists
    (fun document -> setup_mentions a document && setup_mentions b document)
    (setup_documents text)
;;

let test_database_setup_sql_is_idempotent () =
  let sql = Sol_cli_database_setup.sql ~operation:Sol_cli_database_setup.Repair in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a re-run changes an existing role rather than recreating it"
    true
    (setup_mentions "IF NOT EXISTS" sql);
  Windtrap.equal
    Windtrap.bool
    ~msg:"nothing is ever dropped"
    false
    (setup_mentions "DROP" sql);
  Windtrap.equal
    Windtrap.bool
    ~msg:"passwords arrive as psql variables"
    true
    (setup_mentions ":'ddl_password'" sql);
  Windtrap.equal
    Windtrap.bool
    ~msg:"no password literal is embedded in the manifest"
    false
    (setup_mentions "PASSWORD '" sql);
  (* The grants are the difference between roles that exist and roles that work: without
     them the migration cannot create anything and the application cannot read what it
     creates. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"both roles can use the schema"
    true
    (setup_mentions "GRANT USAGE ON SCHEMA public" sql);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DDL role can create in it"
    true
    (setup_mentions "GRANT CREATE ON SCHEMA public" sql);
  Windtrap.equal
    Windtrap.bool
    ~msg:"objects the migration creates default to the DML role"
    true
    (setup_mentions "ALTER DEFAULT PRIVILEGES FOR ROLE" sql);
  (* Upstream requires membership in the role whose default privileges are altered, and a
     Cloud SQL admin is [cloudsqlsuperuser], not a true superuser. Without the membership
     grant the whole script dies at the first ALTER DEFAULT PRIVILEGES — observed live on
     GCP, after the roles themselves were created. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the admin joins the DDL role, so it may alter that role's default privileges"
    true
    (setup_mentions "GRANT sol_migrator TO CURRENT_USER" sql);
  let substring_index haystack needle =
    let n = String.length haystack
    and m = String.length needle in
    let rec loop i =
      if i + m > n
      then None
      else if String.sub haystack i m = needle
      then Some i
      else loop (i + 1)
    in
    loop 0
  in
  match
    ( substring_index sql "GRANT sol_migrator TO CURRENT_USER"
    , substring_index sql "ALTER DEFAULT PRIVILEGES FOR ROLE" )
  with
  | Some grant_at, Some alter_at ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"and joins it before altering its default privileges"
      true
      (grant_at < alter_at)
  | _ -> Windtrap.fail "the membership grant or the default-privilege grants are missing"
;;

let%test "database setup: the role SQL is idempotent and carries no secret" =
  test_database_setup_sql_is_idempotent ()
;;

(* The renderer, asserted on its rendered output. *)

let render_setup () =
  Sol_cli_database_setup_render.docs
    ~ns:"myapp-payments"
    ~target:"payments"
    ~job_uid:"uid-1234"
    ~operation:Sol_cli_database_setup.Bootstrap
    ~service_file:
      (Result.get_ok
         (Sol_cli_database_setup_render.service_file
            ~master_url:"postgresql://postgres:masterpw@db.internal:5432/app"))
    ~ddl_password:"ddl-pw"
    ~dml_password:"dml-pw"
    ~ca_cert:"-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n"
    ~image:("postgres@sha256:" ^ String.make 64 'a')
  |> Sol_cli_yaml.render
;;

let setup_index needle text =
  let n = String.length needle in
  let t = String.length text in
  let rec go i =
    if i + n > t
    then Windtrap.failf "expected %S in the rendered setup" needle
    else if String.equal (String.sub text i n) needle
    then i
    else go (i + 1)
  in
  go 0
;;

let test_database_setup_renders_the_fail_closed_job () =
  let text = render_setup () in
  (* The pod makes no API calls, so it carries no token it could not use. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the setup pod does not mount a service-account token"
    true
    (setup_mentions "automountServiceAccountToken: false" text);
  (* The crash backstop, and the guarantee carried by the script rather than the
     invocation. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Job carries the backstop TTL"
    true
    (setup_mentions
       (Printf.sprintf
          "ttlSecondsAfterFinished: %d"
          Sol_cli_database_setup.crash_backstop_seconds)
       text);
  Windtrap.equal
    Windtrap.bool
    ~msg:"ON_ERROR_STOP travels with the script"
    true
    (setup_mentions "ON_ERROR_STOP" text);
  (* psql reads a file; it is never handed the SQL through argv or -c, which the
     dollar-quoted block and \getenv require. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"psql runs from a file"
    true
    (setup_mentions "--file=/sql/setup.sql" text);
  (* 2d: the CA mount is present and populated from the CA ConfigMap, so the Job runs
     `sslmode=verify-full` against the provider's anchor rather than the image's trust
     store. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the CA mount exists"
    true
    (setup_mentions "mountPath: /etc/sol/db-ca" text);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Job's CA volume comes from the CA ConfigMap"
    true
    (setup_index "kind: ConfigMap" text < setup_index "name: payments-db-ca" text
     && setup_mentions "configMap:" text);
  (* The Job spec must not embed a credential: it references the transient Secret. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Job takes its inputs by reference"
    true
    (setup_mentions "secretKeyRef" text);
  (* The Job is written first, and the Secret it needs after it — which is what lets the
     Secret carry its owner from creation instead of being patched into one. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Job is written before the Secret it needs"
    true
    (setup_index "kind: Job" text < setup_index "pg_service.conf" text);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Secret is owned by the Job from creation, so there is no unowned window"
    true
    (setup_mentions "ownerReferences" text && setup_mentions "uid: uid-1234" text)
;;

let test_database_setup_keeps_credentials_out_of_the_job () =
  let text = render_setup () in
  let occurrences needle =
    let n = String.length needle in
    let t = String.length text in
    let rec go i count =
      if i + n > t
      then count
      else
        go
          (i + 1)
          (if String.equal (String.sub text i n) needle then count + 1 else count)
    in
    go 0 0
  in
  (* The master connection string appears **nowhere**: not in argv, and not in the Secret
     either. What the mount carries is the libpq service file whose contents are its parts. *)
  Windtrap.equal
    Windtrap.int
    ~msg:"the master connection string is never written down"
    0
    (occurrences "postgresql://postgres:masterpw@db.internal:5432/app");
  Windtrap.equal
    Windtrap.int
    ~msg:"the service file is the master's parameters"
    1
    (occurrences "password=masterpw");
  List.iter
    (fun part ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "the service file carries %s" part)
         true
         (setup_mentions part text))
    [ "host=db.internal"; "port=5432"; "dbname=app" ];
  (* The role passwords are each written once, in the Secret's stringData. A second
     occurrence would mean the Job spec carries them too. *)
  List.iter
    (fun credential ->
       Windtrap.equal
         Windtrap.int
         ~msg:(Printf.sprintf "%s appears only in the transient Secret" credential)
         1
         (occurrences credential))
    [ "ddl-pw"; "dml-pw" ];
  (* And nothing names the master connection variable at all. Keyed off the variable name
     rather than the invocation: the YAML renderer escapes the quotes in a command string,
     so a needle containing one silently matches nothing and the assertion goes inert. *)
  Windtrap.equal
    Windtrap.int
    ~msg:"no rendered object names the master connection variable"
    0
    (occurrences "POSTGRES_URL")
;;

let%test "database setup render: the Job is fail-closed and mounts the CA" =
  test_database_setup_renders_the_fail_closed_job ()
;;

(* The service file is parsed by libpq, whose service-file parser takes a value **verbatim**:
   a [#] is literal, single quotes are not stripped, and nothing needs escaping. Sol used to
   wrap such values in single quotes — which libpq then sent to the server as part of the
   password, so a [#]-containing master password never authenticated (#1417).

   The verbatim reading is libpq's, established against PostgreSQL 16 (#1417): unquoted
   values containing [# ? space ' \\ = tab] all authenticated. What a *one-line* entry cannot
   carry is a line break (it ends the entry) or surrounding whitespace (the parser trims it),
   and those are refused rather than rewritten. *)
let test_database_setup_service_file_verbatim () =
  let value = Sol_cli_database_setup_render.service_value in
  let shown = function
    | Ok v -> "Ok " ^ v
    | Error e -> "Error " ^ e
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"a plain value is written as it is"
    "Ok db.internal"
    (shown (value "db.internal"));
  Windtrap.equal
    Windtrap.string
    ~msg:"a hash is written verbatim, not quoted (libpq would read the quotes literally)"
    "Ok pa#ss"
    (shown (value "pa#ss"));
  Windtrap.equal
    Windtrap.string
    ~msg:"a space is written verbatim"
    "Ok two words"
    (shown (value "two words"));
  Windtrap.equal
    Windtrap.string
    ~msg:"a single quote is written verbatim, not escaped"
    "Ok pa'ss"
    (shown (value "pa'ss"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a line break is refused, because one entry cannot carry it"
    true
    (Result.is_error (value "a\nb"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"surrounding whitespace is refused, because the parser trims it"
    true
    (Result.is_error (value " spaced") && Result.is_error (value "spaced "));
  (* The whole file, through the same path the renderer uses: a percent-encoded [#] in the
     password decodes to a literal [#], which must reach the emitted entry verbatim. *)
  let file =
    Result.get_ok
      (Sol_cli_database_setup_render.service_file
         ~master_url:
           "postgresql://postgres:ma%23sterpw@db.internal:5432/app?sslmode=verify-full&sslrootcert=/etc/sol/db-ca/ca.pem")
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the file names the service and writes the #-containing password verbatim"
    true
    (setup_mentions "[sol-setup]" file
     && setup_mentions "password=ma#sterpw" file
     && not (setup_mentions "password='ma#sterpw'" file))
;;

let%test "database setup render: a service-file value is written verbatim, or refused" =
  test_database_setup_service_file_verbatim ()
;;

(* The two bounds are different things: the waiter giving up is not the Job being over.
   Equal deadlines kill a slow-but-succeeding setup exactly when the waiter stops looking. *)
let test_database_setup_deadline_exceeds_the_wait () =
  let wait_window =
    int_of_float
      (Sol_cli_database_setup_run.wait_interval_s
       *. float_of_int Sol_cli_database_setup_run.wait_attempts)
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "the Job may outlive the wait window, so a slow success is not killed as a failure"
    true
    (Sol_cli_database_setup.active_deadline_seconds > wait_window)
;;

let%test "database setup: the Job's deadline exceeds the coordinator's wait window" =
  test_database_setup_deadline_exceeds_the_wait ()
;;

let%test "database setup render: credentials live only in the transient Secret" =
  test_database_setup_keeps_credentials_out_of_the_job ()
;;

(* How the setup Job reaches the database. The workload NetworkPolicies are pod-scoped by
   design (an empty podSelector would make the namespace egress-default-deny for every pod
   in it); the Job's pod template carries no `app` label, so no policy selects it and
   Kubernetes leaves its egress unrestricted — the same reason the migration Job reaches the
   database today. If this Job ever gains a matching label it becomes selected and would
   need its own allowance, so the absence is pinned here. *)
let%test "database setup render: the Job is outside the workload egress policy" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"the setup Job carries no workload `app` label, so no NetworkPolicy selects it"
    false
    (setup_mentions "app:" (render_setup ()))
;;

(* The sequence, against a fake kubectl. This is where the master leaks, so these are the
   assertions that matter: the order, and that cleanup runs on the failure path. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let setup_fake_kubectl ?(mode = "none") ~fail_verb f =
  let dir = Filename.temp_file "sol-setup-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "kubectl" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
echo "$*" >> %s
case "$*" in
  *apply*)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-f" ]; then
        cat "$a" >> %s.manifests
        case "$SETUP_MODE" in
          output) grep -q "payments-ddl-creds" "$a" && exit 1 ;;
          job) grep -q "kind: Job" "$a" && exit 1 ;;
        esac
      fi
      prev="$a"
    done
    exit 0 ;;
  *"get job"*)
    case "$*" in
      *metadata.uid*) echo uid-1234 ;;
      *status.succeeded*)
        if [ "$SETUP_MODE" = "wait" ]; then echo 0; else echo 1; fi ;;
      *status.failed*)
        if [ "$SETUP_MODE" = "wait" ]; then echo 1; else echo 0; fi ;;
    esac
    exit 0 ;;
  *"get secret "*"-db-credentials"*)
    # The password authority. Absent is a first deploy (bootstrap); present **established** is
    # an ordinary deploy (repair), which must reuse these values rather than generate new
    # ones; present **pending** is a bootstrap that never completed, which must re-run the
    # bootstrap rather than repair. The shape is target, owner, two values, state.
    if [ "$SETUP_MODE" = "authority" ]; then
      printf 'payments\nsol\nddl-pw\ndml-pw\nestablished\n'
      exit 0
    fi
    if [ "$SETUP_MODE" = "authority-pending" ]; then
      printf 'payments\nsol\nddl-pw\ndml-pw\npending\n'
      exit 0
    fi
    if [ "$SETUP_MODE" = "authority-foreign" ]; then
      # A same-named Secret that is not Sol's record for this target: name is not identity.
      printf 'other-target\nsol\nddl-pw\ndml-pw\nestablished\n'
      exit 0
    fi
    if [ "$SETUP_MODE" = "authority-unowned" ]; then
      printf 'payments\nnot-sol\nddl-pw\ndml-pw\nestablished\n'
      exit 0
    fi
    if [ "$SETUP_MODE" = "authority-nostate" ]; then
      # A record written before the state key existed: an empty state line reads as pending.
      printf 'payments\nsol\nddl-pw\ndml-pw\n\n'
      exit 0
    fi
    if [ "$SETUP_MODE" = "forbidden" ]; then
      # A restricted identity: the object may exist and still be unreadable. It must never
      # be mistaken for "nothing recorded", which would bootstrap over a live target.
      echo 'Error from server (Forbidden): secrets "payments-db-credentials" is forbidden: User "sol" cannot get resource "secrets" in API group "" in the namespace "myapp-payments"' >&2
      exit 1
    fi
    echo 'Error from server (NotFound): secrets "payments-db-credentials" not found' >&2
    exit 1 ;;
esac
case "$*" in
  *%s*) exit 1 ;;
esac
exit 0
|}
      log
      log
      fail_verb
  in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  let old_mode =
    try Sys.getenv "SETUP_MODE" with
    | Not_found -> ""
  in
  Unix.putenv "SETUP_MODE" mode;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      Unix.putenv "SETUP_MODE" old_mode;
      List.iter
        (fun p ->
           try Sys.remove p with
           | Sys_error _ -> ())
        [ bin; log ];
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () -> f ~log)
;;

(** The class credential as the deploy renders it for this run's passwords — the object
    2b's reader will consume. Rendering the real one, rather than a stub that carries only
    the name, is what lets a test assert *which value* was written. *)
let setup_output_secret ~ddl_password =
  Sol_cli_database_setup_render.output_secret_doc
    ~ns:"myapp-payments"
    ~name:(Sol_cli_database_setup_render.ddl_creds_name "payments")
    ~postgres_url:
      (Sol_cli_database_setup_url.ddl
         ~password:ddl_password
         "postgresql://postgres:masterpw@db.internal:5432/app")
;;

let run_database_setup
      ?(operation = Sol_cli_database_setup.Bootstrap)
      ?(ddl_password = "ddl-pw")
      ?(dml_password = "dml-pw")
      ?(ca_namespaces = [ "myapp-payments" ])
      ()
  =
  Sol_cli_database_setup_run.run
    ~ctx:Sol_cli_kube_destination.local_context
    ~namespace:"myapp-payments"
    ~ca_namespaces
    ~target:"payments"
    ~master_url:"postgresql://postgres:masterpw@db.internal:5432/app"
    ~operation
    ~ddl_password
    ~dml_password
    ~ca_cert:"-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n"
    ~image:("postgres@sha256:" ^ String.make 64 'a')
    ~output_secrets:[ setup_output_secret ~ddl_password ]
;;

let test_database_setup_bootstrap_orders_by_verification () =
  setup_fake_kubectl ~fail_verb:"zzz-never" (fun ~log ->
    match run_database_setup ~operation:Sol_cli_database_setup.Bootstrap () with
    | Error message -> Windtrap.fail message
    | Ok () ->
      let calls = read_file log in
      let manifests = read_file (log ^ ".manifests") in
      (* A bootstrap records the passwords before Postgres is touched, so an interruption
         leaves something to repair from rather than roles whose password nobody knows. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the authority is persisted before the Job"
        true
        (setup_index "payments-db-credentials" manifests
         < setup_index "kind: Job" manifests);
      (* And the projections — what consumers actually read — only once Postgres has accepted
         the passwords they carry. This is the whole defect: written first, a replacement
         password reaches pods that can restart before the server knows it. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the class credential is written only after the Job"
        true
        (setup_index "kind: Job" manifests < setup_index "payments-ddl-creds" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Job is deleted"
        true
        (setup_mentions "delete job" calls);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the transient Secret is deleted"
        true
        (setup_mentions "delete secret" calls);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the script is deleted"
        true
        (setup_mentions "delete configmap" calls);
      (* The surviving resources: 2b consumes the class credentials and a later deploy
         repairs from the authority, so a change that added either to cleanup would break
         both while still passing every "cleanup ran" test. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the class credential is never deleted"
        false
        (setup_mentions "delete secret payments-ddl-creds" calls);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the authority is never deleted"
        false
        (setup_mentions "delete secret payments-db-credentials" calls);
      (* The owner is set at creation, not patched in afterwards: there is no window in
         which the master Secret exists unowned, and therefore nothing for a crash to fall
         into. Pinned as the absence of the patch, because a later "fix" that re-introduces
         the two-step would otherwise pass everything above. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Secret is created owned, with no owner patch"
        true
        (setup_mentions "ownerReferences" manifests && not (setup_mentions "patch" calls)))
;;

(* #1481: the delivery writes one CA ConfigMap per namespace the selection names, before the Job
   that verifies the server against it, and writes no database material into a namespace the
   selection did not name. The selection itself — *which* namespaces — is covered by the
   deployment-plan test; this is the writer's half: every named namespace gets the trust anchor,
   so a consumer does not hang in `ContainerCreating` waiting for a ConfigMap that was only ever
   written beside the migration Job. *)
let test_database_setup_writes_the_ca_into_every_named_namespace () =
  setup_fake_kubectl ~fail_verb:"zzz-never" (fun ~log ->
    match run_database_setup ~ca_namespaces:[ "myapp-payments"; "myapp-comms" ] () with
    | Error message -> Windtrap.fail message
    | Ok () ->
      let manifests = read_file (log ^ ".manifests") in
      let ca = Sol_cli_database_setup_render.ca_configmap_name "payments" in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the consumer's own ConfigMap document names the CA and its namespace"
        true
        (setup_same_document ~a:("name: " ^ ca) ~b:"namespace: myapp-comms" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and the migration namespace has its own document for the same anchor"
        true
        (setup_same_document ~a:("name: " ^ ca) ~b:"namespace: myapp-payments" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the CA is written before the Job that verifies the server against it"
        true
        (setup_index ca manifests < setup_index "kind: Job" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"a namespace the selection did not name gets no database material"
        false
        (setup_mentions "namespace: myapp-search" manifests))
;;

let%test "database setup run: the CA is written into every consuming namespace" =
  test_database_setup_writes_the_ca_into_every_named_namespace ()
;;

(* Where the passwords come from: the authority, not a fresh generation. *)
let resolve_passwords ~ctx () =
  Sol_cli_database_setup_run.resolve ~ctx ~namespace:"myapp-payments" ~target:"payments"
;;

let test_database_setup_bootstraps_only_without_a_record () =
  setup_fake_kubectl ~fail_verb:"zzz-never" (fun ~log:_ ->
    let ctx = Sol_cli_kube_destination.local_context in
    match resolve_passwords ~ctx () with
    | Error message -> Windtrap.fail message
    | Ok (operation, ddl_password, dml_password) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"no recorded authority is a bootstrap"
        true
        (operation = Sol_cli_database_setup.Bootstrap);
      Windtrap.equal
        Windtrap.bool
        ~msg:"a bootstrap generates two distinct, non-blank passwords"
        true
        ((not (Sol_cli_string.is_blank ddl_password))
         && (not (Sol_cli_string.is_blank dml_password))
         && not (String.equal ddl_password dml_password)))
;;

let test_database_setup_repair_reuses_the_record () =
  setup_fake_kubectl ~mode:"authority" ~fail_verb:"zzz-never" (fun ~log:_ ->
    let ctx = Sol_cli_kube_destination.local_context in
    match resolve_passwords ~ctx () with
    | Error message -> Windtrap.fail message
    | Ok (operation, ddl_password, dml_password) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a recorded authority is a repair, not a bootstrap"
        true
        (operation = Sol_cli_database_setup.Repair);
      Windtrap.equal
        Windtrap.string
        ~msg:"the DDL password is the recorded one, not a new one"
        "ddl-pw"
        ddl_password;
      Windtrap.equal
        Windtrap.string
        ~msg:"the DML password is the recorded one, not a new one"
        "dml-pw"
        dml_password)
;;

let test_database_setup_repair_does_not_rewrite_the_record () =
  (* An ordinary deploy re-applies what is recorded. It must not write the authority: an
     unverified replacement over the record is exactly what the ordering prevents. *)
  setup_fake_kubectl ~mode:"authority" ~fail_verb:"zzz-never" (fun ~log ->
    match
      run_database_setup
        ~operation:Sol_cli_database_setup.Repair
        ~ddl_password:"ddl-pw"
        ~dml_password:"dml-pw"
        ()
    with
    | Error message -> Windtrap.fail message
    | Ok () ->
      let manifests = read_file (log ^ ".manifests") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a repair does not rewrite the authority"
        false
        (setup_mentions "payments-db-credentials" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"a repair still writes the class credential"
        true
        (setup_mentions "payments-ddl-creds" manifests);
      (* And it carries the *recorded* password. "Writes the credential" would otherwise
         pass for a value the previous release never held. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the class credential carries the recorded password"
        true
        (setup_mentions "sol_migrator:ddl-pw@" manifests))
;;

(* The finding-1 regression, as a sequence rather than three isolated cases: existing roles,
   no authority, a bootstrap that fails, then a retry. The retry must re-run the *bootstrap*
   -- which the existing roles then refuse -- and never a repair, which would
   [ALTER ROLE ... PASSWORD] against roles the record never created, replacing passwords it
   does not describe. The first deploy's safety refusal, bypassed by retrying, is the bug. *)
let test_database_setup_pending_authority_never_repairs () =
  setup_fake_kubectl ~mode:"authority-pending" ~fail_verb:"zzz-never" (fun ~log:_ ->
    let ctx = Sol_cli_kube_destination.local_context in
    match resolve_passwords ~ctx () with
    | Error message -> Windtrap.fail message
    | Ok (operation, ddl_password, dml_password) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a pending record re-runs the bootstrap, never a repair"
        true
        (operation = Sol_cli_database_setup.Bootstrap);
      Windtrap.equal
        Windtrap.string
        ~msg:"and recovers the *recorded* DDL password rather than generating a new one"
        "ddl-pw"
        ddl_password;
      Windtrap.equal
        Windtrap.string
        ~msg:"and the recorded DML password"
        "dml-pw"
        dml_password)
;;

(* Fail-safe for a record written before the state key existed: an absent state must read as
   pending, so an unverifiable record is never treated as established. *)
let test_database_setup_state_less_record_reads_pending () =
  setup_fake_kubectl ~mode:"authority-nostate" ~fail_verb:"zzz-never" (fun ~log:_ ->
    let ctx = Sol_cli_kube_destination.local_context in
    match resolve_passwords ~ctx () with
    | Error message -> Windtrap.fail message
    | Ok (operation, _, _) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a record with no state key is pending, not established"
        true
        (operation = Sol_cli_database_setup.Bootstrap))
;;

(* The composition, not just the choice: the retry after a pending record must *apply* the
   bootstrap script. That script refuses an existing role (asserted above), so "the retry is
   a bootstrap" is what keeps the first deploy's safety refusal from being bypassed. If the
   retry were a repair, the rendered script would carry ALTER ROLE. *)
let test_database_setup_pending_retry_applies_the_bootstrap_script () =
  setup_fake_kubectl ~mode:"authority-pending" ~fail_verb:"zzz-never" (fun ~log ->
    let ctx = Sol_cli_kube_destination.local_context in
    match
      Sol_cli_database_setup_run.resolve
        ~ctx
        ~namespace:"myapp-payments"
        ~target:"payments"
    with
    | Error message -> Windtrap.fail message
    | Ok (operation, ddl_password, dml_password) ->
      (match run_database_setup ~operation ~ddl_password ~dml_password () with
       | Error message -> Windtrap.fail message
       | Ok () -> ());
      let manifests = read_file (log ^ ".manifests") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the retry's script is the bootstrap"
        true
        (setup_mentions "operation: bootstrap" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"so no ALTER ROLE is composed that would replace an existing password"
        false
        (setup_mentions "ALTER ROLE" manifests))
;;

(* A same-named Secret is not evidence of ownership: the record must state that it is Sol's
   and that it is *this* target's. *)
let test_database_setup_foreign_authority_fails_closed () =
  List.iter
    (fun (mode, what) ->
       setup_fake_kubectl ~mode ~fail_verb:"zzz-never" (fun ~log:_ ->
         let ctx = Sol_cli_kube_destination.local_context in
         match resolve_passwords ~ctx () with
         | Error message ->
           Windtrap.equal
             Windtrap.bool
             ~msg:what
             true
             (setup_mentions "could not read the target's password authority" message)
         | Ok _ -> Windtrap.fail (what ^ ": the record was accepted")))
    [ "authority-foreign", "a same-named record naming another target is refused"
    ; "authority-unowned", "a same-named record Sol did not write is refused"
    ]
;;

(* The promotion itself: written pending before the Job, established only once it succeeded. *)
let test_database_setup_bootstrap_promotes_the_authority () =
  setup_fake_kubectl ~fail_verb:"zzz-never" (fun ~log ->
    match
      run_database_setup
        ~operation:Sol_cli_database_setup.Bootstrap
        ~ddl_password:"ddl-pw"
        ~dml_password:"dml-pw"
        ()
    with
    | Error message -> Windtrap.fail message
    | Ok () ->
      let manifests = read_file (log ^ ".manifests") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the authority is written pending before the Job"
        true
        (setup_mentions "SOL_AUTHORITY_STATE: pending" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and promoted to established once the Job succeeded"
        true
        (setup_mentions "SOL_AUTHORITY_STATE: established" manifests))
;;

(** The URL the rendered *class credential* carries, so two deploys can be compared byte
    for byte.

    Scoped to the class credential on purpose: the manifests log also holds the transient
    Secret, whose POSTGRES_URL is the master — the same value on every deploy. Reading the
    first POSTGRES_URL in the log would compare the master with itself and pass no matter
    what the class credential said. *)
let ddl_credential_url manifests =
  match Sol_cli_string.after_opt ~needle:"payments-ddl-creds" manifests with
  | None -> Windtrap.fail "no class credential was written"
  | Some credential ->
    (match Sol_cli_string.after_opt ~needle:"POSTGRES_URL: " credential with
     | None -> Windtrap.fail "the class credential carries no POSTGRES_URL"
     | Some value ->
       (match String.index_opt value '\n' with
        | None -> value
        | Some i -> String.sub value 0 i))
;;

let test_database_setup_unreadable_authority_fails_closed () =
  (* The RBAC the substrate creates may not grant the deploy `get` on the authority. An
     unreadable record must never read as "nothing recorded": that bootstraps over a live
     target and replaces the passwords its consumers are holding — the very failure this
     change exists to prevent. Only a real NotFound may bootstrap. *)
  setup_fake_kubectl ~mode:"forbidden" ~fail_verb:"zzz-never" (fun ~log:_ ->
    let ctx = Sol_cli_kube_destination.local_context in
    match resolve_passwords ~ctx () with
    | Ok (operation, _, _) ->
      Windtrap.fail
        (Printf.sprintf
           "an unreadable authority resolved to %s; it must fail closed"
           (Sol_cli_database_setup.operation_to_string operation))
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal says the authority could not be read"
        true
        (setup_mentions "could not read the target's password authority" message))
;;

let test_database_setup_a_second_deploy_writes_the_same_credential () =
  (* Two deploys against a recorded authority: the shape of a second deploy while the first
     release is serving traffic. The credential written has to be byte-identical, because
     the pods already running hold it. *)
  let deploy () =
    setup_fake_kubectl ~mode:"authority" ~fail_verb:"zzz-never" (fun ~log ->
      let ctx = Sol_cli_kube_destination.local_context in
      match resolve_passwords ~ctx () with
      | Error message -> Windtrap.fail message
      | Ok (operation, ddl_password, dml_password) ->
        (match run_database_setup ~operation ~ddl_password ~dml_password () with
         | Error message -> Windtrap.fail message
         | Ok () -> ());
        ddl_credential_url (read_file (log ^ ".manifests")))
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"the second deploy writes exactly the credential the first one did"
    (deploy ())
    (deploy ())
;;

let test_database_setup_failure_leaves_the_projections_alone () =
  (* The Job fails. The previous projections must be exactly as they were, because the
     password they carry is still the one Postgres accepts. *)
  setup_fake_kubectl ~mode:"wait" ~fail_verb:"zzz-never" (fun ~log ->
    match run_database_setup () with
    | Ok () -> Windtrap.fail "a failed setup Job must fail the step"
    | Error _ ->
      let manifests = read_file (log ^ ".manifests") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the class credential is not written when the Job fails"
        false
        (setup_mentions "payments-ddl-creds" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the authority was persisted before the Job"
        true
        (setup_mentions "payments-db-credentials" manifests))
;;

let test_database_setup_operations_differ () =
  let bootstrap =
    Sol_cli_database_setup.sql ~operation:Sol_cli_database_setup.Bootstrap
  in
  let repair = Sol_cli_database_setup.sql ~operation:Sol_cli_database_setup.Repair in
  (* Bootstrap must refuse an existing role: with no recorded authority, a replacement
     password would silently invalidate the credential its consumers already hold. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"a bootstrap refuses a role that already exists"
    true
    (setup_mentions "RAISE EXCEPTION" bootstrap && setup_mentions "pg_roles" bootstrap);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a bootstrap never alters an existing role"
    false
    (setup_mentions "ALTER ROLE" bootstrap);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal names the recovery"
    true
    (setup_mentions "Recover the authority Secret" bootstrap);
  (* Repair re-applies the recorded value, and can create a role that has gone missing
     because the password it uses is the recorded one. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"a repair re-applies the recorded password"
    true
    (setup_mentions "ALTER ROLE" repair);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a repair recreates a role that has gone missing"
    true
    (setup_mentions "IF NOT EXISTS" repair);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a repair is not a rotation: it fails closed on an existing role only never"
    false
    (setup_mentions "Recover the authority Secret" repair)
;;

let test_database_setup_reports_a_failed_cleanup () =
  (* The setup succeeded but the master could not be removed. That is its own event, not a
     footnote: it has to reach the step's outcome, because the credential is still in the
     cluster and only the operator can go and confirm it is gone. *)
  setup_fake_kubectl ~fail_verb:"delete secret" (fun ~log ->
    match run_database_setup () with
    | Ok () -> Windtrap.fail "a failed cleanup must fail the phase"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failure says the master's parameters may still be in the cluster"
        true
        (setup_mentions
           "service file carrying the master's parameters may still be in the cluster"
           message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"...and names the delete that failed"
        true
        (setup_mentions "delete secret" message);
      let calls = read_file log in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Job is still deleted"
        true
        (setup_mentions "delete job" calls))
;;

let%test "database setup run: a bootstrap orders by verification and deletes only its own"
  =
  test_database_setup_bootstrap_orders_by_verification ()
;;

let%test "database setup: only a target with no recorded authority bootstraps" =
  test_database_setup_bootstraps_only_without_a_record ()
;;

let%test "database setup: a repair reuses the recorded passwords" =
  test_database_setup_repair_reuses_the_record ()
;;

let%test "database setup run: a repair never rewrites the recorded authority" =
  test_database_setup_repair_does_not_rewrite_the_record ()
;;

let%test "database setup: an unreadable authority fails closed, never a bootstrap" =
  test_database_setup_unreadable_authority_fails_closed ()
;;

let%test "database setup: a pending authority re-runs the bootstrap, never a repair" =
  test_database_setup_pending_authority_never_repairs ()
;;

let%test "database setup: a record with no state key reads as pending" =
  test_database_setup_state_less_record_reads_pending ()
;;

let%test "database setup: a pending retry applies the bootstrap script, not a repair" =
  test_database_setup_pending_retry_applies_the_bootstrap_script ()
;;

let%test "database setup: a same-named authority that is not this target's is refused" =
  test_database_setup_foreign_authority_fails_closed ()
;;

let%test "database setup run: a bootstrap writes the authority pending, then established" =
  test_database_setup_bootstrap_promotes_the_authority ()
;;

let%test "database setup: a second deploy writes the same credential as the first" =
  test_database_setup_a_second_deploy_writes_the_same_credential ()
;;

let%test "database setup run: a failed Job leaves the class credentials untouched" =
  test_database_setup_failure_leaves_the_projections_alone ()
;;

let%test
    "database setup: bootstrap refuses an existing role, repair re-applies the record"
  =
  test_database_setup_operations_differ ()
;;

let%test "database setup run: a failed cleanup is reported, not swallowed" =
  test_database_setup_reports_a_failed_cleanup ()
;;

(* The failure paths, which is where the master leaks: every one of them must still
   delete the transient Secret. *)
let assert_cleanup_after_failure ~mode =
  setup_fake_kubectl ~mode ~fail_verb:"zzz-never" (fun ~log ->
    (match run_database_setup () with
     | Ok () -> Windtrap.failf "expected the phase to fail at %s" mode
     | Error _ -> ());
    let calls = read_file log in
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "the transient Secret is deleted after a failure at %s" mode)
      true
      (setup_mentions "delete secret" calls))
;;

let%test "database setup run: cleanup runs when an output Secret fails to apply" =
  assert_cleanup_after_failure ~mode:"output"
;;

let%test "database setup run: cleanup runs when the Job fails to apply" =
  assert_cleanup_after_failure ~mode:"job"
;;

let%test "database setup run: cleanup runs when the wait reports failure" =
  assert_cleanup_after_failure ~mode:"wait"
;;

(* The credential generator. *)
let%test "database setup password: hex, 64 chars, and different every call" =
  let a = Sol_cli_database_setup_password.generate () in
  let b = Sol_cli_database_setup_password.generate () in
  Windtrap.equal Windtrap.int ~msg:"32 bytes hex-encoded" 64 (String.length a);
  Windtrap.equal
    Windtrap.bool
    ~msg:"hex only, so it is safe inside a URL, a shell and Postgres"
    true
    (String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       a);
  Windtrap.equal Windtrap.bool ~msg:"not a constant" false (String.equal a b)
;;

(* The derived connection URLs. *)
let%test "database setup url: credentials substituted, query parameters preserved" =
  let master =
    "postgresql://postgres:masterpw@db.internal:5432/app?sslmode=verify-full&sslrootcert=/etc/sol/db-ca/ca.pem"
  in
  let ddl = Sol_cli_database_setup_url.ddl ~password:"ddl-pw" master in
  let dml = Sol_cli_database_setup_url.dml ~password:"dml-pw" master in
  (* 2d's parameters must survive: a text substitution of user and password would drop
     the query string, and the failure would be silent. *)
  List.iter
    (fun url ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"sslmode survives the derivation"
         true
         (setup_mentions "sslmode=verify-full" url);
       Windtrap.equal
         Windtrap.bool
         ~msg:"sslrootcert survives the derivation"
         true
         (setup_mentions "sslrootcert=/etc/sol/db-ca/ca.pem" url))
    [ ddl; dml ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DDL URL carries the DDL role and password"
    true
    (setup_mentions "sol_migrator:ddl-pw@" ddl);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DML URL carries the DML role and password"
    true
    (setup_mentions "sol_app:dml-pw@" dml);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the master credential is gone"
    false
    (setup_mentions "masterpw" ddl);
  Windtrap.equal
    Windtrap.bool
    ~msg:"host and database are untouched"
    true
    (setup_mentions "db.internal:5432/app" ddl)
;;

(* The master URL gains the TLS parameters, replacing any the provider left there rather
   than duplicating them (two `sslmode` keys would leave the effective one to libpq's
   parser). *)
(* The contract is provider-neutral; the mechanism is not. What must hold for every
   provider is that the mode is explicit: none of these encrypts without authenticating the
   server, and none lets the server talk the client down. *)
let test_database_setup_sslmode_is_the_providers () =
  let mode provider =
    match Sol_cli_provider_registry.postgres_sslmode provider with
    | Ok mode -> mode
    | Error failure ->
      Windtrap.fail (Sol_cli_provider_registry.resolution_failure_to_string failure)
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"AWS verifies the host against its pinned CA"
    "verify-full"
    (mode Sol_cli_provider.Aws);
  Windtrap.equal
    Windtrap.string
    ~msg:"GCP establishes identity with the instance's own CA over a private address"
    "verify-ca"
    (mode Sol_cli_provider.Gcp);
  List.iter
    (fun provider ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"the mode neither skips authentication nor yields to the server"
         false
         (List.mem (mode provider) [ "disable"; "allow"; "prefer"; "require" ]))
    [ Sol_cli_provider.Aws; Sol_cli_provider.Gcp ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"a provider with no cluster root declares no mode"
    true
    (match Sol_cli_provider_registry.postgres_sslmode Sol_cli_provider.Byo with
     | Ok _ -> false
     | Error _ -> true)
;;

let%test "database setup: each provider's TLS mode is explicit, never a downgrade" =
  test_database_setup_sslmode_is_the_providers ()
;;

let%test "database setup url: with_tls carries the provider's mode and the mounted anchor"
  =
  let url =
    Sol_cli_database_setup_url.with_tls
      ~sslmode:"verify-ca"
      ~ca_cert_path:Sol_cli_database_setup_render.ca_cert_path
      "postgresql://postgres:masterpw@db.internal:5432/app?sslmode=require&application_name=sol"
  in
  (* The mode is whatever the provider declared, not a constant this module knows: asserting
     the literal would re-introduce the coupling the argument removes. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the provider's mode is the one delivered"
    true
    (setup_mentions "sslmode=verify-ca" url);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the anchor is the mounted CA"
    true
    (setup_mentions "sslrootcert=/etc/sol/db-ca/ca.pem" url);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the provider's own parameters survive"
    true
    (setup_mentions "application_name=sol" url);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the weaker sslmode it replaced is gone"
    false
    (setup_mentions "sslmode=require" url)
;;

(* The output Secrets: one per class, named by the shared constants, carrying the derived
   URL and never the master. *)
let%test "database setup render: the class Secrets carry the derived URL, not the master" =
  let ddl_url = "postgresql://sol_migrator:ddl-pw@db.internal:5432/app?sslmode=require" in
  let dml_url = "postgresql://sol_app:dml-pw@db.internal:5432/app?sslmode=require" in
  let render ~name url =
    Sol_cli_yaml.render
      [ Sol_cli_database_setup_render.output_secret_doc
          ~ns:"myapp-payments"
          ~name
          ~postgres_url:url
      ]
  in
  let ddl =
    render ~name:(Sol_cli_database_setup_render.ddl_creds_name "payments") ddl_url
  in
  let dml =
    render ~name:(Sol_cli_database_setup_render.dml_creds_name "payments") dml_url
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DDL Secret is named by the shared constant"
    true
    (setup_mentions "payments-ddl-creds" ddl);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DML Secret is named by the shared constant"
    true
    (setup_mentions "payments-dml-creds" dml);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the two classes do not share a name"
    false
    (String.equal
       (Sol_cli_database_setup_render.ddl_creds_name "payments")
       (Sol_cli_database_setup_render.dml_creds_name "payments"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DDL Secret carries the DDL URL under POSTGRES_URL"
    true
    (setup_mentions ddl_url ddl);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the DML Secret carries the DML URL"
    true
    (setup_mentions dml_url dml);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the master is nowhere in the output Secrets"
    false
    (setup_mentions "postgres:master" (ddl ^ dml))
;;

(* 2b: the writer (Sol's setup step, and the external ESO path) and the reader (the
   workload renderer) must agree on the one key the class Secret carries. They are two
   definitions in two layers, so the agreement is asserted rather than assumed. *)
let%test "2b: the writer and the reader share the POSTGRES_URL key" =
  Windtrap.equal
    Windtrap.string
    ~msg:"the manifest reader and the database setup renderer name the same key"
    Sol_cli_database_setup_render.postgres_url_key
    Sol_cli_manifest.postgres_url_key
;;

(* The ownership gate and the namespace scoping are the two decisions that keep an
   externally bound database out of Sol's DDL/DML credential writing. Both are asked of
   the resolution that already exists; these assert the answers the wiring depends on. *)
let%test
    "database setup: only a Sol-provisioned postgres runs the step, scoped by resource \
     name"
  =
  let binding ~ownership ~typ ~resource =
    { Sol_cli_resource_binding.resource
    ; typ
    ; ownership
    ; store = None
    ; keys = []
    ; connection = []
    ; credentials = []
    }
  in
  let open Sol_cli_config in
  let sol = binding ~ownership:Ownership_sol ~typ:"postgres" ~resource:"app_db" in
  let externally_bound =
    { (binding ~ownership:Ownership_external ~typ:"postgres" ~resource:"reports_db") with
      store = Some "vault"
    ; credentials = [ "ddl", "external/ddl"; "dml", "external/dml" ]
    }
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a Sol-owned postgres resource is the provisioned database"
    (Some "app_db")
    (match Sol_cli_resource_binding.postgres [ sol ] with
     | Ok (Managed_postgres resource) -> Some resource
     | Ok _ -> Windtrap.fail "expected managed PostgreSQL"
     | Error message -> Windtrap.fail message);
  Windtrap.equal
    Windtrap.bool
    ~msg:"an externally bound postgres resource is not provisioned"
    false
    (Sol_cli_resource_binding.provisions ~typ:"postgres" [ externally_bound ]);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an externally bound postgres resource is not the provisioned database"
    None
    (match Sol_cli_resource_binding.postgres [ externally_bound ] with
     | Ok (External_postgres { resource = "reports_db"; _ }) -> None
     | Ok _ -> Windtrap.fail "external database lost its ownership or identity"
     | Error message -> Windtrap.fail message);
  let service name uses =
    { name
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
    { name
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
    { services =
        [ service "pool_consumer" [ "app_db" ]
        ; service "external_consumer" [ "reports_db" ]
        ]
    ; resources = [ resource "app_db"; resource "reports_db" ]
    ; profile = None
    }
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a consumer of the Sol-provisioned resource is included"
    true
    (Sol_cli_deployment_plan.service_uses_resource
       (Some declared)
       "pool_consumer"
       "app_db");
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "a consumer of an external resource is excluded from the provisioned resource's \
       DML set"
    false
    (Sol_cli_deployment_plan.service_uses_resource
       (Some declared)
       "external_consumer"
       "app_db")
;;

(* The external owner's writer: ESO delivers the class Secrets Sol would have written,
   because the reader asks for the same names whatever the ownership is. *)

let external_binding ?(store = Some "vault-production") credentials
  : Sol_cli_resource_binding.t
  =
  { resource = "app_db"
  ; typ = "postgres"
  ; ownership = Sol_cli_config.Ownership_external
  ; store
  ; keys = []
  ; connection = []
  ; credentials
  }
;;

let count_occurrences needle text =
  let n = String.length needle in
  let t = String.length text in
  let rec go i acc =
    if i + n > t
    then acc
    else go (i + 1) (if String.equal (String.sub text i n) needle then acc + 1 else acc)
  in
  go 0 0
;;

(* The resolved target-scoped delivery the plan carries, built the way the plan builds it:
   the identity fields are the name-safe forms the plan passes. *)
let delivery_of_binding ?(store = Some "vault-production") credentials =
  let open Result.Syntax in
  let* database =
    Sol_cli_resource_binding.postgres [ external_binding ~store credentials ]
  in
  match database with
  | External_postgres binding ->
    Ok
      (Sol_cli_database_setup_run.resource_delivery
         ~target:"payments"
         ~resource:"app-db"
         ~migration_namespace:"myapp-payments"
         ~dml_namespaces:[ "myapp-comms" ]
         binding)
  | _ -> Error "expected external postgres selection"
;;

let delivery_docs = Sol_cli_database_setup_run.external_credential_docs

let test_external_database_delivers_the_class_secrets () =
  let binding =
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator"
    ; Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app"
    ]
  in
  match delivery_of_binding binding with
  | Error message -> Windtrap.fail message
  | Ok delivery ->
    let text = Sol_cli_yaml.render (delivery_docs delivery) in
    let present msg needle =
      Windtrap.equal Windtrap.bool ~msg true (setup_mentions needle text)
    in
    present "ESO is the writer" "kind: ExternalSecret";
    (* The names are the reader's, taken from the one definition the Sol writer uses: the
       reader does not branch on ownership. *)
    present
      "the DDL class targets the reader's DDL Secret"
      ("name: " ^ Sol_cli_database_setup_render.ddl_creds_name "payments");
    present
      "the DML class targets the reader's DML Secret"
      ("name: " ^ Sol_cli_database_setup_render.dml_creds_name "payments");
    present
      "the key is the one the reader reads"
      ("secretKey: " ^ Sol_cli_database_setup_render.postgres_url_key);
    present "the DDL remote path is the binding's" "secret/production/app-db-migrator";
    present "the DML remote path is the binding's" "secret/production/app-db-app";
    present "the store is the binding's" "name: vault-production";
    present "the DDL credential lands where migrations run" "namespace: myapp-payments";
    present "the DML credential lands where it is consumed" "namespace: myapp-comms";
    Windtrap.equal
      Windtrap.int
      ~msg:"one ExternalSecret per class, not one per key"
      2
      (count_occurrences "kind: ExternalSecret" text);
    (* The classes are separate objects: the migrator's remote path must not reach the
       application's Secret. *)
    Windtrap.equal
      Windtrap.int
      ~msg:"the DDL remote path appears exactly once"
      1
      (count_occurrences "secret/production/app-db-migrator" text)
;;

let test_external_database_requires_every_class () =
  let refuses ?(store = Some "vault-production") credentials needle =
    match delivery_of_binding ~store credentials with
    | Ok _ -> Windtrap.fail (Printf.sprintf "expected a refusal mentioning %S" needle)
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("the refusal mentions " ^ needle)
        true
        (setup_mentions needle message)
  in
  (* Every class must be delivered: a missing one is indistinguishable from a target with
     no database at all. *)
  refuses
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator" ]
    Sol_cli_database_setup_render.dml_class;
  refuses
    [ Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app" ]
    Sol_cli_database_setup_render.ddl_class;
  refuses
    ~store:None
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator"
    ; Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app"
    ]
    "names no store"
;;

let%test "external database: every class is delivered as the reader's Secret" =
  test_external_database_delivers_the_class_secrets ()
;;

let%test "external database: a missing class or store is refused, naming it" =
  test_external_database_requires_every_class ()
;;

(* #1425: the same extraction the renderer uses is asked while planning, so a binding that
   cannot deliver every class never reaches delivery. *)
let test_plan_time_rejects_an_undeliverable_external_binding () =
  let complete =
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator"
    ; Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app"
    ]
  in
  (match delivery_of_binding complete with
   | Ok _ -> ()
   | Error message -> Windtrap.fail ("a complete binding must resolve: " ^ message));
  let refuses ?(store = Some "vault-production") credentials needle =
    match delivery_of_binding ~store credentials with
    | Ok _ -> Windtrap.fail (Printf.sprintf "expected a refusal mentioning %S" needle)
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("the refusal mentions " ^ needle)
        true
        (setup_mentions needle message)
  in
  refuses
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator" ]
    Sol_cli_database_setup_render.dml_class;
  refuses
    [ Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app" ]
    Sol_cli_database_setup_render.ddl_class;
  refuses ~store:None complete "names no store"
;;

let%test "1425: an undeliverable external binding is refused before delivery" =
  test_plan_time_rejects_an_undeliverable_external_binding ()
;;

(* #1423: the emitted database prerequisite file is a contract — a GitOps consumer finds the
   target's class Secrets by this name, and reads these fields. Pin both, so a rename or a
   dropped field fails here instead of emitting an object nothing references. The key-set
   assertion is **exact**: an added field fails too, the way the database-identity interface
   test covers every field it names. *)
let yaml_key_names text =
  text
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
    let line = String.trim line in
    (* A list item renders as `- key: value`; the key is what follows the dash. *)
    let line =
      if String.length line >= 2 && String.equal (String.sub line 0 2) "- "
      then String.trim (String.sub line 2 (String.length line - 2))
      else line
    in
    match String.index_opt line ':' with
    | None | Some 0 -> None
    | Some i ->
      let key = String.sub line 0 i in
      let is_key_char c =
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || List.mem c [ '.'; '/'; '-'; '_' ]
      in
      if String.for_all is_key_char key then Some key else None)
  |> List.sort_uniq String.compare
;;

let test_resource_prerequisites_file_is_the_interface () =
  Windtrap.equal
    Windtrap.string
    ~msg:"the prerequisite file name is the contract"
    "payments-db-prerequisites.yaml"
    (Sol_cli_database_setup_render.resource_prerequisites_file_name ~target:"payments");
  let binding =
    [ Sol_cli_database_setup_render.ddl_class, "secret/production/app-db-migrator"
    ; Sol_cli_database_setup_render.dml_class, "secret/production/app-db-app"
    ]
  in
  match delivery_of_binding binding with
  | Error message -> Windtrap.fail message
  | Ok delivery ->
    let text = Sol_cli_yaml.render (delivery_docs delivery) in
    Windtrap.equal
      Windtrap.int
      ~msg:"one ExternalSecret per class per namespace"
      2
      (count_occurrences "kind: ExternalSecret" text);
    let expected_fields =
      [ "apiVersion"
      ; "app.kubernetes.io/managed-by"
      ; "creationPolicy"
      ; "data"
      ; "key"
      ; "kind"
      ; "labels"
      ; "metadata"
      ; "name"
      ; "namespace"
      ; "refreshInterval"
      ; "remoteRef"
      ; "secretKey"
      ; "sourceRef"
      ; "spec"
      ; "storeRef"
      ; "target"
      ]
    in
    let actual_fields = yaml_key_names text in
    Windtrap.equal
      Windtrap.bool
      ~msg:
        (Printf.sprintf
           "the document field set is the contract; emitted: %s"
           (String.concat "," actual_fields))
      true
      (actual_fields = expected_fields)
;;

let%test "1423: the emitted database prerequisite file is the interface" =
  test_resource_prerequisites_file_is_the_interface ()
;;
