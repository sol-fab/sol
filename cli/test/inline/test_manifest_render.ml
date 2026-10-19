let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
;;

let expected_release_label =
  Printf.sprintf {|release: "%s"|} (Sol_cli_release_id.to_string release_id_of_test)
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let render_spec_ok
      ?(workspace = "myapp")
      ?env
      ?image
      ?(release_id = release_id_of_test)
      spec
  =
  match Sol_cli_deployment_render.render_spec ~workspace ?env ?image ~release_id spec with
  | Ok bundle -> bundle.namespace_yaml, bundle.prerequisites_yaml ^ bundle.workload_yaml
  | Error e -> Windtrap.fail ("render_spec unexpectedly failed: " ^ e)
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

let render_doc doc = Sol_cli_yaml.render [ doc ]

let workload
      ?(shape = Sol_cli_manifest.Http_service)
      ?(domain = "payments")
      ?(name = "charge-svc")
      ?(primitive = "svc")
      ()
  : Sol_cli_manifest.Workload_spec.t
  =
  { Sol_cli_manifest.Workload_spec.extra_labels = []
  ; secret_keys = []
  ; secret_sources = []
  ; volumes = []
  ; projected_identities = []
  ; env = None
  ; config_hash = "test-hash"
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; kafka_tls = false
  ; readiness_path = "/readyz"
  ; shape
  ; replicas = 1
  ; cpu = "100m"
  ; memory = "128Mi"
  ; ns = "myapp-" ^ domain
  ; name
  ; image = "sol-registry:5000/myapp/" ^ name ^ ":abc123"
  ; workspace = "myapp"
  ; domain
  ; primitive
  ; release_id = release_id_of_test
  ; db_dml_creds_name = None
  ; db_ca_configmap = None
  }
;;

let load_toml path =
  match Sol_cli_toml.load_result path with
  | Ok toml -> toml
  | Error err -> Windtrap.fail (Sol_cli_toml.parse_error_to_string err)
;;

let assert_contains label haystack needle =
  check_bool
    (Printf.sprintf "%s: contains %S" label needle)
    true
    (Sol_cli_string.contains ~needle haystack)
;;

let assert_absent label haystack needle =
  check_bool
    (Printf.sprintf "%s: absent %S" label needle)
    false
    (Sol_cli_string.contains ~needle haystack)
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

let extract_kind_block yaml kind_marker =
  let sep = "\n---" in
  let sl = String.length sep in
  let yl = String.length yaml in
  let blocks = ref [] in
  let start = ref 0 in
  for i = 0 to yl - sl do
    if String.sub yaml i sl = sep
    then (
      blocks := String.sub yaml !start (i - !start) :: !blocks;
      start := i + 1)
  done;
  blocks := String.sub yaml !start (yl - !start) :: !blocks;
  let result = ref "" in
  List.rev !blocks
  |> List.iter (fun b ->
    if !result = "" && Sol_cli_string.contains ~needle:kind_marker b then result := b);
  !result
;;

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "sol-registry:5000/myapp/charge-svc:abc123"
  ; config = [ "APP_ENV", "staging" ]
  ; secrets = []
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
  ; cpu = cpu "200m"
  ; memory = memory "256Mi"
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

(* 2b: a unit that consumes the target's database reads `POSTGRES_URL` from that target's
   DML class Secret, whatever the database's ownership. *)
let db_consumer_spec =
  { svc_spec with
    database =
      Sol_cli_resource_binding.Postgres_use
        { target = "prod-aws-us-east-1"; trust = Connection_trust }
  }
;;

let db_consumer_dml_creds =
  Sol_cli_database_setup_render.dml_creds_name "prod-aws-us-east-1"
;;

let worker_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "comms"
  ; source_name = "notify_worker"
  ; k8s_name = k8s_name "notify-worker"
  ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
  ; primitive = Sol_cli_deployment_plan.Worker
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; source_dir = "app/comms/notify_worker"
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
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
  ; image = "sol-registry:5000/myapp/invoice-fn:abc123"
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

let test_volume : Sol_cli_toml.volume =
  { name = "data"
  ; mount_path = "/var/lib/data"
  ; size = "10Gi"
  ; access_mode = Sol_cli_toml.ReadWriteOnce
  }
;;

let with_volumes volumes (spec : Sol_cli_deployment_plan.service_spec) =
  { spec with volumes }
;;

let test_svc_volumes () =
  let _, workload = render_spec_ok (with_volumes [ test_volume ] svc_spec) in
  assert_contains "svc PVC" workload "kind: PersistentVolumeClaim";
  assert_contains "svc PVC name" workload "name: charge-svc-data";
  assert_contains "svc mountPath" workload "mountPath: /var/lib/data";
  assert_contains "svc claimName" workload "claimName: charge-svc-data";
  assert_contains "svc storage" workload "storage: 10Gi"
;;

let test_worker_volumes () =
  let _, workload = render_spec_ok (with_volumes [ test_volume ] worker_spec) in
  assert_contains "worker PVC name" workload "name: notify-worker-data";
  assert_contains "worker mountPath" workload "mountPath: /var/lib/data";
  assert_contains "worker claimName" workload "claimName: notify-worker-data"
;;

let test_svc_namespace () =
  let ns_yaml, _workload = render_spec_ok svc_spec in
  assert_contains "svc ns_yaml" ns_yaml "name: myapp-payments"
;;

let test_svc_deployment_name () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc deployment name" workload "name: charge-svc"
;;

let test_svc_image () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc image" workload "sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_svc_has_service_resource () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc Service resource" workload "kind: Service\n"
;;

let test_svc_has_ingress () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains "svc Ingress resource" workload "kind: Ingress";
  assert_contains
    "ingress pins the nginx IngressClass"
    ingress_block
    "ingressClassName: nginx"
;;

let test_svc_networkpolicy_allows_monitoring_ingress () =
  let _ns, workload = render_spec_ok svc_spec in
  let netpol_block = extract_kind_block workload "kind: NetworkPolicy" in
  let ingress_block =
    match Str.bounded_split_delim (Str.regexp_string "\n  egress:") netpol_block 2 with
    | ingress_part :: _ -> ingress_part
    | [] -> netpol_block
  in
  assert_contains
    "svc NetworkPolicy ingress allows monitoring namespace"
    ingress_block
    "kubernetes.io/metadata.name: monitoring"
;;

let test_svc_calls_peer_env_and_network_policy () =
  let checkout =
    { Sol_cli_deployment_plan.env_var = "CHECKOUT_SVC_URL"
    ; unit_id = "checkout/checkout-svc"
    ; url = "http://checkout-svc.myapp-checkout.svc.cluster.local"
    ; target_domain = "checkout"
    ; target_name = k8s_name "checkout-svc"
    ; target_namespace = namespace ~workspace:"myapp" ~domain:"checkout"
    }
  in
  let payments =
    { Sol_cli_deployment_plan.env_var = "CHARGE_SVC_URL"
    ; unit_id = "payments/charge-svc"
    ; url = "http://charge-svc.myapp-payments.svc.cluster.local"
    ; target_domain = "payments"
    ; target_name = k8s_name "charge-svc"
    ; target_namespace = namespace ~workspace:"myapp" ~domain:"payments"
    }
  in
  let caller =
    { svc_spec with calls = [ checkout ]; config = [ checkout.env_var, checkout.url ] }
  in
  let callee =
    { svc_spec with
      domain = "checkout"
    ; source_name = "checkout_svc"
    ; k8s_name = k8s_name "checkout-svc"
    ; namespace = namespace ~workspace:"myapp" ~domain:"checkout"
    ; called_by = [ payments ]
    }
  in
  let _ns, caller_yaml = render_spec_ok caller in
  let caller_cm = extract_kind_block caller_yaml "kind: ConfigMap" in
  let caller_netpol = extract_kind_block caller_yaml "kind: NetworkPolicy" in
  assert_contains
    "peer url env"
    caller_cm
    {|CHECKOUT_SVC_URL: "http://checkout-svc.myapp-checkout.svc.cluster.local"|};
  assert_contains
    "the caller config names the projected token file"
    caller_cm
    {|CHECKOUT_SVC_TOKEN_FILE: "/var/run/sol/identity/checkout-svc/token"|};
  assert_contains
    "the caller names its own unit as the token audience it is issued for"
    caller_cm
    {|SOL_UNIT: "payments/charge-svc"|};
  assert_absent
    "a caller with no declared callers has no called_by"
    caller_cm
    "SOL_CALLED_BY";
  let caller_deployment = extract_kind_block caller_yaml "kind: Deployment" in
  assert_contains
    "the caller mounts a projected identity volume"
    caller_deployment
    "name: sol-identity-checkout-svc";
  assert_contains
    "the projected token's audience is the callee's canonical unit"
    caller_deployment
    "checkout/checkout-svc";
  assert_contains "the projected token expires in an hour" caller_deployment "3600";
  assert_contains
    "the projected token is mounted at the stable path"
    caller_deployment
    "/var/run/sol/identity/checkout-svc";
  assert_contains "the projected token is read-only" caller_deployment "readOnly: true";
  assert_contains "the volume is a projection" caller_deployment "projected:";
  assert_contains
    "the projection carries a service account token"
    caller_deployment
    "serviceAccountToken:";
  assert_contains
    "the token file is the framework's stable name"
    caller_deployment
    "path: token";
  assert_contains "egress peer namespace" caller_netpol "myapp-checkout";
  assert_contains "egress peer app" caller_netpol "app: checkout-svc";
  let egress_block =
    match Str.bounded_split_delim (Str.regexp_string "\n  egress:") caller_netpol 2 with
    | _ :: rest -> String.concat "\n  egress:" rest
    | [] -> caller_netpol
  in
  assert_absent "caller egress is not port-pinned" egress_block "port: 8080";
  let _ns, callee_yaml = render_spec_ok callee in
  assert_absent
    "a unit that declares no calls receives no projected identity"
    callee_yaml
    "sol-identity-";
  let callee_cm = extract_kind_block callee_yaml "kind: ConfigMap" in
  assert_contains
    "the callee names its own unit"
    callee_cm
    {|SOL_UNIT: "checkout/checkout-svc"|};
  assert_contains
    "the callee carries its callers as unit=serviceaccount"
    callee_cm
    {|SOL_CALLED_BY: "payments/charge-svc=myapp-payments:charge-svc"|};
  let callee_netpol = extract_kind_block callee_yaml "kind: NetworkPolicy" in
  assert_contains "ingress caller namespace" callee_netpol "myapp-payments";
  assert_contains "ingress caller app" callee_netpol "app: charge-svc";
  assert_contains "ingress uses the container port" callee_netpol "port: 8080"
;;

let fn_call : Sol_cli_deployment_plan.service_call =
  { env_var = "LEDGER_SVC_URL"
  ; unit_id = "payments/ledger-svc"
  ; url = "http://ledger-svc.myapp-payments.svc.cluster.local"
  ; target_domain = "payments"
  ; target_name = k8s_name "ledger-svc"
  ; target_namespace = namespace ~workspace:"myapp" ~domain:"payments"
  }
;;

let test_fn_calls_render_a_projected_identity () =
  let fn = { fn_spec with calls = [ fn_call ] } in
  let _ns, yaml = render_spec_ok fn in
  let cronjob = extract_kind_block yaml "kind: CronJob" in
  assert_contains "fn projected identity volume" cronjob "name: sol-identity-ledger-svc";
  assert_contains "fn projected audience" cronjob "payments/ledger-svc";
  assert_contains "fn projected expiry" cronjob "3600";
  assert_contains "fn projected mount" cronjob "/var/run/sol/identity/ledger-svc";
  let cm = extract_kind_block yaml "kind: ConfigMap" in
  assert_contains
    "fn token file env"
    cm
    {|LEDGER_SVC_TOKEN_FILE: "/var/run/sol/identity/ledger-svc/token"|}
;;

let test_svc_has_ports () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc containerPort" workload "containerPort: 8080"
;;

let test_svc_replicas () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc replicas=2" workload "replicas: 2"
;;

let test_svc_default_resources () =
  let default_spec =
    { svc_spec with replicas = 1; cpu = cpu "100m"; memory = memory "128Mi" }
  in
  let _ns, workload = render_spec_ok default_spec in
  assert_contains "svc default replicas=1" workload "replicas: 1";
  assert_contains "svc default cpu=100m" workload "cpu: 100m";
  assert_contains "svc default memory=128Mi" workload "memory: 128Mi"
;;

let test_svc_extra_config () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc extra configmap key" workload {|APP_ENV: "staging"|}
;;

let test_svc_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  assert_contains "svc env label" workload {|env: "prod"|}
;;

let test_svc_env_label_absent_by_default () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "svc env label" workload {|env: "|}
;;

let test_svc_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc SOL_ENV config" cm_block {|SOL_ENV: "prod"|}
;;

let test_svc_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "svc SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_svc_sol_env_configmap_target_overrides_config () =
  let spec = { svc_spec with config = [ "SOL_ENV", "user-value" ] } in
  let _ns, workload = render_spec_ok ~env:"prod" spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc SOL_ENV target value" cm_block {|SOL_ENV: "prod"|};
  assert_absent "svc SOL_ENV user value" cm_block "user-value"
;;

let test_svc_identity_configmap_carries_the_taxonomy () =
  let _ns, workload = render_spec_ok ~env:"prod" svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  [ "SOL_WORKSPACE: \"myapp\""
  ; "SOL_ENV: \"prod\""
  ; "SOL_DOMAIN: \"payments\""
  ; "SOL_SERVICE: \"charge-svc\""
  ; "SOL_PRIMITIVE: \"svc\""
  ; Printf.sprintf "SOL_RELEASE: \"%s\"" (Sol_cli_release_id.to_string release_id_of_test)
  ]
  |> List.iter (fun entry -> assert_contains "svc identity config" cm_block entry)
;;

let test_svc_identity_cannot_be_shadowed_by_declared_config () =
  let spec =
    { svc_spec with config = [ "SOL_SERVICE", "spoofed"; "APP_ENV", "staging" ] }
  in
  let _ns, workload = render_spec_ok ~env:"prod" spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc identity service" cm_block {|SOL_SERVICE: "charge-svc"|};
  assert_absent "svc identity spoof" cm_block "spoofed";
  assert_contains "ordinary config survives" cm_block {|APP_ENV: "staging"|}
;;

let test_worker_identity_configmap_carries_the_taxonomy () =
  let _ns, workload = render_spec_ok ~env:"staging" worker_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  [ "SOL_WORKSPACE: \"myapp\""
  ; "SOL_ENV: \"staging\""
  ; "SOL_DOMAIN: \"comms\""
  ; "SOL_SERVICE: \"notify-worker\""
  ; "SOL_PRIMITIVE: \"worker\""
  ; Printf.sprintf "SOL_RELEASE: \"%s\"" (Sol_cli_release_id.to_string release_id_of_test)
  ]
  |> List.iter (fun entry -> assert_contains "worker identity config" cm_block entry)
;;

let test_fn_identity_configmap_carries_the_taxonomy () =
  let _ns, workload = render_spec_ok ~env:"dev" fn_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  [ "SOL_WORKSPACE: \"myapp\""
  ; "SOL_ENV: \"dev\""
  ; "SOL_DOMAIN: \"billing\""
  ; Printf.sprintf
      "SOL_SERVICE: \"%s\""
      (Sol_cli_kubernetes_name.k8s_name_to_string fn_spec.k8s_name)
  ; "SOL_PRIMITIVE: \"fn\""
  ; Printf.sprintf "SOL_RELEASE: \"%s\"" (Sol_cli_release_id.to_string release_id_of_test)
  ]
  |> List.iter (fun entry -> assert_contains "fn identity config" cm_block entry)
;;

let test_identity_env_absent_from_local_render () =
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "svc identity workspace without env" cm_block {|SOL_WORKSPACE: "myapp"|};
  assert_absent "svc SOL_ENV absent locally" cm_block {|SOL_ENV: |}
;;

let test_worker_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"staging" worker_spec in
  assert_contains "worker env label" workload {|env: "staging"|}
;;

let test_fn_env_label_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"dev" fn_spec in
  assert_contains "fn env label" workload {|env: "dev"|}
;;

let test_postgres_url_not_in_configmap () =
  let _ns, workload = render_spec_ok svc_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "POSTGRES_URL absent from ConfigMap" cm_block "POSTGRES_URL"
;;

let test_live_render_emits_no_secret_values () =
  Unix.putenv "POSTGRES_URL" "postgresql://user:pass@db.example.com:5432/app";
  Unix.putenv "SOL_API_KEY" "dev-internal-key";
  let _ns, workload = render_spec_ok db_consumer_spec in
  Unix.putenv "POSTGRES_URL" "";
  Unix.putenv "SOL_API_KEY" "";
  assert_absent
    "ordinary deploy render contains no Secret object to apply"
    workload
    "kind: Secret";
  assert_absent "no stringData section" workload "stringData";
  assert_absent
    "no POSTGRES_URL value"
    workload
    "postgresql://user:pass@db.example.com:5432/app";
  assert_absent "no SOL_API_KEY value" workload "dev-internal-key";
  assert_contains
    "a database consumer references the target's DML class Secret"
    workload
    ("name: " ^ db_consumer_dml_creds);
  assert_contains "and reads POSTGRES_URL from it" workload "key: POSTGRES_URL"
;;

let test_placeholder_render_redacts_values () =
  Unix.putenv "POSTGRES_URL" "postgresql://user:pass@db.example.com:5432/app";
  let _ns, workload = render_spec_ok db_consumer_spec in
  Unix.putenv "POSTGRES_URL" "";
  assert_absent "GitOps emits no placeholder Secret" workload "kind: Secret";
  assert_contains
    "GitOps projects POSTGRES_URL from the class Secret"
    workload
    ("name: " ^ db_consumer_dml_creds);
  assert_contains "GitOps projects POSTGRES_URL" workload "key: POSTGRES_URL";
  assert_absent
    "a key no unit declares is not a workload default"
    workload
    "key: SOL_API_KEY";
  assert_absent
    "GitOps placeholder redacts the value"
    workload
    "postgresql://user:pass@db.example.com:5432/app"
;;

(* 1344b: SOL_API_KEY is a unit secret, not a workload default. A unit that serves or calls
   `Api_key` routes declares it; every other unit stops requiring a value it never reads. *)
let test_declared_api_key_is_projected () =
  let _ns, workload = render_spec_ok { svc_spec with secrets = [ "SOL_API_KEY", "" ] } in
  assert_contains
    "a unit that declares SOL_API_KEY gets the reference"
    workload
    "key: SOL_API_KEY"
;;

let test_svc_default_redpanda_admin_url () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "svc default redpanda admin url"
    workload
    {|REDPANDA_ADMIN_URL: "http://redpanda.redpanda.svc.cluster.local:9644"|}
;;

let test_svc_declares_kafka_security_protocol () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "svc declares the Kafka transport posture"
    workload
    {|KAFKA_SECURITY_PROTOCOL: "plaintext"|}
;;

let production_spec =
  { svc_spec with config = Sol_cli_manifest.production_kafka_config @ svc_spec.config }
;;

let test_production_svc_declares_sasl_ssl () =
  let _ns, workload = render_spec_ok production_spec in
  assert_contains
    "production posture is SASL_SSL"
    workload
    {|KAFKA_SECURITY_PROTOCOL: "sasl_ssl"|};
  assert_contains
    "production registry URL is HTTPS"
    workload
    {|SCHEMA_REGISTRY_URL: "https://redpanda.redpanda.svc.cluster.local:8081"|};
  assert_contains
    "production admin URL is HTTPS"
    workload
    {|REDPANDA_ADMIN_URL: "https://redpanda.redpanda.svc.cluster.local:9644"|};
  assert_contains
    "production CA path is the mounted file"
    workload
    {|KAFKA_SSL_CA_LOCATION: "/etc/sol/kafka/ca.crt"|};
  (* #1477: the OCaml client reads KAFKA_SSL_CA_LOCATION, but a Node process (TypeScript
     units and the contract Job) verifies HTTPS with Node's own trust store. The posture
     declares the same CA path to Node, so a durable TypeScript consumer's fetch trusts the
     platform's Schema Registry/Admin endpoints instead of failing with "fetch failed". *)
  assert_contains
    "production Node trust store includes the platform CA (#1477)"
    workload
    {|NODE_EXTRA_CA_CERTS: "/etc/sol/kafka/ca.crt"|};
  assert_absent
    "and the fix never disables certificate verification"
    workload
    "NODE_TLS_REJECT_UNAUTHORIZED";
  assert_contains
    "production SASL mechanism"
    workload
    {|KAFKA_SASL_MECHANISM: "SCRAM-SHA-256"|};
  assert_contains "production SASL user" workload {|KAFKA_SASL_USERNAME: "sol-workloads"|}
;;

let production_consumer =
  { production_spec with
    consumes_kafka = true
  ; secret_sources =
      [ ( "KAFKA_SASL_PASSWORD"
        , Sol_cli_secret_source.Target_kafka { secret = "prod-aws-us-east-1-kafka-creds" }
        )
      ; ( "KAFKA_SSL_CA_CERT"
        , Sol_cli_secret_source.Target_kafka { secret = "prod-aws-us-east-1-kafka-creds" }
        )
      ]
  }
;;

let test_consumer_reads_the_delivered_kafka_secret () =
  let _ns, workload = render_spec_ok production_consumer in
  assert_contains
    "the SASL password is read from the target's delivered Secret"
    workload
    "name: prod-aws-us-east-1-kafka-creds";
  assert_contains
    "the SASL password key is referenced"
    workload
    "key: KAFKA_SASL_PASSWORD";
  assert_contains
    "the CA key is mounted from the delivered Secret"
    workload
    "key: KAFKA_SSL_CA_CERT";
  assert_contains "the CA is mounted at the expected file" workload "path: ca.crt"
;;

let test_non_consumer_has_no_kafka_secret () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "no SASL password" workload "KAFKA_SASL_PASSWORD";
  assert_absent "no CA key" workload "KAFKA_SSL_CA_CERT";
  assert_absent "no delivered Kafka Secret" workload "-kafka-creds"
;;

let test_production_svc_mounts_the_ca () =
  let _ns, workload = render_spec_ok production_spec in
  assert_contains "CA volume name" workload "name: kafka-ca";
  assert_contains
    "CA comes from the workload secret"
    workload
    "secretName: charge-svc-secrets";
  assert_contains "CA secret key" workload "key: KAFKA_SSL_CA_CERT";
  assert_contains "CA mount path" workload "mountPath: /etc/sol/kafka";
  assert_contains "SASL password secret ref" workload "key: KAFKA_SASL_PASSWORD"
;;

let test_local_svc_has_no_kafka_ca_mount () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "no CA mount locally" workload "kafka-ca";
  assert_absent "no CA path locally" workload "KAFKA_SSL_CA_LOCATION";
  assert_absent "no Node CA trust locally" workload "NODE_EXTRA_CA_CERTS"
;;

let test_production_placeholder_secret_requires_kafka_keys () =
  let _ns, workload = render_spec_ok production_spec in
  assert_absent "no placeholder Secret" workload "kind: Secret";
  assert_contains "SASL password is projected" workload "key: KAFKA_SASL_PASSWORD";
  assert_contains "CA key is projected" workload "key: KAFKA_SSL_CA_CERT"
;;

(* The CA env var and the CA volume must be projected from the same Secret object:
   [secret_name_for_key] is the one routing decision both now use. *)
let index_of_needle haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec go i =
    if i + needle_length > haystack_length
    then None
    else if String.equal (String.sub haystack i needle_length) needle
    then Some i
    else go (i + 1)
  in
  go 0
;;

let last_index_of_needle haystack needle =
  let rec go last i =
    match index_of_needle (String.sub haystack i (String.length haystack - i)) needle with
    | None -> last
    | Some at -> go (Some (i + at)) (i + at + 1)
  in
  go None 0
;;

let line_value_after haystack start =
  let n = String.length haystack in
  let rec stop i = if i >= n || haystack.[i] = '\n' then i else stop (i + 1) in
  String.trim (String.sub haystack start (stop start - start))
;;

(* The CA volume is `- name: kafka-ca` then `secret: { secretName: ..., items: ... }`. *)
let ca_volume_secret_name workload =
  match index_of_needle workload "name: kafka-ca" with
  | None -> None
  | Some at ->
    (match
       index_of_needle
         (String.sub workload at (String.length workload - at))
         "secretName:"
     with
     | None -> None
     | Some relative ->
       Some (line_value_after workload (at + relative + String.length "secretName:")))
;;

(* The CA env entry is the last `key: KAFKA_SSL_CA_CERT`, inside its secretKeyRef. *)
let ca_env_secret_name workload =
  match last_index_of_needle workload "key: KAFKA_SSL_CA_CERT" with
  | None -> None
  | Some at ->
    (match last_index_of_needle (String.sub workload 0 at) "name:" with
     | None -> None
     | Some name_at -> Some (line_value_after workload (name_at + String.length "name:")))
;;

let assert_ca_routes workload ~expected =
  (match ca_volume_secret_name workload with
   | Some name -> Windtrap.equal Windtrap.string ~msg:"CA volume secretName" expected name
   | None -> Windtrap.fail "no CA volume secretName in the rendered workload");
  match ca_env_secret_name workload, ca_volume_secret_name workload with
  | Some env, Some volume ->
    Windtrap.equal
      Windtrap.string
      ~msg:"the CA env ref and the CA volume name the same Secret"
      volume
      env
  | _ -> Windtrap.fail "expected both a CA env ref and a CA volume"
;;

let external_ca_spec =
  { production_spec with
    secret_sources =
      [ ( "KAFKA_SSL_CA_CERT"
        , Sol_cli_manifest.External { store = "payments-store"; key = "payments/ca" } )
      ]
  }
;;

let production_fn_spec =
  { fn_spec with config = Sol_cli_manifest.production_kafka_config @ fn_spec.config }
;;

let test_external_ca_routes_to_the_external_secret () =
  let _ns, workload = render_spec_ok external_ca_spec in
  assert_ca_routes workload ~expected:"charge-svc-external-secrets"
;;

let test_sol_managed_ca_routes_to_the_unit_secret () =
  let _ns, workload = render_spec_ok production_spec in
  assert_ca_routes workload ~expected:"charge-svc-secrets"
;;

let test_external_ca_routes_in_a_cronjob () =
  let cronjob =
    { production_fn_spec with
      secret_sources =
        [ ( "KAFKA_SSL_CA_CERT"
          , Sol_cli_manifest.External { store = "payments-store"; key = "payments/ca" } )
        ]
    }
  in
  let _ns, workload = render_spec_ok cronjob in
  assert_ca_routes workload ~expected:"invoice-fn-external-secrets"
;;

let%test "kafka CA: external CA volume and env use the external secret" =
  test_external_ca_routes_to_the_external_secret ()
;;

let%test "kafka CA: Sol-managed CA volume and env use the unit secret" =
  test_sol_managed_ca_routes_to_the_unit_secret ()
;;

let%test "kafka CA: external CA volume and env use the external secret (CronJob)" =
  test_external_ca_routes_in_a_cronjob ()
;;

let test_svc_secret_refs_without_values () =
  let spec =
    { svc_spec with
      secrets = [ "DATABASE_URL", "postgres://secret"; "API_TOKEN", "token-value" ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "database secret ref" workload "key: DATABASE_URL";
  assert_contains "api token secret ref" workload "key: API_TOKEN";
  assert_absent "database value absent" workload "postgres://secret";
  assert_absent "token value absent" workload "token-value";
  assert_contains "shared secret name" workload "name: charge-svc-secrets"
;;

let test_svc_namespace_in_workload () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "svc workload namespace" workload "namespace: myapp-payments"
;;

let test_user_secret_key_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret is rendered" workload "kind: Secret";
  assert_contains "STRIPE_KEY uses Sol-owned Secret" workload "name: charge-svc-secrets";
  assert_contains "STRIPE_KEY reference is present" workload "key: STRIPE_KEY"
;;

let test_user_secret_key_ref_in_deployment () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "STRIPE_KEY secretKeyRef" workload "key: STRIPE_KEY"
;;

let test_multiple_user_secret_keys_in_secret_resource () =
  let spec = { svc_spec with secrets = [ "STRIPE_KEY", ""; "SENDGRID_API_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret is rendered" workload "kind: Secret";
  assert_contains "STRIPE_KEY ref" workload "key: STRIPE_KEY";
  assert_contains "SENDGRID_API_KEY ref" workload "key: SENDGRID_API_KEY"
;;

(* 2b: `POSTGRES_URL` is no longer a workload default. It reaches a database consumer from
   the target's DML class Secret, while a declared application secret stays unit-scoped. *)
let test_database_url_routes_to_the_class_secret () =
  let spec = { db_consumer_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret is rendered" workload "kind: Secret";
  assert_contains "POSTGRES_URL ref" workload "key: POSTGRES_URL";
  assert_contains
    "POSTGRES_URL routes to the class Secret"
    workload
    ("name: " ^ db_consumer_dml_creds);
  assert_contains "STRIPE_KEY ref" workload "key: STRIPE_KEY";
  assert_contains
    "a declared unit secret stays unit-scoped"
    workload
    "name: charge-svc-secrets"
;;

let test_gitops_redacts_all_secret_values () =
  let spec =
    { db_consumer_spec with secrets = [ "STRIPE_KEY", "sk_live_should_not_render" ] }
  in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no placeholder Secret" workload "kind: Secret";
  assert_contains "POSTGRES_URL referenced" workload "key: POSTGRES_URL";
  assert_contains "user STRIPE_KEY referenced" workload "key: STRIPE_KEY";
  assert_absent
    "default postgres value redacted"
    workload
    "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev";
  assert_absent "user secret value redacted" workload "sk_live_should_not_render"
;;

let test_worker_user_secret_key_in_secret_resource () =
  let spec = { worker_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret is rendered" workload "kind: Secret";
  assert_contains "worker STRIPE_KEY reference" workload "key: STRIPE_KEY"
;;

let test_fn_user_secret_key_in_secret_resource () =
  let spec = { fn_spec with secrets = [ "STRIPE_KEY", "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret is rendered" workload "kind: Secret";
  assert_contains "fn STRIPE_KEY reference" workload "key: STRIPE_KEY"
;;

let test_svc_image_override () =
  let push_image = "localhost:5000/myapp/charge-svc:abc123" in
  let _ns, workload = render_spec_ok ~image:push_image svc_spec in
  assert_contains
    "svc push image in dry-run"
    workload
    "localhost:5000/myapp/charge-svc:abc123";
  assert_absent
    "svc cluster image absent"
    workload
    "sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_worker_namespace () =
  let ns_yaml, _ = render_spec_ok worker_spec in
  assert_contains "worker ns" ns_yaml "name: myapp-comms"
;;

let test_worker_image () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker image" workload "sol-registry:5000/myapp/notify-worker:abc123"
;;

let test_worker_no_service_resource () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_absent "worker no Service resource" workload "kind: Service\n";
  assert_absent "worker no Ingress" workload "kind: Ingress"
;;

let test_worker_metrics_port () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker metrics containerPort" workload "containerPort: 9090";
  assert_contains "worker prometheus scrape" workload "prometheus.io/scrape: \"true\"";
  assert_contains "worker prometheus port" workload "prometheus.io/port: \"9090\""
;;

let test_worker_has_deployment () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_contains "worker Deployment" workload "kind: Deployment"
;;

let test_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok worker_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "automount disabled" rendered "automountServiceAccountToken: false";
  assert_absent
    "pod does not re-enable automount"
    workload
    "automountServiceAccountToken: true"
;;

let test_svc_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok svc_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "svc ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "svc automount disabled" rendered "automountServiceAccountToken: false";
  assert_absent
    "svc pod does not re-enable automount"
    workload
    "automountServiceAccountToken: true"
;;

let test_fn_service_account_disables_token_automount () =
  let ns_yaml, workload = render_spec_ok fn_spec in
  let rendered = ns_yaml ^ workload in
  assert_contains "fn ServiceAccount rendered" rendered "kind: ServiceAccount";
  assert_contains "fn automount disabled" rendered "automountServiceAccountToken: false"
;;

let test_termination_grace_is_explicit () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains
    "explicit termination grace (drain has room before SIGKILL)"
    workload
    "terminationGracePeriodSeconds: 45"
;;

let test_worker_consumer_probes () =
  let _ns, workload = render_spec_ok { worker_spec with consumes_kafka = true } in
  assert_contains "consumer readiness endpoint" workload "path: /readyz";
  assert_contains "consumer liveness endpoint" workload "path: /livez";
  assert_contains "consumer startup probe" workload "startupProbe:"
;;

let test_non_consumer_worker_has_no_liveness () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_absent
    "a worker with no consumer state claims no liveness"
    workload
    "livenessProbe:"
;;

let test_node_failure_tolerant_renders_pdb_and_spread () =
  let spec =
    { svc_spec with
      availability = Sol_cli_availability.Node_failure_tolerant
    ; replicas = 2
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "PodDisruptionBudget rendered" workload "kind: PodDisruptionBudget";
  assert_contains "budget keeps one replica available" workload "minAvailable: 1";
  assert_contains "topology spread constraint" workload "topologySpreadConstraints:";
  assert_contains
    "spread keyed on the node"
    workload
    "topologyKey: kubernetes.io/hostname"
;;

let test_single_has_no_pdb () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent
    "a single workload claims no disruption budget"
    workload
    "PodDisruptionBudget"
;;

let test_fn_namespace () =
  let ns_yaml, _ = render_spec_ok fn_spec in
  assert_contains "fn ns" ns_yaml "name: myapp-billing"
;;

let test_fn_image () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn image" workload "sol-registry:5000/myapp/invoice-fn:abc123"
;;

let test_fn_cronjob () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn CronJob kind" workload "kind: CronJob"
;;

let test_fn_schedule () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_contains "fn schedule" workload {|schedule: "0 9 * * 1"|}
;;

let test_fn_no_deployment () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_absent "fn no Deployment" workload "kind: Deployment"
;;

let test_fn_cronjob_pod_template_has_app_label () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn cronjob pod template app label" cronjob_block "app: invoice-fn"
;;

let test_fn_cpu_memory_configurable () =
  let spec = { fn_spec with cpu = cpu "2"; memory = memory "4Gi" } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn configured cpu request" cronjob_block {|cpu: "2"|};
  assert_contains "fn configured memory request" cronjob_block "memory: 4Gi"
;;

let test_fn_cpu_memory_request_equals_limit () =
  let spec = { fn_spec with cpu = cpu "500m"; memory = memory "1Gi" } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  let count_occurrences needle haystack =
    let n = String.length needle
    and s = String.length haystack in
    let count = ref 0 in
    for i = 0 to s - n do
      if String.sub haystack i n = needle then incr count
    done;
    !count
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"cpu: 500m appears twice (requests and limits)"
    2
    (count_occurrences "cpu: 500m" cronjob_block);
  Windtrap.equal
    Windtrap.int
    ~msg:"memory: 1Gi appears twice (requests and limits)"
    2
    (count_occurrences "memory: 1Gi" cronjob_block)
;;

let test_fn_scheduled_concurrency_configurable () =
  let spec = { fn_spec with scheduled_concurrency = Sol_cli_toml.Forbid } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn concurrencyPolicy: Forbid" cronjob_block "concurrencyPolicy: Forbid"
;;

let test_fn_scheduled_concurrency_default_is_allow () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains
    "fn default concurrencyPolicy: Allow"
    cronjob_block
    "concurrencyPolicy: Allow"
;;

let test_fn_backoff_limit_configurable () =
  let spec = { fn_spec with backoff_limit = 7 } in
  let _ns, workload = render_spec_ok spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn backoffLimit: 7" cronjob_block "backoffLimit: 7"
;;

let test_fn_backoff_limit_default_is_three () =
  let _ns, workload = render_spec_ok fn_spec in
  let cronjob_block = extract_kind_block workload "kind: CronJob" in
  assert_contains "fn default backoffLimit: 3" cronjob_block "backoffLimit: 3"
;;

let test_rollout_recreate () =
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.Recreate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "recreate strategy" workload "type: Recreate";
  assert_absent "no RollingUpdate" workload "type: RollingUpdate"
;;

let test_rollout_rolling_update () =
  let spec = { svc_spec with rollout_strategy = Some Sol_cli_toml.RollingUpdate } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rolling strategy" workload "type: RollingUpdate";
  assert_absent "no Recreate" workload "type: Recreate"
;;

let test_rollout_default_is_rolling_update () =
  let spec = { svc_spec with rollout_strategy = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "default is RollingUpdate" workload "type: RollingUpdate"
;;

let test_progressive_default_is_deployment () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_contains "default Deployment" workload "kind: Deployment";
  assert_absent "default no Rollout" workload "kind: Rollout"
;;

let test_progressive_canary_rollout () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps =
                 [ Sol_cli_toml.Weight 10
                 ; Sol_cli_toml.Weight 40
                 ; Sol_cli_toml.Weight 100
                 ]
             })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rollout api" workload "apiVersion: argoproj.io/v1alpha1";
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "canary block" workload "canary:";
  assert_contains "weight 10" workload "setWeight: 10";
  assert_contains "weight 40" workload "setWeight: 40";
  assert_contains "weight 100" workload "setWeight: 100";
  assert_contains "svc port preserved" workload "containerPort: 8080";
  assert_contains "svc probes preserved" workload "readinessProbe:";
  assert_absent "no Deployment" workload "kind: Deployment"
;;

let test_progressive_canary_worker_no_service () =
  let spec =
    { worker_spec with
      progressive_delivery =
        Some (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "worker rollout kind" workload "kind: Rollout";
  assert_contains "worker canary step" workload "setWeight: 50";
  assert_absent "worker no ingress" workload "kind: Ingress";
  assert_absent "worker no service port" workload "port: 80";
  assert_absent "worker no port" workload "containerPort: 8080"
;;

let test_progressive_blue_green_rollout () =
  let spec = { svc_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "rollout kind" workload "kind: Rollout";
  assert_contains "blueGreen block" workload "blueGreen:";
  assert_contains "active service strategy" workload "activeService: charge-svc-active";
  assert_contains "preview service strategy" workload "previewService: charge-svc-preview";
  assert_contains "manual promotion" workload "autoPromotionEnabled: false";
  assert_contains "active service manifest" workload "name: charge-svc-active";
  assert_contains "preview service manifest" workload "name: charge-svc-preview";
  assert_contains "ingress points at active" workload "name: charge-svc-active";
  assert_absent "no Deployment" workload "kind: Deployment"
;;

let test_rollout_canary_secrets_use_sol_secrets () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps = [ Sol_cli_toml.Weight 50; Sol_cli_toml.Weight 100 ] })
    ; secrets = [ "STRIPE_KEY", ""; "DATABASE_URL", "" ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains
    "rollout uses charge-svc-secrets ref"
    rollout_block
    "name: charge-svc-secrets";
  assert_contains "rollout has STRIPE_KEY ref" rollout_block "key: STRIPE_KEY";
  assert_contains "rollout has DATABASE_URL ref" rollout_block "key: DATABASE_URL";
  assert_absent "no global sol-secrets name" rollout_block "name: sol-secrets"
;;

let test_rollout_blue_green_secrets_use_sol_secrets () =
  let spec =
    { svc_spec with
      progressive_delivery = Some Sol_cli_toml.Blue_green
    ; secrets = [ "API_TOKEN", "" ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  let rollout_block = extract_kind_block workload "kind: Rollout" in
  assert_contains
    "blue-green rollout uses charge-svc-secrets"
    rollout_block
    "name: charge-svc-secrets";
  assert_contains "blue-green rollout has API_TOKEN ref" rollout_block "key: API_TOKEN";
  assert_absent "no global sol-secrets name" rollout_block "name: sol-secrets"
;;

let test_ingress_host_override () =
  let spec =
    { svc_spec with
      ingress_host = Some (hostname "payments.example.com")
    ; cluster_issuer = "letsencrypt-staging"
    }
  in
  let _ns, workload = render_spec_ok spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "ingress host rule"
    ingress_block
    "  - host: payments.example.com\n    http:";
  assert_contains
    "cert-manager issuer"
    ingress_block
    "cert-manager.io/cluster-issuer: letsencrypt-staging";
  assert_contains
    "tls host"
    ingress_block
    {|tls:
  - hosts:
    - payments.example.com|};
  assert_contains "tls secret" ingress_block "secretName: charge-svc-tls";
  assert_contains
    "host ingress still pins the nginx IngressClass"
    ingress_block
    "ingressClassName: nginx"
;;

let test_undeclared_ingress_host_gets_dev_host () =
  let _ns, workload = render_spec_ok svc_spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "dev host rule"
    ingress_block
    "  - host: charge-svc.myapp-payments.localhost";
  assert_absent "no issuer for dev host" ingress_block "cert-manager.io/cluster-issuer";
  assert_absent "no ssl redirect for dev host" ingress_block "ssl-redirect";
  assert_absent "no tls for dev host" ingress_block "tls:"
;;

let test_blue_green_ingress_tls_secret_matches_plan () =
  let spec =
    { svc_spec with
      ingress_host = Some (hostname "payments.example.com")
    ; progressive_delivery = Some Sol_cli_toml.Blue_green
    }
  in
  let _ns, workload = render_spec_ok spec in
  let ingress_block = extract_kind_block workload "kind: Ingress" in
  assert_contains
    "ingress points at active service"
    ingress_block
    "name: charge-svc-active";
  assert_contains "tls secret matches plan" ingress_block "secretName: charge-svc-tls"
;;

let test_ingress_path_override () =
  let spec = { svc_spec with ingress_path = Some (ingress_path "/api/v2") } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "ingress path" workload "path: /api/v2"
;;

let test_ingress_default_path () =
  let spec = { svc_spec with ingress_path = None } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "default path" workload "path: /"
;;

let test_extra_labels_appear_in_pod_template () =
  let spec = { svc_spec with extra_labels = [ "team", "platform"; "tier", "backend" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_contains "extra label team" workload {|team: "platform"|};
  assert_contains "extra label tier" workload {|tier: "backend"|}
;;

let test_extra_labels_empty_by_default () =
  let spec = { svc_spec with extra_labels = [] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no team label" workload {|team:|}
;;

let test_toml_invalid_rollout_strategy () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid rollout_strategy raises" true raised
;;

let test_toml_reserved_label_key () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.labels]
extra_labels = { "sol.dev/owner" = "platform" }
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "reserved label key raises" true raised
;;

let test_toml_valid_rollout_recreate () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Recreate\"\n";
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "rollout_strategy is Recreate"
    true
    (toml.rollout_strategy = Some Sol_cli_toml.Recreate)
;;

let test_toml_valid_ingress_overrides () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_host = "api.example.com"
ingress_path = "/v1"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "ingress_host parsed"
    true
    (Option.map Sol_cli_toml.hostname_to_string toml.ingress_host = Some "api.example.com");
  check_bool
    "ingress_path parsed"
    true
    (Option.map Sol_cli_toml.ingress_path_to_string toml.ingress_path = Some "/v1")
;;

let test_toml_valid_service_calls () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[service]
calls = ["checkout/checkout_svc"]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"calls parsed"
    [ "checkout/checkout_svc" ]
    toml.calls
;;

let test_toml_invalid_cpu_quantity () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
cpu = "250Mi"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid cpu quantity" message "cpu quantity"
  | Ok _ -> Windtrap.fail "expected invalid CPU quantity to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_memory_quantity () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
memory = "many"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid memory quantity" message "memory quantity"
  | Ok _ -> Windtrap.fail "expected invalid memory quantity to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_ingress_host () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_host = "Bad_Host.example.com"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid ingress host" message "ingress_host"
  | Ok _ -> Windtrap.fail "expected invalid ingress_host to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_invalid_ingress_path () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.deploy]
ingress_path = "api/v1"
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "invalid ingress path" message "ingress_path"
  | Ok _ -> Windtrap.fail "expected invalid ingress_path to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_secret_keys () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = ["DATABASE_URL", "API_TOKEN"]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool "secret keys parsed" true (toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
;;

let test_toml_build_secret_keys () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = ["DATABASE_URL"]
build_secrets = ["BUILD_REGISTRY_TOKEN", "OPAM_MIRROR_TOKEN"]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "build secret keys parsed"
    true
    (toml.build_secret_keys = [ "BUILD_REGISTRY_TOKEN"; "OPAM_MIRROR_TOKEN" ]);
  check_bool "runtime keys stay separate" true (toml.secret_keys = [ "DATABASE_URL" ])
;;

let test_toml_secret_key_scope_conflict () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = ["SHARED_KEY"]
build_secrets = ["SHARED_KEY"]
|};
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    assert_contains "names the key" message "SHARED_KEY";
    assert_contains "explains the scoping" message "build_secrets"
  | Ok _ -> Windtrap.fail "expected a key declared in both secret sets to be rejected"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_valid_canary_rollout () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [10, 40, 100]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  match toml.progressive_delivery with
  | Some
      (Sol_cli_toml.Canary
         { steps =
             [ Sol_cli_toml.Weight 10; Sol_cli_toml.Weight 40; Sol_cli_toml.Weight 100 ]
         }) -> ()
  | _ -> Windtrap.fail "expected canary progressive_delivery from [infra.rollout]"
;;

let test_toml_valid_blue_green_rollout () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "blue-green"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "blue-green parsed"
    true
    (toml.progressive_delivery = Some Sol_cli_toml.Blue_green)
;;

let test_toml_invalid_progressive_strategy () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "rolling"
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid progressive strategy raises" true raised
;;

let test_toml_canary_requires_steps () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "canary without steps raises" true raised
;;

let test_toml_canary_rejects_bad_weight () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [10, 120]
|};
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "invalid canary weight raises" true raised
;;

let test_toml_rejects_malformed () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "replicas = \n";
  close_out oc;
  let raised = Result.is_error (Sol_cli_toml.load_result path) in
  Sys.remove path;
  check_bool "malformed TOML raises Failure" true raised
;;

let test_toml_load_result_validation_error () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.deploy]\nrollout_strategy = \"Blue/Green\"\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { path = _; message }) ->
    assert_contains "typed validation error" message "unsupported rollout_strategy"
  | Ok _ -> Windtrap.fail "expected typed validation error"
  | Error (Sol_cli_toml.Toml_syntax _) ->
    Windtrap.fail "expected validation error, got syntax error"
;;

let test_toml_load_result_syntax_error () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string oc "replicas = \n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Toml_syntax { path = _; message }) ->
    assert_contains "typed syntax error" message "sol.toml:"
  | Ok _ -> Windtrap.fail "expected typed syntax error"
  | Error (Sol_cli_toml.Validation _) ->
    Windtrap.fail "expected syntax error, got validation error"
;;

let test_toml_multiline_array_secrets () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.env]
secrets = [
  "DATABASE_URL",
  "API_TOKEN",
]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool
    "multi-line secrets array parsed"
    true
    (toml.secret_keys = [ "DATABASE_URL"; "API_TOKEN" ])
;;

let test_toml_dotted_section_headers () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.scale]
replicas = 3
cpu = "250m"
memory = "256Mi"
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  check_bool "replicas from dotted header" true (toml.replicas = Some 3);
  check_bool
    "cpu from dotted header"
    true
    (Option.map Sol_cli_toml.cpu_quantity_to_string toml.cpu = Some "250m");
  check_bool
    "memory from dotted header"
    true
    (Option.map Sol_cli_toml.memory_quantity_to_string toml.memory = Some "256Mi")
;;

let test_toml_canary_pause_steps () =
  let path = Filename.temp_file "sol-toml-test-" ".toml" in
  let oc = open_out path in
  output_string
    oc
    {|[infra.rollout]
strategy = "canary"
steps = [{weight = 20}, {pause = {}}, {weight = 60}, {pause = {duration = 60}}]
|};
  close_out oc;
  let toml = load_toml path in
  Sys.remove path;
  match toml.progressive_delivery with
  | Some
      (Sol_cli_toml.Canary
         { steps =
             [ Sol_cli_toml.Weight 20
             ; Sol_cli_toml.Pause None
             ; Sol_cli_toml.Weight 60
             ; Sol_cli_toml.Pause (Some 60)
             ]
         }) -> ()
  | _ -> Windtrap.fail "expected canary steps with pause from [infra.rollout]"
;;

let test_external_secret_doc_no_stringdata () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~secret_refs:[ "STRIPE_KEY", "aws-secrets-manager", "myapp/payments/stripe" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "kind ExternalSecret" doc "kind: ExternalSecret";
  assert_contains "remoteRef present" doc "remoteRef:";
  assert_contains "ESO apiVersion" doc "apiVersion: external-secrets.io/v1";
  assert_absent "no stringData" doc "stringData"
;;

let test_external_secret_doc_keys_present () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~secret_refs:
        [ "STRIPE_KEY", "aws-secrets-manager", "payments/stripe"
        ; "SENDGRID_API_KEY", "vault-prod", "payments/sendgrid"
        ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "STRIPE_KEY secretKey" doc "secretKey: STRIPE_KEY";
  assert_contains "SENDGRID_API_KEY secretKey" doc "secretKey: SENDGRID_API_KEY";
  assert_contains "per-key store override" doc "name: vault-prod"
;;

let test_external_secret_doc_target_name () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~secret_refs:[ "POSTGRES_URL", "my-store", "db/production" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains
    "target name is charge-svc-external-secrets"
    doc
    "name: charge-svc-external-secrets"
;;

let test_external_secret_doc_namespace_scoped_store () =
  let doc =
    Sol_cli_manifest.external_secret_doc
      ~secret_refs:[ "POSTGRES_URL", "my-store", "db/production" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
    |> render_doc
  in
  assert_contains "namespace-scoped store kind" doc "kind: SecretStore";
  assert_absent "not a ClusterSecretStore" doc "kind: ClusterSecretStore"
;;

let test_render_spec_eso_backend_no_k8s_secret () =
  let spec =
    { svc_spec with
      secrets = [ "STRIPE_KEY", "" ]
    ; secret_sources =
        [ "STRIPE_KEY", Sol_cli_manifest.External { store = "prod-store"; key = "stripe" }
        ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_contains "ExternalSecret present" workload "kind: ExternalSecret";
  assert_contains
    "ESO output name is isolated"
    workload
    "name: charge-svc-external-secrets";
  assert_absent "no plain Secret kind" workload "\nkind: Secret\n"
;;

let test_render_spec_eso_backend_all_keys () =
  let spec =
    { svc_spec with
      secrets = [ "STRIPE_KEY", "" ]
    ; secret_sources =
        [ "STRIPE_KEY", Sol_cli_manifest.External { store = "prod-store"; key = "stripe" }
        ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_absent
    "Sol-owned default is not copied to ESO"
    workload
    "secretKey: POSTGRES_URL";
  assert_contains "only external key is in ESO data" workload "secretKey: STRIPE_KEY";
  assert_contains "external key's store is explicit" workload "name: prod-store";
  assert_contains "external key's remote name is explicit" workload "key: stripe"
;;

let test_render_spec_eso_backend_no_stringdata () =
  let spec =
    { svc_spec with
      secrets = [ "STRIPE_KEY", "" ]
    ; secret_sources =
        [ "STRIPE_KEY", Sol_cli_manifest.External { store = "prod-store"; key = "stripe" }
        ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no stringData in ESO output" workload "stringData"
;;

let test_render_default_backend_emits_no_secret () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_absent "no Secret object in a direct deploy" workload "kind: Secret";
  assert_absent "no ExternalSecret either" workload "kind: ExternalSecret"
;;

let test_live_backend_render_never_reads_env () =
  let absent = "__SOL_TEST_ABSENT_KEY_XQ9Z2__" in
  Unix.putenv absent "";
  let spec = { svc_spec with secrets = [ absent, "" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent
    "live render emits no Secret regardless of the environment"
    workload
    "kind: Secret"
;;

let test_live_backend_no_user_secrets_always_succeeds () =
  let spec = { svc_spec with secrets = [] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent "no Secret with no declared keys" workload "kind: Secret"
;;

let assert_k8s_invariants label yaml =
  assert_contains (label ^ ": runAsNonRoot") yaml "runAsNonRoot: true";
  assert_contains
    (label ^ ": allowPrivilegeEscalation")
    yaml
    "allowPrivilegeEscalation: false";
  assert_contains (label ^ ": readOnlyRootFilesystem") yaml "readOnlyRootFilesystem: true"
;;

let test_svc_satisfies_invariants () =
  let _ns, workload = render_spec_ok svc_spec in
  assert_k8s_invariants "svc" workload
;;

let test_worker_satisfies_invariants () =
  let _ns, workload = render_spec_ok worker_spec in
  assert_k8s_invariants "worker" workload
;;

let test_fn_satisfies_invariants () =
  let _ns, workload = render_spec_ok fn_spec in
  assert_k8s_invariants "fn" workload
;;

let test_rollout_canary_satisfies_invariants () =
  let spec =
    { svc_spec with
      progressive_delivery =
        Some
          (Sol_cli_toml.Canary
             { steps = [ Sol_cli_toml.Weight 50; Sol_cli_toml.Weight 100 ] })
    }
  in
  let _ns, workload = render_spec_ok spec in
  assert_k8s_invariants "canary rollout" workload
;;

let test_rollout_blue_green_satisfies_invariants () =
  let spec = { svc_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  let _ns, workload = render_spec_ok spec in
  assert_k8s_invariants "blue-green rollout" workload
;;

let test_gitops_secret_redacted () =
  let spec = { svc_spec with secrets = [ "SECRET_KEY", "real-value-must-not-appear" ] } in
  let _ns, workload = render_spec_ok spec in
  assert_absent
    "no real secret value in gitops output"
    workload
    "real-value-must-not-appear"
;;

let test_shape_http_service_deployment_has_ports () =
  let doc = Sol_cli_manifest.deployment_doc ~workload:(workload ()) () |> render_doc in
  assert_contains "Http_service containerPort" doc "containerPort: 8080";
  assert_contains "Http_service readinessProbe" doc "readinessProbe:";
  assert_contains
    "Http_service has prometheus.io/scrape (OBS-011)"
    doc
    "prometheus.io/scrape: \"true\""
;;

let test_shape_background_worker_deployment_has_metrics_port () =
  let doc =
    Sol_cli_manifest.deployment_doc
      ~workload:
        (workload
           ~shape:Sol_cli_manifest.Background_worker
           ~domain:"comms"
           ~name:"notify-worker"
           ~primitive:"worker"
           ())
      ()
    |> render_doc
  in
  assert_contains "Background_worker metrics containerPort" doc "containerPort: 9090";
  assert_absent "Background_worker no readinessProbe" doc "readinessProbe:";
  assert_contains
    "Background_worker has prometheus.io/scrape"
    doc
    "prometheus.io/scrape: \"true\"";
  assert_contains "Background_worker scrape port" doc "prometheus.io/port: \"9090\""
;;

let test_shape_rollout_http_service_has_ports () =
  let doc =
    Sol_cli_manifest.rollout_doc
      ~workload:(workload ())
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ()
    |> render_doc
  in
  assert_contains "rollout Http_service containerPort" doc "containerPort: 8080";
  assert_contains "rollout Http_service readinessProbe" doc "readinessProbe:"
;;

let test_shape_rollout_background_worker_metrics_port () =
  let doc =
    Sol_cli_manifest.rollout_doc
      ~workload:
        (workload
           ~shape:Sol_cli_manifest.Background_worker
           ~domain:"comms"
           ~name:"notify-worker"
           ~primitive:"worker"
           ())
      ~pd:(Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
      ()
    |> render_doc
  in
  assert_contains
    "rollout Background_worker metrics containerPort"
    doc
    "containerPort: 9090";
  assert_contains
    "rollout Background_worker prometheus scrape"
    doc
    "prometheus.io/scrape: \"true\"";
  assert_contains
    "rollout Background_worker prometheus port"
    doc
    "prometheus.io/port: \"9090\"";
  assert_absent "rollout Background_worker no readinessProbe" doc "readinessProbe:"
;;

let test_taxonomy_labels_svc () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "payments"|};
  assert_contains "service label" workload {|service: "charge-svc"|};
  assert_contains "primitive label" workload {|primitive: "svc"|};
  assert_contains "release label" workload expected_release_label
;;

let test_taxonomy_labels_worker () =
  let _, workload = render_spec_ok worker_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "comms"|};
  assert_contains "service label" workload {|service: "notify-worker"|};
  assert_contains "primitive label" workload {|primitive: "worker"|};
  assert_contains "release label" workload expected_release_label
;;

let test_taxonomy_labels_fn () =
  let _, workload = render_spec_ok fn_spec in
  assert_contains "workspace label" workload {|workspace: "myapp"|};
  assert_contains "domain label" workload {|domain: "billing"|};
  assert_contains "service label" workload {|service: "invoice-fn"|};
  assert_contains "primitive label" workload {|primitive: "fn"|};
  assert_contains "release label" workload expected_release_label
;;

let assert_release_label_at_verifier_path label kind workload release_id =
  let _, jsonpath = Sol_cli_rollback.live_resource_and_jsonpath kind in
  let inner = String.sub jsonpath 2 (String.length jsonpath - 3) in
  let depth = List.length (String.split_on_char '.' inner) in
  let expected =
    String.make (2 * (depth - 1)) ' ' ^ {|release: "|} ^ release_id ^ {|"|}
  in
  let release_lines =
    String.split_on_char '\n' workload
    |> List.filter (fun line ->
      let t = String.trim line in
      String.length t >= 8 && String.equal (String.sub t 0 8) "release:")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:(label ^ ": one release label line")
    1
    (List.length release_lines);
  Windtrap.equal
    Windtrap.string
    ~msg:(label ^ ": release label sits at the verifier's jsonpath")
    expected
    (List.hd release_lines)
;;

let test_release_label_lives_at_the_verifier_jsonpath () =
  let release_id = Sol_cli_release_id.to_string release_id_of_test in
  let _, svc_workload = render_spec_ok svc_spec in
  assert_release_label_at_verifier_path
    "svc/deployment"
    Sol_cli_rollback.Live_deployment
    svc_workload
    release_id;
  let rollout_spec =
    { svc_spec with
      progressive_delivery =
        Some (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 50 ] })
    }
  in
  let _, rollout_workload = render_spec_ok rollout_spec in
  assert_release_label_at_verifier_path
    "svc/rollout"
    Sol_cli_rollback.Live_rollout
    rollout_workload
    release_id;
  let _, fn_workload = render_spec_ok fn_spec in
  assert_release_label_at_verifier_path
    "fn/cronjob"
    Sol_cli_rollback.Live_cronjob
    fn_workload
    release_id
;;

let test_taxonomy_labels_not_in_selector () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains
    "selector is still exactly app: <name>, nothing else"
    workload
    "matchLabels:\n      app: charge-svc\n  template:"
;;

let test_release_label_is_release_id () =
  let _, workload = render_spec_ok svc_spec in
  assert_contains "release label is the release id" workload expected_release_label
;;

let test_release_label_does_not_leak_image_tag () =
  let spec = { svc_spec with image = "sol-registry:5000/myapp/charge-svc:abc123" } in
  let _, workload = render_spec_ok spec in
  assert_absent "image tag is not the release label" workload {|release: "abc123"|};
  assert_contains
    "image tag still present as the container image"
    workload
    "image: sol-registry:5000/myapp/charge-svc:abc123"
;;

let test_release_label_is_the_supplied_identity () =
  let other =
    Sol_cli_release_id.of_content
      { workspace = "other"; environment = Some "prod"; workloads = []; contract = [] }
  in
  let _, workload = render_spec_ok ~release_id:other svc_spec in
  assert_contains
    "release label is the supplied id"
    workload
    (Printf.sprintf {|release: "%s"|} (Sol_cli_release_id.to_string other));
  assert_absent "not the default id" workload expected_release_label
;;

(* #1305: a whole-target deploy must not roll out the workloads it did not change. The
   Pod template's [release] label is each workload's own immutable identity, derived from
   that workload's effective spec, so changing one workload's image leaves every other
   workload's template byte-for-byte identical while the changed one moves. *)
let workload_identity spec =
  Sol_cli_deployment_plan.workload_release_id ~workspace:"myapp" ~environment:None spec
;;

let render_with_own_identity spec =
  let _, workload =
    render_spec_ok ~workspace:"myapp" ~release_id:(workload_identity spec) spec
  in
  workload
;;

let numbered_svc_specs count =
  List.init count (fun i ->
    let name = Printf.sprintf "unit-%d" i in
    { svc_spec with
      source_name = String.map (fun c -> if Char.equal c '-' then '_' else c) name
    ; k8s_name = k8s_name name
    ; image = Printf.sprintf "sol-registry:5000/myapp/%s:abc123" name
    })
;;

let test_changing_one_workload_leaves_the_others_unchanged () =
  let specs = numbered_svc_specs 5 in
  let changed =
    List.mapi
      (fun i (spec : Sol_cli_deployment_plan.service_spec) ->
         if i = 2
         then { spec with image = "sol-registry:5000/myapp/unit-2:def5678" }
         else spec)
      specs
  in
  let before = List.map render_with_own_identity specs in
  let after = List.map render_with_own_identity changed in
  List.iteri
    (fun i (b, a) ->
       if i = 2
       then
         check_bool "the changed workload's Pod template changes" false (String.equal b a)
       else
         check_bool
           (Printf.sprintf "workload %d that did not change keeps its Pod template" i)
           true
           (String.equal b a))
    (List.combine before after);
  (* The identity is a function of one workload's own spec, never of the target-wide
     release record: a spec that did not change keeps the identity it had, and only the
     workload whose image changed moves. *)
  List.iteri
    (fun i spec ->
       let same =
         String.equal
           (Sol_cli_release_id.to_string (workload_identity spec))
           (Sol_cli_release_id.to_string (workload_identity (List.nth changed i)))
       in
       check_bool
         (Printf.sprintf "workload %d identity tracks only its own spec" i)
         (not (Int.equal i 2))
         same)
    specs
;;

let test_identity_tracks_effective_config_not_the_release_record () =
  let config = [ "APP_ENV", "prod" ] in
  let spec = { svc_spec with config } in
  let same = workload_identity spec in
  let changed_config =
    workload_identity { spec with config = [ "APP_ENV", "staging" ] }
  in
  let changed_image =
    workload_identity { spec with image = "sol-registry:5000/myapp/charge-svc:new" }
  in
  check_bool
    "an unchanged spec keeps its identity"
    true
    (String.equal
       (Sol_cli_release_id.to_string same)
       (Sol_cli_release_id.to_string (workload_identity spec)));
  check_bool
    "an effective config change moves the identity"
    false
    (String.equal
       (Sol_cli_release_id.to_string same)
       (Sol_cli_release_id.to_string changed_config));
  check_bool
    "an image change moves the identity"
    false
    (String.equal
       (Sol_cli_release_id.to_string same)
       (Sol_cli_release_id.to_string changed_image))
;;

let test_sanitize_label_value_bounds_length () =
  let long = String.make 90 'a' in
  check_string
    "truncated to 63 chars"
    (String.make 63 'a')
    (Sol_cli_manifest.sanitize_label_value long)
;;

let test_sanitize_label_value_fixes_trailing_non_alnum () =
  check_string
    "trailing '.' replaced with a safe char"
    "abc0"
    (Sol_cli_manifest.sanitize_label_value "abc.")
;;

let test_sanitize_label_value_no_op_when_already_safe () =
  check_string
    "already-safe value unchanged"
    "payments-team"
    (Sol_cli_manifest.sanitize_label_value "payments-team")
;;

let test_sanitize_label_value_empty_falls_back_to_unknown () =
  check_string
    "empty value -> unknown"
    "unknown"
    (Sol_cli_manifest.sanitize_label_value "")
;;

let test_sanitize_label_value_lowercases_and_replaces_underscores () =
  check_string
    "mixed case + underscores normalized"
    "sol-obs-review-app"
    (Sol_cli_manifest.sanitize_label_value "Sol_Obs_Review_App")
;;

let test_sanitize_label_value_replaces_internal_space () =
  check_string
    "internal space replaced"
    "my-app"
    (Sol_cli_manifest.sanitize_label_value "My App")
;;

let test_sanitize_label_value_strips_leading_non_alnum () =
  check_string
    "leading hyphens stripped"
    "app"
    (Sol_cli_manifest.sanitize_label_value "---app")
;;

let in_temp_workspace f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir = Filename.temp_file "sol-manifest-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sol_cli_fs.remove_tree tmpdir))
    f
;;

let with_charge_svc_workspace f =
  in_temp_workspace
  @@ fun () ->
  let marker = open_out "sol.yml" in
  close_out marker;
  let dir = "app/payments/charge_svc" in
  Result.get_ok (Sol_cli_fs.mkdir_p dir);
  let oc = open_out (Filename.concat dir "Dockerfile") in
  output_string oc "FROM scratch\n";
  close_out oc;
  f ()
;;

let names services = List.map (fun (s : Sol_cli_manifest.service) -> s.name) services

let test_selection_hyphenated_unit_resolves_to_discovered_name () =
  with_charge_svc_workspace
  @@ fun () ->
  let selected =
    match
      Sol_cli_workload_selection.resolve
        ~what:"--scope"
        (Some "payments/charge-svc")
        (Result.get_ok (Sol_cli_manifest.discover_services ()))
    with
    | Ok selected -> selected
    | Error message -> Windtrap.fail message
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"hyphenated unit resolves to the discovered name"
    [ "charge_svc" ]
    (names selected.services)
;;

let test_selection_unknown_unit_fails_closed () =
  with_charge_svc_workspace
  @@ fun () ->
  match
    Sol_cli_workload_selection.resolve
      ~what:"--scope"
      (Some "payments/nope")
      (Result.get_ok (Sol_cli_manifest.discover_services ()))
  with
  | Ok _ -> Windtrap.fail "expected a fail-closed resolution"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"error names what exists"
      true
      (String.length message > 0)
;;

let replace_all haystack needle replacement =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then haystack
  else (
    let out = Buffer.create hl in
    let i = ref 0 in
    while !i <= hl - nl do
      if String.sub haystack !i nl = needle
      then (
        Buffer.add_string out replacement;
        i := !i + nl)
      else (
        Buffer.add_char out haystack.[!i];
        incr i)
    done;
    Buffer.add_string out (String.sub haystack !i (hl - !i));
    Buffer.contents out)
;;

let render_for ?(workspace = "myapp") env spec =
  let ns, workload = render_spec_ok ~workspace ~env spec in
  ns, workload
;;

let resource_names yaml =
  String.split_on_char '\n' yaml
  |> List.filter_map (fun line ->
    let trimmed = String.trim line in
    let prefix = "name:" in
    let plen = String.length prefix in
    if String.length trimmed > plen && String.sub trimmed 0 plen = prefix
    then Some (String.trim (String.sub trimmed plen (String.length trimmed - plen)))
    else None)
;;

let environment_dependent_keys = [ "env"; "SOL_ENV"; "sol.dev/config-hash" ]

let line_key line =
  let trimmed = String.trim line in
  let trimmed =
    if String.length trimmed > 2 && String.sub trimmed 0 2 = "- "
    then String.trim (String.sub trimmed 2 (String.length trimmed - 2))
    else trimmed
  in
  match String.index_opt trimmed ':' with
  | Some i -> String.trim (String.sub trimmed 0 i)
  | None -> trimmed
;;

let values_of_key key yaml =
  String.split_on_char '\n' yaml
  |> List.filter_map (fun line ->
    if line_key line <> key
    then None
    else (
      let trimmed = String.trim line in
      match String.index_opt trimmed ':' with
      | Some i ->
        Some (String.trim (String.sub trimmed (i + 1) (String.length trimmed - i - 1)))
      | None -> None))
;;

let internal_addresses yaml =
  String.split_on_char '\n' yaml
  |> List.filter (fun line -> Sol_cli_string.contains ~needle:".svc.cluster.local" line)
  |> List.map String.trim
;;

let check_no_unexplained_differences label a b ~env_a ~env_b =
  let la = String.split_on_char '\n' a
  and lb = String.split_on_char '\n' b in
  if List.length la <> List.length lb
  then Windtrap.fail (label ^ ": the two renders differ in line count");
  List.iter2
    (fun x y ->
       if x <> y
       then (
         let key = line_key x in
         if not (List.mem key environment_dependent_keys)
         then
           Windtrap.fail
             (Printf.sprintf
                "%s: this line differs between environments, and only %s may: %s"
                label
                (String.concat ", " environment_dependent_keys)
                (String.trim x));
         if key <> "sol.dev/config-hash"
         then (
           assert_contains label x env_a;
           assert_contains label y env_b;
           check_string
             (label ^ ": " ^ key ^ " carries the environment's name and nothing else")
             (replace_all x env_a "<env>")
             (replace_all y env_b "<env>"))))
    la
    lb
;;

let test_environment_labels_but_does_not_re_address () =
  let ns_alpha, workload_alpha = render_for "alpha" svc_spec in
  let ns_beta, workload_beta = render_for "beta" svc_spec in
  assert_contains "the environment is represented" workload_alpha "alpha";
  assert_contains "the environment is represented" workload_beta "beta";
  check_bool
    "the two environments do not render identically"
    false
    (workload_alpha = workload_beta);
  check_string "the namespace document is identical" ns_alpha ns_beta;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"resource names are identical"
    (resource_names workload_alpha)
    (resource_names workload_beta);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"image references are identical"
    (values_of_key "image" workload_alpha)
    (values_of_key "image" workload_beta);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"internal addresses are identical"
    (internal_addresses workload_alpha)
    (internal_addresses workload_beta);
  check_no_unexplained_differences
    "workload"
    workload_alpha
    workload_beta
    ~env_a:"alpha"
    ~env_b:"beta";
  let ns_again, workload_again = render_for "alpha" svc_spec in
  check_string "the namespace document is stable across renders" ns_alpha ns_again;
  check_string "the workload is stable across renders" workload_alpha workload_again
;;

let test_environment_absent_from_the_namespace () =
  let ns_alpha, _ = render_for "alpha" svc_spec in
  let ns_beta, _ = render_for "beta" svc_spec in
  assert_absent "namespace" ns_alpha "alpha";
  assert_absent "namespace" ns_beta "beta"
;;

let test_worker_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"staging" worker_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "worker SOL_ENV config" cm_block {|SOL_ENV: "staging"|}
;;

let test_worker_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok worker_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "worker SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_fn_sol_env_configmap_present_when_resolved () =
  let _ns, workload = render_spec_ok ~env:"dev" fn_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_contains "fn SOL_ENV config" cm_block {|SOL_ENV: "dev"|}
;;

let test_fn_sol_env_configmap_absent_by_default () =
  let _ns, workload = render_spec_ok fn_spec in
  let cm_block = extract_kind_block workload "kind: ConfigMap" in
  assert_absent "fn SOL_ENV config" cm_block {|SOL_ENV: |}
;;

let test_fn_render_carries_pushgateway_job () =
  let _, workload = render_spec_ok fn_spec in
  check_bool
    "SOL_PUSHGATEWAY_JOB is <namespace>.<name>"
    true
    (Sol_cli_string.contains
       ~needle:
         (Printf.sprintf
            "SOL_PUSHGATEWAY_JOB: \"%s.%s\""
            (Sol_cli_kubernetes_name.namespace_to_string fn_spec.namespace)
            (Sol_cli_kubernetes_name.k8s_name_to_string fn_spec.k8s_name))
       workload)
;;

let test_svc_render_has_no_pushgateway_job () =
  let _, workload = render_spec_ok svc_spec in
  check_bool
    "svc has no Pushgateway job"
    false
    (Sol_cli_string.contains ~needle:"SOL_PUSHGATEWAY_JOB" workload)
;;

let test_fn_without_schedule_is_refused_at_render () =
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      { fn_spec with schedule = None }
  with
  | Ok _ -> Windtrap.fail "a -fn spec without a schedule must not render hourly"
  | Error msg ->
    check_bool "names the schedule" true (Sol_cli_string.contains ~needle:"schedule" msg)
;;

let test_local_executor_renders_unverified_jwt_opt_in () =
  let _, workload = render_spec_ok (Sol_cli_executor.local_development_spec svc_spec) in
  check_bool
    "local render carries SOL_ALLOW_UNVERIFIED_JWT=1"
    true
    (Sol_cli_string.contains ~needle:"SOL_ALLOW_UNVERIFIED_JWT: \"1\"" workload)
;;

let test_sol_toml_cannot_set_unverified_jwt_opt_in () =
  let path = Filename.temp_file "sol-toml-optin-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.env]\nconfig = { SOL_ALLOW_UNVERIFIED_JWT = \"1\" }\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    check_bool
      "names the reserved key"
      true
      (Sol_cli_string.contains ~needle:"SOL_ALLOW_UNVERIFIED_JWT" message)
  | Ok _ -> Windtrap.fail "sol.toml must not be able to set SOL_ALLOW_UNVERIFIED_JWT"
  | Error (Sol_cli_toml.Toml_syntax _) -> Windtrap.fail "expected a validation error"
;;

let test_sol_toml_secrets_cannot_name_unverified_jwt_opt_in () =
  let path = Filename.temp_file "sol-toml-optin-secret-" ".toml" in
  let oc = open_out path in
  output_string oc "[infra.env]\nsecrets = [\"SOL_ALLOW_UNVERIFIED_JWT\"]\n";
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    check_bool
      "names the reserved key"
      true
      (Sol_cli_string.contains ~needle:"SOL_ALLOW_UNVERIFIED_JWT" message)
  | Ok _ -> Windtrap.fail "a sol.toml secret must not be able to carry the opt-in"
  | Error (Sol_cli_toml.Toml_syntax _) -> Windtrap.fail "expected a validation error"
;;

let test_sol_secret_rejects_unverified_jwt_opt_in () =
  check_bool
    "sol secret set refuses the reserved key"
    true
    (Result.is_error (Sol_cli_secret.validate_key "SOL_ALLOW_UNVERIFIED_JWT"))
;;

let test_sol_secret_delete_accepts_reserved_key_format () =
  check_bool
    "sol secret delete may remove the reserved key"
    true
    (Result.is_ok (Sol_cli_secret.validate_key_format "SOL_ALLOW_UNVERIFIED_JWT"))
;;

let test_deploy_render_has_no_unverified_jwt_opt_in () =
  let _, workload = render_spec_ok svc_spec in
  check_bool
    "a deploy/GitOps render never carries the opt-in"
    false
    (Sol_cli_string.contains ~needle:"SOL_ALLOW_UNVERIFIED_JWT" workload)
;;

let test_svc_readiness_probe_uses_readyz () =
  let _, workload =
    render_spec_ok { svc_spec with language = Some Sol_cli_compat.Ocaml }
  in
  check_bool
    "readinessProbe path is /readyz"
    true
    (Sol_cli_string.contains
       ~needle:"readinessProbe:\n          httpGet:\n            path: /readyz"
       workload);
  check_bool
    "livenessProbe path is /healthz"
    true
    (Sol_cli_string.contains
       ~needle:"livenessProbe:\n          httpGet:\n            path: /healthz"
       workload)
;;

let test_undeclared_language_readiness_stays_on_healthz () =
  let _, workload = render_spec_ok { svc_spec with language = None } in
  check_bool
    "undeclared-language readinessProbe path is /healthz"
    true
    (Sol_cli_string.contains
       ~needle:"readinessProbe:\n          httpGet:\n            path: /healthz"
       workload)
;;

let test_ts_svc_readiness_uses_readyz () =
  let _, workload =
    render_spec_ok { svc_spec with language = Some Sol_cli_compat.Typescript }
  in
  check_bool
    "TypeScript readinessProbe path is /readyz"
    true
    (Sol_cli_string.contains
       ~needle:"readinessProbe:\n          httpGet:\n            path: /readyz"
       workload);
  check_bool
    "TypeScript livenessProbe path is /healthz"
    true
    (Sol_cli_string.contains
       ~needle:"livenessProbe:\n          httpGet:\n            path: /healthz"
       workload)
;;

let parse_documents text =
  text
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun (docs, current) line ->
          if line = "---" then List.rev current :: docs, [] else docs, line :: current)
       ([], [])
  |> (fun (docs, current) -> List.rev (List.rev current :: docs))
  |> List.map (String.concat "\n")
  |> List.filter (fun doc -> String.trim doc <> "")
  |> List.map (fun doc ->
    match Yaml.of_string doc with
    | Ok v -> v
    | Error (`Msg m) -> Windtrap.failf "rendered document does not parse: %s\n%s" m doc)
;;

let rec lookup path (v : Yaml.value) =
  match path, v with
  | [], v -> Some v
  | key :: rest, `O members -> Option.bind (List.assoc_opt key members) (lookup rest)
  | _ -> None
;;

let find_kind kind docs =
  match List.find_opt (fun d -> lookup [ "kind" ] d = Some (`String kind)) docs with
  | Some d -> d
  | None -> Windtrap.failf "no %s document" kind
;;

let test_hostile_values_round_trip () =
  let hostile = "a \"quoted\" \\ value\n  INJECTED: \"yes\"\n# and: more" in
  let spec =
    { svc_spec with
      config = [ "APP_NOTE", hostile; "APP_FLAG", "true"; "APP_VERSION", "1.10" ]
    ; extra_labels = [ "team", "yes" ]
    }
  in
  let _ns, workload = render_spec_ok spec in
  let docs = parse_documents workload in
  let configmap = find_kind "ConfigMap" docs in
  [ "APP_NOTE", hostile; "APP_FLAG", "true"; "APP_VERSION", "1.10" ]
  |> List.iter (fun (key, expected) ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:("ConfigMap " ^ key)
      (Some expected)
      (match lookup [ "data"; key ] configmap with
       | Some (`String s) -> Some s
       | _ -> None));
  Windtrap.equal
    Windtrap.bool
    ~msg:"no injected key"
    true
    (lookup [ "data"; "INJECTED" ] configmap = None);
  let deployment = find_kind "Deployment" docs in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a label that YAML 1.1 reads as a boolean stays a string"
    true
    (lookup [ "spec"; "template"; "metadata"; "labels"; "team" ] deployment
     = Some (`String "yes"))
;;

let prefix_value ~prefix text =
  text
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
    let trimmed = String.trim line in
    let n = String.length prefix in
    if String.length trimmed >= n && String.sub trimmed 0 n = prefix
    then Some (String.trim (String.sub trimmed n (String.length trimmed - n)))
    else None)
  |> function
  | first :: _ -> first
  | [] -> Windtrap.fail (Printf.sprintf "no line starts with %S" prefix)
;;

let template_dockerfile kind =
  let root =
    match Sol_cli_platform_assets.resolve () with
    | Ok assets -> Sol_cli_platform_assets.templates_root assets
    | Error error ->
      Windtrap.fail
        ("no scaffold templates: " ^ Sol_cli_platform_assets.error_to_string error)
  in
  match Sol_cli_scaffold_tree.text ~root ~kind ~rel:"Dockerfile" with
  | Ok text -> text
  | Error message -> Windtrap.fail message
;;

let test_image_user_matches_pod_security () =
  List.iter
    (fun (kind, spec) ->
       let _, workload = render_spec_ok spec in
       let user = prefix_value ~prefix:"USER " (template_dockerfile kind) in
       check_string
         (kind ^ " manifest runAsUser")
         user
         (prefix_value ~prefix:"runAsUser:" workload);
       check_string
         (kind ^ " manifest runAsGroup")
         user
         (prefix_value ~prefix:"runAsGroup:" workload))
    [ "svc", svc_spec; "worker", worker_spec; "fn", fn_spec ]
;;

let test_contract_job_manifest () =
  let doc =
    Sol_cli_manifest.contract_job_doc
      ~cluster_env:Sol_cli_manifest.default_cluster_env
      ~secret_name:None
      ~name:"sol-contract-1"
      ~namespace:"myapp-payments"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~command:[ "/usr/local/bin/contract" ]
      ~args:[ "--apply" ]
    |> render_doc
  in
  assert_contains "contract Job kind" doc "kind: Job";
  assert_contains "contract Job name" doc "name: sol-contract-1";
  assert_contains "contract Job namespace" doc "namespace: myapp-payments";
  assert_contains "contract Job image" doc "sol-registry:5000/myapp/charge-svc:abc123";
  assert_contains "contract Job command" doc "/usr/local/bin/contract";
  assert_contains "contract Job args" doc "--apply";
  assert_contains "contract Job does not retry" doc "backoffLimit: 0";
  assert_contains "contract Job never restarts" doc "restartPolicy: Never";
  assert_contains "contract Job env names the registry" doc "name: SCHEMA_REGISTRY_URL";
  assert_contains
    "contract Job reaches the private registry in-cluster"
    doc
    "value: http://redpanda.redpanda.svc.cluster.local:8081";
  assert_absent "contract Job does not mount migrations" doc "mountPath: /migrations";
  assert_absent
    "contract Job depends on no runtime Secret (it runs before the workloads create one)"
    doc
    "sol-secrets";
  let tls_doc =
    Sol_cli_manifest.contract_job_doc
      ~cluster_env:(Sol_cli_manifest.cluster_env Sol_cli_manifest.Sasl_ssl)
      ~secret_name:(Some "prod-aws-us-east-1-kafka-creds")
      ~name:"sol-contract-tls"
      ~namespace:"myapp-payments"
      ~image:"sol-registry:5000/myapp/charge-svc:abc123"
      ~command:[ "/usr/local/bin/contract" ]
      ~args:[ "--apply" ]
    |> render_doc
  in
  assert_contains
    "TLS contract Job consumes the delivered Kafka Secret"
    tls_doc
    "name: prod-aws-us-east-1-kafka-creds";
  assert_absent
    "TLS contract Job does not consume the shared platform Secret"
    tls_doc
    "sol-secrets";
  assert_absent
    "TLS contract Job does not envFrom every key in a Secret"
    tls_doc
    "envFrom";
  assert_contains "TLS contract Job mounts the CA key" tls_doc "key: KAFKA_SSL_CA_CERT";
  assert_contains "TLS contract Job receives the SASL key" tls_doc "KAFKA_SASL_PASSWORD";
  (* #1477: the contract Job runs the TypeScript client, whose HTTPS fetch to the Schema
     Registry needs the platform CA in Node's trust store. The env var and the mount must
     name the same file, or the fix would point Node at an absent path. *)
  assert_contains
    "TLS contract Job trusts the platform CA for Node (#1477)"
    tls_doc
    "name: NODE_EXTRA_CA_CERTS";
  assert_contains
    "and the trust path is the mounted CA file"
    tls_doc
    "value: /etc/sol/kafka/ca.crt";
  assert_contains
    "at the same mount path the contract Job uses"
    tls_doc
    "mountPath: /etc/sol/kafka";
  assert_absent
    "the plaintext contract Job does not widen Node's trust store"
    doc
    "NODE_EXTRA_CA_CERTS";
  assert_absent
    "the contract Job never disables certificate verification"
    tls_doc
    "NODE_TLS_REJECT_UNAUTHORIZED"
;;

let test_contract_scope_rule () =
  let ocaml_spec = { svc_spec with language = Some Sol_cli_compat.Ocaml } in
  let ts_spec = { worker_spec with language = Some Sol_cli_compat.Typescript } in
  let undeclared = { svc_spec with language = None } in
  let images services =
    Sol_cli_contract.reconciliation_images services
    |> List.map (fun (namespace, image, _) -> namespace, image)
  in
  let expected_images = Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string) in
  Windtrap.equal
    expected_images
    ~msg:"a TypeScript-only scope reconciles its own image"
    [ "myapp-comms", ts_spec.image ]
    (images [ ts_spec ]);
  Windtrap.equal
    expected_images
    ~msg:"a mixed scope reconciles one image per language"
    [ "myapp-comms", ts_spec.image; "myapp-payments", ocaml_spec.image ]
    (images [ ts_spec; ocaml_spec ]);
  Windtrap.equal
    expected_images
    ~msg:"units sharing a language share the workspace projection and one Job"
    [ "myapp-payments", ocaml_spec.image ]
    (images
       [ ocaml_spec; { ocaml_spec with image = "sol-registry:5000/myapp/other:abc123" } ]);
  Windtrap.equal
    expected_images
    ~msg:"an undeclared language still reconciles"
    [ "myapp-payments", undeclared.image ]
    (images [ undeclared ]);
  (* A managed Kafka consumer's contract Job must read the target-scoped delivered
     Secret, never the shared platform Secret. *)
  let kafka_consumer =
    { ts_spec with
      consumes_kafka = true
    ; config = Sol_cli_manifest.production_kafka_config
    ; secret_sources =
        [ ( "KAFKA_SASL_PASSWORD"
          , Sol_cli_secret_source.Target_kafka
              { secret = "prod-aws-us-east-1-kafka-creds" } )
        ; ( "KAFKA_SSL_CA_CERT"
          , Sol_cli_secret_source.Target_kafka
              { secret = "prod-aws-us-east-1-kafka-creds" } )
        ]
    }
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"the contract Job reads the consumer's delivered Kafka Secret"
    [ "myapp-comms", Some "prod-aws-us-east-1-kafka-creds" ]
    (Sol_cli_contract.reconciliation_images [ kafka_consumer ]
     |> List.map (fun (namespace, _, secret) -> namespace, secret));
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"a consumer that is not the first unit of its language still supplies the Secret"
    [ "myapp-comms", Some "prod-aws-us-east-1-kafka-creds" ]
    (Sol_cli_contract.reconciliation_images [ ts_spec; kafka_consumer ]
     |> List.map (fun (namespace, _, secret) -> namespace, secret))
;;

let%test
    "image user matches the rendered securityContext (REFAC-143): every primitive's \
     image runs as the uid its manifest declares"
  =
  test_image_user_matches_pod_security ()
;;

let%test "values are written exactly (REFAC-131): hostile env and label values round-trip"
  =
  test_hostile_values_round_trip ()
;;

let%test "fn Pushgateway job and schedule (BUG-048): fn carries SOL_PUSHGATEWAY_JOB" =
  test_fn_render_carries_pushgateway_job ()
;;

let%test "fn Pushgateway job and schedule (BUG-048): svc does not" =
  test_svc_render_has_no_pushgateway_job ()
;;

let%test "fn Pushgateway job and schedule (BUG-048): fn without schedule refused" =
  test_fn_without_schedule_is_refused_at_render ()
;;

let%test "unverified JWT opt-in (SEC-006): local executor renders it" =
  test_local_executor_renders_unverified_jwt_opt_in ()
;;

let%test "unverified JWT opt-in (SEC-006): deploy render does not" =
  test_deploy_render_has_no_unverified_jwt_opt_in ()
;;

let%test "unverified JWT opt-in (SEC-006): sol.toml cannot set it" =
  test_sol_toml_cannot_set_unverified_jwt_opt_in ()
;;

let%test "unverified JWT opt-in (SEC-006): sol.toml secrets cannot name it" =
  test_sol_toml_secrets_cannot_name_unverified_jwt_opt_in ()
;;

let%test "unverified JWT opt-in (SEC-006): sol secret set refuses it" =
  test_sol_secret_rejects_unverified_jwt_opt_in ()
;;

let%test "unverified JWT opt-in (SEC-006): sol secret delete can still remove it" =
  test_sol_secret_delete_accepts_reserved_key_format ()
;;

let%test "svc readiness (INFRA-073): readiness uses /readyz" =
  test_svc_readiness_probe_uses_readyz ()
;;

let%test "svc readiness (INFRA-073): TypeScript uses /readyz" =
  test_ts_svc_readiness_uses_readyz ()
;;

let%test "svc readiness (INFRA-073): undeclared language stays on /healthz" =
  test_undeclared_language_readiness_stays_on_healthz ()
;;

let%test "SOL_ENV reaches every primitive: worker SOL_ENV when resolved" =
  test_worker_sol_env_configmap_present_when_resolved ()
;;

let%test "SOL_ENV reaches every primitive: worker SOL_ENV absent by default" =
  test_worker_sol_env_configmap_absent_by_default ()
;;

let%test "SOL_ENV reaches every primitive: fn SOL_ENV when resolved" =
  test_fn_sol_env_configmap_present_when_resolved ()
;;

let%test "SOL_ENV reaches every primitive: fn SOL_ENV absent by default" =
  test_fn_sol_env_configmap_absent_by_default ()
;;

let%test "svc: namespace yaml" = test_svc_namespace ()
let%test "svc: persistent volume claim + mount" = test_svc_volumes ()
let%test "svc: deployment name" = test_svc_deployment_name ()
let%test "svc: image" = test_svc_image ()
let%test "svc: has Service resource" = test_svc_has_service_resource ()
let%test "svc: has Ingress" = test_svc_has_ingress ()

let%test "svc: NetworkPolicy allows monitoring ingress" =
  test_svc_networkpolicy_allows_monitoring_ingress ()
;;

let%test "svc: calls peer env and NetworkPolicy" =
  test_svc_calls_peer_env_and_network_policy ()
;;

let%test "fn: a declared call renders a projected identity (DEC-063)" =
  test_fn_calls_render_a_projected_identity ()
;;

let%test "svc: has containerPort" = test_svc_has_ports ()
let%test "svc: replicas from spec" = test_svc_replicas ()
let%test "svc: default resources (replicas/cpu/memory)" = test_svc_default_resources ()
let%test "svc: extra config in map" = test_svc_extra_config ()
let%test "svc: env label when resolved" = test_svc_env_label_present_when_resolved ()
let%test "svc: env label absent by default" = test_svc_env_label_absent_by_default ()

let%test "svc: SOL_ENV config when resolved" =
  test_svc_sol_env_configmap_present_when_resolved ()
;;

let%test "svc: SOL_ENV config absent by default" =
  test_svc_sol_env_configmap_absent_by_default ()
;;

let%test "svc: SOL_ENV config uses target" =
  test_svc_sol_env_configmap_target_overrides_config ()
;;

let%test "svc: identity ConfigMap carries the taxonomy" =
  test_svc_identity_configmap_carries_the_taxonomy ()
;;

let%test "svc: declared config cannot shadow the identity" =
  test_svc_identity_cannot_be_shadowed_by_declared_config ()
;;

let%test "worker: identity ConfigMap carries the taxonomy" =
  test_worker_identity_configmap_carries_the_taxonomy ()
;;

let%test "fn: identity ConfigMap carries the taxonomy" =
  test_fn_identity_configmap_carries_the_taxonomy ()
;;

let%test "svc: identity env present without env (sol local deploy)" =
  test_identity_env_absent_from_local_render ()
;;

let%test "svc: POSTGRES_URL not in ConfigMap" = test_postgres_url_not_in_configmap ()

let%test "svc: ordinary deploy render emits no Secret values" =
  test_live_render_emits_no_secret_values ()
;;

let%test "svc: GitOps placeholder render redacts values" =
  test_placeholder_render_redacts_values ()
;;

let%test "svc: a declared SOL_API_KEY is projected" =
  test_declared_api_key_is_projected ()
;;

let%test "svc: default redpanda admin" = test_svc_default_redpanda_admin_url ()

let%test "svc: svc declares KAFKA_SECURITY_PROTOCOL" =
  test_svc_declares_kafka_security_protocol ()
;;

let%test "svc: production declares SASL_SSL" = test_production_svc_declares_sasl_ssl ()

let%test "svc: a consumer reads the delivered Kafka Secret" =
  test_consumer_reads_the_delivered_kafka_secret ()
;;

let%test "svc: a non-consumer has no Kafka Secret input" =
  test_non_consumer_has_no_kafka_secret ()
;;

let%test "svc: production mounts the Kafka CA" = test_production_svc_mounts_the_ca ()
let%test "svc: local has no Kafka CA mount" = test_local_svc_has_no_kafka_ca_mount ()

let%test "svc: production placeholder Secret requires Kafka keys" =
  test_production_placeholder_secret_requires_kafka_keys ()
;;

let%test "svc: secret refs no values" = test_svc_secret_refs_without_values ()
let%test "svc: namespace in workload" = test_svc_namespace_in_workload ()
let%test "svc: image override (up dry-run)" = test_svc_image_override ()

let%test "svc: user secret key in Secret resource" =
  test_user_secret_key_in_secret_resource ()
;;

let%test "svc: user secret key ref in Deployment" =
  test_user_secret_key_ref_in_deployment ()
;;

let%test "svc: multiple user secret keys in Secret" =
  test_multiple_user_secret_keys_in_secret_resource ()
;;

let%test "svc: a DB consumer routes POSTGRES_URL to the class Secret" =
  test_database_url_routes_to_the_class_secret ()
;;

let%test "svc: GitOps redacts secret values" = test_gitops_redacts_all_secret_values ()
let%test "worker: namespace yaml" = test_worker_namespace ()
let%test "worker: persistent volume claim + mount" = test_worker_volumes ()
let%test "worker: image" = test_worker_image ()
let%test "worker: no Service/Ingress" = test_worker_no_service_resource ()
let%test "worker: metrics containerPort" = test_worker_metrics_port ()
let%test "worker: has Deployment" = test_worker_has_deployment ()

let%test "worker: ServiceAccount disables token automount" =
  test_service_account_disables_token_automount ()
;;

let%test "worker: svc ServiceAccount disables token automount" =
  test_svc_service_account_disables_token_automount ()
;;

let%test "worker: fn ServiceAccount disables token automount" =
  test_fn_service_account_disables_token_automount ()
;;

let%test "worker: explicit termination grace" = test_termination_grace_is_explicit ()
let%test "worker: consumer probes" = test_worker_consumer_probes ()

let%test "worker: non-consumer worker has no liveness" =
  test_non_consumer_worker_has_no_liveness ()
;;

let%test "worker: node-failure-tolerant renders PDB and spread" =
  test_node_failure_tolerant_renders_pdb_and_spread ()
;;

let%test "worker: single has no PDB" = test_single_has_no_pdb ()

let%test "worker: user secret key in Secret resource" =
  test_worker_user_secret_key_in_secret_resource ()
;;

let%test "worker: env label when resolved" =
  test_worker_env_label_present_when_resolved ()
;;

let%test "fn: namespace yaml" = test_fn_namespace ()
let%test "fn: image" = test_fn_image ()
let%test "fn: kind CronJob" = test_fn_cronjob ()
let%test "fn: schedule from spec" = test_fn_schedule ()
let%test "fn: env label when resolved" = test_fn_env_label_present_when_resolved ()
let%test "fn: no Deployment" = test_fn_no_deployment ()

let%test "fn: user secret key in Secret resource" =
  test_fn_user_secret_key_in_secret_resource ()
;;

let%test "fn: pod template has app label (AUDIT-040)" =
  test_fn_cronjob_pod_template_has_app_label ()
;;

let%test "fn: cpu/memory configurable (BUG-031)" = test_fn_cpu_memory_configurable ()

let%test "fn: cpu/memory request equals limit (BUG-031)" =
  test_fn_cpu_memory_request_equals_limit ()
;;

let%test "fn: scheduled_concurrency configurable (FEAT-079)" =
  test_fn_scheduled_concurrency_configurable ()
;;

let%test "fn: scheduled_concurrency default is Allow (FEAT-079)" =
  test_fn_scheduled_concurrency_default_is_allow ()
;;

let%test "fn: backoff_limit configurable (FEAT-079)" =
  test_fn_backoff_limit_configurable ()
;;

let%test "fn: backoff_limit default is 3 (FEAT-079)" =
  test_fn_backoff_limit_default_is_three ()
;;

let%test "escape_hatches: rollout Recreate" = test_rollout_recreate ()
let%test "escape_hatches: rollout RollingUpdate" = test_rollout_rolling_update ()

let%test "escape_hatches: rollout default=RollingUpdate" =
  test_rollout_default_is_rolling_update ()
;;

let%test "escape_hatches: progressive default Deployment" =
  test_progressive_default_is_deployment ()
;;

let%test "escape_hatches: progressive canary Rollout" = test_progressive_canary_rollout ()

let%test "escape_hatches: progressive worker canary" =
  test_progressive_canary_worker_no_service ()
;;

let%test "escape_hatches: progressive blue-green Rollout" =
  test_progressive_blue_green_rollout ()
;;

let%test "escape_hatches: rollout canary secrets use name-secrets" =
  test_rollout_canary_secrets_use_sol_secrets ()
;;

let%test "escape_hatches: rollout blue-green secrets use name-secrets" =
  test_rollout_blue_green_secrets_use_sol_secrets ()
;;

let%test "escape_hatches: ingress host override" = test_ingress_host_override ()

let%test "escape_hatches: undeclared ingress_host gets a dev host" =
  test_undeclared_ingress_host_gets_dev_host ()
;;

let%test "escape_hatches: blue-green ingress tls secret matches plan" =
  test_blue_green_ingress_tls_secret_matches_plan ()
;;

let%test "escape_hatches: ingress path override" = test_ingress_path_override ()
let%test "escape_hatches: ingress default path" = test_ingress_default_path ()

let%test "escape_hatches: extra_labels in pod template" =
  test_extra_labels_appear_in_pod_template ()
;;

let%test "escape_hatches: extra_labels empty default" =
  test_extra_labels_empty_by_default ()
;;

let%test "escape_hatches: invalid rollout_strategy" =
  test_toml_invalid_rollout_strategy ()
;;

let%test "escape_hatches: reserved label key rejected" = test_toml_reserved_label_key ()
let%test "escape_hatches: valid Recreate from toml" = test_toml_valid_rollout_recreate ()

let%test "escape_hatches: valid ingress overrides toml" =
  test_toml_valid_ingress_overrides ()
;;

let%test "escape_hatches: valid service calls toml" = test_toml_valid_service_calls ()
let%test "escape_hatches: invalid cpu quantity" = test_toml_invalid_cpu_quantity ()
let%test "escape_hatches: invalid memory quantity" = test_toml_invalid_memory_quantity ()
let%test "escape_hatches: invalid ingress host" = test_toml_invalid_ingress_host ()
let%test "escape_hatches: invalid ingress path" = test_toml_invalid_ingress_path ()
let%test "escape_hatches: secret keys from toml" = test_toml_secret_keys ()
let%test "escape_hatches: build secret keys from toml" = test_toml_build_secret_keys ()

let%test "escape_hatches: a key scoped to both secret sets is rejected" =
  test_toml_secret_key_scope_conflict ()
;;

let%test "escape_hatches: valid canary rollout toml" = test_toml_valid_canary_rollout ()

let%test "escape_hatches: valid blue-green rollout toml" =
  test_toml_valid_blue_green_rollout ()
;;

let%test "escape_hatches: invalid progressive strategy" =
  test_toml_invalid_progressive_strategy ()
;;

let%test "escape_hatches: canary requires steps" = test_toml_canary_requires_steps ()

let%test "escape_hatches: canary rejects bad weight" =
  test_toml_canary_rejects_bad_weight ()
;;

let%test "escape_hatches: malformed TOML raises" = test_toml_rejects_malformed ()

let%test "escape_hatches: load_result validation error" =
  test_toml_load_result_validation_error ()
;;

let%test "escape_hatches: load_result syntax error" =
  test_toml_load_result_syntax_error ()
;;

let%test "escape_hatches: multi-line secrets array" = test_toml_multiline_array_secrets ()
let%test "escape_hatches: dotted section headers" = test_toml_dotted_section_headers ()
let%test "escape_hatches: canary pause steps" = test_toml_canary_pause_steps ()

let%test "external_secrets: external_secret_doc: no stringData" =
  test_external_secret_doc_no_stringdata ()
;;

let%test "external_secrets: external_secret_doc: keys present" =
  test_external_secret_doc_keys_present ()
;;

let%test "external_secrets: external_secret_doc: target name" =
  test_external_secret_doc_target_name ()
;;

let%test "external_secrets: external_secret_doc: namespace-scoped store kind" =
  test_external_secret_doc_namespace_scoped_store ()
;;

let%test "external_secrets: render_spec ESO: no k8s Secret" =
  test_render_spec_eso_backend_no_k8s_secret ()
;;

let%test "external_secrets: render_spec ESO: all keys in data" =
  test_render_spec_eso_backend_all_keys ()
;;

let%test "external_secrets: render_spec ESO: no stringData" =
  test_render_spec_eso_backend_no_stringdata ()
;;

let%test "secrets: direct deploy render emits no Secret object" =
  test_render_default_backend_emits_no_secret ()
;;

let%test "secrets: live render never reads the environment" =
  test_live_backend_render_never_reads_env ()
;;

let%test "secrets: live: no user secrets → no Secret object" =
  test_live_backend_no_user_secrets_always_succeeds ()
;;

let%test "workload_shape: Http_service deployment has ports" =
  test_shape_http_service_deployment_has_ports ()
;;

let%test "workload_shape: Background_worker deployment metrics port" =
  test_shape_background_worker_deployment_has_metrics_port ()
;;

let%test "workload_shape: Http_service rollout has ports" =
  test_shape_rollout_http_service_has_ports ()
;;

let%test "workload_shape: Background_worker rollout metrics port" =
  test_shape_rollout_background_worker_metrics_port ()
;;

let%test "artifact_invariants: svc satisfies security invariants" =
  test_svc_satisfies_invariants ()
;;

let%test "artifact_invariants: worker satisfies security invariants" =
  test_worker_satisfies_invariants ()
;;

let%test "artifact_invariants: fn satisfies security invariants" =
  test_fn_satisfies_invariants ()
;;

let%test "artifact_invariants: canary rollout satisfies security invariants" =
  test_rollout_canary_satisfies_invariants ()
;;

let%test "artifact_invariants: blue-green rollout satisfies security invariants" =
  test_rollout_blue_green_satisfies_invariants ()
;;

let%test "artifact_invariants: GitOps mode redacts secret values" =
  test_gitops_secret_redacted ()
;;

let%test "taxonomy_labels: svc" = test_taxonomy_labels_svc ()
let%test "taxonomy_labels: worker" = test_taxonomy_labels_worker ()
let%test "taxonomy_labels: fn" = test_taxonomy_labels_fn ()

let%test "taxonomy_labels: release label sits at the verifier's jsonpath" =
  test_release_label_lives_at_the_verifier_jsonpath ()
;;

let%test "taxonomy_labels: not in selector" = test_taxonomy_labels_not_in_selector ()
let%test "taxonomy_labels: label is the release id" = test_release_label_is_release_id ()

let%test "taxonomy_labels: label does not leak the image tag" =
  test_release_label_does_not_leak_image_tag ()
;;

let%test "taxonomy_labels: label is the supplied identity" =
  test_release_label_is_the_supplied_identity ()
;;

let%test "release identity: changing one workload leaves the others unchanged" =
  test_changing_one_workload_leaves_the_others_unchanged ()
;;

let%test "release identity: tracks effective config, not the release record" =
  test_identity_tracks_effective_config_not_the_release_record ()
;;

let%test "taxonomy_labels: sanitize_label_value bounds length" =
  test_sanitize_label_value_bounds_length ()
;;

let%test "taxonomy_labels: sanitize_label_value fixes trailing non-alnum" =
  test_sanitize_label_value_fixes_trailing_non_alnum ()
;;

let%test "taxonomy_labels: sanitize_label_value no-op when already safe" =
  test_sanitize_label_value_no_op_when_already_safe ()
;;

let%test "taxonomy_labels: sanitize_label_value empty -> unknown" =
  test_sanitize_label_value_empty_falls_back_to_unknown ()
;;

let%test "taxonomy_labels: sanitize_label_value lowercases + replaces underscores" =
  test_sanitize_label_value_lowercases_and_replaces_underscores ()
;;

let%test "taxonomy_labels: sanitize_label_value replaces internal space" =
  test_sanitize_label_value_replaces_internal_space ()
;;

let%test "taxonomy_labels: sanitize_label_value strips leading non-alnum" =
  test_sanitize_label_value_strips_leading_non_alnum ()
;;

let%test "workload_selection: hyphenated unit resolves to discovered name" =
  test_selection_hyphenated_unit_resolves_to_discovered_name ()
;;

let%test "workload_selection: unknown unit fails closed" =
  test_selection_unknown_unit_fails_closed ()
;;

let%test "environment: an environment labels but does not re-address" =
  test_environment_labels_but_does_not_re_address ()
;;

let%test "environment: an environment is absent from the namespace" =
  test_environment_absent_from_the_namespace ()
;;

let%test
    "contract reconciliation: the contract Job runs the deployed image's contract binary"
  =
  test_contract_job_manifest ()
;;

let%test "contract reconciliation: one in-destination Job per language in scope" =
  test_contract_scope_rule ()
;;

let%test "identity projection: labels are bounded and the token file is stable" =
  let long = String.make 63 'a' in
  let p =
    Sol_cli_identity_projection.of_call
      ~callee_k8s_name:long
      ~audience:"domain/unit"
      ~url_env_var:"LEDGER_SVC_URL"
  in
  check_bool
    "the volume name is a bounded DNS label"
    true
    (String.length p.volume_name <= 63);
  check_bool "the volume name has no spaces" false (String.contains p.volume_name ' ');
  check_bool
    "the token file env var mirrors the URL env var"
    true
    (Sol_cli_identity_projection.token_file_env_var p = "LEDGER_SVC_TOKEN_FILE");
  check_bool
    "the token file is the stable projection path"
    true
    (Sol_cli_identity_projection.token_file p = "/var/run/sol/identity/" ^ long ^ "/token")
;;

let toml_rejects_reserved_key ~key =
  let path = Filename.temp_file "sol-toml-reserved-" ".toml" in
  let oc = open_out path in
  output_string oc (Printf.sprintf "[infra.env]\nconfig = { %s = \"1\" }\n" key);
  close_out oc;
  let result = Sol_cli_toml.load_result path in
  Sys.remove path;
  match result with
  | Error (Sol_cli_toml.Validation { message; _ }) ->
    check_bool
      (Printf.sprintf "%s is named in the error" key)
      true
      (Sol_cli_string.contains ~needle:key message)
  | Ok _ -> Windtrap.fail (key ^ " must be reserved in sol.toml")
  | Error (Sol_cli_toml.Toml_syntax _) -> Windtrap.fail "expected a validation error"
;;

let%test "peer auth: sol.toml cannot set the plaintext peer opt-in" =
  toml_rejects_reserved_key ~key:"SOL_ALLOW_PLAINTEXT_PEER_AUTH"
;;

let%test "peer auth: sol secret set refuses the plaintext peer opt-in" =
  check_bool
    "sol secret set refuses the reserved key"
    true
    (Result.is_error (Sol_cli_secret.validate_key "SOL_ALLOW_PLAINTEXT_PEER_AUTH"))
;;

let%test "peer auth: a deployed render never carries the plaintext peer opt-in" =
  let _, workload = render_spec_ok svc_spec in
  check_bool
    "a deploy/GitOps render never carries the opt-in"
    false
    (Sol_cli_string.contains ~needle:"SOL_ALLOW_PLAINTEXT_PEER_AUTH" workload)
;;

let%test "peer auth: the local bare-process runner opts in explicitly" =
  check_bool
    "sol local sets the opt-in for bare processes"
    true
    (List.mem_assoc "SOL_ALLOW_PLAINTEXT_PEER_AUTH" Sol_cli_local_run.dev_env)
;;

let%test "workload identity: user config cannot spoof SOL_UNIT" =
  let _, workload =
    render_spec_ok { svc_spec with config = [ "SOL_UNIT", "spoofed/unit" ] }
  in
  let cm = extract_kind_block workload "kind: ConfigMap" in
  check_bool
    "the renderer's own unit wins"
    true
    (Sol_cli_string.contains ~needle:{|SOL_UNIT: "payments/charge-svc"|} cm);
  check_bool
    "the spoofed unit is dropped"
    false
    (Sol_cli_string.contains ~needle:"spoofed/unit" cm)
;;

let%test "workload identity: sol.toml cannot set SOL_UNIT" =
  toml_rejects_reserved_key ~key:"SOL_UNIT"
;;

let%test "workload identity: sol secret set refuses SOL_CALLED_BY" =
  check_bool
    "sol secret set refuses the projected key"
    true
    (Result.is_error (Sol_cli_secret.validate_key "SOL_CALLED_BY"))
;;

let%test "workload identity: target issuer is projected into svc config" =
  let _, workload =
    render_spec_ok
      { svc_spec with
        config =
          ( "SOL_TRUSTED_WORKLOAD_ISSUER"
          , "https://oidc.eks.us-east-1.amazonaws.com/id/cluster" )
          :: svc_spec.config
      }
  in
  check_bool
    "the trusted issuer is projected into the workload"
    true
    (Sol_cli_string.contains
       ~needle:
         {|SOL_TRUSTED_WORKLOAD_ISSUER: "https://oidc.eks.us-east-1.amazonaws.com/id/cluster"|}
       workload)
;;

let%test "workload identity: sol.toml cannot set the target issuer" =
  toml_rejects_reserved_key ~key:"SOL_TRUSTED_WORKLOAD_ISSUER"
;;

let%test "workload identity: sol secret set refuses the target issuer" =
  check_bool
    "sol secret set refuses the target-projected key"
    true
    (Result.is_error (Sol_cli_secret.validate_key "SOL_TRUSTED_WORKLOAD_ISSUER"))
;;

(* Deploy ordering depends on the renderer separating the objects that must exist
   before a pod starts (the ExternalSecret) from the objects that start pods. *)
let%test "bundle: the ExternalSecret is a prerequisite, not part of the workload" =
  let spec =
    { svc_spec with
      secrets = [ "PAYMENT_KEY", "" ]
    ; secret_sources =
        [ ( "PAYMENT_KEY"
          , Sol_cli_manifest.External { store = "payments-store"; key = "payment/key" } )
        ]
    }
  in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      spec
  with
  | Error message -> Windtrap.fail ("render_spec failed: " ^ message)
  | Ok bundle ->
    assert_contains
      "prerequisites carry the ExternalSecret"
      bundle.Sol_cli_manifest.prerequisites_yaml
      "kind: ExternalSecret";
    assert_contains
      "the workload document carries the Deployment"
      bundle.workload_yaml
      "kind: Deployment";
    assert_absent
      "the ExternalSecret is not applied with the workload"
      bundle.workload_yaml
      "kind: ExternalSecret";
    assert_absent
      "the Deployment is not applied with the prerequisites"
      bundle.prerequisites_yaml
      "kind: Deployment"
;;
