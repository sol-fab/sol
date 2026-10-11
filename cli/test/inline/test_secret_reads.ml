let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with
  | Sys_error _ -> ""
;;

let fake_kubectl ~log ~mode_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
kind=""
next_is_kind=0
next_is_ns=0
namespace=""
for a in "$@"; do
  if [ "$next_is_kind" = 1 ]; then kind="$a"; next_is_kind=0; fi
  if [ "$next_is_ns" = 1 ]; then namespace="$a"; next_is_ns=0; fi
  case "$a" in
    apply|patch|rollout|create) [ -z "$verb" ] && verb="$a" ;;
    get) [ -z "$verb" ] && verb="get" && next_is_kind=1 ;;
    -n) next_is_ns=1 ;;
  esac
done
resource_name=""
want_name=0
for a in "$@"; do
  case "$a" in
    -*) want_name=0 ;;
    externalsecret|externalsecrets|secret|secrets|deployment) want_name=1 ;;
    *) if [ "$want_name" = 1 ]; then resource_name="$a"; want_name=0; fi ;;
  esac
done
printf '%%s %%s\n' "$verb" "$kind" >> %s
if [ "$verb" = "rollout" ]; then printf 'rollout-args %%s\n' "$*" >> %s; exit 0; fi
mode=$(cat %s)
if [ "$verb" = "get" ]; then
  if [ "$mode" = "unreachable" ]; then
    echo 'Unable to connect to the server: net/http: TLS handshake timeout' >&2
    exit 1
  fi
  case "$kind" in
    externalsecret)
      if [ "$mode" = "eso-ready" ]; then
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        exit 0
      fi
      if [ "$mode" = "eso-no-synced-version" ]; then
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        exit 0
      fi
      if [ "$mode" = "eso-stale-version" ]; then
        printf '{"metadata":{"generation":3},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        exit 0
      fi
      if [ "$mode" = "phased-eso-ready" ] || [ "$mode" = "phased-eso-not-synced" ]; then
        state=True
        reason=SecretSynced
        if [ "$mode" = "phased-eso-not-synced" ]; then reason=SecretSyncedError; state=False; fi
        printf '{"metadata":{"name":"charge-svc-external-secrets","namespace":"payments","uid":"es-uid","generation":2,"labels":{"app.kubernetes.io/managed-by":"sol"}},"spec":{"target":{"name":"charge-svc-external-secrets"}},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"%%s","reason":"%%s"}]}}\n' "$state" "$reason"
        exit 0
      fi
      if [ "$mode" = "eso-not-synced" ] || [ "$mode" = "eso-wrong-keys" ]; then
        reason=SecretSynced
        state=True
        if [ "$mode" = "eso-not-synced" ]; then reason=SecretSyncedError; state=False; fi
        # A matching syncedResourceVersion, so this mode exercises the *key* check: without
        # one the freshness gate refuses first and the key check is unreachable.
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-1","conditions":[{"type":"Ready","status":"%%s","reason":"%%s"}]}}\n' "$state" "$reason"
      fi
      exit 0 ;;
    externalsecrets)
      if [ "$mode" = "platform-collision" ] && [ "$namespace" = "notifications" ]; then
        printf 'owner\tsol-secrets\n'
      fi
      exit 0 ;;
    secrets)
      if [ "$mode" = "listing-fails" ]; then
        echo 'Error from server (Forbidden): secrets is forbidden: cannot list resource "secrets"' >&2
        exit 1
      fi
      exit 0 ;;
    deployment)
      if [ "$mode" = "workloads-fail" ]; then
        echo 'Error from server (Forbidden): deployments.apps is forbidden: cannot list resource' >&2
        exit 1
      fi
      exit 0 ;;
    secret)
      if [ "$mode" = "phased-eso-ready" ] || [ "$mode" = "phased-eso-not-synced" ]; then
        case "$resource_name" in
          *-external-secrets)
            echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"charge-svc-external-secrets","namespace":"payments","resourceVersion":"1","ownerReferences":[{"uid":"es-uid"}]},"data":{"PAYMENT_KEY":"c2VjcmV0"}}' ;;
          *)
            echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"charge-svc-secrets","namespace":"payments","resourceVersion":"1","labels":{"app.kubernetes.io/managed-by":"sol"}},"data":{"POSTGRES_URL":"cG9zdGdyZXM6Ly9kYg==","SOL_API_KEY":"a2V5"}}' ;;
        esac
        exit 0
      fi
      if [ "$mode" = "eso-ready" ] || [ "$mode" = "eso-no-synced-version" ] || [ "$mode" = "eso-stale-version" ] || [ "$mode" = "eso-not-synced" ] || [ "$mode" = "eso-wrong-keys" ]; then
        if [ "$mode" = "eso-wrong-keys" ]; then
          echo '{"apiVersion":"v1","kind":"Secret","data":{"OTHER_KEY":"c2VjcmV0"}}'
        else
          echo '{"apiVersion":"v1","kind":"Secret","data":{"PAYMENT_KEY":"c2VjcmV0"}}'
        fi
        exit 0
      fi
      if [ "$mode" = "present" ] || [ "$mode" = "listing-fails" ] || [ "$mode" = "workloads-fail" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"sol-secrets","namespace":"payments","resourceVersion":"1"},"data":{"EXISTING":"ZXhpc3Rpbmc="}}'
        exit 0
      fi
      if [ "$mode" = "runtime-valid" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"sol-secrets","namespace":"payments","resourceVersion":"1"},"data":{"POSTGRES_URL":"cG9zdGdyZXM6Ly9kYiJ9"}}'
        exit 0
      fi
      if [ "$mode" = "owned-unit" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"charge-svc-secrets","namespace":"payments","resourceVersion":"1","labels":{"app.kubernetes.io/managed-by":"sol"}},"data":{"EXISTING":"ZXhpc3Rpbmc="}}'
        exit 0
      fi
      if [ "$mode" = "blank" ]; then
        echo '{"apiVersion":"v1","kind":"Secret","data":{"BLANK":""}}'
        exit 0
      fi
      echo 'Error from server (NotFound): secrets "sol-secrets" not found' >&2
      exit 1 ;;
    rollout)
      if [ "$mode" = "no-rollouts" ]; then
        echo 'error: the server doesn'"'"'t have a resource type "rollout"' >&2
        exit 1
      fi
      exit 0 ;;
    *) exit 0 ;;
  esac
fi
if [ "$verb" = "apply" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-f" ]; then cat "$a" >> %s.manifests; fi
    prev="$a"
  done
fi
exit 0
|}
    log
    log
    mode_file
    log
;;

let with_fake_kubectl ~mode f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let mode_file = Filename.concat dir "mode" in
  write_file mode_file mode;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~log ~mode_file);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      List.iter
        (fun f ->
           try Sys.remove f with
           | Sys_error _ -> ())
        [ bin; mode_file; log; log ^ ".manifests" ];
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       f
         ~calls:(fun () -> read_file log)
         ~manifests:(fun () -> read_file (log ^ ".manifests")))
;;

let ctx = Sol_cli_kube_destination.local_context
let namespaces = [ "payments" ]

let verify ?(secret_name = "charge-svc-secrets") ?(required_keys = [ "EXISTING" ]) mode =
  with_fake_kubectl ~mode (fun ~calls:_ ~manifests:_ ->
    Sol_cli_secret.verify_required_keys
      ~ctx
      ~namespace:"payments"
      ~secret_name
      ~required_keys)
;;

let test_verify_passes_when_required_keys_are_present () =
  match verify "present" with
  | Ok () -> ()
  | Error message -> Windtrap.fail ("expected verification to pass: " ^ message)
;;

let test_verify_names_the_missing_key () =
  match verify ~required_keys:[ "EXISTING"; "MISSING_KEY" ] "present" with
  | Ok () -> Windtrap.fail "a missing key must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the workload Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/charge-svc-secrets" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the missing key"
      true
      (Sol_cli_string.contains ~needle:"MISSING_KEY" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"does not name the key it found"
      false
      (Sol_cli_string.contains ~needle:"EXISTING" message)
;;

let test_verify_rejects_a_blank_value () =
  match verify ~required_keys:[ "BLANK" ] "blank" with
  | Ok () -> Windtrap.fail "an empty secret value must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the blank key"
      true
      (Sol_cli_string.contains ~needle:"BLANK" message)
;;

let test_verify_rejects_an_absent_secret () =
  match verify "missing" with
  | Ok () -> Windtrap.fail "an absent Secret must fail verification"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the secret"
      true
      (Sol_cli_string.contains ~needle:"charge-svc-secrets" message)
;;

let test_verify_runtime_secret_reads_the_substrate_secret () =
  match
    with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:"payments")
  with
  | Ok () ->
    Windtrap.fail "the substrate Secret lacks POSTGRES_URL; verification must fail"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the runtime Secret"
      true
      (Sol_cli_string.contains ~needle:"payments/sol-secrets" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the missing contract key"
      true
      (Sol_cli_string.contains ~needle:"POSTGRES_URL" message)
;;

let test_platform_set_writes_only_the_runtime_secret () =
  with_fake_kubectl ~mode:"present" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.set_platform_key
        ~ctx
        ~namespaces:[ "payments"; "orders" ]
        ~key:"POSTGRES_URL"
        ~value:"postgres://platform-db"
    with
    | Error message -> Windtrap.failf "platform secret set failed: %s" message
    | Ok _ ->
      let manifests = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the platform Secret is written"
        true
        (Sol_cli_string.contains ~needle:"name: sol-secrets" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"application Secrets are not written"
        false
        (Sol_cli_string.contains ~needle:"charge-svc-secrets" manifests))
;;

let test_platform_preflight_checks_all_namespaces_before_secret_writes () =
  with_fake_kubectl ~mode:"platform-collision" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.verify_platform_secret_destinations
        ~ctx
        ~namespaces:[ "payments"; "notifications" ]
    with
    | Ok () -> Windtrap.fail "an ExternalSecret collision must fail preflight"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the conflicting shared Secret"
        true
        (Sol_cli_string.contains
           ~needle:"ExternalSecret already targets this object"
           message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"preflight writes no shared Secret before discovering the collision"
        false
        (Sol_cli_string.contains ~needle:"kind: Secret" (manifests ())))
;;

let test_external_secret_status_reports_sync_and_materialized_keys () =
  with_fake_kubectl ~mode:"eso-ready" (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.external_secret_status
        ~ctx
        ~namespace:"payments"
        ~unit_name:"charge-svc"
        ~expected_keys:[ "PAYMENT_KEY" ]
    with
    | Error message -> Windtrap.failf "ESO status observation failed: %s" message
    | Ok state ->
      Windtrap.equal
        Windtrap.string
        ~msg:"reports synced state and last refresh without value"
        "ready (SecretSynced; refreshed 2026-10-10T12:00:00Z)"
        state)
;;

let external_workload_spec () : Sol_cli_deployment_plan.service_spec =
  let k8s_name =
    match Sol_cli_deployment_plan.k8s_name_result "charge-svc" with
    | Ok value -> value
    | Error error -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string error)
  in
  let namespace =
    match
      Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain:"payments"
    with
    | Ok value -> value
    | Error error -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string error)
  in
  let cpu =
    match Sol_cli_toml.cpu_quantity_of_string "100m" with
    | Ok value -> value
    | Error message -> Windtrap.fail message
  in
  let memory =
    match Sol_cli_toml.memory_quantity_of_string "128Mi" with
    | Ok value -> value
    | Error message -> Windtrap.fail message
  in
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name
  ; namespace
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "registry.example.com/myapp/charge-svc:test"
  ; config = []
  ; secrets = [ "PAYMENT_KEY", "" ]
  ; secret_sources =
      [ ( "PAYMENT_KEY"
        , Sol_cli_manifest.External { store = "payments-store"; key = "payment/key" } )
      ]
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = None
  ; cpu
  ; memory
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  ; db_ca_target = None
  }
;;

let test_external_secret_readiness_succeeds () =
  with_fake_kubectl ~mode:"eso-ready" (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.verify_external_secret_ready ~ctx (external_workload_spec ())
    with
    | Ok () -> ()
    | Error message -> Windtrap.failf "synced external Secret was rejected: %s" message)
;;

let test_external_secret_readiness_fails_closed mode expected_message =
  with_fake_kubectl ~mode (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.verify_external_secret_ready
        ~timeout_s:0.
        ~ctx
        (external_workload_spec ())
    with
    | Ok () -> Windtrap.failf "ESO state %s should fail readiness" mode
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("reports readiness failure for " ^ mode)
        true
        (Sol_cli_string.contains ~needle:expected_message message))
;;

(* syncedResourceVersion names the generation ESO processed, so a matching one is a
   verified sync and needs no warning. *)
let test_external_secret_readiness_verifies_the_generation () =
  with_fake_kubectl ~mode:"eso-ready" (fun ~calls:_ ~manifests:_ ->
    let result, reported =
      Sol_cli_report.collect (fun () ->
        Sol_cli_secret.verify_external_secret_ready ~ctx (external_workload_spec ()))
    in
    (match result with
     | Ok () -> ()
     | Error message -> Windtrap.failf "a generation-bound sync was rejected: %s" message);
    Windtrap.equal
      Windtrap.int
      ~msg:"a generation-bound sync needs no freshness warning"
      0
      (List.length reported))
;;

(* The signal is an ESO implementation detail, so its absence must degrade to
   Ready+SecretSynced with a warning — never a deploy failure. *)
(* "Unsupported" is not "fresh". Without a generation-bound version there is nothing that
   distinguishes this selection's sync from an earlier one's, so Ready alone would let a
   changed binding keep serving the previous database. *)
let test_external_secret_readiness_refuses_without_a_synced_version () =
  with_fake_kubectl ~mode:"eso-no-synced-version" (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.verify_external_secret_ready ~ctx (external_workload_spec ())
    with
    | Ok () -> Windtrap.fail "readiness without freshness evidence must refuse"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal says there is no evidence the sync belongs to this selection"
        true
        (Sol_cli_string.contains
           ~needle:"no evidence the sync belongs to this selection"
           message))
;;

(* A *known* mismatch: the published version has not reached the spec this selection asks
   for. Proceeding is how a changed binding quietly keeps serving the old database — the
   previous ExternalSecret still reports Ready and its Secret still carries the key. *)
let test_external_secret_readiness_refuses_when_the_generation_lags () =
  with_fake_kubectl ~mode:"eso-stale-version" (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.verify_external_secret_ready
        ~timeout_s:0.
        ~ctx
        (external_workload_spec ())
    with
    | Ok () -> Windtrap.fail "a lagging generation must refuse, not proceed"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the lagging generation"
        true
        (Sol_cli_string.contains ~needle:"has not reached generation" message))
;;

let test_unit_set_writes_only_its_unit_secret () =
  with_fake_kubectl ~mode:"owned-unit" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_secret.set_unit_key
        ~ctx
        ~namespace:"payments"
        ~secret_name:"charge-svc-secrets"
        ~key:"API_TOKEN"
        ~value:"unit-only"
    with
    | Error message -> Windtrap.failf "unit secret set failed: %s" message
    | Ok _ ->
      let manifests = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the selected unit Secret is written"
        true
        (Sol_cli_string.contains ~needle:"name: charge-svc-secrets" manifests);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the platform Secret is not written"
        false
        (Sol_cli_string.contains ~needle:"name: sol-secrets" manifests))
;;

let test_platform_readiness_requires_only_the_database_job_input () =
  match
    with_fake_kubectl ~mode:"runtime-valid" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:"payments")
  with
  | Ok () -> ()
  | Error message -> Windtrap.failf "valid platform Job input was rejected: %s" message
;;

let test_contract_readiness_names_missing_tls_job_input () =
  match
    with_fake_kubectl ~mode:"runtime-valid" (fun ~calls:_ ~manifests:_ ->
      Sol_cli_secret.verify_runtime_secret_keys
        ~ctx
        ~namespace:"payments"
        ~required_keys:[ "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ])
  with
  | Ok () ->
    Windtrap.fail "a runtime Secret without Kafka inputs passed contract readiness"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names both missing TLS inputs"
      true
      (Sol_cli_string.contains ~needle:"KAFKA_SASL_PASSWORD" message
       && Sol_cli_string.contains ~needle:"KAFKA_SSL_CA_CERT" message)
;;

let test_tls_contract_job_refuses_before_submission_without_platform_inputs () =
  with_fake_kubectl ~mode:"missing" (fun ~calls ~manifests:_ ->
    match
      Sol_cli_contract.reconcile_in_destination
        ~ctx
        ~platform_shape:Sol_cli_profile.Durable
        ~namespace:"payments"
        ~image:"contract-image"
    with
    | Ok () -> Windtrap.fail "TLS contract Job started without platform Kafka inputs"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the required Kafka platform values"
        true
        (Sol_cli_string.contains ~needle:"KAFKA_SASL_PASSWORD" message
         && Sol_cli_string.contains ~needle:"KAFKA_SSL_CA_CERT" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"does not submit a Job before the values are verified"
        false
        (Sol_cli_string.contains ~needle:"apply" (calls ())))
;;

let%test "verify: present required keys pass" =
  test_verify_passes_when_required_keys_are_present ()
;;

let%test "verify: a missing key fails and is named" = test_verify_names_the_missing_key ()
let%test "verify: a blank value fails" = test_verify_rejects_a_blank_value ()
let%test "verify: an absent Secret fails" = test_verify_rejects_an_absent_secret ()

let%test "verify: runtime Secret check reads the substrate Secret" =
  test_verify_runtime_secret_reads_the_substrate_secret ()
;;

let%test "scope: platform writes only the shared Job Secret" =
  test_platform_set_writes_only_the_runtime_secret ()
;;

let%test "scope: platform secret destinations preflight as a target" =
  test_platform_preflight_checks_all_namespaces_before_secret_writes ()
;;

let%test "scope: unit writes only the selected unit Secret" =
  test_unit_set_writes_only_its_unit_secret ()
;;

let%test "verify: platform readiness checks the database Job input" =
  test_platform_readiness_requires_only_the_database_job_input ()
;;

let%test "verify: TLS contract readiness checks both Kafka Job inputs" =
  test_contract_readiness_names_missing_tls_job_input ()
;;

let%test "verify: TLS contract Job requires platform inputs before submit" =
  test_tls_contract_job_refuses_before_submission_without_platform_inputs ()
;;

let%test "external Secret status reports readiness and keys" =
  test_external_secret_status_reports_sync_and_materialized_keys ()
;;

let%test "external Secret deploy readiness accepts exact synced key set" =
  test_external_secret_readiness_succeeds ()
;;

let%test "external Secret deploy readiness rejects unsynced ESO condition" =
  test_external_secret_readiness_fails_closed "eso-not-synced" "SecretSyncedError"
;;

let%test "external Secret deploy readiness rejects wrong materialized keys" =
  test_external_secret_readiness_fails_closed
    "eso-wrong-keys"
    "expected exactly [PAYMENT_KEY]"
;;

(* --- Deploy ordering: an external Secret is materialized before the workload that
   consumes it, and a not-synced ESO blocks the workload entirely. --- *)

let prerequisites_doc =
  "---\nkind: ExternalSecret\nmetadata:\n  name: charge-svc-external-secrets\n"
;;

let workload_doc = "---\nkind: Deployment\nmetadata:\n  name: charge-svc\n"
let namespace_doc = "---\nkind: Namespace\nmetadata:\n  name: payments\n"

let phased_bundle ~prerequisites ~workload =
  { Sol_cli_manifest.namespace_yaml = namespace_doc
  ; prerequisites_yaml = prerequisites
  ; workload_yaml = workload
  }
;;

let index_of_substring haystack needle =
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

let test_phased_apply_waits_for_the_external_secret_before_the_workload () =
  with_fake_kubectl ~mode:"phased-eso-ready" (fun ~calls ~manifests ->
    match
      Sol_cli_executor.apply_workload_phased
        ~ctx
        ~spec:(external_workload_spec ())
        ~bundle:(phased_bundle ~prerequisites:prerequisites_doc ~workload:workload_doc)
        ()
    with
    | Error message -> Windtrap.failf "synced external Secret deploy failed: %s" message
    | Ok () ->
      let applied = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the external Secret is applied before the workload"
        true
        (match
           ( index_of_substring applied "kind: ExternalSecret"
           , index_of_substring applied "kind: Deployment" )
         with
         | Some external_secret_at, Some workload_at -> external_secret_at < workload_at
         | _ -> false);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the namespace is created before any object is applied"
        true
        (match
           index_of_substring (calls ()) "create", index_of_substring (calls ()) "apply"
         with
         | Some created_at, Some applied_at -> created_at < applied_at
         | _ -> false))
;;

let test_phased_apply_blocks_the_workload_when_eso_is_not_synced () =
  with_fake_kubectl ~mode:"phased-eso-not-synced" (fun ~calls:_ ~manifests ->
    match
      Sol_cli_executor.apply_workload_phased
        ~eso_timeout_s:0.
        ~ctx
        ~spec:(external_workload_spec ())
        ~bundle:(phased_bundle ~prerequisites:prerequisites_doc ~workload:workload_doc)
        ()
    with
    | Ok () -> Windtrap.fail "a not-synced external Secret must block the workload apply"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"reports the ESO condition"
        true
        (Sol_cli_string.contains ~needle:"SecretSyncedError" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the workload is never applied"
        false
        (Sol_cli_string.contains ~needle:"kind: Deployment" (manifests ())))
;;

(* ESO's ExternalSecretStatusCondition has no observedGeneration, so a real
   Ready=True/SecretSynced condition must be accepted: requiring that field would fail
   every deploy with an external key against the real controller. *)
let test_external_secret_readiness_accepts_eso_without_observed_generation () =
  with_fake_kubectl ~mode:"eso-ready" (fun ~calls:_ ~manifests:_ ->
    match
      Sol_cli_secret.verify_external_secret_ready ~ctx (external_workload_spec ())
    with
    | Ok () -> ()
    | Error message ->
      Windtrap.failf
        "a Ready/SecretSynced condition without observedGeneration (the real ESO schema) \
         must be accepted: %s"
        message)
;;

let test_local_development_spec_forces_sol_managed () =
  let local = Sol_cli_executor.local_development_spec (external_workload_spec ()) in
  Windtrap.equal
    Windtrap.int
    ~msg:"local development carries no external secret source"
    0
    (List.length local.secret_sources);
  Windtrap.equal
    Windtrap.bool
    ~msg:"local development still sets the unverified-JWT escape hatch"
    true
    (List.mem_assoc "SOL_ALLOW_UNVERIFIED_JWT" local.config)
;;

let test_wait_for_workload_ready_skips_a_cronjob () =
  with_fake_kubectl ~mode:"present" (fun ~calls ~manifests:_ ->
    let fn =
      { (external_workload_spec ()) with
        primitive = Sol_cli_deployment_plan.Fn
      ; progressive_delivery = None
      }
    in
    match Sol_cli_executor.wait_for_workload_ready ~ctx ~spec:fn with
    | Error message ->
      Windtrap.failf "a CronJob must not be waited on as a rollout: %s" message
    | Ok () ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a CronJob is applied only, never waited on"
        false
        (Sol_cli_string.contains ~needle:"rollout" (calls ())))
;;

let test_wait_for_workload_ready_targets_a_deployment () =
  with_fake_kubectl ~mode:"present" (fun ~calls ~manifests:_ ->
    match
      Sol_cli_executor.wait_for_workload_ready ~ctx ~spec:(external_workload_spec ())
    with
    | Error message -> Windtrap.failf "a Deployment rollout wait failed: %s" message
    | Ok () ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"waits on the Deployment"
        true
        (Sol_cli_string.contains ~needle:"deployment/charge-svc" (calls ())))
;;

let test_wait_for_workload_ready_targets_a_rollout () =
  with_fake_kubectl ~mode:"present" (fun ~calls ~manifests:_ ->
    let progressive =
      { (external_workload_spec ()) with
        progressive_delivery = Some Sol_cli_toml.Blue_green
      }
    in
    match Sol_cli_executor.wait_for_workload_ready ~ctx ~spec:progressive with
    | Error message -> Windtrap.failf "a Rollout rollout wait failed: %s" message
    | Ok () ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"waits on the Argo Rollout, not a Deployment"
        true
        (Sol_cli_string.contains ~needle:"rollout/charge-svc" (calls ())))
;;

let%test "phased apply: external Secret materializes before the workload" =
  test_phased_apply_waits_for_the_external_secret_before_the_workload ()
;;

let%test "phased apply: a not-synced external Secret blocks the workload" =
  test_phased_apply_blocks_the_workload_when_eso_is_not_synced ()
;;

let%test "rollout: a CronJob is applied only" =
  test_wait_for_workload_ready_skips_a_cronjob ()
;;

let%test "rollout: a Deployment is waited on" =
  test_wait_for_workload_ready_targets_a_deployment ()
;;

let%test "rollout: an Argo Rollout is waited on" =
  test_wait_for_workload_ready_targets_a_rollout ()
;;

let%test
    "external Secret readiness accepts a real ESO condition without observedGeneration"
  =
  test_external_secret_readiness_accepts_eso_without_observed_generation ()
;;

let%test "local development forces every key to Sol-managed" =
  test_local_development_spec_forces_sol_managed ()
;;

let%test "external Secret readiness verifies the synced generation" =
  test_external_secret_readiness_verifies_the_generation ()
;;

let%test "external Secret readiness refuses when no synced version is published" =
  test_external_secret_readiness_refuses_without_a_synced_version ()
;;

let%test "external Secret readiness refuses when the generation lags" =
  test_external_secret_readiness_refuses_when_the_generation_lags ()
;;

(* The rollback path renders and applies the same bundle as a deploy: a release whose
   workload carries external refs must render its ExternalSecret into prerequisites, and
   [apply_workload_phased] must apply that ExternalSecret before the workload. This is the
   cross-PR invariant from #1342 exercised on the rollback path, so a future change that
   moved the ES out of prerequisites would break a rollback here. *)
let test_rollback_renders_and_applies_the_external_secret_first () =
  let spec = external_workload_spec () in
  let release_id =
    match Sol_cli_release_id.of_string "r-0123456789abcdef" with
    | Ok release_id -> release_id
    | Error message -> Windtrap.failf "invalid test release id: %s" message
  in
  let bundle =
    match Sol_cli_deployment_render.render_spec ~workspace:"myapp" ~release_id spec with
    | Ok bundle -> bundle
    | Error message -> Windtrap.failf "rollback render failed: %s" message
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a rollback renders the ExternalSecret as a prerequisite"
    true
    (Sol_cli_string.contains ~needle:"kind: ExternalSecret" bundle.prerequisites_yaml);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a rollback does not put the ExternalSecret in the workload"
    false
    (Sol_cli_string.contains ~needle:"kind: ExternalSecret" bundle.workload_yaml);
  with_fake_kubectl ~mode:"phased-eso-ready" (fun ~calls:_ ~manifests ->
    match Sol_cli_executor.apply_workload_phased ~ctx ~spec ~bundle () with
    | Error message -> Windtrap.failf "rollback apply failed: %s" message
    | Ok () ->
      let applied = manifests () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a rollback applies the ExternalSecret before the workload"
        true
        (match
           ( index_of_substring applied "kind: ExternalSecret"
           , index_of_substring applied "kind: Deployment" )
         with
         | Some external_secret_at, Some workload_at -> external_secret_at < workload_at
         | _ -> false))
;;

let%test "rollback: the ExternalSecret is a prerequisite applied before the workload" =
  test_rollback_renders_and_applies_the_external_secret_first ()
;;
