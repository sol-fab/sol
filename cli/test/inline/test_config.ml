let check_str msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let check_strs msg expected actual =
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg expected actual
;;

let check_int_opt msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.int) ~msg expected actual
;;

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let check_str_opt msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.string) ~msg expected actual
;;

let check_provider label expected provider =
  check_str label expected (Sol_cli_provider.to_string provider)
;;

let only_index indexes =
  match indexes with
  | [ index ] -> index
  | _ -> Windtrap.fail "expected one index"
;;

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
      let next = if current = "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  loop "" parts
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-config-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let with_chdir dir f =
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let expect_load_error expected =
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Ok _ -> Windtrap.fail "expected load_for_target to fail"
  | Error e -> check_str "message" expected e.message
;;

let expect_yaml_error () =
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Ok _ -> Windtrap.fail "expected a YAML syntax error"
  | Error e ->
    let prefix = "invalid YAML: " in
    check_str
      "prefix"
      prefix
      (String.sub e.message 0 (min (String.length e.message) (String.length prefix)));
    Windtrap.equal Windtrap.bool ~msg:"names a line" true (e.line > 0)
;;

let example_pluto_dir () = Filename.concat (Source_root.find ()) "examples/pluto"

let write_base () =
  write
    "sol.yml"
    {|
project: pluto

resources:
  app_db:
    type: postgres

  sessions:
    type: dynamodb
    partition_key: user_id
    sort_key: session_id
    indexes:
      by_expires_at:
        partition_key: tenant_id
        sort_key: expires_at

services:
  api:
    type: http
    path: app/core/api
    uses: [app_db, sessions]
|}
;;

let test_target_path_supplies_placement () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: pluto-prod
  base_domain: pluto.example.com
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: ops@pluto.example.com

services:
  api:
    scale:
      min: 2
      max: 10
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      check_str "project" "pluto" (Option.get cfg.project);
      let target = cfg.target in
      check_str "target name" "prod/aws/us-east-1" target.name;
      check_str "env" "prod" target.env;
      check_provider "provider" "aws" target.provider;
      check_str "region" "us-east-1" target.region;
      check_str "cluster" "pluto-prod" (Option.get target.cluster_name);
      check_str "cluster issuer" "letsencrypt-staging" (Option.get target.cluster_issuer);
      check_str
        "Let's Encrypt email"
        "ops@pluto.example.com"
        (Option.get target.letsencrypt_email);
      let resource = List.hd (Sol_cli_config.resources cfg) in
      check_str "resource" "app_db" resource.name;
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str "service" "api" service.name;
      check_strs "uses" [ "app_db"; "sessions" ] service.uses;
      check_int_opt "scale min" (Some 2) service.scale_min;
      check_int_opt "scale max" (Some 10) service.scale_max)
;;

let test_target_secret_authorities_resolve_per_unit_key () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|target:
  registry: registry.example.test/pluto
  secrets:
    payments/charge_svc:
      DATABASE_URL:
        authority: sol
      STRIPE_API_KEY:
        authority: external
        store: vault-production
        key: secret/production/payments/stripe
    notifications/email_worker:
      STRIPE_API_KEY:
        authority: sol
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
    | Ok config ->
      let target = config.Sol_cli_config.target in
      Windtrap.equal
        Windtrap.bool
        ~msg:"charge database authority"
        true
        (Sol_cli_config.secret_authority
           target
           ~unit_address:"payments/charge_svc"
           ~key:"DATABASE_URL"
         = Some Sol_cli_config.Sol_managed);
      Windtrap.equal
        Windtrap.bool
        ~msg:"external authority retains provider reference"
        true
        (Sol_cli_config.secret_authority
           target
           ~unit_address:"payments/charge_svc"
           ~key:"STRIPE_API_KEY"
         = Some
             (Sol_cli_config.External
                { store = "vault-production"; key = "secret/production/payments/stripe" })
        );
      Windtrap.equal
        Windtrap.bool
        ~msg:"same key has independent unit authority"
        true
        (Sol_cli_config.secret_authority
           target
           ~unit_address:"notifications/email_worker"
           ~key:"STRIPE_API_KEY"
         = Some Sol_cli_config.Sol_managed);
      Windtrap.equal
        Windtrap.string
        ~msg:"unmapped key does not inherit authority"
        ""
        (match
           Sol_cli_config.secret_authority
             target
             ~unit_address:"payments/charge_svc"
             ~key:"UNMAPPED"
         with
         | None -> ""
         | Some _ -> "mapped"))
;;

let test_secret_authorities_reject_malformed_references () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|target:
  secrets:
    payments/charge_svc:
      STRIPE_API_KEY:
        authority: external
        store: ""
        key: secret/stripe
|};
    expect_load_error
      "prod.targets.aws/us-east-1: secrets.STRIPE_API_KEY.store must be a non-empty \
       string")
;;

let test_secret_authorities_reject_scalar_shorthand () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|target:
  secrets:
    payments/charge_svc:
      DATABASE_URL: sol
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "scalar secret authority shorthand must be rejected"
    | Error error ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"explains the required mapping shape"
        true
        (Sol_cli_string.contains
           ~needle:"secrets.DATABASE_URL must be an authority mapping"
           (Sol_cli_config.error_to_string error)))
;;

let test_duplicate_resource_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres
  app_db:
    type: dynamodb
|};
    expect_load_error "duplicate resource \"app_db\"")
;;

let test_unknown_key_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    typo: nope
|};
    expect_load_error "unknown service key \"typo\"")
;;

let test_service_language_parses () =
  with_temp_dir (fun () ->
    write "sol.yml" "services:\n  api:\n    language: ocaml\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_bool "language parsed" true (service.language = Some Sol_cli_compat.Ocaml))
;;

let test_unknown_service_language_fails () =
  with_temp_dir (fun () ->
    write "sol.yml" "services:\n  api:\n    language: rust\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "expected an unknown language to fail"
    | Error e ->
      check_bool
        "names the supported languages"
        true
        (Sol_cli_string.contains ~needle:"supported: ocaml, typescript" e.message))
;;

let test_duplicate_top_level_section_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

services:
  api:
    type: http

resources:
  sessions:
    type: dynamodb
|};
    expect_load_error "duplicate top-level section \"resources\"")
;;

let test_duplicate_index_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
      by_expires_at:
|};
    expect_load_error "duplicate index \"by_expires_at\"")
;;

let test_malformed_list_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [app_db
|};
    expect_yaml_error ())
;;

let test_malformed_quoted_scalar_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    path: "app/core/api
|};
    expect_yaml_error ())
;;

let test_malformed_quoted_list_item_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: ["app_db]
|};
    expect_yaml_error ())
;;

let test_undeclared_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [missing]
|};
    expect_load_error "service \"api\" uses undeclared resource \"missing\"")
;;

let test_absolute_cross_region_uses_ref_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/us-east-1/analytics_db]
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_strs "uses" [ "/us-east-1/analytics_db" ] service.uses;
      check_str
        "formatted use"
        "/us-east-1/analytics_db (cross-region)"
        (Sol_cli_config.format_use_ref (List.hd service.uses)))
;;

let test_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/gcp/us-central1/analytics_db]
|};
    expect_load_error "cross-provider uses refs are not supported in v1")
;;

let test_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/prod/aws/us-east-1/analytics_db]
|};
    expect_load_error "cross-env uses refs are not supported in v1")
;;

let test_three_segment_cross_env_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/prod/us-east-1/analytics_db]
|};
    expect_load_error "cross-env uses refs are not supported in v1")
;;

let test_two_segment_cross_provider_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/gcp/analytics_db]
|};
    expect_load_error "cross-provider uses refs are not supported in v1")
;;

let test_empty_segment_uses_ref_fails_to_parse () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    uses: [/us-east-1//analytics_db]
|};
    expect_load_error "absolute uses ref must look like /<region>/<resource>")
;;

let test_omitted_resource_uses_ref_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

services:
  api:
    uses: [app_db]
|};
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
resources:
  app_db:
    omit: true
|};
    expect_load_error "service \"api\" uses undeclared resource \"app_db\"")
;;

let test_resource_key_after_indexes_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
    size: small
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource = List.hd (Sol_cli_config.resources cfg) in
      check_str_opt "size" (Some "small") resource.size)
;;

let test_service_key_after_scale_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    scale:
      min: 1
    path: app/core/api
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api") service.path)
;;

let test_nested_provider_box_still_tolerated () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc:
      id: vpc-123
  registry: registry.example.com
|};
    expect_load_error "aws.vpc must be a single value, not a nested block")
;;

let test_target_provider_box_ends_before_generic_key () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    account_id: "123456789012"
  registry: registry.example.com
    typo: nope
|};
    expect_yaml_error ())
;;

let test_empty_target_value_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  registry:
|};
    expect_load_error "missing value for registry")
;;

let test_target_after_resources_parses () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    type: postgres

target:
  registry: registry.example.com
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      check_str
        "registry"
        "registry.example.com"
        (Option.value cfg.target.registry ~default:"<none>"))
;;

let test_quoted_hash_survives () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
    path: "app/core/api#1"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api#1") service.path)
;;

let test_single_quoted_hash_survives () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
    path: 'app/core/api#1'
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let service = List.hd (Sol_cli_config.services cfg) in
      check_str_opt "path" (Some "app/core/api#1") service.path)
;;

let test_malformed_int_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    scale:
      min: abc
|};
    expect_load_error "expected integer for min")
;;

let test_malformed_bool_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
resources:
  app_db:
    omit: TRUE
|};
    expect_load_error "expected true or false for omit")
;;

let test_target_overlay_can_omit_resources_and_services () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: sol-dev

resources:
  app_db:
    omit: true

services:
  api:
    omit: true
|};
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource_names =
        Sol_cli_config.resources cfg
        |> List.map (fun (r : Sol_cli_config.resource) -> r.name)
      in
      let service_names =
        Sol_cli_config.services cfg
        |> List.map (fun (s : Sol_cli_config.service) -> s.name)
      in
      check_strs "resources" [ "sessions" ] resource_names;
      check_strs "services" [] service_names)
;;

let test_target_observability_backend_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  observability_backend: external
  observability_logs_url: https://logs.example.com/loki/api/v1/push
  observability_logs_username: "123456"
  observability_logs_password_env: SOL_TEST_LOKI_PASSWORD
  observability_metrics_url: https://metrics.example.com/api/prom/push
  observability_metrics_username: "654321"
  observability_metrics_password_env: SOL_TEST_PROM_PASSWORD
  observability_traces_url: https://otlp.example.com/v1/traces
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str
        "observability_backend"
        "external"
        (Option.get target.observability_backend);
      check_str
        "observability_logs_url"
        "https://logs.example.com/loki/api/v1/push"
        (Option.get target.observability_logs_url);
      check_str
        "observability_logs_username"
        "123456"
        (Option.get target.observability_logs_username);
      check_str
        "observability_metrics_url"
        "https://metrics.example.com/api/prom/push"
        (Option.get target.observability_metrics_url);
      check_str
        "observability_metrics_username"
        "654321"
        (Option.get target.observability_metrics_username);
      check_str
        "observability_logs_password_env"
        "SOL_TEST_LOKI_PASSWORD"
        (Option.get target.observability_logs_password_env);
      check_str
        "observability_metrics_password_env"
        "SOL_TEST_PROM_PASSWORD"
        (Option.get target.observability_metrics_password_env);
      check_str
        "observability_traces_url"
        "https://otlp.example.com/v1/traces"
        (Option.get target.observability_traces_url))
;;

let test_target_alert_delivery_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  alert_receiver_type: webhook
  alert_receiver_url: https://hooks.example.com/sol-alerts
  alert_owner: payments-oncall
  alert_runbook_url: https://runbooks.example.com/sol
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str "receiver type" "webhook" (Option.get target.alert_receiver_type);
      check_str
        "receiver url"
        "https://hooks.example.com/sol-alerts"
        (Option.get target.alert_receiver_url);
      check_str "owner" "payments-oncall" (Option.get target.alert_owner);
      check_str
        "runbook"
        "https://runbooks.example.com/sol"
        (Option.get target.alert_runbook_url))
;;

let test_target_recoverable_state_and_identities_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  base_domain: pluto.example.com
  state_bucket: acme-tfstate
  aws:
    state_lock_table: acme-tflock
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
    deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
    operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str "state_bucket" "acme-tfstate" (Option.get target.state_bucket);
      check_str
        "state_lock_table"
        "acme-tflock"
        (Option.get (Sol_cli_config.provider_field target "state_lock_table"));
      check_str
        "provisioner_role_arn"
        "arn:aws:iam::111122223333:role/sol-provisioner"
        (Option.get (Sol_cli_config.provider_field target "provisioner_role_arn"));
      check_str
        "cluster_access_role_arn"
        "arn:aws:iam::111122223333:role/sol-cluster-access"
        (Option.get (Sol_cli_config.provider_field target "cluster_access_role_arn"));
      check_str
        "deploy_role_arn"
        "arn:aws:iam::111122223333:role/sol-deploy"
        (Option.get (Sol_cli_config.provider_field target "deploy_role_arn"));
      check_str
        "operator_role_arn"
        "arn:aws:iam::111122223333:role/sol-operator"
        (Option.get (Sol_cli_config.provider_field target "operator_role_arn"));
      check_str
        "cluster_endpoint_cidr"
        "203.0.113.0/24"
        (Option.get target.cluster_endpoint_cidr))
;;

let test_target_observability_backend_absent_when_unset () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: sol-dev
|};
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_bool "observability_backend absent" true (target.observability_backend = None))
;;

let test_bad_target_path_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"prod" with
    | Ok _ -> Windtrap.fail "expected invalid target path"
    | Error e ->
      check_str "message" "target must look like <env>/<provider>/<region>" e.message)
;;

let test_unknown_target_provider_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"prod/azure/us-east-1" with
    | Ok _ -> Windtrap.fail "expected unknown target provider"
    | Error e -> check_str "message" "unsupported provider \"azure\"" e.message)
;;

let test_parent_target_path_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"../../etc" with
    | Ok _ -> Windtrap.fail "expected invalid target path"
    | Error e -> check_str "message" "target path must not contain '..'" e.message)
;;

let test_target_outside_a_workspace_fails_closed () =
  with_temp_dir (fun () ->
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-west-2" with
    | Ok _ -> Windtrap.fail "expected load_for_target to fail outside a workspace"
    | Error e ->
      check_bool
        "message names the fix"
        true
        (Sol_cli_string.contains ~needle:"sol new workspace" e.message))
;;

let test_target_with_only_sol_yml_succeeds () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail e.message
    | Ok _ -> ())
;;

let test_same_cluster_across_envs_fails () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared
|};
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "expected same-cluster envs to fail"
    | Error e ->
      assert (Sol_cli_string.contains ~needle:"dev" e.message);
      assert (Sol_cli_string.contains ~needle:"prod" e.message);
      assert (Sol_cli_string.contains ~needle:"shared" e.message))
;;

let test_different_destinations_succeed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-west-2"
      {|
target:
  cluster_name: shared
  kube_context: shared-eu
|};
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: shared
  kube_context: shared-us
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok _ -> ())
;;

let test_destination_comes_from_the_target () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: sol-prod-us-east-1
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      (match Sol_cli_config.destination_of_target target with
       | Error message -> Windtrap.fail message
       | Ok destination ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the context comes from the target"
           "sol-prod-us-east-1"
           destination.context;
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"and scopes the kubectl call"
           [ "--context"; "sol-prod-us-east-1" ]
           (Sol_cli_kube_destination.kubectl_args destination)))
;;

let test_destination_includes_scoped_kubeconfig () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: sol-prod-us-east-1
  kubeconfig: .sol/kubeconfigs/prod-aws-us-east-1.kubeconfig
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      (match Sol_cli_config.destination_of_target target with
       | Error message -> Windtrap.fail message
       | Ok destination ->
         check_str_opt
           "the scoped kubeconfig comes from the target"
           (Some ".sol/kubeconfigs/prod-aws-us-east-1.kubeconfig")
           destination.kubeconfig;
         Windtrap.equal
           (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
           ~msg:"the child env scopes kubectl to that kubeconfig"
           [ "KUBECONFIG", ".sol/kubeconfigs/prod-aws-us-east-1.kubeconfig" ]
           (Sol_cli_kube_destination.environment destination)))
;;

let test_destination_missing_fails_closed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: sol-prod
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      (match Sol_cli_config.destination_of_target target with
       | Ok destination ->
         Windtrap.fail
           (Printf.sprintf
              "expected a target with no context to fail closed, got %S"
              (Sol_cli_kube_destination.to_string destination))
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the error names the field to set"
           true
           (Sol_cli_string.contains ~needle:"kube_context" message)))
;;

let test_root_target_defaults_survive () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  registry: registry.example.com

services:
  api:
    type: http
|};
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  cluster_name: pluto-prod
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str_opt "registry" (Some "registry.example.com") target.registry)
;;

let test_feat_028_shapes_still_tolerated () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    account_id: "123456789012"

resources:
  sessions:
    type: dynamodb
    indexes:
      by_expires_at:
        partition_key: tenant_id
        sort_key: expires_at
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str "env" "prod" target.env;
      let resource = List.hd (Sol_cli_config.resources cfg) in
      let index = only_index resource.indexes in
      check_str "index" "by_expires_at" index.index_name;
      check_str_opt "index partition_key" (Some "tenant_id") index.partition_key;
      check_str_opt "index sort_key" (Some "expires_at") index.sort_key)
;;

let test_provider_box_round_trips () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  gcp:
    project_id: pluto-dev
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_strs
        "aws fields"
        [ "vpc_cidr=10.42.0.0/16" ]
        (List.assoc "aws" target.provider_fields |> List.map (fun (k, v) -> k ^ "=" ^ v));
      check_strs
        "gcp fields"
        [ "project_id=pluto-dev" ]
        (List.assoc "gcp" target.provider_fields |> List.map (fun (k, v) -> k ^ "=" ^ v)))
;;

let test_duplicate_provider_box_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  aws:
    account_id: "123456789012"
|};
    expect_load_error "duplicate target provider box \"aws\"")
;;

let test_unknown_provider_box_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  azure:
    subscription_id: pluto-dev
|};
    expect_load_error "unsupported provider \"azure\"")
;;

let test_provider_fields_feed_active_terraform_provider () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
  gcp:
    project_id: pluto-dev
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool "aws var present" true (List.mem ("vpc_cidr", "10.42.0.0/16") vars);
         check_bool "gcp var absent" false (List.mem ("project_id", "pluto-dev") vars)))
;;

let test_destroy_retention_survives_the_merge () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: example.test
|};
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  destroy_retention: none
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str_opt
        "destroy_retention reaches the resolved target"
        (Some "none")
        target.destroy_retention)
;;

let test_provisioner_impersonator_reaches_the_gcp_root () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
    provisioner_impersonator: user:ops@example.test
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "the declared caller reaches the GCP root as the list the root declares"
           (Some {|["user:ops@example.test"]|})
           (List.assoc_opt "provisioner_impersonators" vars)))
;;

let test_publisher_service_account_reaches_the_gcp_root () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
    publisher_service_account: publisher@sol-qualification.iam.gserviceaccount.com
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "the declared publisher reaches the GCP cluster root"
           (Some "publisher@sol-qualification.iam.gserviceaccount.com")
           (List.assoc_opt "publisher_service_account" vars)))
;;

let test_absent_provisioner_impersonator_grants_nobody () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool
           "no caller named means no impersonation, not the caller's own identity"
           false
           (List.mem_assoc "provisioner_impersonators" vars)))
;;

let test_flat_provider_key_is_refused () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "a flat provider-native key must be refused"
    | Error e ->
      let message = Sol_cli_config.error_to_string e in
      check_bool
        "names where the key now lives"
        true
        (Sol_cli_string.contains ~needle:"aws.provisioner_role_arn" message))
;;

let test_gcp_target_cannot_carry_aws_identity () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    state_lock_table: acme-tflock
  gcp:
    project_id: sol-qualification
|};
    let target_of name =
      match Sol_cli_config.load_for_target ~target:name with
      | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
      | Ok cfg -> cfg, cfg.target
    in
    let gcp_cfg, gcp = target_of "prod/gcp/us-central1" in
    let _, aws = target_of "prod/aws/us-east-1" in
    check_str_opt
      "the GCP target reads no AWS role"
      None
      (Sol_cli_config.provider_field gcp "provisioner_role_arn");
    check_str_opt
      "the AWS target does (positive control)"
      (Some "arn:aws:iam::111122223333:role/sol-provisioner")
      (Sol_cli_config.provider_field aws "provisioner_role_arn");
    match Sol_cli_terraform_vars.of_config ~workspace:"pluto" gcp_cfg with
    | Error msg -> Windtrap.fail msg
    | Ok vars ->
      check_bool
        "no AWS key reaches the GCP root"
        false
        (List.mem_assoc "provisioner_role_arn" vars
         || List.mem_assoc "state_lock_table" vars))
;;

let test_sol_owned_keys_are_not_passed_through () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    state_lock_table: acme-tflock
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    some_root_variable: passed
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool
           "the lock table is not a -var"
           false
           (List.mem_assoc "state_lock_table" vars);
         Windtrap.equal
           Windtrap.int
           ~msg:"the provisioner role is routed exactly once"
           1
           (List.length (List.filter (fun (k, _) -> k = "provisioner_role_arn") vars));
         check_str_opt
           "an ordinary provider-block variable still passes through"
           (Some "passed")
           (List.assoc_opt "some_root_variable" vars)))
;;

let test_provisioner_impersonator_survives_the_merge () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: example.test
|};
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  gcp:
    provisioner_impersonator: user:ops@example.test
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      check_str_opt
        "the declared caller survives the merge"
        (Some "user:ops@example.test")
        (Sol_cli_config.provider_field target "provisioner_impersonator"))
;;

let ecr_repositories_of_workspace () =
  write "sol.yml" "target:\n  aws:\n    vpc_cidr: \"10.42.0.0/16\"\n";
  match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
  | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
  | Ok cfg ->
    (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
     | Error msg -> Windtrap.fail msg
     | Ok vars -> List.assoc_opt "ecr_repositories" vars)
;;

let test_ecr_repositories_without_app_dir_are_empty () =
  with_temp_dir (fun () ->
    check_str_opt
      "no app/ -> no repositories"
      (Some "[]")
      (ecr_repositories_of_workspace ()))
;;

let test_ecr_repositories_follow_dockerfiles () =
  with_temp_dir (fun () ->
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    mkdir_p "app/payments/refund_svc";
    check_str_opt
      "only the workload with a Dockerfile"
      (Some {|["charge-svc"]|})
      (ecr_repositories_of_workspace ()))
;;

let test_unknown_destroy_retention_is_refused_at_prepare () =
  with_temp_dir (fun () ->
    write "sol.yml" "target:\n  base_domain: example.test\n";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      "target:\n  destroy_retention: keep-everything\n";
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok config ->
      let target =
        { config.Sol_cli_config.target with
          Sol_cli_config.destroy_retention = Some "keep-everything"
        }
      in
      (match Sol_cli_provider_capabilities.validate_target target.provider target with
       | Error message ->
         Windtrap.is_true
           ~msg:"the refusal names the invalid value"
           (Sol_cli_string.contains ~needle:"keep-everything" message)
       | Ok () -> Windtrap.fail "an unknown destroy_retention was accepted at prepare"))
;;

let test_gcs_soft_delete_follows_destroy_retention () =
  let soft_delete ~target ~retention =
    with_temp_dir (fun () ->
      write "sol.yml" "target:\n  base_domain: example.test\n";
      retention
      |> Option.iter (fun r ->
        Targets_fixture.write ~target ("target:\n  destroy_retention: " ^ r ^ "\n"));
      match Sol_cli_config.load_for_target ~target with
      | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
      | Ok cfg ->
        (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
         | Error msg -> Windtrap.fail msg
         | Ok vars -> List.assoc_opt "gcs_soft_delete_retention_seconds" vars))
  in
  check_str_opt
    "GCP none: soft delete off"
    (Some "0")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:(Some "none"));
  check_str_opt
    "GCP default: 7 days, explicit"
    (Some "604800")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:None);
  check_str_opt
    "GCP final-snapshot: 7 days, explicit"
    (Some "604800")
    (soft_delete ~target:"prod/gcp/us-central1" ~retention:(Some "final-snapshot"));
  check_str_opt
    "the AWS root does not declare it"
    None
    (soft_delete ~target:"prod/aws/us-east-1" ~retention:(Some "none"))
;;

let test_terraform_vars_are_provider_shaped () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool
           "the GCP root's own variable reaches it"
           true
           (List.mem ("project_id", "sol-qualification") vars);
         check_bool "region reaches it" true (List.mem ("region", "us-central1") vars);
         List.iter
           (fun aws_only ->
              check_bool
                (Printf.sprintf "%s must not reach the GCP root" aws_only)
                false
                (List.mem_assoc aws_only vars))
           [ "create_rds"
           ; "rds_multi_az"
           ; "ecr_repositories"
           ; "workspace_name"
           ; "provisioner_role_arn"
           ; "cluster_endpoint_cidr"
           ; "deploy_role_arn"
           ]))
;;

(* sol-fab/sol#1275: the durable root owns the delegated zone, so the cluster
   root must reuse it rather than create a second hosted zone for base_domain
   (which made its own data.aws_route53_zone lookup ambiguous). *)
let test_aws_cluster_root_reuses_the_durable_zone () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: qual.example.test
  dns_zone_ownership: sol
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "the cluster root reuses the durable root's zone"
           (Some "false")
           (List.assoc_opt "create_route53_zone" vars)))
;;

let test_no_zone_var_without_a_base_domain () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool
           "a target with no base_domain passes no zone setting"
           false
           (List.mem_assoc "create_route53_zone" vars)))
;;

(* The GCP cluster root has the same create_dns_zone flag as AWS. The durable
   root owns the delegated zone, so Sol's own vars must select the existing
   zone rather than letting the inventory classify a target-created zone as an
   external prerequisite. *)
let test_gcp_cluster_root_reuses_the_durable_zone () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  base_domain: qual.example.test
  dns_zone_ownership: sol
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "the GCP cluster root reuses the durable root's zone"
           (Some "false")
           (List.assoc_opt "create_dns_zone" vars)))
;;

let test_gcp_zone_var_is_always_false_without_a_base_domain () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "a GCP target with no base_domain still prohibits a target-owned zone"
           (Some "false")
           (List.assoc_opt "create_dns_zone" vars)))
;;

let test_terraform_vars_workspace_name_and_ecr_repositories () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    mkdir_p "app/payments/charge_svc";
    write "app/payments/charge_svc/Dockerfile" "FROM scratch\n";
    mkdir_p "app/comms/notify_worker";
    write "app/comms/notify_worker/Dockerfile" "FROM scratch\n";
    mkdir_p "app/comms/spike_fn";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "workspace_name"
           (Some "pluto")
           (List.assoc_opt "workspace_name" vars);
         (match List.assoc_opt "ecr_repositories" vars with
          | None -> Windtrap.fail "expected ecr_repositories var"
          | Some ecr ->
            check_bool
              "charge-svc present"
              true
              (Sol_cli_string.contains ~needle:"\"charge-svc\"" ecr);
            check_bool
              "notify-worker present"
              true
              (Sol_cli_string.contains ~needle:"\"notify-worker\"" ecr);
            check_bool
              "spike-fn absent (no Dockerfile)"
              false
              (Sol_cli_string.contains ~needle:"spike-fn" ecr))))
;;

let test_production_profile_enables_rds_multi_az () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      "target:\n  profile: production-single-region\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt "RDS Multi-AZ" (Some "true") (List.assoc_opt "rds_multi_az" vars)))
;;

let test_production_profile_enables_gcp_sql_ha () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  profile: production-single-region
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "Cloud SQL Regional HA"
           (Some "true")
           (List.assoc_opt "sql_high_availability" vars);
         check_str_opt
           "Cloud SQL deletion protection"
           (Some "true")
           (List.assoc_opt "sql_deletion_protection" vars)))
;;

let test_gcp_target_endpoint_cidr_reaches_the_cluster_root () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/gcp";
    Targets_fixture.write
      ~target:"prod/gcp/us-central1"
      {|
target:
  profile: production-single-region
  cluster_endpoint_cidr: 203.0.113.0/24
  gcp:
    project_id: sol-qualification
|};
    match Sol_cli_config.load_for_target ~target:"prod/gcp/us-central1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "the GCP control-plane endpoint CIDR reaches the cluster root"
           (Some "203.0.113.0/24")
           (List.assoc_opt "cluster_endpoint_cidr" vars)))
;;

let test_production_profile_enables_rds_deletion_protection () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      "target:\n  profile: production-single-region\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "RDS deletion protection"
           (Some "true")
           (List.assoc_opt "rds_deletion_protection" vars)))
;;

let test_non_production_target_leaves_rds_deletion_protection_unset () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/dev/aws";
    Targets_fixture.write
      ~target:"dev/aws/us-east-1"
      "target:\n  cluster_name: dev-cluster\n";
    match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "no forced value without a production profile"
           None
           (List.assoc_opt "rds_deletion_protection" vars)))
;;

let effective_value key vars =
  List.fold_left
    (fun acc v ->
       match String.index_opt v '=' with
       | Some i when String.sub v 0 i = key ->
         Some (String.sub v (i + 1) (String.length v - i - 1))
       | _ -> acc)
    None
    vars
;;

let test_profile_precedence_defeats_a_conflicting_override () =
  let cli_vars = [ "rds_deletion_protection=false" ] in
  let config_vars = [ "rds_deletion_protection=true" ] in
  check_str_opt
    "production profile: override defeated, profile value wins"
    (Some "true")
    (effective_value
       "rds_deletion_protection"
       (Sol_cli_config.vars_with_profile_precedence
          ~has_profile:true
          ~cli_vars
          ~config_vars));
  check_str_opt
    "no profile: ordinary target keeps full operator control"
    (Some "false")
    (effective_value
       "rds_deletion_protection"
       (Sol_cli_config.vars_with_profile_precedence
          ~has_profile:false
          ~cli_vars
          ~config_vars))
;;

let test_terraform_vars_route_cluster_issuer_to_the_base_layer () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  cluster_issuer: letsencrypt-staging
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_bool
           "cluster_issuer is not routed to the provider root"
           false
           (List.mem_assoc "cluster_issuer" vars);
         check_str_opt
           "a provider-root variable the root does declare is still routed"
           (Some "203.0.113.0/24")
           (List.assoc_opt "cluster_endpoint_cidr" vars)))
;;

let test_terraform_vars_route_deploy_role_arn () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
    deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
    operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "deploy_role_arn is routed to the provider root"
           (Some "arn:aws:iam::111122223333:role/sol-deploy")
           (List.assoc_opt "deploy_role_arn" vars);
         check_str_opt
           "provisioner_role_arn is routed"
           (Some "arn:aws:iam::111122223333:role/sol-provisioner")
           (List.assoc_opt "provisioner_role_arn" vars);
         check_str_opt
           "cluster_access_role_arn is routed"
           (Some "arn:aws:iam::111122223333:role/sol-cluster-access")
           (List.assoc_opt "cluster_access_role_arn" vars);
         check_str_opt
           "operator_role_arn is routed to the provider root (DEC-038)"
           (Some "arn:aws:iam::111122223333:role/sol-operator")
           (List.assoc_opt "operator_role_arn" vars)))
;;

let test_terraform_vars_ecr_repositories_empty_without_app_dir () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
target:
  aws:
    vpc_cidr: "10.42.0.0/16"
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      (match Sol_cli_terraform_vars.of_config ~workspace:"pluto" cfg with
       | Error msg -> Windtrap.fail msg
       | Ok vars ->
         check_str_opt
           "ecr_repositories"
           (Some "[]")
           (List.assoc_opt "ecr_repositories" vars)))
;;

let test_example_pluto_prod_target_parses () =
  with_chdir (example_pluto_dir ()) (fun () ->
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let resource =
        Sol_cli_config.resources cfg
        |> List.find (fun (r : Sol_cli_config.resource) -> r.name = "app_db")
      in
      check_str_opt "size" (Some "small") resource.size)
;;

let test_local_env_is_reserved () =
  with_temp_dir (fun () ->
    write_base ();
    match Sol_cli_config.load_for_target ~target:"local/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "expected `local` to be rejected as an env name"
    | Error e ->
      assert (Sol_cli_string.contains ~needle:"reserved" e.message);
      assert (Sol_cli_string.contains ~needle:"sol local deploy" e.message))
;;

let test_target_cannot_resolve_to_the_local_destination () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    Targets_fixture.write
      ~target:"prod/aws/us-east-1"
      {|
target:
  kube_context: k3d-sol-local
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let target = cfg.target in
      (match Sol_cli_config.destination_of_target target with
       | Ok _ -> Windtrap.fail "a configured target must not resolve to the local cluster"
       | Error message ->
         assert (String.length message > 0);
         assert (String.length message > 0 && message <> "")))
;;

let test_yaml_flow_map_and_exact_text () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol";
    write
      "sol/environments.yml"
      {|prod: { targets: { aws/us-east-1: { registry: r.example.com, cluster_name: 012,
  base_domain: "1.10", services: { api: { scale: { min: 1, max: 3 } } } } } }
|};
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok cfg ->
      let t = cfg.target in
      check_str "registry" "r.example.com" (Option.value t.registry ~default:"");
      check_str "cluster_name" "012" (Option.value t.cluster_name ~default:"");
      check_str "base_domain" "1.10" (Option.value t.base_domain ~default:""))
;;

let test_yaml_duplicate_key_fails () =
  with_temp_dir (fun () ->
    write
      "sol.yml"
      {|
services:
  api:
    type: http
  api:
    type: worker
|};
    expect_load_error "duplicate service \"api\"")
;;

let test_yaml_syntax_error_names_its_line () =
  with_temp_dir (fun () ->
    write "sol.yml" "project: p\nservices:\n  api:\n    uses: [app_db\n";
    match Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Ok _ -> Windtrap.fail "expected a YAML syntax error"
    | Error e -> Windtrap.equal Windtrap.int ~msg:"line" 4 e.line)
;;

let test_var_file_resolution () =
  let resolve =
    Sol_cli_terraform_vars.var_file ~cwd:"/ws/app/deep" ~workspace_root:"/ws"
  in
  let check name want got =
    Windtrap.equal (Windtrap.option Windtrap.string) ~msg:name want got
  in
  check
    "a target's relative path is from the workspace root"
    (Some "/ws/vars/x.tfvars")
    (resolve ~flag:None ~target:(Some "vars/x.tfvars"));
  check
    "a relative flag is from the shell's directory"
    (Some "/ws/app/deep/f.tfvars")
    (resolve ~flag:(Some "f.tfvars") ~target:None);
  check
    "the flag wins over the target"
    (Some "/ws/app/deep/f.tfvars")
    (resolve ~flag:(Some "f.tfvars") ~target:(Some "vars/x.tfvars"));
  check
    "an absolute target path is used as written"
    (Some "/abs/x.tfvars")
    (resolve ~flag:None ~target:(Some "/abs/x.tfvars"));
  check "no var file" None (resolve ~flag:None ~target:None)
;;

let write_envs ?local text =
  mkdir_p "sol";
  write "sol/environments.yml" text;
  Option.iter (write "sol/environments.local.yml") local
;;

let resolve_ok target =
  match Sol_cli_config.load_for_target ~target with
  | Ok cfg -> cfg
  | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
;;

let resolve_error target =
  match Sol_cli_config.load_for_target ~target with
  | Ok _ -> Windtrap.fail ("expected " ^ target ^ " to be refused")
  | Error e -> e.message
;;

let target_of (cfg : Sol_cli_config.t) = cfg.target

let service cfg name =
  List.find
    (fun (s : Sol_cli_config.service) -> s.name = name)
    (Sol_cli_config.services cfg)
;;

let check_contains name ~needle haystack =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack && (String.sub haystack i n = needle || go (i + 1))
  in
  Windtrap.equal Windtrap.bool ~msg:(name ^ ": " ^ haystack) true (go 0)
;;

let test_env_layer_precedence () =
  with_temp_dir (fun () ->
    write "sol.yml" "project: p\ntarget:\n  base_domain: from-sol-yml.test\n";
    write_envs
      {|prod:
  base_domain: from-env.test
  letsencrypt_email: ops@env.test
  targets:
    aws/us-east-1:
      letsencrypt_email: ops@target.test
      cluster_name: east
    aws/us-west-2:
      cluster_name: west
|};
    let east = target_of (resolve_ok "prod/aws/us-east-1") in
    let west = target_of (resolve_ok "prod/aws/us-west-2") in
    check_str "env overrides sol.yml" "from-env.test" (Option.get east.base_domain);
    check_str "target overrides env" "ops@target.test" (Option.get east.letsencrypt_email);
    check_str "env inherited" "ops@env.test" (Option.get west.letsencrypt_email);
    check_str "target-only key" "west" (Option.get west.cluster_name))
;;

let test_scale_and_provider_blocks_deep_merge () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      {|prod:
  aws:
    state_lock_table: lock
  services:
    api:
      scale:
        min: 2
  targets:
    aws/us-east-1:
      aws:
        provisioner_role_arn: arn:aws:iam::1:role/p
      services:
        api:
          scale:
            max: 5
|};
    let cfg = resolve_ok "prod/aws/us-east-1" in
    let api = service cfg "api" in
    Windtrap.equal
      (Windtrap.option Windtrap.int)
      ~msg:"env min survives"
      (Some 2)
      api.scale_min;
    Windtrap.equal (Windtrap.option Windtrap.int) ~msg:"target max" (Some 5) api.scale_max;
    let t = target_of cfg in
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"env provider field survives"
      (Some "lock")
      (Sol_cli_config.provider_field t "state_lock_table");
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"target provider field"
      (Some "arn:aws:iam::1:role/p")
      (Sol_cli_config.provider_field t "provisioner_role_arn"))
;;

let test_omit_is_sticky () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      {|dev:
  services:
    api:
      omit: true
  targets:
    aws/us-east-1:
      services:
        api:
          omit: false
|};
    let cfg = resolve_ok "dev/aws/us-east-1" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"a target cannot bring back what its environment omitted"
      false
      (Sol_cli_config.services cfg
       |> List.exists (fun (s : Sol_cli_config.service) -> s.name = "api")))
;;

let test_blank_values_are_missing () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs "prod:\n  targets:\n    aws/us-east-1:\n      registry: \"  \"\n";
    check_contains
      "quoted blank"
      ~needle:"missing value for registry"
      (resolve_error "prod/aws/us-east-1");
    write_envs "prod:\n  targets:\n    aws/us-east-1:\n      registry: \"\"\n";
    check_contains
      "quoted empty"
      ~needle:"missing value for registry"
      (resolve_error "prod/aws/us-east-1");
    write_envs "prod:\n  targets:\n    aws/us-east-1:\n      registry: \" r.example \"\n";
    let cfg = resolve_ok "prod/aws/us-east-1" in
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"trimmed"
      (Some "r.example")
      cfg.target.registry)
;;

let test_target_only_key_rejected_at_env_level () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs "prod:\n  cluster_name: shared\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"cluster_name is target-only"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_app_shape_rejected_outside_sol_yml () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      "prod:\n\
      \  targets:\n\
      \    aws/us-east-1:\n\
      \      services:\n\
      \        api:\n\
      \          path: elsewhere\n";
    check_contains
      "message"
      ~needle:"services.api.path belongs in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_undeclared_service_rejected () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      "prod:\n  services:\n    ghost:\n      omit: true\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"service \"ghost\" is not declared in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_local_file_adds_keys_and_environments () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:
        {|prod:
  targets:
    aws/us-east-1:
      registry: 123456789012.dkr.ecr.us-east-1.amazonaws.com
qual:
  targets:
    gcp/us-central1:
      cluster_name: sol-qual
|}
      "prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: prod\n";
    let prod = target_of (resolve_ok "prod/aws/us-east-1") in
    check_str "tracked key" "prod" (Option.get prod.cluster_name);
    check_str
      "local key"
      "123456789012.dkr.ecr.us-east-1.amazonaws.com"
      (Option.get prod.registry);
    let qual = target_of (resolve_ok "qual/gcp/us-central1") in
    check_str "local-only environment" "sol-qual" (Option.get qual.cluster_name))
;;

let test_local_file_may_not_change_tracked_keys () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:"prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: other\n"
      "prod:\n  targets:\n    aws/us-east-1:\n      cluster_name: prod\n";
    check_contains
      "message"
      ~needle:"cluster_name is already set in sol/environments.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_per_target_files_refused () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sol/prod/aws";
    write "sol/prod/aws/us-east-1.yml" "target:\n  cluster_name: old\n";
    check_contains
      "message"
      ~needle:"per-target files are no longer read"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_project_rejected_in_environment () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs "prod:\n  project: nope\n  targets:\n    aws/us-east-1:\n";
    check_contains
      "message"
      ~needle:"project belongs in sol.yml"
      (resolve_error "prod/aws/us-east-1"))
;;

let test_declared_targets_are_discovered () =
  with_temp_dir (fun () ->
    write_base ();
    write_envs
      ~local:"qual:\n  targets:\n    gcp/us-central1:\n"
      "prod:\n  targets:\n    aws/us-east-1:\n    aws/us-west-2:\n";
    match Sol_cli_config.discover_target_paths () with
    | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
    | Ok paths ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"targets"
        [ "prod/aws/us-east-1"; "prod/aws/us-west-2"; "qual/gcp/us-central1" ]
        paths)
;;

let%test "sol.yml: local env is reserved" = test_local_env_is_reserved ()

let%test "sol.yml: target path supplies placement" =
  test_target_path_supplies_placement ()
;;

let%test "sol.yml: target overlay omits entries" =
  test_target_overlay_can_omit_resources_and_services ()
;;

let%test "sol.yml: observability_backend parsed" =
  test_target_observability_backend_parsed ()
;;

let%test "sol.yml: observability_backend absent when unset" =
  test_target_observability_backend_absent_when_unset ()
;;

let%test "sol.yml: alert delivery declaration parsed" =
  test_target_alert_delivery_parsed ()
;;

let%test "sol.yml: recoverable state and identities parsed" =
  test_target_recoverable_state_and_identities_parsed ()
;;

let%test "sol.yml: bad target path fails" = test_bad_target_path_fails ()
let%test "sol.yml: unknown target provider fails" = test_unknown_target_provider_fails ()
let%test "sol.yml: parent target path fails" = test_parent_target_path_fails ()

let%test "sol.yml: target outside a workspace fails closed" =
  test_target_outside_a_workspace_fails_closed ()
;;

let%test "sol.yml: target with only sol.yml succeeds" =
  test_target_with_only_sol_yml_succeeds ()
;;

let%test "sol.yml: same cluster across envs fails" =
  test_same_cluster_across_envs_fails ()
;;

let%test "sol.yml: different destinations succeed" =
  test_different_destinations_succeed ()
;;

let%test "sol.yml: destination comes from the target" =
  test_destination_comes_from_the_target ()
;;

let%test "sol.yml: destination includes scoped kubeconfig" =
  test_destination_includes_scoped_kubeconfig ()
;;

let%test "sol.yml: missing destination fails closed" =
  test_destination_missing_fails_closed ()
;;

let%test "sol.yml: a target cannot resolve to the local destination" =
  test_target_cannot_resolve_to_the_local_destination ()
;;

let%test "sol.yml: duplicate resource fails" = test_duplicate_resource_fails ()
let%test "sol.yml: unknown key fails" = test_unknown_key_fails ()
let%test "sol.yml: service language parses" = test_service_language_parses ()

let%test "sol.yml: unknown service language fails" =
  test_unknown_service_language_fails ()
;;

let%test "sol.yml: duplicate top-level section fails" =
  test_duplicate_top_level_section_fails ()
;;

let%test "sol.yml: duplicate index fails" = test_duplicate_index_fails ()
let%test "sol.yml: malformed list fails" = test_malformed_list_fails ()
let%test "sol.yml: malformed quoted scalar fails" = test_malformed_quoted_scalar_fails ()

let%test "sol.yml: malformed quoted list item fails" =
  test_malformed_quoted_list_item_fails ()
;;

let%test "sol.yml: undeclared uses ref fails" = test_undeclared_uses_ref_fails ()

let%test "sol.yml: absolute cross-region uses ref parses" =
  test_absolute_cross_region_uses_ref_parses ()
;;

let%test "sol.yml: cross-provider uses ref fails" = test_cross_provider_uses_ref_fails ()
let%test "sol.yml: cross-env uses ref fails" = test_cross_env_uses_ref_fails ()

let%test "sol.yml: three-segment cross-env uses ref fails" =
  test_three_segment_cross_env_uses_ref_fails ()
;;

let%test "sol.yml: two-segment cross-provider uses ref fails" =
  test_two_segment_cross_provider_uses_ref_fails ()
;;

let%test "sol.yml: empty-segment uses ref fails to parse" =
  test_empty_segment_uses_ref_fails_to_parse ()
;;

let%test "sol.yml: omitted resource uses ref fails" =
  test_omitted_resource_uses_ref_fails ()
;;

let%test "sol.yml: resource key after indexes parses" =
  test_resource_key_after_indexes_parses ()
;;

let%test "sol.yml: service key after scale parses" =
  test_service_key_after_scale_parses ()
;;

let%test "sol.yml: nested provider field is refused, naming the key" =
  test_nested_provider_box_still_tolerated ()
;;

let%test "sol.yml: provider box ends before generic key" =
  test_target_provider_box_ends_before_generic_key ()
;;

let%test "sol.yml: empty target value fails" = test_empty_target_value_fails ()
let%test "sol.yml: target after resources parses" = test_target_after_resources_parses ()
let%test "sol.yml: quoted hash survives" = test_quoted_hash_survives ()
let%test "sol.yml: single quoted hash survives" = test_single_quoted_hash_survives ()
let%test "sol.yml: malformed int fails" = test_malformed_int_fails ()
let%test "sol.yml: malformed bool fails" = test_malformed_bool_fails ()
let%test "sol.yml: root target defaults survive" = test_root_target_defaults_survive ()
let%test "sol.yml: FEAT-028 shapes tolerated" = test_feat_028_shapes_still_tolerated ()
let%test "sol.yml: provider box round trips" = test_provider_box_round_trips ()
let%test "sol.yml: duplicate provider box fails" = test_duplicate_provider_box_fails ()
let%test "sol.yml: unknown provider box fails" = test_unknown_provider_box_fails ()

let%test "sol.yml: provider fields feed terraform vars" =
  test_provider_fields_feed_active_terraform_provider ()
;;

let%test "sol.yml: ECR repositories: no app/ is empty (INFRA-074)" =
  test_ecr_repositories_without_app_dir_are_empty ()
;;

let%test "sol.yml: ECR repositories follow Dockerfiles (INFRA-074)" =
  test_ecr_repositories_follow_dockerfiles ()
;;

let%test "sol.yml: an unknown destroy_retention is refused at prepare" =
  test_unknown_destroy_retention_is_refused_at_prepare ()
;;

let%test "sol.yml: destroy_retention survives the merge" =
  test_destroy_retention_survives_the_merge ()
;;

let%test "sol.yml: provisioner impersonator: reaches the GCP root" =
  test_provisioner_impersonator_reaches_the_gcp_root ()
;;

let%test "sol.yml: provisioner impersonator: absent grants nobody" =
  test_absent_provisioner_impersonator_grants_nobody ()
;;

let%test "sol.yml: provisioner impersonator: survives the merge" =
  test_provisioner_impersonator_survives_the_merge ()
;;

let%test "sol.yml: REFAC-098: a flat provider-native key is refused" =
  test_flat_provider_key_is_refused ()
;;

let%test "sol.yml: REFAC-098: a GCP target cannot carry AWS identity" =
  test_gcp_target_cannot_carry_aws_identity ()
;;

let%test "sol.yml: REFAC-098: Sol-owned keys are not passed through" =
  test_sol_owned_keys_are_not_passed_through ()
;;

let%test "sol.yml: terraform vars: provider-shaped" =
  test_terraform_vars_are_provider_shaped ()
;;

let%test "sol.yml: terraform vars: the cluster root reuses the durable zone" =
  test_aws_cluster_root_reuses_the_durable_zone ()
;;

let%test "sol.yml: terraform vars: no zone setting without a base_domain" =
  test_no_zone_var_without_a_base_domain ()
;;

let%test "sol.yml: terraform vars: the GCP cluster root reuses the durable zone" =
  test_gcp_cluster_root_reuses_the_durable_zone ()
;;

let%test
    "sol.yml: terraform vars: GCP prohibits a target-owned zone without a base_domain"
  =
  test_gcp_zone_var_is_always_false_without_a_base_domain ()
;;

let%test "sol.yml: terraform vars: GCS soft delete follows destroy_retention" =
  test_gcs_soft_delete_follows_destroy_retention ()
;;

let%test "sol.yml: terraform vars: workspace_name + ecr_repositories" =
  test_terraform_vars_workspace_name_and_ecr_repositories ()
;;

let%test "sol.yml: production profile enables RDS Multi-AZ" =
  test_production_profile_enables_rds_multi_az ()
;;

let%test "sol.yml: production profile enables Cloud SQL Regional HA" =
  test_production_profile_enables_gcp_sql_ha ()
;;

let%test "sol.yml: a GCP endpoint CIDR reaches the cluster root" =
  test_gcp_target_endpoint_cidr_reaches_the_cluster_root ()
;;

let%test "sol.yml: production profile enables RDS deletion protection" =
  test_production_profile_enables_rds_deletion_protection ()
;;

let%test "sol.yml: non-production target leaves RDS deletion protection unset" =
  test_non_production_target_leaves_rds_deletion_protection_unset ()
;;

let%test "sol.yml: profile precedence defeats a conflicting override" =
  test_profile_precedence_defeats_a_conflicting_override ()
;;

let%test "sol.yml: terraform vars: cluster_issuer stays in the base layer" =
  test_terraform_vars_route_cluster_issuer_to_the_base_layer ()
;;

let%test "sol.yml: terraform vars: deploy_role_arn reaches the provider root" =
  test_terraform_vars_route_deploy_role_arn ()
;;

let%test "sol.yml: terraform vars: ecr_repositories empty without app/" =
  test_terraform_vars_ecr_repositories_empty_without_app_dir ()
;;

let%test "sol.yml: example pluto prod target parses" =
  test_example_pluto_prod_target_parses ()
;;

let%test "sol.yml: environments: layer precedence" = test_env_layer_precedence ()

let%test "sol.yml: environments: scale and provider blocks deep-merge" =
  test_scale_and_provider_blocks_deep_merge ()
;;

let%test "sol.yml: environments: omit is sticky" = test_omit_is_sticky ()

let%test "sol.yml: blank values are missing (REFAC-123)" =
  test_blank_values_are_missing ()
;;

let%test "sol.yml: environments: target-only key rejected at env level" =
  test_target_only_key_rejected_at_env_level ()
;;

let%test "sol.yml: environments: app shape rejected outside sol.yml" =
  test_app_shape_rejected_outside_sol_yml ()
;;

let%test "sol.yml: environments: undeclared service rejected" =
  test_undeclared_service_rejected ()
;;

let%test "sol.yml: environments: local file adds keys and environments" =
  test_local_file_adds_keys_and_environments ()
;;

let%test "sol.yml: environments: local file may not change tracked keys" =
  test_local_file_may_not_change_tracked_keys ()
;;

let%test "sol.yml: environments: per-target files refused" =
  test_per_target_files_refused ()
;;

let%test "sol.yml: environments: project rejected in an environment" =
  test_project_rejected_in_environment ()
;;

let%test "sol.yml: environments: declared targets are discovered" =
  test_declared_targets_are_discovered ()
;;

let%test "sol.yml: yaml: flow maps and exact scalar text (REFAC-106)" =
  test_yaml_flow_map_and_exact_text ()
;;

let%test "sol.yml: yaml: duplicate key fails" = test_yaml_duplicate_key_fails ()

let%test "sol.yml: yaml: syntax error names its line" =
  test_yaml_syntax_error_names_its_line ()
;;

let%test "sol.yml: terraform vars: var file resolution (BUG-057)" =
  test_var_file_resolution ()
;;

let owned_key_names driver =
  Sol_cli_provider.owned_keys driver
  |> List.map (fun (owned : Sol_cli_provider.owned_key) -> owned.key)
;;

let test_owned_keys_are_declared_once () =
  let all_keys = Sol_cli_provider.all |> List.concat_map owned_key_names in
  check_bool
    "no key is owned by two drivers"
    true
    (List.length (List.sort_uniq String.compare all_keys) = List.length all_keys);
  check_strs
    "aws owns its declared keys"
    [ "state_lock_table"
    ; "provisioner_role_arn"
    ; "cluster_access_role_arn"
    ; "deploy_role_arn"
    ; "operator_role_arn"
    ]
    (owned_key_names Sol_cli_provider.Aws);
  check_strs
    "gcp owns its declared key"
    [ "provisioner_impersonator"; "publisher_service_account" ]
    (owned_key_names Sol_cli_provider.Gcp);
  check_strs "byo owns no key" [] (owned_key_names Sol_cli_provider.Byo)
;;

let test_sol_keys_derive_from_the_declaration () =
  Sol_cli_provider.all
  |> List.iter (fun driver ->
    let consumed =
      Sol_cli_provider.owned_keys driver
      |> List.filter_map (fun (owned : Sol_cli_provider.owned_key) ->
        match owned.disposition with
        | Sol_cli_provider.Sol_consumes -> Some owned.key
        | Sol_cli_provider.Passed_to_terraform -> None)
    in
    check_strs
      (Printf.sprintf
         "%s: sol_keys is the consumed subset"
         (Sol_cli_provider.to_string driver))
      consumed
      (Sol_cli_provider.sol_keys driver));
  check_strs
    "aws consumed keys"
    [ "state_lock_table"
    ; "provisioner_role_arn"
    ; "cluster_access_role_arn"
    ; "deploy_role_arn"
    ; "operator_role_arn"
    ]
    (Sol_cli_provider.sol_keys Sol_cli_provider.Aws);
  check_strs
    "gcp consumed key"
    [ "provisioner_impersonator"; "publisher_service_account" ]
    (Sol_cli_provider.sol_keys Sol_cli_provider.Gcp);
  check_strs "byo consumes nothing" [] (Sol_cli_provider.sol_keys Sol_cli_provider.Byo)
;;

let test_owned_legacy_key_finds_the_driver () =
  check_bool
    "an aws key resolves to aws"
    true
    (Sol_cli_provider.owned_legacy_key "deploy_role_arn" = Some Sol_cli_provider.Aws);
  check_bool
    "a gcp key resolves to gcp"
    true
    (Sol_cli_provider.owned_legacy_key "provisioner_impersonator"
     = Some Sol_cli_provider.Gcp);
  check_bool
    "an ordinary key belongs to no driver"
    true
    (Sol_cli_provider.owned_legacy_key "registry" = None)
;;

let%test "driver keys: one declaration per driver (DEC-053)" =
  test_owned_keys_are_declared_once ()
;;

let%test "driver keys: sol_keys is the consumed subset (DEC-053)" =
  test_sol_keys_derive_from_the_declaration ()
;;

let%test "driver keys: a flat key resolves to its owning driver (DEC-053)" =
  test_owned_legacy_key_finds_the_driver ()
;;

let%test "target secrets: per-unit authority resolution" =
  test_target_secret_authorities_resolve_per_unit_key ()
;;

let%test "target secrets: malformed external refs fail" =
  test_secret_authorities_reject_malformed_references ()
;;

let%test "target secrets: scalar authority shorthand fails" =
  test_secret_authorities_reject_scalar_shorthand ()
;;

(* Resource bindings — docs/architecture/resource-bindings.md. The base workspace declares
   app_db (postgres); a target-level binding overrides its ownership. *)

let mentions needle text =
  let n = String.length needle in
  let t = String.length text in
  let rec go i =
    i + n <= t && (String.equal (String.sub text i n) needle || go (i + 1))
  in
  go 0
;;

let load_with_binding body =
  write_base ();
  mkdir_p "sol/prod/aws";
  Targets_fixture.write ~target:"prod/aws/us-east-1" body;
  Sol_cli_config.load_for_target ~target:"prod/aws/us-east-1"
;;

let test_external_binding_suppresses_provisioning () =
  with_temp_dir (fun () ->
    match
      load_with_binding
        {|target:
  resources:
    app_db:
      binding:
        ownership: external
        store: vault-production
        keys:
          POSTGRES_URL: secret/production/app-db
|}
    with
    | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
    | Ok config ->
      (match Sol_cli_resource_binding.resolve config with
       | Error message -> Windtrap.fail message
       | Ok bindings ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"an externally bound database must not also be provisioned"
           false
           (Sol_cli_resource_binding.provisions bindings ~typ:"postgres");
         let store =
           match Sol_cli_resource_binding.of_type bindings ~typ:"postgres" with
           | [ binding ] -> binding.store
           | _ -> None
         in
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"the external store is resolved"
           (Some "vault-production")
           store))
;;

let test_binding_override_is_atomic () =
  with_temp_dir (fun () ->
    (* Environment-level binding, then a target-level one. The target replaces the whole
       selection: its store is used and the environment's keys do not survive. *)
    match
      load_with_binding
        {|target:
  resources:
    app_db:
      binding:
        ownership: external
        store: eu-vault
        keys:
          POSTGRES_URL: secret/eu/app-db
|}
    with
    | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
    | Ok config ->
      (match Sol_cli_resource_binding.resolve config with
       | Error message -> Windtrap.fail message
       | Ok bindings ->
         (match Sol_cli_resource_binding.of_type bindings ~typ:"postgres" with
          | [ binding ] ->
            Windtrap.equal
              (Windtrap.option Windtrap.string)
              ~msg:"the target's store replaces the inherited one"
              (Some "eu-vault")
              binding.store;
            Windtrap.equal
              (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
              ~msg:"the target's keys replace the inherited ones"
              [ "POSTGRES_URL", "secret/eu/app-db" ]
              binding.keys
          | _ -> Windtrap.fail "expected one postgres binding")))
;;

let test_ownership_sol_is_refused () =
  with_temp_dir (fun () ->
    match
      load_with_binding
        {|target:
  resources:
    app_db:
      binding:
        ownership: sol
        store: vault-production
        keys:
          POSTGRES_URL: secret/production/app-db
|}
    with
    | Ok _ ->
      Windtrap.fail "ownership sol must be refused: the resource graph is the declaration"
    | Error error ->
      let text = Sol_cli_config.error_to_string error in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal explains why"
        true
        (mentions "already declares a Sol-provisioned resource" text))
;;

let test_external_binding_requires_store_and_keys () =
  with_temp_dir (fun () ->
    let refuses body needle =
      match load_with_binding body with
      | Ok _ -> Windtrap.fail (Printf.sprintf "expected a refusal mentioning %S" needle)
      | Error error ->
        Windtrap.equal
          Windtrap.bool
          ~msg:("refusal mentions " ^ needle)
          true
          (mentions needle (Sol_cli_config.error_to_string error))
    in
    refuses
      {|target:
  resources:
    app_db:
      binding:
        ownership: external
        keys:
          POSTGRES_URL: secret/production/app-db
|}
      "requires store";
    refuses
      {|target:
  resources:
    app_db:
      binding:
        ownership: external
        store: vault-production
|}
      "requires keys")
;;

let postgres_resource ?binding name =
  { Sol_cli_config.name
  ; typ = Some "postgres"
  ; partition_key = None
  ; sort_key = None
  ; indexes = []
  ; size = None
  ; omit = false
  ; binding
  }
;;

let external_postgres_binding store =
  ({ Sol_cli_config.ownership = Sol_cli_config.Ownership_external
   ; store = Some store
   ; keys = []
   ; connection = []
   ; credentials = [ "ddl", "external/ddl"; "dml", "external/dml" ]
   }
   : Sol_cli_config.resource_binding)
;;

let resolve_refuses what resources =
  let config =
    { Sol_cli_config.project = Some "ws"
    ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
    ; resources
    ; services = []
    }
  in
  match Sol_cli_resource_binding.resolve config with
  | Ok _ -> Windtrap.fail (what ^ ": expected a refusal")
  | Error message -> message
;;

let with_setup_image_env value f =
  let saved = Sys.getenv_opt Sol_cli_platform_assets.setup_image_env in
  Unix.putenv Sol_cli_platform_assets.setup_image_env (Option.value value ~default:"");
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv Sol_cli_platform_assets.setup_image_env (Option.value saved ~default:""))
    f
;;

(* **#1427: an image is required exactly when the deployment provisions its own database.**
   This is the predicate the preflight and the setup step share, so a target that binds its
   database externally — delivered by ESO, not by the setup Job — is not made to carry an
   image it never uses, and a target with no database is not either. *)
let test_setup_image_needed_only_for_a_provisioned_database () =
  let preflight resources =
    Sol_cli_database_setup_run.setup_image_preflight
      { Sol_cli_config.project = Some "ws"
      ; target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/us-east-1")
      ; resources
      ; services = []
      }
  in
  let digest = "postgres@sha256:" ^ String.make 64 'a' in
  (match preflight [] with
   | Ok None -> ()
   | Ok (Some image) ->
     Windtrap.fail ("a target with no database required an image: " ^ image)
   | Error message -> Windtrap.fail ("a target with no database refused: " ^ message));
  (match
     preflight [ postgres_resource ~binding:(external_postgres_binding "vault") "app_db" ]
   with
   | Ok None -> ()
   | Ok (Some image) ->
     Windtrap.fail ("an externally bound database required a setup image: " ^ image)
   | Error message -> Windtrap.fail ("an externally bound database refused: " ^ message));
  with_setup_image_env (Some digest) (fun () ->
    match preflight [ postgres_resource "app_db" ] with
    | Ok (Some image) ->
      Windtrap.equal
        Windtrap.string
        ~msg:"a provisioned database resolves the image"
        digest
        image
    | Ok None -> Windtrap.fail "a Sol-provisioned database resolved no image"
    | Error message -> Windtrap.fail message);
  with_setup_image_env None (fun () ->
    match preflight [ postgres_resource "app_db" ] with
    | Ok None -> Windtrap.fail "a Sol-provisioned database refused to require an image"
    | Ok (Some _) -> Windtrap.fail "a provisioned database resolved an image from nowhere"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names what to configure"
        true
        (Sol_cli_string.contains ~needle:Sol_cli_platform_assets.setup_image_env message))
;;

let%test "1427: a setup image is required only for a provisioned database" =
  test_setup_image_needed_only_for_a_provisioned_database ()
;;

let test_more_than_one_database_is_refused () =
  (* A layer may not declare a resource's shape (DEC-047), so build the graph directly. *)
  let two_sol =
    resolve_refuses
      "two Sol-provisioned databases"
      [ postgres_resource "app_db"; postgres_resource "analytics_db" ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal names the v1 limit"
    true
    (mentions "one database per target" two_sol);
  let two_external =
    resolve_refuses
      "two external databases"
      [ postgres_resource ~binding:(external_postgres_binding "vault") "app_db"
      ; postgres_resource ~binding:(external_postgres_binding "vault") "analytics_db"
      ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"two external databases are refused, naming both"
    true
    (mentions "app_db" two_external && mentions "analytics_db" two_external);
  let sol_and_external =
    resolve_refuses
      "Sol-provisioned plus external"
      [ postgres_resource "app_db"
      ; postgres_resource ~binding:(external_postgres_binding "vault") "analytics_db"
      ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"Sol-provisioned plus external is refused, naming both"
    true
    (mentions "app_db" sol_and_external && mentions "analytics_db" sol_and_external)
;;

let%test "resource binding: an external binding suppresses provisioning" =
  test_external_binding_suppresses_provisioning ()
;;

let%test "resource binding: an override replaces the selection whole" =
  test_binding_override_is_atomic ()
;;

let%test "resource binding: ownership sol is refused" = test_ownership_sol_is_refused ()

let%test "resource binding: external requires store and keys" =
  test_external_binding_requires_store_and_keys ()
;;

(* The class dimension: a contract with credential classes resolves one contract key to a
   different remote path per class, so the class is the outer dimension of the selection. *)
let test_external_binding_credentials_are_per_class () =
  with_temp_dir (fun () ->
    match
      load_with_binding
        {|target:
  resources:
    app_db:
      binding:
        ownership: external
        store: vault-production
        credentials:
          ddl: secret/production/app-db-migrator
          dml: secret/production/app-db-app
|}
    with
    | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
    | Ok config ->
      (match Sol_cli_resource_binding.resolve config with
       | Error message -> Windtrap.fail message
       | Ok bindings ->
         (match Sol_cli_resource_binding.of_type bindings ~typ:"postgres" with
          | [ binding ] ->
            Windtrap.equal
              (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
              ~msg:"the per-class remote paths are resolved"
              [ "ddl", "secret/production/app-db-migrator"
              ; "dml", "secret/production/app-db-app"
              ]
              binding.credentials
          | _ -> Windtrap.fail "expected one postgres binding")))
;;

let%test "resource binding: external credentials are per class" =
  test_external_binding_credentials_are_per_class ()
;;

let%test "resource binding: more than one database is refused whatever the ownership" =
  test_more_than_one_database_is_refused ()
;;
