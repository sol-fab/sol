let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_grants msg expected actual =
  let render grants =
    Sol_cli_authorization.normalize grants
    |> List.map Sol_cli_authorization.grant_to_string
  in
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg (render expected) (render actual)
;;

let grant unit capability resource = { Sol_cli_authorization.unit; capability; resource }
let stripe = grant "payments-api" "secret" "stripe"
let legacy = grant "payments-api" "secret" "legacy"

let write_file path content =
  Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let in_temp_dir f =
  let orig = Sys.getcwd () in
  let dir = Filename.temp_file "sol-grants-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir orig) f
;;

let service ?(domain = "payments") name =
  { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = name }
;;

let workload ?(keys = []) name =
  write_file
    (Filename.concat name "sol.toml")
    (Printf.sprintf
       "[infra.env]\nsecrets = [%s]\n"
       (keys |> List.map (Printf.sprintf "%S") |> String.concat ", "));
  { Sol_cli_workspace_model.service = service name
  ; has_dockerfile = true
  ; language = None
  ; config =
      Sol_cli_toml.load_result
        (Filename.concat (Sys.getcwd ()) (Filename.concat name "sol.toml"))
  }
;;

let model workloads =
  { Sol_cli_workspace_model.root = Sys.getcwd ()
  ; app_dir = None
  ; workloads
  ; unexpected = []
  ; declared = []
  ; topics = []
  ; schema_subjects = []
  ; migrations = []
  ; events = []
  ; targets = []
  }
;;

let namespace_of = function
  | "payments-api" -> Some "payments"
  | "checkout-api" -> Some "checkout"
  | _ -> None
;;

let test_desired_is_every_declared_secret_of_every_unit () =
  in_temp_dir (fun () ->
    let model = model [ workload ~keys:[ "stripe"; "legacy" ] "payments-api" ] in
    match Sol_cli_authorization_reconcile.desired model with
    | Error message -> Windtrap.fail message
    | Ok grants -> check_grants "one grant per declared secret" [ stripe; legacy ] grants)
;;

let test_desired_refuses_iam_wildcards () =
  in_temp_dir (fun () ->
    List.iter
      (fun key ->
         let model = model [ workload ~keys:[ key ] "payments-api" ] in
         match Sol_cli_authorization_reconcile.desired model with
         | Ok _ -> Windtrap.failf "grant resource %S was accepted" key
         | Error message ->
           check_bool
             (Printf.sprintf "the refusal names %S" key)
             true
             (Sol_cli_string.contains ~needle:key message))
      [ "*"; "FOO*"; "FOO?"; "A/B"; "" ])
;;

let test_desired_spans_the_whole_workspace () =
  in_temp_dir (fun () ->
    let model =
      model
        [ workload ~keys:[ "stripe" ] "payments-api"
        ; workload ~keys:[ "stripe" ] "checkout-api"
        ]
    in
    match Sol_cli_authorization_reconcile.desired model with
    | Error message -> Windtrap.fail message
    | Ok grants ->
      check_grants
        "every unit is covered"
        [ stripe; grant "checkout-api" "secret" "stripe" ]
        grants)
;;

let test_desired_refuses_an_unreadable_declaration () =
  in_temp_dir (fun () ->
    write_file "payments-api/sol.toml" "this is not toml = = =";
    let broken =
      { Sol_cli_workspace_model.service = service "payments-api"
      ; has_dockerfile = true
      ; language = None
      ; config =
          Sol_cli_toml.load_result
            (Filename.concat (Sys.getcwd ()) "payments-api/sol.toml")
      }
    in
    match Sol_cli_authorization_reconcile.desired (model [ broken ]) with
    | Ok _ -> Windtrap.fail "an unreadable declaration produced a plan"
    | Error _ -> ())
;;

let test_terraform_grants_carry_the_namespace () =
  match
    Sol_cli_authorization_reconcile.terraform_grants ~grants:[ stripe ] ~namespace_of
  with
  | Error message -> Windtrap.fail message
  | Ok [ mapped ] ->
    check_string "unit" "payments-api" mapped.unit;
    check_string "namespace" "payments" mapped.namespace
  | Ok _ -> Windtrap.fail "expected exactly one mapped grant"
;;

let test_terraform_grants_refuse_an_unaddressable_unit () =
  let orphan = grant "unknown-api" "secret" "stripe" in
  match
    Sol_cli_authorization_reconcile.terraform_grants ~grants:[ orphan ] ~namespace_of
  with
  | Ok _ -> Windtrap.fail "a unit with no namespace was accepted"
  | Error _ -> ()
;;

let test_terraform_var_carries_every_field () =
  let mapped =
    { Sol_cli_authorization_reconcile.unit = "payments-api"
    ; capability = "secret"
    ; resource = "stripe"
    ; namespace = "payments"
    }
  in
  let key, value = Sol_cli_authorization_reconcile.terraform_var [ mapped ] in
  check_string "variable name" "grants" key;
  check_bool
    "unit"
    true
    (Sol_cli_string.contains ~needle:"\"unit\":\"payments-api\"" value);
  check_bool
    "capability"
    true
    (Sol_cli_string.contains ~needle:"\"capability\":\"secret\"" value);
  check_bool
    "resource"
    true
    (Sol_cli_string.contains ~needle:"\"resource\":\"stripe\"" value);
  check_bool
    "namespace"
    true
    (Sol_cli_string.contains ~needle:"\"namespace\":\"payments\"" value)
;;

let test_current_reads_the_established_grants_output () =
  let output =
    {|{"established_grants":{"value":[{"unit":"payments-api","capability":"secret","resource":"stripe","namespace":"payments"}],"type":["list","object"]}}|}
  in
  match Sol_cli_authorization_reconcile.current_of_output_json output with
  | Error message -> Windtrap.fail message
  | Ok grants -> check_grants "the applied set is read back" [ stripe ] grants
;;

let test_current_is_empty_before_the_root_is_applied () =
  match Sol_cli_authorization_reconcile.current_of_output_json "{}" with
  | Error message -> Windtrap.fail message
  | Ok grants -> check_grants "no applied set" [] grants
;;

let test_current_refuses_a_malformed_output () =
  match
    Sol_cli_authorization_reconcile.current_of_output_json
      {|{"established_grants":{"value":"nope"}}|}
  with
  | Ok _ -> Windtrap.fail "a malformed output was accepted"
  | Error _ -> ()
;;

let deployment ~namespace ~name ~app ~annotation =
  let metadata =
    [ "name", `String name
    ; "namespace", `String namespace
    ; "labels", `Assoc [ "app", `String app ]
    ]
  in
  let template_metadata =
    match annotation with
    | None -> `Assoc [ "labels", `Assoc [ "app", `String app ] ]
    | Some value ->
      `Assoc
        [ "labels", `Assoc [ "app", `String app ]
        ; "annotations", `Assoc [ Sol_cli_grant.annotation_key, `String value ]
        ]
  in
  `Assoc
    [ "metadata", `Assoc metadata
    ; "spec", `Assoc [ "template", `Assoc [ "metadata", template_metadata ] ]
    ]
;;

let listing deployments = `Assoc [ "items", `List deployments ] |> Yojson.Safe.to_string

let test_deployed_reads_the_recorded_grants () =
  let recorded =
    Sol_cli_grant.encode_tags
      [ Sol_cli_grant.tag_of_secret_key "stripe"
      ; Sol_cli_grant.tag_of_secret_key "legacy"
      ]
  in
  let json =
    listing
      [ deployment
          ~namespace:"payments"
          ~name:"payments-api"
          ~app:"payments-api"
          ~annotation:(Some recorded)
      ]
  in
  match
    Sol_cli_authorization_reconcile.deployed_of_listing_json
      ~namespaces:[ "payments" ]
      json
  with
  | Error message -> Windtrap.fail message
  | Ok grants ->
    check_grants "the deployed requirement is read back" [ stripe; legacy ] grants
;;

let test_deployed_ignores_units_outside_the_target () =
  let recorded = Sol_cli_grant.encode_tags [ Sol_cli_grant.tag_of_secret_key "stripe" ] in
  let json =
    listing
      [ deployment
          ~namespace:"other"
          ~name:"other-api"
          ~app:"other-api"
          ~annotation:(Some recorded)
      ]
  in
  match
    Sol_cli_authorization_reconcile.deployed_of_listing_json
      ~namespaces:[ "payments" ]
      json
  with
  | Error message -> Windtrap.fail message
  | Ok grants -> check_grants "another target's workload is not observed" [] grants
;;

let test_deployed_treats_a_missing_annotation_as_no_grants () =
  let json =
    listing
      [ deployment
          ~namespace:"payments"
          ~name:"payments-api"
          ~app:"payments-api"
          ~annotation:None
      ]
  in
  match
    Sol_cli_authorization_reconcile.deployed_of_listing_json
      ~namespaces:[ "payments" ]
      json
  with
  | Error message -> Windtrap.fail message
  | Ok grants -> check_grants "nothing recorded" [] grants
;;

let test_deployed_refuses_an_unreadable_annotation () =
  let json =
    listing
      [ deployment
          ~namespace:"payments"
          ~name:"payments-api"
          ~app:"payments-api"
          ~annotation:(Some "not json")
      ]
  in
  match
    Sol_cli_authorization_reconcile.deployed_of_listing_json
      ~namespaces:[ "payments" ]
      json
  with
  | Ok _ -> Windtrap.fail "an unreadable annotation was treated as no grants"
  | Error _ -> ()
;;

let target ?(fields = []) provider =
  { Sol_cli_config.name = "dev/aws/us-east-1"
  ; env = "dev"
  ; provider
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = None
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_logs_url = None
  ; observability_logs_username = None
  ; observability_logs_password_env = None
  ; observability_metrics_url = None
  ; observability_metrics_username = None
  ; observability_metrics_password_env = None
  ; observability_traces_url = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields = [ Sol_cli_provider.to_string provider, fields ]
  ; secret_authorities = []
  }
;;

let test_reconciler_requires_its_own_identity () =
  let only_deploy =
    target
      ~fields:[ "deploy_role_arn", "arn:aws:iam::1:role/deploy" ]
      Sol_cli_provider.Aws
  in
  match Sol_cli_authorization_identity.of_target only_deploy with
  | Ok _ -> Windtrap.fail "the reconciler ran without its own identity"
  | Error _ -> ()
;;

let test_reconciler_must_differ_from_the_deploy_identity () =
  let role = "arn:aws:iam::1:role/deploy" in
  let same =
    target
      ~fields:[ "deploy_role_arn", role; "reconciler_role_arn", role ]
      Sol_cli_provider.Aws
  in
  match Sol_cli_authorization_identity.of_target same with
  | Ok _ -> Windtrap.fail "the deploy identity was accepted as the reconciler"
  | Error _ -> ()
;;

let test_reconciler_accepts_a_separate_role () =
  let role = "arn:aws:iam::1:role/sol/dev/reconciler" in
  let target =
    target
      ~fields:
        [ "deploy_role_arn", "arn:aws:iam::1:role/deploy"; "reconciler_role_arn", role ]
      Sol_cli_provider.Aws
  in
  match Sol_cli_authorization_identity.of_target target with
  | Error message -> Windtrap.fail message
  | Ok identity ->
    check_bool
      "the assumed-role session is accepted"
      true
      (Result.is_ok
         (Sol_cli_authorization_identity.caller_is_reconciler
            identity
            ~principal:"arn:aws:sts::1:assumed-role/sol/dev/reconciler/session"));
    check_bool
      "another identity is refused"
      false
      (Result.is_ok
         (Sol_cli_authorization_identity.caller_is_reconciler
            identity
            ~principal:"arn:aws:iam::1:role/deploy"))
;;

let test_gcp_reconciler_requires_its_service_account () =
  let target = target Sol_cli_provider.Gcp in
  match Sol_cli_authorization_identity.of_target target with
  | Ok _ -> Windtrap.fail "a GCP reconciler ran without a declared service account"
  | Error _ -> ()
;;

let test_annotation_round_trips () =
  let tags = [ Sol_cli_grant.tag_of_secret_key "stripe"; "object-store/bucket" ] in
  match Sol_cli_grant.decode_tags (Sol_cli_grant.encode_tags tags) with
  | Error message -> Windtrap.fail message
  | Ok decoded ->
    check_bool "decoded" true (List.equal String.equal tags decoded);
    check_string
      "capability"
      "object-store"
      (Sol_cli_grant.capability_of_tag "object-store/bucket");
    check_string "resource" "bucket" (Sol_cli_grant.resource_of_tag "object-store/bucket")
;;

let render_deployment ~secret_keys =
  let release_id =
    Sol_cli_release_id.of_content
      { workspace = "myapp"; environment = None; workloads = []; contract = [] }
  in
  let workload : Sol_cli_manifest.Workload_spec.t =
    { Sol_cli_manifest.Workload_spec.extra_labels = []
    ; secret_keys
    ; secret_sources = []
    ; volumes = []
    ; projected_identities = []
    ; env = None
    ; config_hash = "hash"
    ; availability = Sol_cli_availability.Single
    ; consumes_kafka = false
    ; kafka_tls = false
    ; readiness_path = "/readyz"
    ; shape = Sol_cli_manifest.Http_service
    ; replicas = 1
    ; cpu = "100m"
    ; memory = "128Mi"
    ; ns = "myapp-payments"
    ; name = "payments-api"
    ; image = "registry/myapp/payments-api:tag"
    ; workspace = "myapp"
    ; domain = "payments"
    ; primitive = "svc"
    ; release_id
    ; db_dml_creds_name = None
    ; db_ca_configmap = None
    }
  in
  Sol_cli_manifest.deployment_doc ~workload () |> fun doc -> Sol_cli_yaml.render [ doc ]
;;

let test_deploy_records_the_grants () =
  let recorded = render_deployment ~secret_keys:[ "stripe" ] in
  check_bool
    "the annotation is on the workload"
    true
    (Sol_cli_string.contains ~needle:Sol_cli_grant.annotation_key recorded);
  check_bool
    "the recorded tag names the secret"
    true
    (Sol_cli_string.contains ~needle:"secret/stripe" recorded)
;;

let test_deploy_records_nothing_without_grants () =
  let recorded = render_deployment ~secret_keys:[] in
  check_bool
    "no annotation without declarations"
    false
    (Sol_cli_string.contains ~needle:Sol_cli_grant.annotation_key recorded)
;;

let test_fence_vars_require_the_trust_principal () =
  let without = target Sol_cli_provider.Aws in
  check_bool
    "no trust principal is refused"
    false
    (Result.is_ok (Sol_cli_authorization_stage.root_vars without));
  let declared =
    target
      ~fields:[ "reconciler_trust_principal_arn", "arn:aws:iam::1:role/ci" ]
      Sol_cli_provider.Aws
  in
  match Sol_cli_authorization_stage.root_vars declared with
  | Error message -> Windtrap.fail message
  | Ok vars ->
    check_bool "region passed" true (List.mem_assoc "region" vars);
    check_bool "environment passed" true (List.mem_assoc "environment" vars);
    check_bool
      "trust principal passed"
      true
      (List.mem_assoc "reconciler_trust_principal_arn" vars)
;;

let%test "grants: the desired set is every declared secret of every unit" =
  test_desired_is_every_declared_secret_of_every_unit ()
;;

let%test "grants: IAM wildcards cannot become secret grants" =
  test_desired_refuses_iam_wildcards ()
;;

let%test "grants: desired spans the whole workspace, never a scope" =
  test_desired_spans_the_whole_workspace ()
;;

let%test "grants: an unreadable declaration fails the plan closed" =
  test_desired_refuses_an_unreadable_declaration ()
;;

let%test "grants: the terraform input carries the unit namespace" =
  test_terraform_grants_carry_the_namespace ()
;;

let%test "grants: an unaddressable unit is refused" =
  test_terraform_grants_refuse_an_unaddressable_unit ()
;;

let%test "grants: the terraform variable carries every field" =
  test_terraform_var_carries_every_field ()
;;

let%test "grants: the applied set is read back from the root's output" =
  test_current_reads_the_established_grants_output ()
;;

let%test "grants: an unapplied root reads as an empty current set" =
  test_current_is_empty_before_the_root_is_applied ()
;;

let%test "grants: a malformed output is refused" =
  test_current_refuses_a_malformed_output ()
;;

let%test "grants: the deployed workload's recorded requirements are read back" =
  test_deployed_reads_the_recorded_grants ()
;;

let%test "grants: a workload outside the target is not observed" =
  test_deployed_ignores_units_outside_the_target ()
;;

let%test "grants: a workload with no annotation records no requirements" =
  test_deployed_treats_a_missing_annotation_as_no_grants ()
;;

let%test "grants: an unreadable annotation is refused, not treated as none" =
  test_deployed_refuses_an_unreadable_annotation ()
;;

let%test "grants: the reconciler refuses to run without its own identity" =
  test_reconciler_requires_its_own_identity ()
;;

let%test "grants: the reconciler must differ from the deploy identity" =
  test_reconciler_must_differ_from_the_deploy_identity ()
;;

let%test "grants: a separate reconciler identity is accepted and observable" =
  test_reconciler_accepts_a_separate_role ()
;;

let%test "grants: a GCP reconciler requires its service account" =
  test_gcp_reconciler_requires_its_service_account ()
;;

let%test "grants: the deployment annotation round-trips" = test_annotation_round_trips ()

let%test "grants: a deploy records the grants it was deployed against" =
  test_deploy_records_the_grants ()
;;

let%test "grants: a deploy with no declarations records no grants" =
  test_deploy_records_nothing_without_grants ()
;;

let%test "grants: the fence root needs the reconciler trust principal" =
  test_fence_vars_require_the_trust_principal ()
;;

let test_external_resource_capabilities () =
  check_string
    "queue publishes"
    "message.publish"
    (Sol_cli_grant.capability_to_string Sol_cli_grant.Message_publish);
  check_string
    "queue subscribes"
    "message.subscribe"
    (Sol_cli_grant.capability_to_string Sol_cli_grant.Message_subscribe);
  check_string
    "object reads"
    "object.read"
    (Sol_cli_grant.capability_to_string Sol_cli_grant.Object_read);
  check_string
    "object writes"
    "object.write"
    (Sol_cli_grant.capability_to_string Sol_cli_grant.Object_write);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"queue resource capabilities"
    [ "message.publish"; "message.subscribe" ]
    (List.map
       Sol_cli_grant.capability_to_string
       (Sol_cli_grant.resource_capabilities "queue"));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"object-store resource capabilities"
    [ "object.read"; "object.write" ]
    (List.map
       Sol_cli_grant.capability_to_string
       (Sol_cli_grant.resource_capabilities "object_store"))
;;

let%test "external resource capabilities" = test_external_resource_capabilities ()

let test_function_invoke_capability () =
  check_string
    "function invoke capability"
    "function.invoke"
    (Sol_cli_grant.capability_to_string Sol_cli_grant.Function_invoke);
  let requirement = Sol_cli_grant.invoke_requirement "daily-report_fn" in
  Windtrap.equal
    Windtrap.string
    ~msg:"invocation requirement resource"
    "daily-report_fn"
    requirement.resource;
  Windtrap.equal
    Windtrap.string
    ~msg:"invocation requirement capability"
    "function.invoke"
    (Sol_cli_grant.capability_to_string requirement.capability)
;;

let%test "function invoke capability" = test_function_invoke_capability ()
