let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
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

let service
      ?(name = "charge-svc")
      ?(primitive = Sol_cli_deployment_plan.Svc)
      ?progressive_delivery
      ()
  =
  { Sol_cli_deployment_plan.domain = "payments"
  ; source_name = name
  ; k8s_name = k8s_name name
  ; namespace =
      (match
         Sol_cli_deployment_plan.namespace_result ~workspace:"pluto" ~domain:"payments"
       with
       | Ok namespace -> namespace
       | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err))
  ; primitive
  ; source_dir = "payments/" ^ name
  ; image = "registry.sol.dev/acct_123/pluto/" ^ name ^ ":abc123"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DATABASE_URL", "postgres://secret" ]
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
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery
  ; db_ca_target = None
  }
;;

let hosted_plan ?progressive_delivery () =
  let env : Sol_cli_deployment_plan.env_config =
    { name = "production"
    ; mode = Sol_cli_deployment_plan.Sol_hosted
    ; registry = "registry.sol.dev/acct_123"
    ; image_tag = "abc123"
    ; env = Some "prod"
    ; region = Some "us-east-1"
    ; base_domain = Some "sol.example"
    ; cluster_issuer = "letsencrypt-prod"
    }
  in
  { Sol_cli_deployment_plan.workspace = "pluto"
  ; environment = env
  ; services =
      [ service ?progressive_delivery ()
      ; service ~name:"notify-worker" ~primitive:Sol_cli_deployment_plan.Worker ()
      ]
  ; topics =
      (match Sol_cli_plan_ids.Topic_name.of_string "charged" with
       | Ok t -> [ t ]
       | Error _ -> failwith "fixture: \"charged\" must be a valid topic name")
  ; migrations =
      (match Sol_cli_plan_ids.Migration_file.of_string "0001_notifications.sql" with
       | Ok m -> [ m ]
       | Error _ ->
         failwith "fixture: \"0001_notifications.sql\" must be a valid migration")
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

let image_refs : Sol_cli_release_inspection.image_ref list =
  [ { Sol_cli_release_inspection.service_name = "charge-svc"
    ; image = "ghcr.io/acme/charge@sha256:111"
    }
  ; { Sol_cli_release_inspection.service_name = "notify-worker"
    ; image = "ghcr.io/acme/notify@sha256:222"
    }
  ]
;;

let release_for plan =
  let services =
    List.map2
      (fun service (image_ref : Sol_cli_release_inspection.image_ref) ->
         Sol_cli_release_inspection.affected_service ~image:image_ref.image service)
      plan.Sol_cli_deployment_plan.services
      image_refs
  in
  Sol_cli_release_inspection.release_summary
    ~release_id:"rel_env-prod_abc123"
    ~environment_id:"env_prod"
    ~environment_name:"production"
    ~status:Sol_cli_release_inspection.Mock_submitted
    ~plan
    ~image_refs
    ~services
;;

let test_release_summary_json () =
  let plan = hosted_plan () in
  let release = release_for plan in
  let json = Sol_cli_release_inspection.release_summary_to_json release in
  let open Yojson.Safe.Util in
  check_string
    "release id"
    "rel_env-prod_abc123"
    (json |> member "release_id" |> to_string);
  check_string
    "mode"
    "sol_hosted"
    (json |> member "deployment_plan" |> member "mode" |> to_string);
  check_int
    "service count"
    2
    (json |> member "deployment_plan" |> member "service_count" |> to_int);
  check_string
    "rollout status default"
    "unknown"
    (json |> member "services" |> index 0 |> member "rollout_status" |> to_string);
  check_bool
    "secret values absent"
    false
    (Sol_cli_string.contains ~needle:"postgres://secret" (Yojson.Safe.to_string json))
;;

let test_rendered_manifest_diagnostics () =
  let progressive_delivery =
    Some
      (Sol_cli_toml.Canary { steps = [ Sol_cli_toml.Weight 10; Sol_cli_toml.Pause None ] })
  in
  let plan = hosted_plan ?progressive_delivery () in
  let manifests =
    match Sol_cli_release_inspection.rendered_manifests_of_plan plan with
    | Ok manifests -> manifests
    | Error msg -> Windtrap.fail msg
  in
  check_int "manifest count" 12 (List.length manifests);
  let rollout =
    List.find
      (fun (m : Sol_cli_release_inspection.rendered_manifest) ->
         m.name = "charge-svc" && m.kind = "Rollout")
      manifests
  in
  check_string "rollout kind" "Rollout" rollout.kind;
  check_bool
    "rollout carries env label"
    true
    (Sol_cli_string.contains ~needle:{|env: "prod"|} rollout.yaml);
  let ingress =
    List.find
      (fun (m : Sol_cli_release_inspection.rendered_manifest) ->
         m.name = "charge-svc" && m.kind = "Ingress")
      manifests
  in
  check_string "ingress kind" "Ingress" ingress.kind;
  let release = release_for plan in
  let event : Sol_cli_release_inspection.diagnostic_event =
    { source = "hosted-control-plane"
    ; reason = "Progressing"
    ; message = "rollout accepted by mock executor"
    ; severity = "info"
    }
  in
  let diagnostics =
    Sol_cli_release_inspection.diagnostics
      ~rendered_manifests:manifests
      ~reconciliation_events:[ event ]
      ~rollout_resources:[ "charge-svc" ]
      release
  in
  let json = Sol_cli_release_inspection.diagnostics_to_json diagnostics in
  let open Yojson.Safe.Util in
  check_string
    "rollout resource"
    "charge-svc"
    (json |> member "rollout_resources" |> index 0 |> to_string);
  check_string
    "event reason"
    "Progressing"
    (json |> member "reconciliation_events" |> index 0 |> member "reason" |> to_string)
;;

let%test "summary: release summary json" = test_release_summary_json ()
let%test "diagnostics: rendered manifests" = test_rendered_manifest_diagnostics ()
