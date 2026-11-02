let aws_scope =
  match
    Sol_cli_provider_secret.scope
      ~provider:Sol_cli_provider_secret.Aws
      ~environment:"dev"
      ~target:"dev-aws-us-east-1"
      ~project:None
      ~region:(Some "us-east-1")
  with
  | Ok scope -> scope
  | Error message -> Windtrap.fail message
;;

let gcp_scope =
  match
    Sol_cli_provider_secret.scope
      ~provider:Sol_cli_provider_secret.Gcp
      ~environment:"dev"
      ~target:"dev-gcp-us-central1"
      ~project:(Some "example-project")
      ~region:None
  with
  | Ok scope -> scope
  | Error message -> Windtrap.fail message
;;

let secret ?(scope = aws_scope) ?(domain = "payments") ?(unit = "charge-svc") key =
  match Sol_cli_provider_secret.application ~scope ~domain ~unit ~key with
  | Ok secret -> secret
  | Error message -> Windtrap.fail message
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let refused = function
  | Ok _ -> Windtrap.fail "an unsafe provider secret address was accepted"
  | Error _ -> ()
;;

let%test "provider names include the unit, so a shared key is not a shared authority" =
  let first = secret ~domain:"payments" ~unit:"charge-svc" "API_KEY" in
  let second = secret ~domain:"billing" ~unit:"charge-svc" "API_KEY" in
  check_string
    "AWS names the unit path"
    "sol/dev/dev-aws-us-east-1/units/payments/charge-svc/API_KEY"
    (Sol_cli_provider_secret.reference first);
  check_string
    "GCP flattens the same path"
    "sol-dev-dev-gcp-us-central1-units-payments-charge-svc-API_KEY"
    (Sol_cli_provider_secret.reference (secret ~scope:gcp_scope "API_KEY"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"two units with the same key have different authorities"
    true
    (not
       (String.equal
          (Sol_cli_provider_secret.reference first)
          (Sol_cli_provider_secret.reference second)));
  check_string
    "the names differ by the unit path"
    "sol/dev/dev-aws-us-east-1/units/billing/charge-svc/API_KEY"
    (Sol_cli_provider_secret.reference second)
;;

let%test "GCP projects a versioned resource name; AWS projects its name" =
  let gcp = secret ~scope:gcp_scope "API_KEY" in
  check_string
    "the GKE resource names the project, secret and version"
    "projects/example-project/secrets/sol-dev-dev-gcp-us-central1-units-payments-charge-svc-API_KEY/versions/latest"
    (Sol_cli_provider_secret.spc_reference gcp);
  check_string
    "the AWS object is the secret name"
    "sol/dev/dev-aws-us-east-1/units/payments/charge-svc/API_KEY"
    (Sol_cli_provider_secret.spc_reference (secret "API_KEY"))
;;

let%test "provider names refuse path and wildcard injection" =
  refused
    (Sol_cli_provider_secret.application
       ~scope:aws_scope
       ~domain:"payments"
       ~unit:"charge-svc"
       ~key:"API/KEY");
  refused
    (Sol_cli_provider_secret.application
       ~scope:aws_scope
       ~domain:"payments"
       ~unit:"charge-svc"
       ~key:"API*");
  refused
    (Sol_cli_provider_secret.application
       ~scope:aws_scope
       ~domain:"payments"
       ~unit:"charge-svc"
       ~key:"api_key");
  refused
    (Sol_cli_provider_secret.application
       ~scope:aws_scope
       ~domain:"payments"
       ~unit:"charge-svc"
       ~key:"");
  refused
    (Sol_cli_provider_secret.application
       ~scope:aws_scope
       ~domain:"payments/../billing"
       ~unit:"charge-svc"
       ~key:"API_KEY")
;;

let%test "a provider scope refuses a store it cannot address" =
  refused
    (Sol_cli_provider_secret.scope
       ~provider:Sol_cli_provider_secret.Gcp
       ~environment:"dev"
       ~target:"dev-gcp-us-central1"
       ~project:None
       ~region:None);
  refused
    (Sol_cli_provider_secret.scope
       ~provider:Sol_cli_provider_secret.Aws
       ~environment:"dev"
       ~target:"dev-aws-us-east-1"
       ~project:None
       ~region:None);
  refused
    (Sol_cli_provider_secret.scope
       ~provider:Sol_cli_provider_secret.Aws
       ~environment:"Dev/Prod"
       ~target:"dev-aws-us-east-1"
       ~project:None
       ~region:(Some "us-east-1"))
;;

let%test "ownership metadata is the same predicate on both providers" =
  let labels = Sol_cli_provider_secret.ownership_labels (secret "API_KEY") in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the labels state the owner, authority and environment"
    [ "sol-managed-by"; "sol-authority"; "sol-environment"; "sol-target" ]
    (List.map (fun (k, _) -> k) labels);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the label values are nonconfidential identity"
    [ "sol"; "application"; "dev"; "dev-aws-us-east-1" ]
    (List.map snd labels)
;;

(* The authorization root receives the unit-qualified resource, so two units that declare
   the same key are bound to different provider secrets. *)
let%test "authorization grants are unit-qualified" =
  let target =
    { Sol_cli_config.name = "dev/aws/us-east-1"
    ; env = "dev"
    ; provider = Sol_cli_provider.Aws
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
    ; shape = Some Sol_cli_profile.Durable
    ; provider_fields = [ "aws", [ "state_lock_table", "lock" ] ]
    ; secret_authorities = []
    }
  in
  let config = { Sol_cli_config.project = None; target; resources = []; services = [] } in
  let service domain name =
    { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "app" }
  in
  let workload domain name =
    { Sol_cli_workspace_model.service = service domain name
    ; has_dockerfile = true
    ; language = None
    ; config = Ok { Sol_cli_toml.empty with secret_keys = [ "API_KEY" ] }
    }
  in
  let model =
    { Sol_cli_workspace_model.root = "/workspace"
    ; app_dir = Some "app"
    ; workloads = [ workload "payments" "charge_svc"; workload "billing" "charge_svc" ]
    ; unexpected = []
    ; declared = []
    ; topics = []
    ; schema_subjects = []
    ; migrations = []
    ; events = []
    ; targets = []
    }
  in
  match Sol_cli_authorization_reconcile.desired ~binding_config:config model with
  | Error message -> Windtrap.fail message
  | Ok grants ->
    let resources =
      grants
      |> List.map (fun (grant : Sol_cli_authorization.grant) -> grant.resource)
      |> List.sort String.compare
    in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"each unit gets its own provider resource"
      [ "units/billing/charge-svc/API_KEY"; "units/payments/charge-svc/API_KEY" ]
      resources
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    f
;;

let with_tmp content f =
  let path = Filename.temp_file "sol-secret-contract-" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc content);
       f path)
;;

let%test "a projected file is read before the environment" =
  with_tmp "file-value\n" (fun path ->
    with_env "SOL_PROBE_KEY" "env-value" (fun () ->
      with_env "SOL_PROBE_KEY_FILE" path (fun () ->
        Windtrap.equal
          (Windtrap.option Windtrap.string)
          ~msg:"the file is the value"
          (Some "file-value")
          (Sol_runtime.secret "SOL_PROBE_KEY"))))
;;

let%test "SOL_SECRETS_DIR is the provider-independent fallback" =
  let dir = Filename.temp_file "sol-secret-dir-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "SOL_PROBE_KEY") with
       | Sys_error _ -> ());
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       Out_channel.with_open_bin (Filename.concat dir "SOL_PROBE_KEY") (fun oc ->
         Out_channel.output_string oc "mounted-value");
       with_env "SOL_PROBE_KEY" "env-value" (fun () ->
         with_env "SOL_PROBE_KEY_FILE" "" (fun () ->
           with_env "SOL_SECRETS_DIR" dir (fun () ->
             Windtrap.equal
               (Windtrap.option Windtrap.string)
               ~msg:"the mounted file wins over the environment"
               (Some "mounted-value")
               (Sol_runtime.secret "SOL_PROBE_KEY")))))
;;

let%test "an environment-only value still works" =
  with_env "SOL_PROBE_KEY" "env-value" (fun () ->
    with_env "SOL_PROBE_KEY_FILE" "" (fun () ->
      with_env "SOL_SECRETS_DIR" "/nonexistent/sol/secrets" (fun () ->
        Windtrap.equal
          (Windtrap.option Windtrap.string)
          ~msg:"existing environment consumption is preserved"
          (Some "env-value")
          (Sol_runtime.secret "SOL_PROBE_KEY"))))
;;

let%test "an absent optional secret is None" =
  with_env "SOL_PROBE_KEY" "" (fun () ->
    with_env "SOL_PROBE_KEY_FILE" "" (fun () ->
      with_env "SOL_SECRETS_DIR" "/nonexistent/sol/secrets" (fun () ->
        Windtrap.equal
          (Windtrap.option Windtrap.string)
          ~msg:"no value and no file"
          None
          (Sol_runtime.secret "SOL_PROBE_KEY"))))
;;
