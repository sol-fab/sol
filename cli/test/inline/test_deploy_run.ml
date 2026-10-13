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

let quantity parse s =
  match parse s with
  | Ok q -> q
  | Error message -> Windtrap.fail message
;;

let spec ~domain ~name ~k8s primitive : Sol_cli_deployment_plan.service_spec =
  { domain
  ; source_name = name
  ; k8s_name = k8s_name k8s
  ; namespace = namespace ~domain
  ; primitive
  ; source_dir = "app/" ^ domain ^ "/" ^ name
  ; image = "registry.example.com/myapp/" ^ k8s ^ ":abc123"
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
  ; db_uses_target = None
  ; db_ca_target = None
  }
;;

(* The plan's own content id, computed from the services the way [of_services_result]
   does, so a release record built from this fixture rederives its id and validates. *)
let plan_release_id services =
  Sol_cli_release_id.of_content
    { workspace = "myapp"
    ; environment = None
    ; workloads = List.map Sol_cli_deployment_plan.release_workload_of_spec services
    ; contract = []
    }
;;

let plan ?profile services : Sol_cli_deployment_plan.t =
  { workspace = "myapp"
  ; environment =
      { name = "myapp"
      ; mode = Sol_cli_deployment_plan.Customer_cloud
      ; registry = "registry.example.com"
      ; image_tag = "abc123"
      ; env = None
      ; region = None
      ; base_domain = None
      ; cluster_issuer = "letsencrypt-prod"
      }
  ; services
  ; topics = []
  ; migrations = []
  ; schema_subjects = []
  ; consumer_groups = []
  ; release_id = plan_release_id services
  ; requested_scope = "workspace"
  ; platform_shape = Sol_cli_profile.Local
  ; profile
  ; contract = []
  ; contract_changes = []
  }
;;

let production : Sol_cli_deployment_plan.profile_claim =
  { profile = Sol_cli_profile.Production_single_region
  ; requirements = []
  ; application_findings = []
  }
;;

let temp_dir () =
  let dir = Filename.temp_file "sol-deploy-run-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let with_context ?(migrations = []) f =
  let root = temp_dir () in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir root;
       Out_channel.with_open_text "sol.yml" (fun oc ->
         output_string oc "project: myapp\n");
       Targets_fixture.write ~target:"dev/aws/us-east-1" "target:\n  cluster_name: c\n";
       if migrations <> []
       then (
         Unix.mkdir "db" 0o755;
         Unix.mkdir "db/migrations" 0o755;
         List.iter
           (fun name ->
              Out_channel.with_open_text (Filename.concat "db/migrations" name) (fun oc ->
                output_string oc "select 1;\n"))
           migrations);
       let config =
         match Sol_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
         | Ok config -> config
         | Error e -> Windtrap.fail (Sol_cli_config.error_to_string e)
       in
       let facts =
         match Sol_cli_workspace_model.load ~root with
         | Ok facts -> facts
         | Error e -> Windtrap.fail e
       in
       let ctx : Sol_cli_deploy_run.context =
         { execution =
             Sol_cli_execution.context
               ~cluster:Sol_cli_kube_destination.local_context
               ~workspace:"myapp"
               ()
         ; sha = "abc123"
         ; registry = "registry.example.com"
         ; facts
         ; emit_plan_to = None
         ; target_cfg = config.target
         ; resolved_config = config
         ; services = []
         ; inventory = []
         ; image_refs = []
         ; target_name = "dev/aws/us-east-1"
         ; run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"deploy" ()
         ; keep_releases = 5
         }
       in
       f ctx)
;;

let gate ctx ~plan ~live =
  Sol_cli_report.collect (fun () ->
    Sol_cli_deploy_run.migration_prerequisite ctx ~plan ~live)
;;

let reported = List.map snd

let test_no_profile_is_not_checked () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan []) ~live:true with
    | Ok (), [] -> ()
    | Ok (), lines ->
      Windtrap.failf "unexpected report: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Windtrap.fail "a deploy with no profile must not be gated")
;;

let test_offline_run_reports_not_verified () =
  with_context ~migrations:[ "001_init.sql" ] (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [ (_, line) ] ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"says NOT verified"
        true
        (Sol_cli_string.contains ~needle:"NOT verified" line)
    | Ok (), lines ->
      Windtrap.failf "expected one report, got: %s" (String.concat "; " (reported lines))
    | Error _, _ -> Windtrap.fail "an offline run must not fail the gate")
;;

let test_offline_run_without_migrations_says_nothing () =
  with_context (fun ctx ->
    match gate ctx ~plan:(plan ~profile:production []) ~live:false with
    | Ok (), [] -> ()
    | _ -> Windtrap.fail "no migrations: nothing to verify and nothing to say")
;;

let test_deploy_events_one_per_service () =
  with_context (fun ctx ->
    let events =
      Sol_cli_deploy_run.deploy_events
        ~workspace:"myapp"
        ~target_cfg:ctx.target_cfg
        (plan
           [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc
           ; spec ~domain:"comms" ~name:"notify_worker" ~k8s:"notify-worker" Worker
           ])
    in
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"service and primitive"
      [ "charge-svc", "svc"; "notify-worker", "worker" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.service, e.primitive) events);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the target's env"
      [ "dev"; "dev" ]
      (List.map (fun (e : Sol_cli_deploy_event.t) -> e.env) events))
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try In_channel.with_open_text path In_channel.input_all with
  | Sys_error _ -> ""
;;

let fake_kubectl ~dir ?live_listing () =
  let live_case =
    match live_listing with
    | None -> ""
    | Some json ->
      Printf.sprintf
        {|case " $* " in
  *" get deployment -n "*) printf '%%s' '%s' ;;
  *" get rollout -n "*) printf '%%s' '{"items":[]}' ;;
  *" get cronjob -n "*) printf '%%s' '{"items":[]}' ;;
esac
|}
        json
  in
  Printf.sprintf
    {|#!/bin/sh
echo "$*" >> %s/calls.log
name=""
file=""
previous=""
for a in "$@"; do
  if [ "$previous" = "-f" ]; then file="$a"; fi
  case "$a" in
    sol-boundary-lease-*|sol-deploy-state-*|sol-release-current-*|sol-release-r-*) name="$a" ;;
  esac
  previous="$a"
done
if [ -n "${SOL_FAKE_KUBECTL_FAIL_GET:-}" ]; then
  case " $* " in *" $SOL_FAKE_KUBECTL_FAIL_GET "*) printf 'Error from server (NotFound): not found\n' >&2; exit 1 ;; esac
fi
case " $* " in
  *" create "*)
    if [ -n "$file" ] && grep -q sol-boundary-lease "$file" 2>/dev/null; then
      sed 's/"metadata": {/"metadata": {"resourceVersion": "1",/' "$file" > %s/lease.json
    fi
    exit 0
    ;;
  *" replace "*)
    if [ -n "$file" ] && grep -q sol-boundary-lease "$file" 2>/dev/null; then
      cp "$file" %s/lease.json
    fi
    exit 0
    ;;
esac
case " $* " in
  *" get secret "*) printf '{"data":{"POSTGRES_URL":"postgres://user:pass@host/db","SOL_API_KEY":"test"}}'; exit 0 ;;
esac
case " $* " in
  *" get configmap sol-platform-network "*)
    printf 'Error from server (NotFound): configmaps "sol-platform-network" not found\n' >&2
    exit 1
    ;;
esac
%s
case "$name" in
  sol-boundary-lease-*)
    if [ -f %s/lease.json ]; then
      cat %s/lease.json
    else
      printf 'Error from server (NotFound): configmaps "lease" not found\n' >&2
      exit 1
    fi
    ;;
  sol-release-current-*)
    printf 'Error from server (NotFound): configmaps "current" not found\n' >&2
    exit 1
    ;;
  sol-release-r-*)
    printf 'Error from server (NotFound): configmaps "release" not found\n' >&2
    exit 1
    ;;
  sol-deploy-state-*) printf 'alpha\nbravo' ;;
esac
exit 0
|}
    dir
    dir
    dir
    live_case
    dir
    dir
;;

let with_fake_kubectl ?live_listing f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~dir ?live_listing ());
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" old_path)
    (fun () -> f ~calls:(fun () -> read_file (Filename.concat dir "calls.log")))
;;

(* A minimal scripted kubectl for a single behaviour under test, e.g. answering the
   per-object UID read the deploy warning makes. *)
let with_scripted_kubectl script f =
  let dir = Filename.temp_file "sol-scripted-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  write_file bin script;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

(* The warning is the deploy-path half of the ownership rule: a declared workload whose live
   object is not Sol-owned is named (object and both UIDs) and apply continues; the new
   release re-captures the live UID, so the mismatch is transient. *)
let test_deploy_warns_only_when_the_declared_workload_is_not_owned () =
  let spec =
    spec
      ~domain:"payments"
      ~name:"charge_svc"
      ~k8s:"charge-svc"
      Sol_cli_deployment_plan.Svc
  in
  let plan = plan [ spec ] in
  let reports_with ~evidence =
    let (), reported =
      Sol_cli_report.collect (fun () ->
        Sol_cli_deploy_run.warn_not_owned_declared
          ~cluster:Sol_cli_kube_destination.local_context
          ~evidence
          plan)
    in
    String.concat "\n" (List.map snd reported)
  in
  let recorded uid : Sol_cli_release_id.owned_object =
    { resource = "deployment"; namespace = "myapp-payments"; name = "charge-svc"; uid }
  in
  with_scripted_kubectl
    {|#!/bin/sh
case "$*" in
  *jsonpath*) printf '%s' 'live-uid' ;;
  *) printf '%s' '{}' ;;
esac
|}
    (fun () ->
       let mismatched = reports_with ~evidence:[ recorded "recorded-uid" ] in
       Windtrap.equal
         Windtrap.bool
         ~msg:"a mismatch names the object and both UIDs"
         true
         (Sol_cli_string.contains
            ~needle:"deployment myapp-payments/charge-svc"
            mismatched
          && Sol_cli_string.contains ~needle:"live-uid" mismatched
          && Sol_cli_string.contains ~needle:"recorded-uid" mismatched);
       let no_evidence = reports_with ~evidence:[] in
       Windtrap.equal
         Windtrap.bool
         ~msg:"no recorded UID is reported as such"
         true
         (Sol_cli_string.contains
            ~needle:"deployment myapp-payments/charge-svc"
            no_evidence
          && Sol_cli_string.contains ~needle:"recorded no UID" no_evidence);
       Windtrap.equal
         Windtrap.string
         ~msg:"an owned workload is not reported"
         ""
         (reports_with ~evidence:[ recorded "live-uid" ]))
;;

(* The deploy-path half of whole-target reconciliation: a workload the target no longer
   declares is removed only while the live UID equals the UID the superseded release
   recorded, and removal is deferred -- nothing removed, and said so -- when the live set
   cannot be observed. This drives the deploy's own [remove_surplus_workloads], not just
   the prune boundary. *)
let release_configmap_files ~dir ~evidence_plan ~owned =
  let release =
    Sol_cli_release.of_plan_with_boundary
      ~owned
      ~apply_mode:Sol_cli_release.Direct
      ~retained:[]
      evidence_plan
  in
  let current = Filename.concat dir "current-release.json" in
  let record = Filename.concat dir "release-record.json" in
  write_file current (Sol_cli_release.to_current_configmap_json release);
  write_file record (Sol_cli_release.to_configmap_json release);
  current, record
;;

let deployment_listing_item ~name ~namespace ~uid =
  Printf.sprintf
    {|{"kind":"Deployment","metadata":{"name":"%s","namespace":"%s","uid":"%s"},"spec":{"template":{"metadata":{"labels":{"workspace":"myapp"}}}}}|}
    name
    namespace
    uid
;;

let listing items = Printf.sprintf {|{"items":[%s]}|} (String.concat "," items)

let surplus_kubectl_script
      ~current
      ~record
      ~deployments
      ~deletes
      ?(listing_failure = None)
      ?(current_missing = false)
      ?(delete_fails_first = false)
      ?(charge_uid = "uid-recorded")
      ()
  =
  let current_case =
    if current_missing
    then
      "*\" get configmap sol-release-current-\"*) printf 'Error from server (NotFound): \
       configmaps \"current\" not found\\n' >&2; exit 1 ;;"
    else Printf.sprintf "*\" get configmap sol-release-current-\"*) cat %s ;;" current
  in
  let deployments_case =
    match listing_failure with
    | Some message ->
      Printf.sprintf
        "*\" get deployment -n \"*) printf '%%s\\n' '%s' >&2; exit 1 ;;"
        message
    | None -> Printf.sprintf "*\" get deployment -n \"*) cat %s ;;" deployments
  in
  let delete_case =
    if delete_fails_first
    then
      Printf.sprintf
        {|*" delete "*) if [ -f %s ]; then printf '%%s\n' "$*" >> %s ; else : > %s ; printf '%%s\n' 'Error from server: temporarily unavailable' >&2 ; exit 1 ; fi ;;|}
        (deletes ^ ".marker")
        deletes
        (deletes ^ ".marker")
    else Printf.sprintf {|*" delete "*) printf '%%s\n' "$*" >> %s ;;|} deletes
  in
  Printf.sprintf
    {|#!/bin/sh
case " $* " in
  %s
  *" get configmap sol-release-r-"*) cat %s ;;
  %s
  *" get rollout -n "*) printf '%%s' '{"items":[]}' ;;
  *" get cronjob -n "*) printf '%%s' '{"items":[]}' ;;
  *jsonpath=*)
    case " $* " in
      *" stale-svc "*) printf '%%s' 'uid-other' ;;
      *) printf '%%s' '%s' ;;
    esac ;;
  %s
  *) printf '%%s' '{}' ;;
esac
exit 0
|}
    current_case
    record
    deployments_case
    charge_uid
    delete_case
;;

let recorded_charge_svc uid : Sol_cli_release_id.owned_object =
  { resource = "deployment"; namespace = "myapp-payments"; name = "charge-svc"; uid }
;;

let recorded_svc name uid : Sol_cli_release_id.owned_object =
  { resource = "deployment"; namespace = "myapp-payments"; name; uid }
;;

let surplus_removal_outcome ~ctx plan =
  let outcome, reports =
    Sol_cli_report.collect (fun () ->
      Sol_cli_deploy_run.remove_surplus_workloads ctx plan)
  in
  outcome, String.concat "\n" (List.map snd reports)
;;

let check_removal_result ~msg expected outcome =
  Windtrap.equal (Windtrap.result Windtrap.unit Windtrap.string) ~msg expected outcome
;;

(* Removal succeeds: the UID-matched object and its auxiliary are removed, and the
   operation reports Ok so the caller may advance the release boundary. *)
let test_deploy_removes_only_the_uid_matched_surplus () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let evidence_plan =
      plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
    in
    let current, record =
      release_configmap_files
        ~dir
        ~evidence_plan
        ~owned:[ recorded_charge_svc "uid-recorded" ]
    in
    let deployments = Filename.concat dir "deployments.json" in
    write_file
      deployments
      (listing
         [ deployment_listing_item
             ~name:"charge-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-recorded"
         ; deployment_listing_item
             ~name:"stale-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-other"
         ]);
    let deletes = Filename.concat dir "deletes.log" in
    with_scripted_kubectl
      (surplus_kubectl_script ~current ~record ~deployments ~deletes ())
      (fun () ->
         let outcome, _ = surplus_removal_outcome ~ctx (plan []) in
         check_removal_result ~msg:"a complete removal returns Ok" (Ok ()) outcome;
         let log = read_file deletes in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the UID-matched surplus workload is removed"
           true
           (Sol_cli_string.contains
              ~needle:"delete deployment charge-svc -n myapp-payments"
              log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"its auxiliary follows the owning workload's match"
           true
           (Sol_cli_string.contains
              ~needle:"delete serviceaccount charge-svc -n myapp-payments"
              log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"a surplus workload with no matching recorded UID is retained"
           false
           (Sol_cli_string.contains ~needle:"stale-svc" log)))
;;

(* An unobservable live set is not a completed reconciliation: the operation errors, so
   the caller must not advance the release boundary past an object whose ownership Sol
   could not check. *)
let test_deploy_fails_when_the_live_set_is_unobservable () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let evidence_plan =
      plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
    in
    let current, record =
      release_configmap_files
        ~dir
        ~evidence_plan
        ~owned:[ recorded_charge_svc "uid-recorded" ]
    in
    let deletes = Filename.concat dir "deletes.log" in
    with_scripted_kubectl
      (surplus_kubectl_script
         ~current
         ~record
         ~deployments:""
         ~deletes
         ~listing_failure:(Some "Unable to connect to the server")
         ())
      (fun () ->
         let outcome, _ = surplus_removal_outcome ~ctx (plan []) in
         (match outcome with
          | Ok () -> Windtrap.fail "an unobservable live set must fail the reconciliation"
          | Error message ->
            Windtrap.equal
              Windtrap.bool
              ~msg:"the failure names the live set it could not observe"
              true
              (Sol_cli_string.contains ~needle:"could not be observed" message);
            Windtrap.equal
              Windtrap.bool
              ~msg:"the failure says the release boundary was left unchanged"
              true
              (Sol_cli_string.contains
                 ~needle:"release boundary was left unchanged"
                 message));
         Windtrap.equal
           Windtrap.string
           ~msg:"nothing is deleted when the live set cannot be observed"
           ""
           (read_file deletes)))
;;

(* A surplus object Sol cannot prove it owns is retained and reported, not a reconciliation
   failure: there is no recorded object left to authorize a removal, so nothing is lost by
   advancing. *)
let test_deploy_completes_when_surplus_is_not_provably_owned () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let evidence_plan =
      plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
    in
    let current, record =
      release_configmap_files
        ~dir
        ~evidence_plan
        ~owned:[ recorded_charge_svc "uid-recorded" ]
    in
    let deployments = Filename.concat dir "deployments.json" in
    write_file
      deployments
      (listing
         [ deployment_listing_item
             ~name:"charge-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-live-other"
         ; deployment_listing_item
             ~name:"stale-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-other"
         ]);
    let deletes = Filename.concat dir "deletes.log" in
    with_scripted_kubectl
      (surplus_kubectl_script
         ~current
         ~record
         ~deployments
         ~deletes
         ~charge_uid:"uid-live-other"
         ())
      (fun () ->
         let outcome, reports = surplus_removal_outcome ~ctx (plan []) in
         check_removal_result
           ~msg:"surplus Sol cannot prove it owns is retained, not fatal"
           (Ok ())
           outcome;
         let log = read_file deletes in
         Windtrap.equal
           Windtrap.bool
           ~msg:"a differing live UID is retained"
           false
           (Sol_cli_string.contains ~needle:"charge-svc" log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"no recorded UID is retained"
           false
           (Sol_cli_string.contains ~needle:"stale-svc" log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"both are reported for explicit adoption"
           true
           (Sol_cli_string.contains
              ~needle:"its live UID differs from the UID Sol recorded"
              reports
            && Sol_cli_string.contains ~needle:"Sol recorded no UID for it" reports)))
;;

(* A first deployment has no prior release to read and no boundary to preserve, so it must
   not fail merely because no recorded evidence exists. *)
let test_deploy_completes_on_a_first_deployment () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let deployments = Filename.concat dir "deployments.json" in
    write_file
      deployments
      (listing
         [ deployment_listing_item
             ~name:"stale-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-other"
         ]);
    let deletes = Filename.concat dir "deletes.log" in
    with_scripted_kubectl
      (surplus_kubectl_script
         ~current:""
         ~record:""
         ~deployments
         ~deletes
         ~current_missing:true
         ())
      (fun () ->
         let outcome, _ = surplus_removal_outcome ~ctx (plan []) in
         check_removal_result
           ~msg:"a first deployment with no prior evidence completes"
           (Ok ())
           outcome;
         Windtrap.equal
           Windtrap.string
           ~msg:"nothing is deleted without recorded ownership"
           ""
           (read_file deletes)))
;;

(* A partial prune failure errors, so the boundary is not advanced. A retry re-reads the
   same evidence, observes the objects that remain, and completes the removal. *)
let test_deploy_removal_is_retryable_after_a_partial_failure () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let evidence_plan =
      plan
        [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc
        ; spec ~domain:"payments" ~name:"stale_svc" ~k8s:"stale-svc" Svc
        ]
    in
    let current, record =
      release_configmap_files
        ~dir
        ~evidence_plan
        ~owned:
          [ recorded_svc "charge-svc" "uid-recorded"
          ; recorded_svc "stale-svc" "uid-other"
          ]
    in
    let deployments = Filename.concat dir "deployments.json" in
    write_file
      deployments
      (listing
         [ deployment_listing_item
             ~name:"charge-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-recorded"
         ; deployment_listing_item
             ~name:"stale-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-other"
         ]);
    let deletes = Filename.concat dir "deletes.log" in
    with_scripted_kubectl
      (surplus_kubectl_script
         ~current
         ~record
         ~deployments
         ~deletes
         ~delete_fails_first:true
         ())
      (fun () ->
         let first, _ = surplus_removal_outcome ~ctx (plan []) in
         (match first with
          | Ok () -> Windtrap.fail "a failed delete must fail the reconciliation"
          | Error message ->
            Windtrap.equal
              Windtrap.bool
              ~msg:"the failure names the unfinished removal"
              true
              (Sol_cli_string.contains ~needle:"surplus workload removal failed" message));
         let second, _ = surplus_removal_outcome ~ctx (plan []) in
         check_removal_result
           ~msg:"a retry with the same evidence completes the removal"
           (Ok ())
           second;
         let log = read_file deletes in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the retry removes the workload whose delete failed"
           true
           (Sol_cli_string.contains
              ~needle:"delete deployment charge-svc -n myapp-payments"
              log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"and the workload that was already removable"
           true
           (Sol_cli_string.contains
              ~needle:"delete deployment stale-svc -n myapp-payments"
              log)))
;;

(* The lifecycle half: an incomplete removal fails the deploy before the new release is
   recorded (report_success runs only after recording), so the superseded release stays
   authoritative and the next deploy retries with its recorded UID evidence. *)
let test_lifecycle_fails_before_recording_when_removal_is_incomplete () =
  with_fake_kubectl (fun ~calls:_ ->
    with_context (fun ctx ->
      let reported = ref false in
      let plan =
        plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
      in
      let outcome =
        Sol_cli_deploy_run.apply
          ctx
          ~present_plan:(fun _ -> Ok ())
          ~effective_access:(fun () -> Ok ())
          ~on_substrate_refused:(fun _ -> ())
          ~confirm_group_change:true
          ~push_events:(fun _ -> Windtrap.fail "an incomplete removal emitted events")
          ~report_success:(fun _ _ -> reported := true)
          plan
      in
      (match outcome with
       | Ok () -> Windtrap.fail "an incomplete removal must fail the deploy"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:
             (Printf.sprintf
                "the failure names the unobservable live set and the unchanged boundary \
                 [%s]"
                message)
           true
           (Sol_cli_string.contains ~needle:"could not be observed" message
            && Sol_cli_string.contains
                 ~needle:"release boundary was left unchanged"
                 message));
      Windtrap.equal
        Windtrap.bool
        ~msg:"the release was not recorded, so no success was reported"
        false
        !reported))
;;

(* The complementary lifecycle half: when the removal step completes, the deploy records
   the new release and reports success. *)
let test_lifecycle_advances_when_removal_completes () =
  with_fake_kubectl ~live_listing:{|{"items":[]}|} (fun ~calls:_ ->
    with_context (fun ctx ->
      let reported = ref false in
      let plan =
        plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
      in
      let outcome =
        Sol_cli_deploy_run.apply
          ctx
          ~present_plan:(fun _ -> Ok ())
          ~effective_access:(fun () -> Ok ())
          ~on_substrate_refused:(fun _ -> ())
          ~confirm_group_change:true
          ~push_events:(fun _ -> ())
          ~report_success:(fun _ _ -> reported := true)
          plan
      in
      check_removal_result
        ~msg:"a completed removal lets the whole-target deploy finish"
        (Ok ())
        outcome;
      Windtrap.equal
        Windtrap.bool
        ~msg:"the new release was recorded and reported"
        true
        !reported))
;;

let consumer_group_exn s =
  match Sol_cli_plan_ids.Consumer_group.of_string s with
  | Ok group -> group
  | Error message -> Windtrap.fail message
;;

let first_line_matching log needle =
  let lines = String.split_on_char '\n' log in
  let rec go index = function
    | [] -> None
    | line :: rest ->
      if Sol_cli_string.contains ~needle line then Some index else go (index + 1) rest
  in
  go 0 lines
;;

(* A lifecycle run whose plan drops a consumer group the record still names:
   [record_plan] runs, then the group guard refuses before apply. *)
let removed_group_lifecycle ~(ctx : Sol_cli_deploy_run.context) =
  let notify =
    spec
      ~domain:"comms"
      ~name:"notify_worker"
      ~k8s:"notify-worker"
      Sol_cli_deployment_plan.Worker
  in
  let plan =
    { (plan [ notify ]) with
      consumer_groups = [ consumer_group_exn "myapp.comms.notify_worker" ]
    }
  in
  Sol_cli_deploy_run.run_lifecycle
    ~cluster:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~run_log:ctx.run_log
    ~keep_releases:ctx.keep_releases
    ~confirm_group_change:false
    ~present_plan:(fun _ -> Ok ())
    ~gates:(fun _ -> Ok ())
    ~database_setup:(fun () -> Ok ())
    ~post_setup_gates:(fun _ -> Ok ())
    ~before_apply:(fun _ -> Ok ())
    ~apply:(fun ~lease:_ ~release_id:_ _ ->
      Windtrap.fail "a group the plan no longer carries must refuse before apply")
    ~report_success:(fun _ _ -> ())
    ~push_events:(fun ~release_id:_ _ -> ())
    plan
;;

let group_refusal outcome =
  match outcome with
  | Ok () ->
    Windtrap.fail
      "a record the plan no longer carries must refuse the deploy before it applies"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the refusal names the groups the plan no longer carries"
      true
      (Sol_cli_string.contains ~needle:"no longer present" message)
;;

(* Replacing the run's directory with a regular file makes an append fail with
   ENOTDIR, which no privilege bypasses, so this is not a permissions test. *)
let poison_run_log log =
  let dir = Sol_cli_run_log.dir log in
  ignore (Sol_cli_fs.remove_tree dir : (unit, string) result);
  Out_channel.with_open_text dir (fun oc -> output_string oc "not a directory")
;;

let test_the_group_check_reads_the_record_under_the_lease () =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let outcome = removed_group_lifecycle ~ctx in
      group_refusal outcome;
      let log = calls () in
      let lease_at = first_line_matching log "sol-boundary-lease-myapp" in
      let recorded_at = first_line_matching log "sol-deploy-state-myapp" in
      let contract_at = first_line_matching log "sol-release-current-myapp" in
      (match lease_at, contract_at, recorded_at with
       | Some lease_at, Some contract_at, Some recorded_at ->
         Windtrap.equal
           Windtrap.bool
           true
           (lease_at < contract_at && contract_at < recorded_at)
       | _ ->
         Windtrap.failf
           "contract observation must run under the lease before the group guard:\n%s"
           log);
      (match lease_at, recorded_at with
       | Some lease_at, Some recorded_at ->
         Windtrap.equal
           Windtrap.bool
           ~msg:
             "the record is read only after the lease boundary is written, so an update \
              that landed in between cannot be missed"
           true
           (lease_at < recorded_at)
       | None, _ -> Windtrap.failf "the deploy never took its boundary lease:\n%s" log
       | _, None -> Windtrap.failf "the recorded groups were never read:\n%s" log);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and nothing was applied, because the check refused first"
        false
        (Sol_cli_string.contains ~needle:" apply " log)))
;;

let test_an_unavailable_run_log_does_not_change_the_lifecycle_outcome () =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      poison_run_log ctx.run_log;
      let outcome, reports =
        Sol_cli_report.collect (fun () -> removed_group_lifecycle ~ctx)
      in
      group_refusal outcome;
      Windtrap.equal
        Windtrap.bool
        ~msg:"the unavailable log is reported"
        true
        (List.exists
           (fun (_, line) -> Sol_cli_string.contains ~needle:"run log unavailable" line)
           reports);
      let log = calls () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the lease is still released when the log is unavailable"
        true
        (Sol_cli_string.contains ~needle:" delete " log);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and nothing was applied"
        false
        (Sol_cli_string.contains ~needle:" apply " log)))
;;

let%test "migration gate (AUDIT-069): no profile" = test_no_profile_is_not_checked ()

let%test "migration gate (AUDIT-069): offline: not verified" =
  test_offline_run_reports_not_verified ()
;;

let%test "migration gate (AUDIT-069): offline: no migrations" =
  test_offline_run_without_migrations_says_nothing ()
;;

let%test "deploy events: one per service" = test_deploy_events_one_per_service ()

let%test "consumer-group guard (BUG-088): the record is read under the boundary lease" =
  test_the_group_check_reads_the_record_under_the_lease ()
;;

let%test "lifecycle: an unavailable run log does not change the outcome" =
  test_an_unavailable_run_log_does_not_change_the_lifecycle_outcome ()
;;

let%test
    "apply: a refused prerequisite gate releases the lease before any workload mutation"
  =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let outcome =
        Sol_cli_deploy_run.apply
          ctx
          ~present_plan:(fun _ -> Ok ())
          ~effective_access:(fun () -> Error "prerequisite refused")
          ~on_substrate_refused:(fun _ -> ())
          ~confirm_group_change:true
          ~push_events:(fun _ -> Windtrap.fail "a refused prerequisite emitted events")
          ~report_success:(fun _ _ ->
            Windtrap.fail "a refused prerequisite reported success")
          (plan [])
      in
      Windtrap.equal
        (Windtrap.result Windtrap.unit Windtrap.string)
        (Error "prerequisite refused")
        outcome;
      let log = calls () in
      Windtrap.equal Windtrap.bool false (Sol_cli_string.contains ~needle:" apply " log);
      Windtrap.equal Windtrap.bool true (Sol_cli_string.contains ~needle:" delete " log)))
;;

let%test "lifecycle: a refused gate releases the lease before apply" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let applied = ref false in
      let outcome =
        Sol_cli_deploy_run.run_lifecycle
          ~cluster:ctx.execution.cluster
          ~workspace:ctx.execution.workspace
          ~sha:ctx.sha
          ~run_log:ctx.run_log
          ~keep_releases:ctx.keep_releases
          ~confirm_group_change:true
          ~present_plan:(fun _ -> Ok ())
          ~gates:(fun _ -> Error "gate refused")
          ~database_setup:(fun () -> Ok ())
          ~post_setup_gates:(fun _ -> Ok ())
          ~before_apply:(fun _ -> Ok ())
          ~apply:(fun ~lease:_ ~release_id:_ _ ->
            applied := true;
            Ok [])
          ~report_success:(fun _ _ -> ())
          ~push_events:(fun ~release_id:_ _ -> ())
          (plan [])
      in
      Windtrap.equal
        (Windtrap.result Windtrap.unit Windtrap.string)
        (Error "gate refused")
        outcome;
      Windtrap.equal Windtrap.bool ~msg:"a refused gate must not apply" false !applied;
      let log = calls () in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the lease is released when the gate refuses"
        true
        (Sol_cli_string.contains ~needle:" delete " log)))
;;

let%test "lifecycle: presentation, gates and apply run in order under one lease" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      let order = ref [] in
      let note step = order := step :: !order in
      let outcome =
        Sol_cli_deploy_run.run_lifecycle
          ~cluster:ctx.execution.cluster
          ~workspace:ctx.execution.workspace
          ~sha:ctx.sha
          ~run_log:ctx.run_log
          ~keep_releases:ctx.keep_releases
          ~confirm_group_change:true
          ~present_plan:(fun _ ->
            note "present";
            Ok ())
          ~gates:(fun _ ->
            note "gates";
            Ok ())
          ~database_setup:(fun () ->
            note "database_setup";
            Ok ())
          ~post_setup_gates:(fun _ ->
            note "post_setup_gates";
            Ok ())
          ~before_apply:(fun _ ->
            note "before_apply";
            Ok ())
          ~apply:(fun ~lease:_ ~release_id:_ _ ->
            note "apply";
            Error "stop before recording")
          ~report_success:(fun _ _ -> ())
          ~push_events:(fun ~release_id:_ _ -> ())
          (plan [])
      in
      Windtrap.equal
        (Windtrap.result Windtrap.unit Windtrap.string)
        (Error "stop before recording")
        outcome;
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:
          "presentation, then gates, then database setup, then the post-setup gates, \
           then apply"
        [ "present"
        ; "gates"
        ; "database_setup"
        ; "post_setup_gates"
        ; "before_apply"
        ; "apply"
        ]
        (List.rev !order);
      let log = calls () in
      let lease_at = first_line_matching log "sol-boundary-lease-myapp" in
      let contract_at = first_line_matching log "sol-release-current-myapp" in
      match lease_at, contract_at with
      | Some lease_at, Some contract_at ->
        Windtrap.equal
          Windtrap.bool
          ~msg:"the prior contract is read under the lease"
          true
          (lease_at < contract_at)
      | _ -> Windtrap.failf "expected a lease and a prior-contract read:\n%s" log))
;;

let%test
    "ownership: a declared workload that is not Sol-owned is reported, then reconciled"
  =
  test_deploy_warns_only_when_the_declared_workload_is_not_owned ()
;;

let%test "removal: a surplus workload is removed only on its recorded UID match" =
  test_deploy_removes_only_the_uid_matched_surplus ()
;;

let%test "removal: an unobservable live set fails the reconciliation" =
  test_deploy_fails_when_the_live_set_is_unobservable ()
;;

let%test "removal: unowned surplus is retained and reconciliation completes" =
  test_deploy_completes_when_surplus_is_not_provably_owned ()
;;

let%test "removal: a first deployment needs no prior ownership evidence" =
  test_deploy_completes_on_a_first_deployment ()
;;

let%test "removal: a partial prune failure is retryable with the same evidence" =
  test_deploy_removal_is_retryable_after_a_partial_failure ()
;;

let%test "removal: an incomplete removal fails before the release is recorded" =
  test_lifecycle_fails_before_recording_when_removal_is_incomplete ()
;;

let%test "removal: a completed removal lets the release advance" =
  test_lifecycle_advances_when_removal_completes ()
;;

(* #4 end-to-end through the deploy's own [remove_surplus_workloads]: a unit that dropped
   its last external key is still declared, so its workload is not surplus, but its
   recorded ExternalSecret is pruned and the workload is left alone. *)
let test_deploy_prunes_an_external_secret_the_unit_no_longer_declares () =
  with_context (fun ctx ->
    let dir = temp_dir () in
    let declared =
      plan [ spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc ]
    in
    (* The superseded release still declared an external key, so its record attached the
       ExternalSecret's UID to the workload. The new plan declares the workload without
       one, so the ExternalSecret is an orphan while the workload is not surplus. *)
    let with_external_key =
      plan
        [ { (spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc) with
            secret_sources =
              [ ( "PAYMENT_KEY"
                , Sol_cli_manifest.External
                    { store = "payments-vault"; key = "payments/key" } )
              ]
          }
        ]
    in
    let owned =
      [ recorded_charge_svc "uid-recorded"
      ; { Sol_cli_release_id.resource = "externalsecret"
        ; namespace = "myapp-payments"
        ; name = "charge-svc-external-secrets"
        ; uid = "uid-recorded"
        }
      ]
    in
    let current, record =
      release_configmap_files ~dir ~evidence_plan:with_external_key ~owned
    in
    let deployments = Filename.concat dir "deployments.json" in
    write_file
      deployments
      (listing
         [ deployment_listing_item
             ~name:"charge-svc"
             ~namespace:"myapp-payments"
             ~uid:"uid-recorded"
         ]);
    let deletes = Filename.concat dir "deletes.log" in
    write_file deletes "";
    with_scripted_kubectl
      (surplus_kubectl_script ~current ~record ~deployments ~deletes ())
      (fun () ->
         let outcome, reports = surplus_removal_outcome ~ctx declared in
         check_removal_result
           ~msg:"pruning the orphaned ExternalSecret lets the release advance"
           (Ok ())
           outcome;
         let log = read_file deletes in
         Windtrap.equal
           Windtrap.bool
           ~msg:"the orphaned ExternalSecret is removed"
           true
           (Sol_cli_string.contains
              ~needle:
                "delete externalsecret charge-svc-external-secrets -n myapp-payments"
              log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the still-declared workload is not removed"
           false
           (Sol_cli_string.contains ~needle:"delete deployment" log);
         Windtrap.equal
           Windtrap.bool
           ~msg:"the removal is reported to the user"
           true
           (Sol_cli_string.contains
              ~needle:"Removed externalsecret myapp-payments/charge-svc-external-secrets"
              reports)))
;;

let%test "removal: an ExternalSecret the unit no longer declares is pruned" =
  test_deploy_prunes_an_external_secret_the_unit_no_longer_declares ()
;;

let%test "lifecycle: a failed apply does not report success" =
  with_fake_kubectl (fun ~calls:_ ->
    with_context (fun ctx ->
      let reported = ref false in
      let outcome =
        Sol_cli_deploy_run.run_lifecycle
          ~cluster:ctx.execution.cluster
          ~workspace:ctx.execution.workspace
          ~sha:ctx.sha
          ~run_log:ctx.run_log
          ~keep_releases:ctx.keep_releases
          ~confirm_group_change:true
          ~present_plan:(fun _ -> Ok ())
          ~gates:(fun _ -> Ok ())
          ~database_setup:(fun () -> Ok ())
          ~post_setup_gates:(fun _ -> Ok ())
          ~before_apply:(fun _ -> Ok ())
          ~apply:(fun ~lease:_ ~release_id:_ _ -> Error "apply failed")
          ~report_success:(fun _ _ -> reported := true)
          ~push_events:(fun ~release_id:_ _ -> ())
          (plan [])
      in
      Windtrap.equal
        (Windtrap.result Windtrap.unit Windtrap.string)
        (Error "apply failed")
        outcome;
      Windtrap.equal Windtrap.bool ~msg:"no success is reported" false !reported))
;;

(* The substrate prerequisite is a library operation an owner runs; its behaviour is
   asserted here rather than inferred from source positions. #1191. *)

let substrate_prerequisite ctx ~live services =
  Sol_cli_deploy_run.substrate_prerequisite ctx ~plan:(plan services) ~live
;;

let worker_plan =
  [ spec ~domain:"comms" ~name:"notify_worker" ~k8s:"notify-worker" Worker ]
;;

let%test "substrate_prerequisite: a profile-less live plan establishes its namespaces" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      match substrate_prerequisite ctx ~live:true worker_plan with
      | Ok () ->
        Windtrap.equal
          Windtrap.bool
          ~msg:"the live path creates the substrate documents for the plan's namespace"
          true
          (Sol_cli_string.contains ~needle:"create" (calls ()))
      | Error _ ->
        Windtrap.fail
          "a profile-less live plan must build its namespaces, not skip the substrate"))
;;

let%test "substrate_prerequisite: a side-effect-free run checks, never creates" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      match substrate_prerequisite ctx ~live:false worker_plan with
      | Ok () ->
        let log = calls () in
        Windtrap.equal
          Windtrap.bool
          ~msg:"it reads the namespace"
          true
          (Sol_cli_string.contains ~needle:"get namespace" log);
        Windtrap.equal
          Windtrap.bool
          ~msg:"it does not create anything"
          false
          (Sol_cli_string.contains ~needle:"create" log)
      | Error _ ->
        Windtrap.fail "an offline run must be able to check an established namespace"))
;;

let refusal_mentions ~fail_on needle =
  with_fake_kubectl (fun ~calls:_ ->
    with_context (fun ctx ->
      Fun.protect
        ~finally:(fun () -> Unix.putenv "SOL_FAKE_KUBECTL_FAIL_GET" "")
        (fun () ->
           Unix.putenv "SOL_FAKE_KUBECTL_FAIL_GET" fail_on;
           match substrate_prerequisite ctx ~live:false worker_plan with
           | Ok () -> Windtrap.failf "a %s that cannot be read must refuse" fail_on
           | Error (Sol_cli_deploy_run.Refused message) ->
             Windtrap.equal
               Windtrap.bool
               ~msg:("names " ^ fail_on)
               true
               (Sol_cli_string.contains ~needle message)
           | Error (Sol_cli_deploy_run.Failed _) ->
             Windtrap.fail "an unreadable prerequisite is a refusal, not a failure report")))
;;

let%test "substrate_prerequisite: an offline run checks the namespace and both bindings" =
  refusal_mentions ~fail_on:"namespace" "does not exist";
  refusal_mentions ~fail_on:"sol-deploy" "sol-deploy";
  refusal_mentions ~fail_on:"sol-operator" "sol-operator"
;;

let%test "substrate_prerequisite: an empty plan establishes nothing" =
  with_fake_kubectl (fun ~calls ->
    with_context (fun ctx ->
      match substrate_prerequisite ctx ~live:true [] with
      | Ok () -> Windtrap.equal Windtrap.string ~msg:"no kubectl call" "" (calls ())
      | Error _ -> Windtrap.fail "a plan with no namespaces has nothing to establish"))
;;

(* The invariant behind the ExternalSecret fix: every entry captured into [owned] must be
   attached to some workload in the release record, or it is silently dropped before the
   record is written and any prune that reads it is inert. *)
let test_captured_evidence_is_recorded () =
  let plan =
    plan
      [ { (spec ~domain:"payments" ~name:"charge_svc" ~k8s:"charge-svc" Svc) with
          secret_sources =
            [ ( "PAYMENT_KEY"
              , Sol_cli_manifest.External
                  { store = "payments-vault"; key = "payments/key" } )
            ]
        }
      ]
  in
  let owned =
    [ recorded_charge_svc "uid-recorded"
    ; { Sol_cli_release_id.resource = "externalsecret"
      ; namespace = "myapp-payments"
      ; name = "charge-svc-external-secrets"
      ; uid = "uid-2"
      }
    ]
  in
  let release =
    Sol_cli_release.of_plan_with_boundary
      ~owned
      ~apply_mode:Sol_cli_release.Direct
      ~retained:[]
      plan
  in
  let recorded =
    release.workloads
    |> List.concat_map (fun (w : Sol_cli_release_id.recorded_workload) -> w.owned)
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"every captured evidence entry is attached to a workload"
    (List.length owned)
    (List.length recorded)
;;

let%test "removal: a captured evidence entry is recorded with its workload" =
  test_captured_evidence_is_recorded ()
;;
