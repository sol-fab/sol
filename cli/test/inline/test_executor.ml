let ok = function
  | Ok r -> r
  | Error e -> Windtrap.fail e
;;

let release_id_of_test =
  Sol_cli_release_id.of_content
    { workspace = "test"; environment = None; workloads = []; contract = [] }
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

let svc_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = "sol-registry:5000/myapp/charge-svc:abc123"
  ; config = []
  ; secrets = []
  ; uses = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; schedule_timezone = None
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
  ; image = "sol-registry:5000/myapp/notify-worker:abc123"
  ; config = []
  ; secrets = []
  ; uses = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; schedule_timezone = None
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
  ; database = Sol_cli_resource_binding.No_postgres_use
  }
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let test_local_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  check_string "local namespace" "myapp-payments" r.namespace;
  check_string "local name" "charge-svc" r.name;
  check_string "local image" "sol-registry:5000/myapp/charge-svc:abc123" r.image
;;

let test_local_worker_result () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  check_string "local worker namespace" "myapp-comms" r.namespace;
  check_string "local worker name" "notify-worker" r.name
;;

let test_direct_result_fields () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      svc_spec
    |> ok
  in
  check_string "direct namespace" "myapp-payments" r.namespace;
  check_string "direct name" "charge-svc" r.name;
  check_string "direct image" "sol-registry:5000/myapp/charge-svc:abc123" r.image
;;

let test_direct_worker_result () =
  let r =
    Sol_cli_executor.local
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dry_run:true
      worker_spec
    |> ok
  in
  check_string "direct worker namespace" "myapp-comms" r.namespace;
  check_string "direct worker name" "notify-worker" r.name
;;

let test_gitops_result_fields () =
  let dir = Filename.temp_file "sol-gitops-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let r =
    Sol_cli_executor.gitops
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dir
      svc_spec
    |> ok
  in
  check_string "gitops namespace" "myapp-payments" r.namespace;
  check_string "gitops name" "charge-svc" r.name;
  check_string "gitops image" "sol-registry:5000/myapp/charge-svc:abc123" r.image;
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  (try Sys.remove path with
   | _ -> ());
  try Unix.rmdir dir with
  | _ -> ()
;;

let test_gitops_writes_file () =
  let dir = Filename.temp_file "sol-gitops-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  ignore
    (Sol_cli_executor.gitops
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~dir
       svc_spec);
  let path = Filename.concat dir "myapp-payments-charge-svc.yaml" in
  let exists = Sys.file_exists path in
  let content =
    if exists
    then (
      let ic = open_in path in
      let s = In_channel.input_all ic in
      close_in ic;
      s)
    else ""
  in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  Windtrap.equal Windtrap.bool ~msg:"gitops file created" true exists;
  Windtrap.equal
    Windtrap.bool
    ~msg:"gitops yaml has namespace"
    true
    (let needle = "name: myapp-payments" in
     let hl = String.length content
     and nl = String.length needle in
     let found = ref false in
     for i = 0 to hl - nl do
       if String.sub content i nl = needle then found := true
     done;
     !found)
;;

let test_gitops_worker () =
  let dir = Filename.temp_file "sol-gitops-worker-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let r =
    Sol_cli_executor.gitops
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~release_id:release_id_of_test
      ~dir
      worker_spec
    |> ok
  in
  let path = Filename.concat dir "myapp-comms-notify-worker.yaml" in
  let exists = Sys.file_exists path in
  (try Sys.remove path with
   | _ -> ());
  (try Unix.rmdir dir with
   | _ -> ());
  check_string "gitops worker namespace" "myapp-comms" r.namespace;
  check_string "gitops worker name" "notify-worker" r.name;
  Windtrap.equal Windtrap.bool ~msg:"gitops worker file created" true exists
;;

let read_file path =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  content
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let remove_dir dir name =
  (try Sys.remove (Filename.concat dir name) with
   | _ -> ());
  try Unix.rmdir dir with
  | _ -> ()
;;

let secretful_spec : Sol_cli_deployment_plan.service_spec =
  { svc_spec with secrets = [ "DATABASE_URL", ""; "API_KEY", "" ] }
;;

let emitted_name = "myapp-payments-charge-svc.yaml"

let test_gitops_preserves_external_secrets () =
  let dir = temp_dir "sol-gitops-eso-" in
  let spec =
    { secretful_spec with
      secret_sources =
        [ ( "DATABASE_URL"
          , Sol_cli_manifest.External { store = "probe-store"; key = "myapp/db" } )
        ; "API_KEY", Sol_cli_manifest.Sol_managed
        ]
    }
  in
  (match
     Sol_cli_executor.gitops
       ~ctx:Sol_cli_kube_destination.local_context
       ~workspace:"myapp"
       ~release_id:release_id_of_test
       ~dir
       spec
   with
   | Error e -> Windtrap.fail ("gitops emission failed: " ^ e)
   | Ok _ -> ());
  let content = read_file (Filename.concat dir emitted_name) in
  remove_dir dir emitted_name;
  Windtrap.equal
    Windtrap.bool
    ~msg:"An ExternalSecret is emitted, not a plain Secret"
    true
    (Sol_cli_string.contains ~needle:"kind: ExternalSecret" content);
  Windtrap.equal
    Windtrap.bool
    ~msg:"store reference preserved"
    true
    (Sol_cli_string.contains ~needle:"probe-store" content);
  Windtrap.equal
    Windtrap.bool
    ~msg:"remote key preserved"
    true
    (Sol_cli_string.contains ~needle:"key: myapp/db" content);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Sol key remains in its own Secret"
    true
    (Sol_cli_string.contains ~needle:"name: charge-svc-secrets" content);
  Windtrap.equal
    Windtrap.bool
    ~msg:"no plaintext Secret"
    false
    (Sol_cli_string.contains ~needle:"\nkind: Secret\n" content)
;;

let with_secretless_kubectl f =
  let dir = temp_dir "sol-executor-kubectl-" in
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "kubectl" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
verb=""
kind=""
next=0
for a in "$@"; do
  case "$a" in
    apply|create|patch) [ -z "$verb" ] && verb="$a" ;;
    get) [ -z "$verb" ] && verb="get" && next=1 ;;
    *) if [ "$next" = 1 ]; then kind="$a"; next=0; fi ;;
  esac
done
printf '%%s %%s\n' "$verb" "$kind" >> %s
if [ "$verb" = "get" ] && [ "$kind" = "secret" ]; then
  echo 'Error from server (NotFound): secrets "charge-svc-secrets" not found' >&2
  exit 1
fi
exit 0
|}
      log
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
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f ~calls:(fun () -> read_file log))
;;

let test_apply_fails_closed_when_the_workload_secret_is_absent () =
  with_secretless_kubectl (fun ~calls ->
    let outcome =
      Sol_cli_executor.local
        ~ctx:Sol_cli_kube_destination.local_context
        ~workspace:"myapp"
        ~release_id:release_id_of_test
        ~dry_run:false
        (* 2b: `POSTGRES_URL` is no longer a workload default, so this spec declares the
           required unit secret it is missing. The fail-closed check is unchanged. *)
        { svc_spec with secrets = [ "SOL_API_KEY", "" ] }
    in
    (match outcome with
     | Error message ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"names the missing required key"
         true
         (Sol_cli_string.contains ~needle:"SOL_API_KEY" message);
       Windtrap.equal
         Windtrap.bool
         ~msg:
           "directs application values to the operator and resource credentials to their \
            binding"
         true
         (Sol_cli_string.contains
            ~needle:"sol secret set <TARGET> <DOMAIN/UNIT/KEY>"
            message
          && Sol_cli_string.contains ~needle:"Resource-owned credentials" message)
     | Ok _ -> Windtrap.fail "apply must fail closed when the workload Secret is absent");
    Windtrap.equal
      Windtrap.bool
      ~msg:"no manifest was applied"
      false
      (Sol_cli_string.contains ~needle:"apply" (calls ())))
;;

let%test "local: result fields (svc)" = test_local_result_fields ()
let%test "local: result fields (worker)" = test_local_worker_result ()
let%test "direct: result fields (svc)" = test_direct_result_fields ()
let%test "direct: result fields (worker)" = test_direct_worker_result ()
let%test "gitops: result fields" = test_gitops_result_fields ()
let%test "gitops: file written" = test_gitops_writes_file ()
let%test "gitops: worker file written" = test_gitops_worker ()

let%test "gitops: external secrets preserved (BUG-081)" =
  test_gitops_preserves_external_secrets ()
;;

let%test "apply: fails closed before apply when the workload Secret is absent (BUG-054)" =
  test_apply_fails_closed_when_the_workload_secret_is_absent ()
;;
