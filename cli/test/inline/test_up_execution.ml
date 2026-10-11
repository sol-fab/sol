(* The local workload rollout adapter: a rollout that does not report success
   must fail with its own cause, and the live diagnosis is additional context,
   never a replacement. Tests drive a fake kubectl so the rollout status result
   and the diagnosis probes are independent. *)

let quantity parse s =
  match parse s with
  | Ok q -> q
  | Error message -> Windtrap.fail message
;;

let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace:"myapp" ~domain with
  | Ok namespace -> namespace
  | Error err -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~domain:"payments"
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
  ; cpu = quantity Sol_cli_toml.cpu_quantity_of_string "100m"
  ; memory = quantity Sol_cli_toml.memory_quantity_of_string "128Mi"
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

let exec =
  Sol_cli_up_execution.service_execution
    ~workspace:"myapp"
    ~ctx_dir:"/tmp/does-not-matter"
    ~sha:"abc123"
    spec
;;

let wait () =
  Sol_cli_up_execution.wait_for_service_rollout
    ~ctx:Sol_cli_kube_destination.local_context
    spec
    exec
;;

let healthy_pods_json =
  {|{"items":[{"metadata":{"name":"charge-svc-abc"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0,"image":"registry.example.com/myapp/charge-svc:abc123","state":{"running":{}}}]}}]}|}
;;

let crash_loop_pods_json =
  {|{"items":[{"metadata":{"name":"charge-svc-abc"},"status":{"phase":"Running","containerStatuses":[{"ready":false,"restartCount":6,"image":"registry.example.com/myapp/charge-svc:abc123","state":{"waiting":{"reason":"CrashLoopBackOff","message":null}},"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}]}|}
;;

(* The fake kubectl keeps the rollout status result independent of the diagnosis
   probes: rollout status succeeds only when SOL_FAKE_ROLLOUT_OK=1, otherwise it
   fails with SOL_FAKE_ROLLOUT_FAILURE; the pods are reported in the configured
   state and events are empty. *)
let fake_kubectl ~pods_json =
  Printf.sprintf
    {|#!/bin/sh
case " $* " in
  *" rollout status "*)
    if [ "${SOL_FAKE_ROLLOUT_OK:-0}" = "1" ]; then exit 0; fi
    printf '%%s\n' "${SOL_FAKE_ROLLOUT_FAILURE:-Error from server (Forbidden): deployments.apps \"charge-svc\" is forbidden}"
    exit 1
    ;;
  *" get pods "*)
    printf '%%s' '%s'
    exit 0
    ;;
  *" get events "*)
    printf '{"items":[]}'
    exit 0
    ;;
esac
exit 0
|}
    pods_json
;;

let write_file path contents =
  Out_channel.with_open_text path (fun oc -> output_string oc contents)
;;

let with_fake_kubectl ~pods_json f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~pods_json);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path) (fun () -> f ())
;;

let reports message needle =
  Windtrap.equal
    Windtrap.bool
    ~msg:(Printf.sprintf "the failure includes %S:\n%s" needle message)
    true
    (Sol_cli_string.contains ~needle message)
;;

let test_rollout_failure_keeps_its_cause_and_adds_healthy_diagnosis () =
  with_fake_kubectl ~pods_json:healthy_pods_json (fun () ->
    Unix.putenv "SOL_FAKE_ROLLOUT_OK" "0";
    Unix.putenv "SOL_FAKE_ROLLOUT_FAILURE" "error: timed out waiting for the condition";
    match wait () with
    | Ok () -> Windtrap.fail "a rollout that failed must not report success"
    | Error message ->
      reports message "did not succeed";
      reports message "timed out waiting for the condition";
      reports message "look healthy")
;;

let test_rollout_failure_keeps_its_cause_and_adds_unhealthy_diagnosis () =
  with_fake_kubectl ~pods_json:crash_loop_pods_json (fun () ->
    Unix.putenv "SOL_FAKE_ROLLOUT_OK" "0";
    Unix.putenv
      "SOL_FAKE_ROLLOUT_FAILURE"
      "Error from server (Forbidden): deployments.apps \"charge-svc\" is forbidden";
    match wait () with
    | Ok () -> Windtrap.fail "a rollout that failed must not report success"
    | Error message ->
      reports message "Forbidden";
      reports message "CrashLoopBackOff")
;;

let test_rollout_launch_failure_keeps_its_cause () =
  with_fake_kubectl ~pods_json:healthy_pods_json (fun () ->
    let old_path = Sys.getenv "PATH" in
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         (* With no kubectl reachable, both the rollout status and the diagnosis
            probes fail to launch. The rollout's own spawn failure must survive. *)
         Unix.putenv "PATH" "/nonexistent-sol-test-bin";
         match wait () with
         | Ok () -> Windtrap.fail "a rollout that could not run must not report success"
         | Error message ->
           reports message "spawn failed";
           reports message "could not determine"))
;;

let test_successful_rollout_is_ok () =
  with_fake_kubectl ~pods_json:healthy_pods_json (fun () ->
    Unix.putenv "SOL_FAKE_ROLLOUT_OK" "1";
    match wait () with
    | Ok () -> ()
    | Error message -> Windtrap.failf "a successful rollout must be Ok: %s" message)
;;

let%test "rollout: a failed rollout keeps its cause and healthy diagnosis as context" =
  test_rollout_failure_keeps_its_cause_and_adds_healthy_diagnosis ()
;;

let%test "rollout: a failed rollout keeps its cause and unhealthy diagnosis as context" =
  test_rollout_failure_keeps_its_cause_and_adds_unhealthy_diagnosis ()
;;

let%test "rollout: a launch failure keeps its original cause" =
  test_rollout_launch_failure_keeps_its_cause ()
;;

let%test "rollout: an explicit success is Ok" = test_successful_rollout_is_ok ()
