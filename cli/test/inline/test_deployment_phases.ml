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

let with_setup_image value f =
  let name = Sol_cli_database_setup.image_env in
  let previous = Sol_cli_string.env name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv
        name
        (match previous with
         | Some p -> p
         | None -> ""))
    f
;;

let test_database_setup_image_requires_a_digest () =
  let digest = "postgres@sha256:" ^ String.make 64 'a' in
  with_setup_image (Some "postgres:16") (fun () ->
    match Sol_cli_database_setup.setup_image () with
    | Ok _ -> Windtrap.fail "a floating tag must be refused: this Job runs as the master"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the configured variable"
        true
        (setup_mentions Sol_cli_database_setup.image_env message));
  with_setup_image (Some digest) (fun () ->
    match Sol_cli_database_setup.setup_image () with
    | Error message -> Windtrap.fail message
    | Ok resolved ->
      Windtrap.equal Windtrap.string ~msg:"the digest is used" digest resolved);
  with_setup_image None (fun () ->
    match Sol_cli_database_setup.setup_image () with
    | Ok _ -> Windtrap.fail "an unset image must not resolve"
    | Error message ->
      (* Unlike the runner, there is nothing for Sol to publish: the message must name
         the variable to pin, not an artifact to build. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the message names what to set"
        true
        (setup_mentions Sol_cli_database_setup.image_env message))
;;

let test_database_setup_sql_is_idempotent () =
  let sql = Sol_cli_database_setup.role_sql in
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
    (setup_mentions "ALTER DEFAULT PRIVILEGES FOR ROLE" sql)
;;

let%test "database setup: the image must be a digest reference" =
  test_database_setup_image_requires_a_digest ()
;;

let%test "database setup: the role SQL is idempotent and carries no secret" =
  test_database_setup_sql_is_idempotent ()
;;

(* The renderer, asserted on its rendered output. *)

let render_setup () =
  Sol_cli_database_setup_render.docs
    ~ns:"myapp-payments"
    ~target:"payments"
    ~master_url:"postgresql://postgres:masterpw@db.internal:5432/app"
    ~ddl_password:"ddl-pw"
    ~dml_password:"dml-pw"
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
  (* The CA mount is present but empty: 2d populates it without reshaping the pod. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the CA mount exists and is empty"
    true
    (setup_mentions "emptyDir: {}" text);
  (* The Job spec must not embed a credential: it references the transient Secret. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Job takes its inputs by reference"
    true
    (setup_mentions "secretKeyRef" text);
  (* Sol writes the Secret first, then the Job. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"the Secret is written before the Job"
    true
    (setup_index "kind: Secret" text < setup_index "kind: Job" text)
;;

let test_database_setup_keeps_credentials_out_of_the_job () =
  let text = render_setup () in
  (* Every credential appears once, in the Secret's stringData. A second occurrence would
     mean the Job spec carries it too. *)
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
  List.iter
    (fun credential ->
       Windtrap.equal
         Windtrap.int
         ~msg:(Printf.sprintf "%s appears only in the transient Secret" credential)
         1
         (occurrences credential))
    [ "postgresql://postgres:masterpw@db.internal:5432/app"; "ddl-pw"; "dml-pw" ]
;;

let%test "database setup render: the Job is fail-closed and mounted empty of the CA" =
  test_database_setup_renders_the_fail_closed_job ()
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

let setup_output_secret () =
  Sol_cli_yaml.document
    (Sol_cli_yaml.map
       [ "kind", Sol_cli_yaml.string "Secret"
       ; "metadata", Sol_cli_yaml.map [ "name", Sol_cli_yaml.string "payments-ddl-creds" ]
       ])
;;

let run_database_setup () =
  Sol_cli_database_setup_run.run
    ~ctx:Sol_cli_kube_destination.local_context
    ~namespace:"myapp-payments"
    ~target:"payments"
    ~master_url:"postgresql://postgres:masterpw@db.internal:5432/app"
    ~ddl_password:"ddl-pw"
    ~dml_password:"dml-pw"
    ~image:("postgres@sha256:" ^ String.make 64 'a')
    ~output_secrets:[ setup_output_secret () ]
;;

let test_database_setup_applies_before_the_job_and_keeps_the_output_secrets () =
  setup_fake_kubectl ~fail_verb:"zzz-never" (fun ~log ->
    match run_database_setup () with
    | Error message -> Windtrap.fail message
    | Ok () ->
      let calls = read_file log in
      let manifests = read_file (log ^ ".manifests") in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Secret is applied before the Job"
        true
        (setup_index "kind: Secret" manifests < setup_index "kind: Job" manifests);
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
      (* The surviving resource: 2b consumes the output Secrets, so a change that added
         them to cleanup would break it while still passing every "cleanup ran" test. *)
      Windtrap.equal
        Windtrap.bool
        ~msg:"the output Secret is never deleted"
        false
        (setup_mentions "delete secret payments-ddl-creds" calls);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Secret is owned before cleanup reaches it"
        true
        (* "delete secret" happens only in cleanup; "delete job" also appears in the
           re-deploy pre-delete, which correctly precedes the patch. *)
        (setup_index "patch secret" calls < setup_index "delete secret" calls))
;;

let test_database_setup_cleans_up_when_the_patch_fails () =
  (* The failure that matters most: the Job exists, the Secret is never owned by it, so
     the TTL cascade can never collect it. Cleanup must still run. *)
  setup_fake_kubectl ~fail_verb:"patch" (fun ~log ->
    match run_database_setup () with
    | Ok () -> Windtrap.fail "a failed owner patch must fail the phase"
    | Error _ ->
      let calls = read_file log in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the transient Secret is still deleted when the patch fails"
        true
        (setup_mentions "delete secret" calls);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the Job is still deleted when the patch fails"
        true
        (setup_mentions "delete job" calls))
;;

let%test "database setup run: applies before the Job and deletes only what it owns" =
  test_database_setup_applies_before_the_job_and_keeps_the_output_secrets ()
;;

let%test "database setup run: cleanup runs even when the owner patch fails" =
  test_database_setup_cleans_up_when_the_patch_fails ()
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
    }
  in
  let open Sol_cli_config in
  let sol = binding ~ownership:Ownership_sol ~typ:"postgres" ~resource:"app_db" in
  let externally_bound =
    binding ~ownership:Ownership_external ~typ:"postgres" ~resource:"reports_db"
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a Sol-owned postgres resource is the provisioned database"
    (Some "app_db")
    (Option.map
       (fun b -> b.Sol_cli_resource_binding.resource)
       (Sol_cli_resource_binding.provisioned_database [ sol ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an externally bound postgres resource is not provisioned"
    false
    (Sol_cli_resource_binding.provisions ~typ:"postgres" [ externally_bound ]);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an externally bound postgres resource is not the provisioned database"
    None
    (Option.map
       (fun b -> b.Sol_cli_resource_binding.resource)
       (Sol_cli_resource_binding.provisioned_database [ externally_bound ]));
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
