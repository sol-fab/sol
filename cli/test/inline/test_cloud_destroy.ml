open Sol_cli_cloud_destroy

let matches_regex re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let show_json_resources resources =
  Printf.sprintf {|{"values":{"root_module":{"resources":[%s]}}}|} resources
;;

let gcp_cluster =
  {|{"address":"google_container_cluster.main","type":"google_container_cluster","values":{"name":"c","deletion_protection":true,"self_link":"https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c","project":"sol-qualification","location":"us-central1"}}|}
;;

let gcp_binding_inside_the_cluster =
  {|{"address":"kubernetes_cluster_role_binding.provisioner_bootstrap_admin","type":"kubernetes_cluster_role_binding","values":{"metadata":[{"name":"sol-provisioner-bootstrap"}]}}|}
;;

let gcp_postgres_outside_the_cluster =
  {|{"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"name":"sol-postgres","deletion_protection":true}}|}
;;

let test_the_cluster_contents_are_classified () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"a kubernetes_ kind lives inside the cluster"
    true
    (in_cluster_kind "kubernetes_cluster_role_binding");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a helm_ kind lives inside the cluster"
    true
    (in_cluster_kind "helm_release");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a cloud object outside the cluster does not"
    false
    (in_cluster_kind "google_sql_database_instance")
;;

let test_empty_state () =
  let state = inventory_of_show_json {|{"values":{"root_module":{"resources":[]}}}|} in
  Windtrap.equal Windtrap.bool ~msg:"empty is a valid absence" true (state = State_empty);
  Windtrap.equal
    Windtrap.bool
    ~msg:"empty substrate is absent"
    true
    (substrate_presence state = Substrate_absent);
  Windtrap.equal (Windtrap.list Windtrap.string) ~msg:"no addresses" [] (addresses state)
;;

let test_missing_values_is_empty () =
  List.iter
    (fun json ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"absent values is a valid empty state"
         true
         (inventory_of_show_json json = State_empty))
    [ {|{}|}
    ; {|{"format_version":"1.0"}|}
    ; {|{"values":null}|}
    ; {|{"values":{"root_module":{}}}|}
    ]
;;

let test_represented_identity () =
  match inventory_of_show_json (show_json_resources gcp_cluster) with
  | State_represented [ resource ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"real address"
      "google_container_cluster.main"
      resource.address;
    Windtrap.equal Windtrap.string ~msg:"kind" "google_container_cluster" resource.kind;
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"the name Terraform recorded"
      (Some "c")
      resource.name;
    Windtrap.equal
      (Windtrap.option Windtrap.bool)
      ~msg:"deletion guard"
      (Some true)
      resource.deletion_protection
  | other ->
    Windtrap.failf
      "expected one represented resource, got %s"
      (match other with
       | State_empty -> "State_empty"
       | State_represented _ -> "State_represented"
       | State_unreadable message -> "State_unreadable " ^ message)
;;

let test_null_protection_is_not_an_error () =
  let json =
    show_json_resources
      {|{"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"deletion_protection":null}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Windtrap.equal
      (Windtrap.option Windtrap.bool)
      ~msg:"null guard reads as absent, not an error"
      None
      resource.deletion_protection
  | _ -> Windtrap.fail "expected a represented resource with a null guard"
;;

let test_child_module_address_preserved () =
  let json =
    {|{"values":{"root_module":{"resources":[],"child_modules":[{"address":"module.net","resources":[{"address":"module.net.google_compute_network.vpc","type":"google_compute_network","values":{"name":"vpc","self_link":"https://x/vpc","project":"p","region":"us-central1"}}]}]}}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"child-module address verbatim"
      "module.net.google_compute_network.vpc"
      resource.address;
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"its name, as Terraform recorded it"
      (Some "vpc")
      resource.name
  | _ -> Windtrap.fail "a child-module resource must be represented with its real address"
;;

let test_same_type_instances_are_distinct () =
  let json =
    show_json_resources
      {|{"address":"google_sql_database_instance.postgres","type":"google_sql_database_instance","values":{"deletion_protection":true}},{"address":"google_sql_database_instance.replica","type":"google_sql_database_instance","values":{"deletion_protection":false}}|}
  in
  match inventory_of_show_json json with
  | State_represented resources ->
    Windtrap.equal
      Windtrap.int
      ~msg:"both instances represented"
      2
      (List.length resources);
    let guard address =
      Option.bind (find_address (State_represented resources) address) (fun r ->
        r.deletion_protection)
    in
    Windtrap.equal
      (Windtrap.option Windtrap.bool)
      ~msg:"first instance keeps its own guard"
      (Some true)
      (guard "google_sql_database_instance.postgres");
    Windtrap.equal
      (Windtrap.option Windtrap.bool)
      ~msg:"second instance keeps its own guard"
      (Some false)
      (guard "google_sql_database_instance.replica")
  | _ -> Windtrap.fail "expected two represented resources"
;;

let test_unreadable_is_unknown () =
  List.iter
    (fun json ->
       match inventory_of_show_json json with
       | State_unreadable _ ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"unreadable is not absence"
           true
           (substrate_presence (inventory_of_show_json json) = Substrate_unknown)
       | State_empty | State_represented _ ->
         Windtrap.failf "expected UNKNOWN for %s" json)
    [ "not json at all"
    ; {|{"values":42}|}
    ; show_json_resources {|{"type":"google_container_cluster"}|}
    ; show_json_resources
        {|{"address":"x.y","type":"z","values":{"deletion_protection":"yes"}}|}
    ]
;;

let test_identifier_captured () =
  let json =
    show_json_resources
      {|{"address":"aws_db_instance.postgres","type":"aws_db_instance","values":{"identifier":"pluto-postgres","arn":"arn:aws:rds:eu-west-1:111122223333:db:pluto-postgres","skip_final_snapshot":true}}|}
  in
  match inventory_of_show_json json with
  | State_represented [ resource ] ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"the identifier is kept"
      (Some "pluto-postgres")
      resource.identifier;
    Windtrap.equal
      (Windtrap.option Windtrap.bool)
      ~msg:"retention state is kept"
      (Some true)
      resource.skip_final_snapshot
  | _ -> Windtrap.fail "expected a represented resource"
;;

type calls =
  { mutable credentials : int
  ; mutable init : int
  ; mutable observe : int
  ; mutable reconcile_absence : int
  ; mutable prepare : state_read list
  ; mutable outputs : int
  ; mutable reconcile : int
  ; mutable platform : int
  ; mutable remove : int
  ; mutable substrate : int
  ; mutable verify : int
  ; mutable reports : string list
  ; mutable order : string list
  }

let verified_observation =
  { Sol_cli_destroy_verification.state = State_absent
  ; sweep = Sweep_ran { residues = []; indeterminate = [] }
  ; retention = Retention_not_required "this fixture declares no retention"
  }
;;

let fake_deps
      ?(state = Ok {|{}|})
      ?state_after_reconciliation
      ?(outputs = Outputs_available)
      ?(prepare = fun ~state:_ -> Sol_cli_cloud_lifecycle.Nothing_to_prepare)
      ?(reconcile_provable_absence = fun () -> Ok Nothing_to_reconcile)
      ?(reconcile = fun () -> Ok ())
      ?(remove = fun () -> Ok ())
      ?(authority = None)
      ?(platform = fun () -> Ok ())
      ?(release_workloads = fun () -> Sol_cli_workload_scope.Workloads_released)
      ?(accept_unreleased = false)
      ?(destroy_substrate = fun () -> Ok ())
      ?(verify_destruction = fun ~pre_destroy:_ ~preparation:_ -> verified_observation)
      ()
  =
  let calls =
    { credentials = 0
    ; init = 0
    ; observe = 0
    ; reconcile_absence = 0
    ; prepare = []
    ; outputs = 0
    ; reconcile = 0
    ; platform = 0
    ; remove = 0
    ; substrate = 0
    ; verify = 0
    ; reports = []
    ; order = []
    }
  in
  let authority =
    match authority with
    | Some declared -> declared
    | None ->
      Mechanism
        { reconcile_and_enable =
            (fun () ->
              calls.reconcile <- calls.reconcile + 1;
              reconcile ())
        ; remove_elevated_access =
            (fun () ->
              calls.remove <- calls.remove + 1;
              remove ())
        }
  in
  let deps =
    { require_credentials =
        (fun () ->
          calls.credentials <- calls.credentials + 1;
          Ok ())
    ; terraform_init =
        (fun () ->
          calls.init <- calls.init + 1;
          Ok ())
    ; observe_state =
        (fun () ->
          calls.observe <- calls.observe + 1;
          match state_after_reconciliation with
          | Some next when calls.observe > 1 -> next
          | _ -> state)
    ; reconcile_provable_absence =
        (fun () ->
          calls.reconcile_absence <- calls.reconcile_absence + 1;
          match reconcile_provable_absence () with
          | Ok (Reconciled _ as reconciled) ->
            calls.order <- "reconcile-absence" :: calls.order;
            Ok reconciled
          | outcome -> outcome)
    ; cloud_outputs =
        (fun () ->
          calls.outputs <- calls.outputs + 1;
          outputs)
    ; prepare =
        (fun ~state ->
          calls.prepare <- state :: calls.prepare;
          prepare ~state)
    ; authority
    ; destroy_platform =
        (fun () ->
          calls.platform <- calls.platform + 1;
          platform ())
    ; observe_window_before = (fun () -> Ok ())
    ; verify_window_after = (fun () -> Ok ())
    ; release_workloads =
        (fun () ->
          calls.order <- "release" :: calls.order;
          release_workloads ())
    ; accept_unreleased
    ; destroy_substrate =
        (fun () ->
          calls.substrate <- calls.substrate + 1;
          calls.order <- "substrate" :: calls.order;
          destroy_substrate ())
    ; verify_destruction =
        (fun ~pre_destroy ~preparation ->
          calls.verify <- calls.verify + 1;
          verify_destruction ~pre_destroy ~preparation)
    ; report = (fun message -> calls.reports <- message :: calls.reports)
    ; warn = (fun _ -> ())
    }
  in
  deps, calls
;;

let test_empty_state_destroys_without_outputs () =
  let deps, calls =
    fake_deps ~state:(Ok {|{}|}) ~outputs:(Outputs_unavailable "no outputs") ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; cleanup; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"empty substrate is absent"
       true
       (substrate = Substrate_absent);
     Windtrap.equal
       Windtrap.bool
       ~msg:"no elevated access was opened"
       true
       (cleanup = Cleanup_not_needed)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "an empty, output-less target must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "an empty, output-less target must still destroy: %s"
       (failure_message failure));
  Windtrap.equal Windtrap.int ~msg:"substrate destroy ran" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"no reconciliation on an empty state" 0 calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"absence verified" 1 calls.verify
;;

let reconciliation =
  Reconciled
    { evidence = "GKE cluster sol-qual is absent (gcloud container clusters list)"
    ; forgotten =
        [ "module.platform.kubernetes_namespace.cert_manager"
        ; "module.platform.helm_release.redpanda"
        ]
    }
;;

let test_a_provably_absent_substrate_accounts_for_stale_state () =
  let deps, calls =
    fake_deps
      ~state:(Ok {|{}|})
      ~outputs:(Outputs_unavailable "no install outputs are published")
      ~reconcile_provable_absence:(fun () -> Ok reconciliation)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"a destroy that reconciled its stale state still exits 0"
    0
    (exit_code outcome);
  (match outcome with
   | Destroy_succeeded { degradations = []; _ } -> ()
   | Destroy_succeeded { degradations; _ } ->
     Windtrap.failf
       "a reconciliation is an act Sol completed, not a degradation (got %d)"
       (List.length degradations)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "the reconciliation must not block the destroy: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "a destroy whose stale state was reconciled must converge: %s"
       (failure_message failure));
  Windtrap.equal Windtrap.int ~msg:"the reconciliation ran once" 1 calls.reconcile_absence;
  let reported =
    List.exists
      (fun report ->
         matches_regex (Str.regexp_string "state entr") report
         && matches_regex (Str.regexp_string "sol-qual is absent") report
         && matches_regex
              (Str.regexp_string "module.platform.helm_release.redpanda")
              report
         && matches_regex
              (Str.regexp_string "module.platform.kubernetes_namespace.cert_manager")
              report)
      calls.reports
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the act names what it forgot and the evidence it was permitted on"
    true
    reported;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the reconciliation runs before the substrate is destroyed"
    [ "reconcile-absence"; "substrate" ]
    (List.rev calls.order)
;;

let test_a_failed_reconciliation_degrades_and_still_destroys () =
  let deps, calls =
    fake_deps
      ~state:(Ok {|{}|})
      ~outputs:(Outputs_unavailable "no install outputs are published")
      ~reconcile_provable_absence:(fun () -> Error "state rm refused")
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"Sol's own bookkeeping does not block the teardown it just performed"
    0
    (exit_code outcome);
  (match outcome with
   | Destroy_succeeded { degradations = [ degradation ]; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the unreconciled state is named"
       true
       (matches_regex (Str.regexp_string "state rm refused") degradation)
   | Destroy_succeeded { degradations; _ } ->
     Windtrap.failf "expected exactly one degradation, got %d" (List.length degradations)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "a failed reconciliation must not block the destroy: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "a failed reconciliation must not fail the teardown: %s"
       (failure_message failure));
  Windtrap.equal Windtrap.int ~msg:"the substrate was still destroyed" 1 calls.substrate
;;

let test_a_substrate_the_provider_lost_skips_what_must_reach_it () =
  let state_before =
    show_json_resources
      (String.concat
         ","
         [ gcp_cluster; gcp_binding_inside_the_cluster; gcp_postgres_outside_the_cluster ])
  in
  let state_after =
    show_json_resources (String.concat "," [ gcp_postgres_outside_the_cluster ])
  in
  let verified_pre_destroy = ref None in
  let deps, calls =
    fake_deps
      ~state:(Ok state_before)
      ~state_after_reconciliation:(Ok state_after)
      ~prepare:(fun ~state:_ -> Sol_cli_cloud_lifecycle.Nothing_to_prepare)
      ~reconcile_provable_absence:(fun () -> Ok reconciliation)
      ~verify_destruction:(fun ~pre_destroy ~preparation:_ ->
        verified_pre_destroy := Some pre_destroy;
        verified_observation)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"a destroy that reconciled a lost substrate still exits 0"
    0
    (exit_code outcome);
  (match outcome with
   | Destroy_succeeded { substrate; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the postgres instance still standing keeps the substrate represented"
       true
       (substrate = Substrate_present)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "a lost substrate must not block the destroy: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "a target whose substrate the provider lost must converge: %s"
       (failure_message failure));
  Windtrap.equal
    Windtrap.int
    ~msg:"the state is read again, because Terraform changed it"
    2
    calls.observe;
  Windtrap.equal
    Windtrap.bool
    ~msg:"no workload release is attempted against a cluster that does not exist"
    false
    (List.mem "release" calls.order);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the report says why the release does not apply"
    true
    (List.exists
       (fun report ->
          matches_regex (Str.regexp_string "no workload this target deployed") report)
       calls.reports);
  Windtrap.equal
    Windtrap.int
    ~msg:"the platform teardown has nothing to reach, so no outputs are read"
    0
    calls.outputs;
  Windtrap.equal
    Windtrap.bool
    ~msg:"the report says why the platform teardown is skipped"
    true
    (List.exists
       (fun report ->
          matches_regex (Str.regexp_string "nothing inside it can still exist") report)
       calls.reports);
  Windtrap.equal
    Windtrap.bool
    ~msg:"verification compares against what the state represents afterwards"
    true
    (match !verified_pre_destroy with
     | Some state -> state = inventory_of_show_json state_after
     | None -> false)
;;

let test_a_reconciled_state_that_cannot_be_reread_degrades () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~state_after_reconciliation:(Error "terraform show exited 1")
      ~outputs:(Outputs_unavailable "no install outputs are published")
      ~reconcile_provable_absence:(fun () -> Ok reconciliation)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"an unreadable state after the reconciliation is a degradation, not a refusal"
    0
    (exit_code outcome);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the degradation names what could not be re-read"
    true
    (match outcome with
     | Destroy_succeeded { degradations; _ } ->
       List.exists
         (fun degradation ->
            matches_regex (Str.regexp_string "could not be re-read") degradation)
         degradations
     | _ -> false);
  Windtrap.equal Windtrap.int ~msg:"the substrate teardown still ran" 1 calls.substrate
;;

let test_no_reconciliation_is_claimed_when_there_is_none () =
  let deps, calls =
    fake_deps
      ~state:(Ok {|{}|})
      ~outputs:(Outputs_unavailable "no install outputs are published")
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"the destroy converged" 0 (exit_code outcome);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a destroy with nothing to reconcile says nothing about reconciling"
    false
    (List.exists
       (fun report -> matches_regex (Str.regexp_string "state entr") report)
       calls.reports)
;;

let test_half_built_state_is_destroyable () =
  let state = show_json_resources gcp_cluster in
  let deps, calls =
    fake_deps ~state:(Ok state) ~outputs:(Outputs_unavailable "partial outputs") ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the subset is represented"
       true
       (substrate = Substrate_present)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "a half-built target must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "a half-built target must be destroyable: %s"
       (failure_message failure));
  Windtrap.equal Windtrap.int ~msg:"preparation ran once" 1 (List.length calls.prepare);
  Windtrap.equal
    Windtrap.bool
    ~msg:"preparation saw the represented state"
    true
    (match calls.prepare with
     | [ State_represented _ ] -> true
     | _ -> false);
  Windtrap.equal Windtrap.int ~msg:"substrate destroy ran" 1 calls.substrate
;;

let test_partial_outputs_never_refuse () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:(Outputs_unavailable "invalid GCP Terraform output JSON: expected object")
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"exit code is success" 0 (exit_code outcome);
  Windtrap.equal
    Windtrap.int
    ~msg:"the platform teardown was not wired from bad outputs"
    0
    calls.platform;
  Windtrap.equal Windtrap.int ~msg:"the substrate was still destroyed" 1 calls.substrate
;;

let test_state_read_failure_is_not_absence () =
  let deps, calls = fake_deps ~state:(Error "terraform show exited 1") () in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"UNKNOWN, not absent"
       true
       (substrate = Substrate_unknown)
   | Destroy_blocked { guarantee; _ } ->
     Windtrap.failf "an unreadable state must not be blocked: %s" guarantee
   | Destroy_failed { failure; _ } ->
     Windtrap.failf
       "an unreadable state must not block destruction: %s"
       (failure_message failure));
  Windtrap.equal Windtrap.int ~msg:"the destroy was still attempted" 1 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:"no constructive whole-root apply on an unreadable state"
    0
    calls.reconcile
;;

let test_elevated_access_opened_and_removed () =
  let deps, calls =
    fake_deps ~state:(Ok (show_json_resources gcp_cluster)) ~outputs:Outputs_available ()
  in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"access enabled" 1 calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"platform torn down under the access" 1 calls.platform;
  Windtrap.equal Windtrap.int ~msg:"access removed" 1 calls.remove;
  match outcome with
  | Destroy_succeeded { cleanup; _ } ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"cleanup recorded as succeeding"
      true
      (cleanup = Cleanup_succeeded)
  | Destroy_blocked { guarantee; _ } -> Windtrap.failf "unexpected block: %s" guarantee
  | Destroy_failed { failure; _ } ->
    Windtrap.failf "expected success: %s" (failure_message failure)
;;

let test_no_authority_mechanism_acquires_nothing () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:Outputs_available
      ~authority:(Some No_authority_required)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"no acquisition apply runs when the provider declares no mechanism"
    0
    calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"nothing is released afterwards" 0 calls.remove;
  Windtrap.equal Windtrap.int ~msg:"the platform teardown still runs" 1 calls.platform;
  Windtrap.equal
    Windtrap.bool
    ~msg:"no elevated access was ever opened, so none was cleaned up"
    true
    (List.exists
       (fun report ->
          matches_regex (Str.regexp_string "no temporary authority mechanism") report)
       calls.reports);
  match outcome with
  | Destroy_succeeded { cleanup; _ } ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"a mechanism-less teardown has nothing to clean up"
      true
      (cleanup = Cleanup_not_needed)
  | Destroy_blocked { guarantee; _ } -> Windtrap.failf "unexpected block: %s" guarantee
  | Destroy_failed { failure; _ } ->
    Windtrap.failf "expected success: %s" (failure_message failure)
;;

let test_no_authority_mechanism_still_reports_a_failed_teardown () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:Outputs_available
      ~authority:(Some No_authority_required)
      ~platform:(fun () -> Error "platform destroy refused")
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"no acquisition apply runs" 0 calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"no removal apply runs" 0 calls.remove;
  match outcome with
  | Destroy_failed { failure = Platform_destroy_failed message; cleanup; _ } ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the provider's refusal is the failure that is reported"
      true
      (matches_regex (Str.regexp_string "platform destroy refused") message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"no cleanup is claimed for access that was never opened"
      true
      (cleanup = Cleanup_not_needed)
  | Destroy_failed { failure; _ } ->
    Windtrap.failf "expected the teardown failure, got: %s" (failure_message failure)
  | Destroy_succeeded _ ->
    Windtrap.failf "a refused platform teardown must not report success"
  | Destroy_blocked { guarantee; _ } -> Windtrap.failf "unexpected block: %s" guarantee
;;

let test_protected_operation_failure_still_removes () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Ok ())
      ~platform:(fun () -> Error "platform destroy refused")
      ~remove:(fun () -> Ok ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Platform_destroy_failed message; cleanup; _ } ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the platform failure is reported"
       "platform destroy refused"
       message;
     Windtrap.equal
       Windtrap.bool
       ~msg:"the removal succeeded"
       true
       (cleanup = Cleanup_succeeded)
   | _ -> Windtrap.fail "expected a platform-destroy failure carrying its cleanup");
  Windtrap.equal
    Windtrap.int
    ~msg:"removal was attempted after the failure"
    1
    calls.remove
;;

let test_skipped_teardown_is_a_degradation () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Error "reconciliation apply failed")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ message ]; cleanup = Cleanup_succeeded; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the skipped teardown says what it was waiting on"
       true
       (matches_regex (Str.regexp_string "bootstrap authority") message)
   | _ -> Windtrap.fail "a failed reconciliation must degrade, not refuse the destroy");
  Windtrap.equal Windtrap.int ~msg:"the platform operation did not run" 0 calls.platform;
  Windtrap.equal Windtrap.int ~msg:"removal was still attempted" 1 calls.remove;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:"a degraded success exits 0 with a warning"
    exit_clean
    (exit_code outcome)
;;

let test_platform_failure_is_not_a_degradation () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~platform:(fun () -> Error "platform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed { failure = Platform_destroy_failed message; degradations = []; _ } ->
    Windtrap.equal
      Windtrap.string
      ~msg:"the platform failure stands"
      "platform destroy exited 1"
      message
  | _ -> Windtrap.fail "a failed protected operation is a failure, not a degradation"
;;

let test_skipped_teardown_and_cleanup_failure_are_both_preserved () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(fun () -> Error "no authority")
      ~remove:(fun () -> Error "cleanup refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations; cleanup = Cleanup_failed cleanup_message; _ } ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the removal failure is carried as cleanup evidence"
       "cleanup refused"
       cleanup_message;
     Windtrap.equal
       Windtrap.bool
       ~msg:"and as a degradation naming what it removed"
       true
       (List.exists
          (fun m ->
             matches_regex (Str.regexp_string "elevated access") m
             && matches_regex (Str.regexp_string "cleanup refused") m)
          degradations);
     Windtrap.equal
       Windtrap.bool
       ~msg:"and the skipped teardown is still there"
       true
       (List.exists
          (fun m -> matches_regex (Str.regexp_string "bootstrap authority") m)
          degradations)
   | _ ->
     Windtrap.fail
       "a cleanup failure the substrate deletes anyway must proceed, with every fact \
        preserved");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"and absence was still verified" 1 calls.verify;
  Windtrap.equal
    Windtrap.int
    ~msg:"so a verified absence exits 0"
    exit_clean
    (exit_code outcome)
;;

let test_cleanup_failure_does_not_decide_absence () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~remove:(fun () -> Error "terraform exited 1: access removal failed")
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues =
                  [ "the cluster is still listed by the provider, in state ERROR" ]
              ; indeterminate = []
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Verification_failed message; cleanup; degradations; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the absence check is what failed, not the cleanup"
       true
       (matches_regex (Str.regexp_string "still listed by the provider") message);
     Windtrap.equal
       Windtrap.bool
       ~msg:"the cleanup failure is preserved as evidence"
       true
       (match cleanup with
        | Cleanup_failed _ -> true
        | _ -> false);
     Windtrap.equal
       Windtrap.bool
       ~msg:"and as a degradation"
       true
       (List.exists
          (fun m -> matches_regex (Str.regexp_string "access removal failed") m)
          degradations)
   | _ -> Windtrap.fail "residue must fail the destroy however the cleanup went");
  Windtrap.equal
    Windtrap.int
    ~msg:"a destroy with residue exits 1"
    exit_failure
    (exit_code outcome);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and claims no absence"
    false
    (matches_regex
       (Str.regexp_string "reached verified absence")
       (completion_message outcome))
;;

let test_cleanup_failure_preserved_when_operation_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~platform:(fun () -> Error "platform destroy refused")
      ~remove:(fun () -> Error "removal refused too")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed
      { failure = Platform_destroy_failed _; cleanup = Cleanup_failed message; _ } ->
    Windtrap.equal
      Windtrap.string
      ~msg:"the cleanup failure is preserved"
      "removal refused too"
      message
  | _ -> Windtrap.fail "expected the platform failure with its cleanup evidence"
;;

let continue_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Continue_to_destroy }
;;

let block_failure reason =
  Sol_cli_cloud_lifecycle.Preparation_failed
    { reason; policy = Sol_cli_cloud_lifecycle.Block_destroy }
;;

let test_continue_preparation_failure_destroys () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { preparation = Nothing_prepared; degradations = [ message ]; _ }
     ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the preparation failure is preserved as evidence"
       "preparation: the deletion guards could not be lowered"
       message
   | _ ->
     Windtrap.fail
       "a Continue_to_destroy preparation failure must let destruction proceed, and stay \
        visible");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed" 1 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:"a degraded preparation with verified absence exits 0"
    exit_clean
    (exit_code outcome)
;;

let test_unremovable_elevated_access_does_not_immobilise_the_substrate () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered: replace refused")
      ~remove:(fun () -> Error "the binding could not be removed: replace refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { cleanup = Cleanup_failed message; degradations; _ } ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the unremoved binding stays visible as evidence"
       "the binding could not be removed: replace refused"
       message;
     Windtrap.equal
       Windtrap.bool
       ~msg:"and the run records it as a degradation"
       true
       (List.length degradations >= 1)
   | _ ->
     Windtrap.fail
       "a cleanup failure must not make the substrate immortal: the binding it removes \
        lives inside the cluster");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed anyway" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"and the absence check still ran" 1 calls.verify;
  Windtrap.equal
    Windtrap.int
    ~msg:"a verified absence exits 0"
    exit_clean
    (exit_code outcome)
;;

let test_an_unreadable_workload_listing_is_an_error () =
  Windtrap.equal
    (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
    ~msg:"a namespace with no workload of this workspace is empty, not an error"
    (Ok [])
    (Sol_cli_workload_scope.workloads_of_json {|{"items":[]}|} ~workspace:"pluto"
     |> Result.map (List.map Sol_cli_workload_scope.workload_to_string));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a listing that cannot be read is an error rather than an empty scope"
    true
    (match Sol_cli_workload_scope.workloads_of_json "not json" ~workspace:"pluto" with
     | Error _ -> true
     | Ok _ -> false)
;;

let test_the_workload_selection_reads_the_pod_template () =
  let listing =
    {|{"items":[
        {"kind":"Deployment","metadata":{"name":"charge-svc"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}},
        {"kind":"CronJob","metadata":{"name":"invoice-fn"},
         "spec":{"jobTemplate":{"spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}}}},
        {"kind":"Job","metadata":{"name":"invoice-fn-invoke"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}},
        {"kind":"Deployment","metadata":{"name":"someone-else"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"other"}}}}},
        {"kind":"Deployment","metadata":{"name":"unlabelled"},
         "spec":{"template":{"metadata":{}}}},
        {"kind":"Rollout","metadata":{"name":"progressive"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}},
        {"metadata":{"name":"no-kind-at-all"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}},
        {"kind":"Deployment","spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}}
      ]}|}
  in
  Windtrap.equal
    (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
    ~msg:
      "the workloads whose pod template belongs to this workspace, and only those — \
       including the progressive-delivery Rollout, which carries the ownership label on \
       the same pod template; an item that names no kind, or no name, is not a workload \
       this can remove"
    (Ok
       [ "cronjob/invoice-fn"
       ; "deployment/charge-svc"
       ; "job/invoice-fn-invoke"
       ; "rollout/progressive"
       ])
    (Sol_cli_workload_scope.workloads_of_json listing ~workspace:"pluto"
     |> Result.map (List.map Sol_cli_workload_scope.workload_to_string))
;;

let test_a_rollout_listing_is_read_from_its_pod_template () =
  let listing =
    {|{"items":[
        {"kind":"Rollout","metadata":{"name":"charge-svc"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"pluto","release":"r-1"}}}}},
        {"kind":"Rollout","metadata":{"name":"someone-else"},
         "spec":{"template":{"metadata":{"labels":{"workspace":"other"}}}}},
        {"kind":"Rollout","metadata":{"name":"labelled-on-the-object","labels":{"workspace":"pluto"}},
         "spec":{"template":{"metadata":{"labels":{}}}}}
      ]}|}
  in
  Windtrap.equal
    (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
    ~msg:
      "a service that opts into progressive delivery renders a Rollout, and its pods \
       carry the workspace label on spec.template.metadata.labels exactly where a \
       Deployment's do, so the release can find and remove it before the database is \
       dropped"
    (Ok [ "rollout/charge-svc" ])
    (Sol_cli_workload_scope.workloads_of_json listing ~workspace:"pluto"
     |> Result.map (List.map Sol_cli_workload_scope.workload_to_string))
;;

let test_the_label_is_read_from_the_template_not_the_object () =
  let listing =
    {|{"items":[
        {"kind":"Deployment",
         "metadata":{"name":"charge-svc","labels":{"workspace":"pluto"}},
         "spec":{"template":{"metadata":{"labels":{}}}}}
      ]}|}
  in
  Windtrap.equal
    (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
    ~msg:
      "a workload labelled on the object rather than on its pod template is not this \
       workspace's: Sol labels the template, and only the pods' labels can be awaited"
    (Ok [])
    (Sol_cli_workload_scope.workloads_of_json listing ~workspace:"pluto"
     |> Result.map (List.map Sol_cli_workload_scope.workload_to_string))
;;

(* Releasing a target removes a workload only while its live UID equals the UID the
   workspace recorded at apply; the workspace label that listed it is not proof. *)
let test_the_release_removes_only_proven_workloads () =
  let evidence =
    [ { Sol_cli_release_id.resource = "deployment"
      ; namespace = "pluto-payments"
      ; name = "charge-svc"
      ; uid = "uid-1"
      }
    ]
  in
  let workload resource name uid = { Sol_cli_workload_scope.resource; name; uid } in
  let scope =
    { Sol_cli_workload_scope.namespace = "pluto-payments"
    ; workloads =
        [ workload "deployment" "charge-svc" "uid-1" (* owned *)
        ; workload "deployment" "charge-svc-old" "uid-2" (* no evidence *)
        ; workload "cronjob" "invoice-fn" "" (* UID not observed *)
        ]
    }
  in
  let owned, retained = Sol_cli_workload_scope.partition_owned ~evidence scope in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only the exact recorded-UID match is removable"
    [ "deployment/charge-svc" ]
    (List.map Sol_cli_workload_scope.workload_to_string owned);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"a workload with no evidence, or none observed, is retained"
    [ "deployment/charge-svc-old"; "cronjob/invoice-fn" ]
    (List.map Sol_cli_workload_scope.workload_to_string retained)
;;

let test_the_workload_read_is_scoped_to_the_declared_namespace () =
  let reads =
    List.map
      (fun kind -> Sol_cli_workload_scope.list_args ~namespace:"pluto-payments" ~kind)
      Sol_cli_workload_scope.kinds
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.list Windtrap.string))
    ~msg:
      "each kind below is read on its own, in the declared namespace, so one kind the \
       cluster does not serve cannot fail the reads of the kinds it does, and nothing \
       reads cluster-wide"
    [ [ "get"; "deployment"; "-n"; "pluto-payments"; "--output"; "json" ]
    ; [ "get"; "cronjob"; "-n"; "pluto-payments"; "--output"; "json" ]
    ; [ "get"; "job"; "-n"; "pluto-payments"; "--output"; "json" ]
    ; [ "get"; "rollout"; "-n"; "pluto-payments"; "--output"; "json" ]
    ]
    reads;
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "no read is a multi-kind listing, which is what would fail whole where the \
       Rollouts custom resource is not served"
    true
    (List.for_all
       (fun args ->
          not (List.exists (fun arg -> Sol_cli_string.contains ~needle:"," arg) args))
       reads)
;;

let test_only_a_controller_installed_kind_may_read_as_absence () =
  let absence_is_expected =
    List.filter_map
      (fun kind ->
         match Sol_cli_workload_scope.list_args ~namespace:"pluto-payments" ~kind with
         | [ "get"; resource; "-n"; _; "--output"; "json" ]
           when Sol_cli_workload_scope.optional_kind kind -> Some resource
         | _ -> None)
      Sol_cli_workload_scope.kinds
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "only the kind a controller installs may read as absence; for the built-in kinds \
       the platform itself installs, an unreadable listing stays a failed release rather \
       than an empty scope"
    [ "rollout" ]
    absence_is_expected
;;

let cluster_refusal stderr =
  Sol_cli_process.Non_zero { exit_code = 1; stdout = ""; stderr }
;;

let unreachable_read =
  cluster_refusal "Unable to connect to the server: dial tcp 34.1.2.3:443: i/o timeout"
;;

let refused_read =
  cluster_refusal
    {|Error from server (Forbidden): deployments.apps is forbidden: User "sol-deploy" cannot list resource "deployments"|}
;;

let unserved_kind =
  cluster_refusal {|error: the server doesn't have a resource type "rollouts"|}
;;

let absent_namespace =
  cluster_refusal {|Error from server (NotFound): namespaces "pluto-payments" not found|}
;;

let workspace_deployment =
  {|{"items":[{"kind":"Deployment","metadata":{"name":"charge-svc"},
      "spec":{"template":{"metadata":{"labels":{"workspace":"pluto"}}}}}]}|}
;;

type cluster_replies =
  { mutable read : string list
  ; replies : (string * (string, Sol_cli_process.error) result) list
  }

let cluster_answering ?(replies = []) () = { read = []; replies }

let run_cluster cluster args =
  let resource = List.nth args 1 in
  cluster.read <- resource :: cluster.read;
  match List.assoc_opt resource cluster.replies with
  | Some reply -> reply
  | None -> Ok {|{"items":[]}|}
;;

(* The default probe answers "the namespace exists", so a test that exercises the namespaced
   reads keeps exercising them; `~namespace_probe` overrides it for the namespace-absence
   branch (sol-fab/sol#1491). *)
let read_cluster
      ?(namespace_probe = fun _ -> Sol_cli_workload_scope.Namespace_exists)
      ?(replies = [])
      namespaces
  =
  let cluster = cluster_answering ~replies () in
  let read =
    Sol_cli_workload_scope.read_workloads
      ~run:(run_cluster cluster)
      ~namespace_probe
      ~namespaces
      ~workspace:"pluto"
  in
  cluster, read
;;

let test_a_scope_with_no_declared_namespace_reads_nothing () =
  let cluster, read = read_cluster [] in
  (match read with
   | Ok { Sol_cli_workload_scope.scopes = []; _ } -> ()
   | Ok _ -> Windtrap.fail "no declared namespace is no scope"
   | Error _ ->
     Windtrap.fail
       "no declared namespace must not be a failed read: there is nothing to read");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "and it runs no kubectl at all, so a target with no services cannot be blocked by \
       a cluster it never needed"
    []
    cluster.read
;;

let test_an_unserved_kind_is_absence_not_a_failed_read () =
  let cluster, read =
    read_cluster ~replies:[ "rollout", Error unserved_kind ] [ "pluto-payments" ]
  in
  (match read with
   | Ok { Sol_cli_workload_scope.scopes = [ { workloads = []; _ } ]; _ } -> ()
   | Ok _ -> Windtrap.fail "a cluster that serves none of this workspace's workloads is "
   | Error _ ->
     Windtrap.fail
       "an unserved custom resource is absence of that kind, not a failed release: the \
        kinds the cluster does serve are still released");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"every kind is still read, one at a time"
    [ "cronjob"; "deployment"; "job"; "rollout" ]
    (List.sort String.compare cluster.read)
;;

let test_a_namespace_that_does_not_exist_holds_no_workload () =
  let replies =
    List.map
      (fun resource -> resource, Error absent_namespace)
      [ "deployment"; "cronjob"; "job"; "rollout" ]
  in
  let _, read = read_cluster ~replies [ "pluto-payments" ] in
  match read with
  | Ok { Sol_cli_workload_scope.scopes = [ { workloads = []; _ } ]; _ } -> ()
  | Ok _ ->
    Windtrap.fail "a declared namespace that does not exist has no workload of this one"
  | Error _ ->
    Windtrap.fail
      "a namespace that is not there is absence of that scope, not an unestablished \
       release: a target whose apply never created it must stay destructible"
;;

(* --- Namespace existence before the release (sol-fab/sol#1491) -------------------------

   The release precondition must be able to tell "the declared namespace does not exist, so
   no workload can be running" from "this identity may not look". The first is not
   applicable, the second keeps the refusal. These tests drive the decision, and they fail
   if the namespace-absence branch is removed: the absent cases would then fall through to
   the namespaced read and come back unestablished, exactly as AWS attempt 1 did. *)

let release_with
      ?(namespace_probe = fun _ -> Sol_cli_workload_scope.Namespace_exists)
      ?(replies = [])
      namespaces
  =
  let reads = ref [] in
  let deletes = ref [] in
  let cluster = cluster_answering ~replies () in
  let release, reported =
    Sol_cli_report.collect (fun () ->
      Sol_cli_workload_scope.release_workloads
        ~run:(fun args ->
          reads := !reads @ [ args ];
          run_cluster cluster args)
        ~namespace_probe
        ~delete:(fun ~namespace ~names ->
          deletes := !deletes @ [ namespace, names ];
          Ok ())
        ~wait:(fun ~namespace:_ -> Ok ())
        ~evidence:[]
        ~namespaces
        ~workspace:"pluto")
  in
  release, !reads, !deletes, reported
;;

let is_not_releasable = function
  | Sol_cli_workload_scope.Workloads_not_releasable reason -> Some reason
  | _ -> None
;;

let contains haystack needle = Sol_cli_string.contains ~needle haystack

let test_every_declared_namespace_absent_is_not_applicable () =
  let release, reads, deletes, _ =
    release_with
      ~namespace_probe:(fun _ -> Sol_cli_workload_scope.Namespace_absent)
      [ "pluto-payments"; "pluto-comms" ]
  in
  (match is_not_releasable release with
   | Some reason ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the reason names the declared namespaces that do not exist"
       true
       (contains reason "pluto-payments" && contains reason "pluto-comms")
   | None ->
     Windtrap.fail
       "a target whose declared namespaces do not exist has nothing to release: the \
        release is not applicable, and destruction must proceed without an override");
  Windtrap.equal
    Windtrap.int
    ~msg:"and no namespaced read is attempted, so no Forbidden answer can arise"
    0
    (List.length reads);
  Windtrap.equal Windtrap.int ~msg:"and nothing is deleted" 0 (List.length deletes)
;;

let test_a_target_with_no_declared_namespace_is_not_applicable () =
  let release, reads, _, _ = release_with [] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a target that declares no application namespace has no workload to release from"
    true
    (Option.is_some (is_not_releasable release));
  Windtrap.equal Windtrap.int ~msg:"and nothing is read" 0 (List.length reads)
;;

let test_an_absent_namespace_does_not_hide_a_present_one () =
  let probe = function
    | "pluto-comms" -> Sol_cli_workload_scope.Namespace_absent
    | _ -> Sol_cli_workload_scope.Namespace_exists
  in
  let release, reads, _, _ =
    release_with ~namespace_probe:probe [ "pluto-payments"; "pluto-comms" ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the release still applies to the namespace that exists"
    true
    (match release with
     | Sol_cli_workload_scope.Workloads_released -> true
     | _ -> false);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the existing namespace is read"
    true
    (List.exists (fun args -> List.mem "pluto-payments" args) reads);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the absent one is never read"
    true
    (List.for_all (fun args -> not (List.mem "pluto-comms" args)) reads)
;;

let test_a_partial_deployment_is_released_not_read_as_absent () =
  let release, reads, _, _ = release_with [ "pluto-payments" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "a namespace that exists with nothing deployed is released, never reported as a \
       namespace that does not exist"
    true
    (match release with
     | Sol_cli_workload_scope.Workloads_released -> true
     | _ -> false);
  Windtrap.equal
    Windtrap.int
    ~msg:"and its kinds are read, because a namespace that exists may hold a workload"
    4
    (List.length reads)
;;

let test_an_unestablishable_namespace_existence_is_unestablished () =
  let release, reads, _, _ =
    release_with
      ~namespace_probe:(fun _ ->
        Sol_cli_workload_scope.Namespace_unestablished
          "exited with code 1: Error from server (Forbidden): namespaces \
           \"pluto-payments\" is forbidden")
      [ "pluto-payments" ]
  in
  (match release with
   | Sol_cli_workload_scope.Workloads_unestablished
       { namespace = "pluto-payments"; kind = None; operation; reason } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the failure names the existence read as the operation"
       true
       (contains operation "namespace");
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it keeps the provider's own words"
       true
       (contains reason "Forbidden")
   | Sol_cli_workload_scope.Workloads_not_releasable _ ->
     Windtrap.fail
       "an existence read that was refused is not a namespace that does not exist"
   | _ ->
     Windtrap.fail
       "an existence read that cannot be established keeps the refusal, so the \
        operator's explicit override is still required");
  Windtrap.equal
    Windtrap.int
    ~msg:"and no namespaced read is attempted behind an unestablished namespace"
    0
    (List.length reads)
;;

(* One observation decides one namespace, and it decides once: the probe is counted and the
   namespaced reads are counted, so a re-ask or a fallback to a weaker read would show up here.
   Presence and absence stay different facts throughout: an inspected namespace is a scope with
   whatever it holds, and only a namespace that does not exist is absence. *)
let observations ?(replies = []) probe namespaces =
  let probes = ref []
  and reads = ref [] in
  let cluster = cluster_answering ~replies () in
  let read =
    Sol_cli_workload_scope.read_workloads
      ~run:(fun args ->
        reads := !reads @ [ args ];
        run_cluster cluster args)
      ~namespace_probe:(fun namespace ->
        probes := !probes @ [ namespace ];
        probe namespace)
      ~namespaces
      ~workspace:"pluto"
  in
  read, !probes, !reads
;;

let test_one_observation_decides_one_namespace () =
  let read, probes, reads =
    observations
      (fun _ -> Sol_cli_workload_scope.Namespace_exists)
      [ "pluto-payments"; "pluto-comms" ]
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"each declared namespace is observed exactly once, in order"
    [ "pluto-payments"; "pluto-comms" ]
    probes;
  Windtrap.equal
    Windtrap.int
    ~msg:"and an existing namespace is inspected, once per kind"
    8
    (List.length reads);
  (match read with
   | Ok { Sol_cli_workload_scope.scopes = [ _; _ ]; namespaces_absent = [] } -> ()
   | _ ->
     Windtrap.fail "two namespaces that exist are two inspected scopes, never absence");
  let _, probes, _ =
    observations (fun _ -> Sol_cli_workload_scope.Namespace_absent) [ "pluto-comms" ]
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"an absent namespace is observed once, and decides that namespace alone"
    [ "pluto-comms" ]
    probes
;;

let test_a_view_that_cannot_be_established_refuses_rather_than_falling_back () =
  let read, probes, reads =
    observations
      ~replies:[ "deployment", Error refused_read ]
      (fun _ ->
         Sol_cli_workload_scope.Namespace_unestablished
           "the lifecycle identity's namespace view could not be established (no cluster \
            access)")
      [ "pluto-payments" ]
  in
  (match read with
   | Error
       (Sol_cli_workload_scope.Read_unestablished { kind = None; operation; reason; _ })
     ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the failure names the existence observation"
       true
       (contains operation "namespace");
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it carries the view's own words"
       true
       (contains reason "could not be established")
   | Error _ ->
     Windtrap.fail "a view that cannot be established is an unestablished existence read"
   | Ok _ -> Windtrap.fail "a view that cannot be established is never absence");
  Windtrap.equal
    Windtrap.int
    ~msg:"and no weaker namespaced read is attempted behind it"
    0
    (List.length reads);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"which leaves the one observation as what decided"
    [ "pluto-payments" ]
    probes
;;

let test_absence_and_a_successful_inspection_are_different_facts () =
  let read, _, _ =
    observations (fun _ -> Sol_cli_workload_scope.Namespace_exists) [ "pluto-payments" ]
  in
  (match read with
   | Ok
       { Sol_cli_workload_scope.scopes =
           [ { Sol_cli_workload_scope.namespace = "pluto-payments"; workloads = [] } ]
       ; namespaces_absent = []
       } -> ()
   | Ok _ ->
     Windtrap.fail
       "a namespace that was inspected is a scope, never absence, even when it holds \
        nothing"
   | Error _ -> Windtrap.fail "an existing namespace is not a failed read");
  let read, _, _ =
    observations (fun _ -> Sol_cli_workload_scope.Namespace_absent) [ "pluto-payments" ]
  in
  match read with
  | Ok { Sol_cli_workload_scope.scopes = []; namespaces_absent = [ "pluto-payments" ] } ->
    ()
  | Ok _ ->
    Windtrap.fail
      "a namespace that does not exist is absence, and is never reported as an inspected \
       scope"
  | Error _ -> Windtrap.fail "a namespace that does not exist is not a failed read"
;;

let test_an_unreachable_cluster_probe_is_the_carve_out () =
  let release, _, _, _ =
    release_with
      ~namespace_probe:(fun _ ->
        Sol_cli_workload_scope.Namespace_unreachable
          "exited with code 1: Unable to connect to the server: dial tcp: i/o timeout")
      [ "pluto-payments" ]
  in
  match is_not_releasable release with
  | Some reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:
        "a cluster that cannot be reached is the documented carve-out, naming the cause"
      true
      (contains reason "could not be reached")
  | None ->
    Windtrap.fail
      "a cluster that cannot be reached is not an unestablished release that would \
       strand the target"
;;

let test_an_absent_namespace_never_masks_an_unreadable_one () =
  let probe = function
    | "pluto-comms" -> Sol_cli_workload_scope.Namespace_absent
    | _ -> Sol_cli_workload_scope.Namespace_unestablished "Error from server (Forbidden)"
  in
  let release, _, _, _ =
    release_with ~namespace_probe:probe [ "pluto-payments"; "pluto-comms" ]
  in
  match release with
  | Sol_cli_workload_scope.Workloads_unestablished { namespace = "pluto-payments"; _ } ->
    ()
  | Sol_cli_workload_scope.Workloads_not_releasable _ ->
    Windtrap.fail
      "one absent namespace must not make the release inapplicable while another \
       namespace could not be read"
  | _ -> Windtrap.fail "one unreadable namespace keeps the release unestablished"
;;

let test_a_live_cluster_that_refuses_a_read_is_unestablished () =
  let _, read =
    read_cluster ~replies:[ "deployment", Error refused_read ] [ "pluto-payments" ]
  in
  match read with
  | Error
      (Sol_cli_workload_scope.Read_unestablished
         { namespace = "pluto-payments"
         ; kind = Some "deployment"
         ; operation = "reading"
         ; reason
         }) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"and the reason keeps kubectl's own words"
      true
      (Sol_cli_string.contains ~needle:"Forbidden" reason)
  | Error (Sol_cli_workload_scope.Read_unestablished _) ->
    Windtrap.fail "the failure must name the namespace, the kind and the operation"
  | Error (Sol_cli_workload_scope.No_cluster _) ->
    Windtrap.fail
      "a cluster that answered and refused is not a cluster that cannot be reached"
  | Ok _ -> Windtrap.fail "a refused read is not absence"
;;

let test_a_listing_that_cannot_be_decoded_is_unestablished () =
  let _, read =
    read_cluster ~replies:[ "deployment", Ok "not json" ] [ "pluto-payments" ]
  in
  match read with
  | Error
      (Sol_cli_workload_scope.Read_unestablished
         { kind = Some "deployment"; operation = "reading"; reason; _ }) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the decode failure is carried rather than read as an empty scope"
      true
      (reason <> "")
  | _ -> Windtrap.fail "a listing that cannot be read is an unestablished release"
;;

let test_an_unreachable_cluster_is_not_a_failed_release () =
  let replies =
    List.map
      (fun resource -> resource, Error unreachable_read)
      [ "deployment"; "cronjob"; "job"; "rollout" ]
  in
  let cluster, read = read_cluster ~replies [ "pluto-payments" ] in
  (match read with
   | Error (Sol_cli_workload_scope.No_cluster reason) ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the carve-out names what could not be reached"
       true
       (Sol_cli_string.contains ~needle:"could not be reached" reason)
   | Error (Sol_cli_workload_scope.Read_unestablished _) ->
     Windtrap.fail
       "a cluster that could not be reached at all is the carve-out, not an \
        unestablished release that would strand the target"
   | Ok _ -> Windtrap.fail "an unreachable cluster is not absence");
  Windtrap.equal
    Windtrap.int
    ~msg:"and the read stops at the first kind rather than failing every kind in turn"
    1
    (List.length cluster.read)
;;

let test_a_cluster_that_answered_then_went_away_is_unestablished () =
  let replies =
    [ "deployment", Ok workspace_deployment; "cronjob", Error unreachable_read ]
  in
  let _, read = read_cluster ~replies [ "pluto-payments" ] in
  match read with
  | Error
      (Sol_cli_workload_scope.Read_unestablished
         { kind = Some "cronjob"; operation = "reading"; _ }) -> ()
  | Error (Sol_cli_workload_scope.No_cluster _) ->
    Windtrap.fail
      "once the cluster has answered and a workload was found, losing it is an \
       unestablished release: the fail-closed direction, recoverable by re-running"
  | _ ->
    Windtrap.fail "a cluster that answered and then went away is an unestablished release"
;;

let test_the_removal_names_the_workloads_and_waits () =
  let args =
    Sol_cli_workload_scope.delete_args
      ~namespace:"pluto-payments"
      ~names:[ "deployment/charge-svc"; "cronjob/notify-worker" ]
      ~timeout_seconds:300
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "the removal names the workloads it found rather than selecting them, because the \
       objects carry no ownership label of their own"
    true
    (List.mem "deployment/charge-svc" args
     && List.mem "cronjob/notify-worker" args
     && not (List.exists (fun arg -> arg = "--selector") args));
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "and a workload that is already gone is a satisfied removal, not a failed one: an \
       object that vanishes between the read and the removal must not stop a teardown"
    true
    (List.exists (fun arg -> arg = "--ignore-not-found") args);
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "the removal waits and is bounded, so the sessions are closed before the database \
       is touched but a stuck removal cannot hang the teardown forever"
    true
    (List.exists (fun arg -> arg = "--wait=true") args
     && List.exists (fun arg -> Sol_cli_string.contains ~needle:"--timeout=" arg) args);
  let waiting =
    Sol_cli_workload_scope.wait_args
      ~namespace:"pluto-payments"
      ~workspace:"pluto"
      ~timeout_seconds:300
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "the pods the ownership label Sol renders selects are awaited, so their database \
       sessions are gone, and that wait is bounded too"
    true
    (List.exists (fun arg -> arg = "pod") waiting
     && List.exists (fun arg -> arg = "--for=delete") waiting
     && List.exists (fun arg -> arg = "workspace=pluto") waiting
     && List.exists (fun arg -> Sol_cli_string.contains ~needle:"--timeout=" arg) waiting
    )
;;

let test_the_workloads_are_released_before_the_substrate_is_destroyed () =
  let deps, calls = fake_deps ~state:(Ok (show_json_resources gcp_cluster)) () in
  ignore (execute ~deps);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the workloads that hold the managed database's sessions are released first"
    [ "release"; "substrate" ]
    (List.rev calls.order)
;;

let test_a_target_with_no_substrate_has_no_release_to_run () =
  let deps, calls = fake_deps ~state:(Ok {|{}|}) () in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = []; _ } -> ()
   | Destroy_succeeded _ ->
     Windtrap.fail
       "a target whose substrate is already absent is idempotent: the release is not \
        applicable and must not be recorded as a degradation"
   | _ -> Windtrap.fail "a re-destroy of an absent target must still succeed");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "the release is not attempted at all, so it neither warns nor waits on a cluster \
       that is not there"
    [ "substrate" ]
    (List.rev calls.order);
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:
      "and the install outputs are not read: with nothing represented there is no \
       platform to wire, so there is no cloud read to fail on either"
    0
    calls.outputs
;;

let test_an_unreadable_state_listing_refuses_before_anything_is_destroyed () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:(Outputs_unreadable "terraform state list failed with exit 1")
      ()
  in
  let outcome = execute ~deps in
  let text = Sol_cli_cloud_destroy.completion_message outcome in
  (match outcome with
   | Destroy_failed
       { failure = Outputs_unreadable message; verification = None; cleanup; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the refusal carries the read that failed, which is the state listing"
       true
       (Sol_cli_string.contains ~needle:"terraform state list failed with exit 1" message);
     Windtrap.equal
       Windtrap.bool
       ~msg:
         "and the refusal says what an unreadable listing means, so it is not read as an \
          absence"
       true
       (Sol_cli_string.contains ~needle:"could not be listed" text
        && Sol_cli_string.contains ~needle:"not an absence" text);
     Windtrap.equal
       Windtrap.bool
       ~msg:"the completion message is a refusal, not a teardown that failed to converge"
       true
       (not (Sol_cli_string.contains ~needle:"did not converge" text));
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it destroys nothing, so no elevated access was opened either"
       true
       (cleanup = Cleanup_not_needed)
   | _ ->
     Windtrap.fail
       "a destroy with a represented substrate whose state cannot be listed must refuse \
        before it destroys anything, rather than skip the platform teardown");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "nothing at all runs, not even the workload release, so a refusal leaves the \
       target as it found it"
    []
    calls.order;
  Windtrap.equal Windtrap.int ~msg:"no elevated access was acquired" 0 calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"the platform teardown never ran" 0 calls.platform;
  Windtrap.equal Windtrap.int ~msg:"the binding was not removed" 0 calls.remove;
  Windtrap.equal Windtrap.int ~msg:"the substrate was not destroyed" 0 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"and absence was never verified" 0 calls.verify;
  Windtrap.equal
    Windtrap.int
    ~msg:"the refusal is a failure"
    exit_failure
    (exit_code outcome)
;;

let test_a_confirmed_absent_listing_keeps_the_degraded_destroy_policy () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~outputs:(Outputs_unavailable "no install outputs are published")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = []; _ } -> ()
   | Destroy_succeeded _ ->
     Windtrap.fail
       "a confirmed absent listing is a warning about a skipped platform teardown, not a \
        degradation of the destroy itself"
   | _ ->
     Windtrap.fail
       "a confirmed absent listing keeps the existing degraded-destroy policy instead of \
        refusing");
  Windtrap.equal
    Windtrap.int
    ~msg:
      "the platform teardown could not be wired, so it was skipped rather than attempted"
    0
    calls.platform;
  Windtrap.equal
    Windtrap.int
    ~msg:"so no elevated access was needed either"
    0
    calls.reconcile;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"and absence was still verified" 1 calls.verify;
  Windtrap.equal
    Windtrap.int
    ~msg:"so the destroy is clean"
    exit_clean
    (exit_code outcome)
;;

let test_an_unreadable_state_observation_is_not_the_refusal () =
  let deps, calls =
    fake_deps
      ~state:(Error "the state backend refused the read")
      ~outputs:(Outputs_unreadable "terraform state list failed with exit 1")
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state =
            Sol_cli_destroy_verification.State_unreadable "permission denied"
        ; sweep =
            Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] }
        ; retention =
            Sol_cli_destroy_verification.Retention_not_required
              "this target declares none"
        })
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Verification_failed _; _ } -> ()
   | Destroy_failed { failure = Outputs_unreadable _; _ } ->
     Windtrap.fail
       "when the state observation itself failed there is no represented substrate and \
        no platform teardown to protect, so this is not the state-listing refusal"
   | _ ->
     Windtrap.fail
       "an unreadable state observation proceeds to the substrate destroy, where the \
        absence check is what fails closed");
  Windtrap.equal
    Windtrap.int
    ~msg:
      "the refusal needs a represented substrate, so the install outputs are not even \
       read"
    0
    calls.outputs;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:"and the run does not claim a clean destruction"
    exit_failure
    (exit_code outcome)
;;

let unestablished_release =
  Sol_cli_workload_scope.Workloads_unestablished
    { namespace = "pluto-payments"
    ; kind = Some "deployment"
    ; operation = "reading"
    ; reason =
        "exited with code 1: Error from server (Forbidden): deployments.apps is forbidden"
    }
;;

let test_an_unestablished_release_stops_before_the_substrate () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~release_workloads:(fun () -> unestablished_release)
      ()
  in
  let outcome = execute ~deps in
  let text = Sol_cli_cloud_destroy.completion_message outcome in
  (match outcome with
   | Destroy_failed { failure = Release_unestablished _; verification = None; cleanup; _ }
     ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the stop names the namespace, the kind and the operation that failed"
       true
       (Sol_cli_string.contains ~needle:"pluto-payments" text
        && Sol_cli_string.contains ~needle:"deployment" text
        && Sol_cli_string.contains ~needle:"reading" text);
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it names the override that accepts the precondition"
       true
       (Sol_cli_string.contains
          ~needle:("--" ^ Sol_cli_cloud_destroy.accept_unreleased_flag)
          text);
     Windtrap.equal
       Windtrap.bool
       ~msg:"the stop claims no absence"
       true
       (Sol_cli_string.contains ~needle:"no absence is claimed" text
        && not (Sol_cli_string.contains ~needle:"verified absence" text));
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it destroys nothing, so no elevated access was opened either"
       true
       (cleanup = Cleanup_not_needed)
   | _ ->
     Windtrap.fail
       "a destroy that cannot establish its workloads are released must stop before the \
        substrate, not proceed and not claim absence");
  Windtrap.equal Windtrap.int ~msg:"the substrate was not destroyed" 0 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"and absence was never verified" 0 calls.verify;
  Windtrap.equal
    Windtrap.int
    ~msg:"the platform was left standing too, so a re-run starts from unchanged state"
    0
    calls.platform;
  Windtrap.equal
    Windtrap.int
    ~msg:"and no destruction authority was acquired"
    0
    calls.reconcile;
  Windtrap.equal
    Windtrap.int
    ~msg:"the release runs before the whole destruction, not only before the substrate"
    0
    calls.remove;
  Windtrap.equal
    Windtrap.int
    ~msg:"the stop is a failure"
    exit_failure
    (exit_code outcome)
;;

let test_the_override_destroys_with_the_release_unestablished () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~release_workloads:(fun () -> unestablished_release)
      ~accept_unreleased:true
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations; verification; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the run records that the workloads are not released"
       true
       (List.exists
          (fun degradation ->
             Sol_cli_string.contains ~needle:"are not released" degradation)
          degradations);
     Windtrap.equal
       Windtrap.bool
       ~msg:"and it records that the absence check, not the release, decided"
       true
       (List.exists
          (fun degradation ->
             Sol_cli_string.contains ~needle:"absence check below" degradation)
          degradations);
     Windtrap.equal
       Windtrap.bool
       ~msg:"the absence evidence is the verification's, and it is the verified one"
       true
       (verification = verified_observation)
   | _ -> Windtrap.fail "the override must destroy despite an unestablished release");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"the absence check still ran" 1 calls.verify
;;

let test_a_release_that_does_not_apply_is_recorded_and_the_teardown_continues () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~release_workloads:(fun () ->
        Sol_cli_workload_scope.Workloads_not_releasable
          "the cloud substrate is absent, so there is no cluster to release from")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the carve-out is reported rather than hidden, so the run record can state it"
       true
       (List.exists
          (fun degradation ->
             Sol_cli_string.contains
               ~needle:"the cloud substrate is absent, so there is no cluster"
               degradation)
          degradations)
   | _ ->
     Windtrap.fail
       "a release that does not apply must not block a teardown, and must be recorded");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed" 1 calls.substrate
;;

let test_destroy_that_cannot_converge_claims_no_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        continue_failure "the deletion guards could not be lowered: replace refused")
      ~remove:(fun () -> Error "the binding could not be removed: replace refused")
      ~destroy_substrate:(fun () ->
        Error
          "Error waiting for deleting GKE cluster: the cluster is in ERROR and Terraform \
           refused the plan")
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"a destroy that cannot converge exits non-zero"
    exit_failure
    (exit_code outcome);
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy was attempted" 1 calls.substrate;
  let message = completion_message outcome in
  Windtrap.equal
    Windtrap.bool
    ~msg:"and it never claims absence"
    false
    (matches_regex (Str.regexp_string "reached verified absence") message);
  Windtrap.equal
    Windtrap.bool
    ~msg:"it says the destruction did not converge"
    true
    (matches_regex (Str.regexp_string "did not converge") message)
;;

let test_residue_the_state_does_not_own_is_not_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues =
                  [ "the cluster is still listed by the provider, in state ERROR" ]
              ; indeterminate = []
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"residue outside Terraform's state still fails"
    exit_failure
    (exit_code outcome);
  Windtrap.equal Windtrap.int ~msg:"the sweep ran after the destroy" 1 calls.verify;
  let message = completion_message outcome in
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the run claims no absence"
    false
    (matches_regex (Str.regexp_string "reached verified absence") message)
;;

let test_inconclusive_residue_probe_is_unknown () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        { Sol_cli_destroy_verification.state = State_absent
        ; sweep =
            Sweep_ran
              { residues = []
              ; indeterminate =
                  [ "the GCP residue check could not establish the target's project, so \
                     the service-networking peering check was not run"
                  ]
              }
        ; retention = Retention_not_required "this fixture declares no retention"
        })
      ()
  in
  let outcome = execute ~deps in
  let message = completion_message outcome in
  (match outcome with
   | Destroy_succeeded _ ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the summary never claims verified absence while a probe did not run"
       false
       (matches_regex (Str.regexp_string "reached verified absence") message);
     Windtrap.equal
       Windtrap.bool
       ~msg:"it says so plainly instead"
       true
       (matches_regex (Str.regexp_string "residue absence is NOT established") message
        && matches_regex (Str.regexp_string "peering check was not run") message)
   | _ ->
     Windtrap.fail
       "a destroy whose owned resources are gone is not a failure; the observation is");
  Windtrap.equal
    Windtrap.int
    ~msg:"and the owned resources are still gone, so the destruction itself succeeded"
    exit_clean
    (exit_code outcome)
;;

let absence_rule = Sol_cli_absence.Named_for_target "the target's own cluster name"

let absent_class resource_class =
  Sol_cli_absence.Absent
    { resource_class
    ; identity = "qual-1"
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let present_class resource_class =
  Sol_cli_absence.Present
    { resource_class
    ; identity = "qual-1-postgres"
    ; found = [ "qual-1-postgres" ]
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let unobservable_class resource_class =
  Sol_cli_absence.Unobservable
    { resource_class; reason = "the CLI is unavailable"; checked_with = "gcloud list" }
;;

let test_an_empty_inventory_permits_the_absence_claim () =
  let observations = [ absent_class "GKE cluster"; absent_class "Cloud SQL instance" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"every class observed absent permits the claim"
    true
    (Sol_cli_absence.permits_absence_claim (Sol_cli_absence.verdict observations));
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the sweep carries no residue and no unknown"
    true
    (Sol_cli_absence.to_sweep observations
     = Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] })
;;

let test_a_present_resource_refuses_the_absence_claim () =
  let observations = [ absent_class "GKE cluster"; present_class "Cloud SQL instance" ] in
  let verdict = Sol_cli_absence.verdict observations in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a resource the state never adopted still refuses the claim"
    false
    (Sol_cli_absence.permits_absence_claim verdict);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and it is named"
    true
    (List.exists
       (fun line -> matches_regex (Str.regexp_string "qual-1-postgres") line)
       (Sol_cli_absence.residue verdict));
  let verification =
    Sol_cli_destroy_verification.classify
      { Sol_cli_destroy_verification.state = State_absent
      ; sweep = Sol_cli_absence.to_sweep observations
      ; retention = Retention_not_required "fixture"
      }
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"so the destruction verdict is not verified"
    false
    (Sol_cli_destroy_verification.is_verified verification)
;;

let test_an_unobservable_class_refuses_the_absence_claim () =
  let verdict =
    Sol_cli_absence.verdict
      [ absent_class "GKE cluster"; unobservable_class "forwarding rule" ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"an observation that did not run is UNKNOWN, never absence"
    false
    (Sol_cli_absence.permits_absence_claim verdict)
;;

let test_a_present_resource_outranks_an_unobservable_class () =
  let verdict =
    Sol_cli_absence.verdict
      [ unobservable_class "GKE cluster"; present_class "Cloud SQL instance" ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"both refuse the claim"
    false
    (Sol_cli_absence.permits_absence_claim verdict);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the resource that was actually found is reported first"
    true
    (match Sol_cli_absence.residue verdict with
     | first :: _ -> matches_regex (Str.regexp_string "qual-1-postgres") first
     | [] -> false)
;;

let test_an_external_resource_is_not_residue () =
  let observations =
    [ Sol_cli_absence.External
        { resource_class = "Terraform state bucket"
        ; identity = "the durable backend"
        ; reason = "durable by contract"
        }
    ; absent_class "GKE cluster"
    ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a resource the contract keeps alive is not this target's residue"
    true
    (Sol_cli_absence.permits_absence_claim (Sol_cli_absence.verdict observations))
;;

let test_the_report_explains_attribution () =
  let report = Sol_cli_absence.report [ present_class "Cloud SQL instance" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"it says what was found"
    true
    (matches_regex (Str.regexp_string "PRESENT: Cloud SQL instance") report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and why it is this target's"
    true
    (matches_regex (Str.regexp_string "the target's own cluster name") report);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and which command established it"
    true
    (matches_regex (Str.regexp_string "gcloud list") report)
;;

let recovery_entry address ~resource_class ~observed_as ~ownership ~import_identity =
  Sol_cli_resource_identity.
    { address
    ; resource_class
    ; observed_as
    ; ownership
    ; identity = "fixture"
    ; import_identity
    }
;;

let recovery_present resource_class found =
  Sol_cli_absence.Present
    { resource_class
    ; identity = "fixture"
    ; found = [ found ]
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let recovery_plan ?(state_addresses = []) ~entries observations =
  Sol_cli_ownership_reconciliation.dispositions ~entries ~state_addresses observations
;;

let recovery_unobservable resource_class reason =
  Sol_cli_absence.Unobservable { resource_class; reason; checked_with = "gcloud list" }
;;

let recovery_absent resource_class =
  Sol_cli_absence.Absent
    { resource_class
    ; identity = "fixture"
    ; attribution = absence_rule
    ; checked_with = "gcloud list"
    }
;;

let mentions haystack needle = Sol_cli_string.contains ~needle haystack

let test_recovery_carries_a_check_that_could_not_run () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_unobservable "Cloud NAT" "AccessDenied: denied" ]
  in
  (match dispositions with
   | [ Sol_cli_ownership_reconciliation.Unresolved { resource_class; reason } ] ->
     Windtrap.equal Windtrap.string ~msg:"the class is named" "Cloud NAT" resource_class;
     Windtrap.equal
       Windtrap.string
       ~msg:"and the provider's reason"
       "AccessDenied: denied"
       reason
   | _ -> Windtrap.fail "a check that could not run must be carried, never dropped");
  Windtrap.equal
    Windtrap.int
    ~msg:"it is outstanding, so the command exits nonzero"
    1
    (List.length (Sol_cli_ownership_reconciliation.unreconciled dispositions));
  let outcome = Sol_cli_ownership_reconciliation.outcome dispositions in
  Windtrap.equal
    Windtrap.bool
    ~msg:"no reconciled claim is made"
    false
    (mentions outcome "reconciled. No changes.");
  Windtrap.equal
    Windtrap.bool
    ~msg:"the unresolved check is reported"
    true
    (mentions outcome "Cloud NAT could not be checked");
  Windtrap.equal
    Windtrap.bool
    ~msg:"and absence is not claimed for it"
    true
    (mentions outcome "nothing is claimed about the resources those checks cover")
;;

let test_recovery_reports_present_and_unresolved_together () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan
      ~entries
      [ recovery_present "Cloud SQL instance" "qual-1-postgres"
      ; recovery_unobservable "Cloud NAT" "AccessDenied: denied"
      ]
  in
  let outcome = Sol_cli_ownership_reconciliation.outcome dispositions in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the recoverable resource is still reported"
    true
    (mentions outcome "Restored Terraform ownership");
  Windtrap.equal
    Windtrap.bool
    ~msg:"the unresolved check is reported too"
    true
    (mentions outcome "Cloud NAT could not be checked");
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the result is not called reconciled"
    false
    (mentions outcome "Infrastructure ownership is reconciled.")
;;

let test_recovery_claims_no_changes_only_for_a_complete_inventory () =
  let dispositions = recovery_plan ~entries:[] [ recovery_absent "Cloud NAT" ] in
  Windtrap.equal
    Windtrap.int
    ~msg:"nothing is outstanding"
    0
    (List.length (Sol_cli_ownership_reconciliation.unreconciled dispositions));
  Windtrap.equal
    Windtrap.string
    ~msg:"a complete all-absent inventory reconciles"
    "Infrastructure ownership is reconciled.\nNo changes.\n"
    (Sol_cli_ownership_reconciliation.outcome dispositions)
;;

let test_recovery_maps_a_present_resource_to_its_address () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan ~entries [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Recover candidate ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"the address comes from the registry"
      "google_sql_database_instance.postgres"
      candidate.address;
    Windtrap.equal
      Windtrap.string
      ~msg:"and the import identity is the provider name"
      "qual-1-postgres"
      candidate.import_identity
  | _ -> Windtrap.fail "a mappable orphan must be a recovery candidate"
;;

let test_recovery_refuses_a_resource_the_state_already_owns () =
  let entries =
    [ recovery_entry
        "google_sql_database_instance.postgres"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan
      ~state_addresses:[ "google_sql_database_instance.postgres" ]
      ~entries
      [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Already_owned _ ] -> ()
  | _ -> Windtrap.fail "a resource the state already owns must not be imported twice"
;;

let test_recovery_refuses_a_class_it_cannot_map () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_present "forwarding rule" "k8s2-something" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Unmapped { resource_class; found } ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"a controller-created class is reported, not adopted"
      "forwarding rule"
      resource_class;
    Windtrap.equal Windtrap.string ~msg:"and named" "k8s2-something" found
  | _ -> Windtrap.fail "a class with no Terraform address must be reported, never adopted"
;;

let test_recovery_refuses_an_unmapped_class () =
  let dispositions =
    recovery_plan ~entries:[] [ recovery_present "Some future class" "whatever" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Unmapped _ ] -> ()
  | _ -> Windtrap.fail "a class with no registry entry must be reported, never guessed at"
;;

let test_recovery_refuses_a_class_the_registry_calls_unrecoverable () =
  let entries =
    [ recovery_entry
        "google_service_networking_connection.sql"
        ~resource_class:"service-networking peering connection"
        ~observed_as:"qual-1"
        ~ownership:
          (Sol_cli_resource_identity.Direct_not_recoverable
             "a composite import identity Sol has not established")
        ~import_identity:""
    ]
  in
  let dispositions =
    recovery_plan
      ~entries
      [ recovery_present "service-networking peering connection" "qual-1" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Cannot_recover { reason; _ } ] ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the reason is the registry's, not a guess"
      true
      (matches_regex (Str.regexp_string "composite import identity") reason)
  | _ -> Windtrap.fail "a class marked unrecoverable must be refused with its reason"
;;

let test_recovery_refuses_an_ambiguous_match () =
  let entries =
    [ recovery_entry
        "provider.one"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1-postgres"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ; recovery_entry
        "provider.two"
        ~resource_class:"Cloud SQL instance"
        ~observed_as:"qual-1"
        ~ownership:Sol_cli_resource_identity.Direct
        ~import_identity:"qual-1-postgres"
    ]
  in
  let dispositions =
    recovery_plan ~entries [ recovery_present "Cloud SQL instance" "qual-1-postgres" ]
  in
  match dispositions with
  | [ Sol_cli_ownership_reconciliation.Cannot_recover { reason; _ } ] ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"two candidate addresses are reported as ambiguous"
      true
      (matches_regex (Str.regexp_string "ambiguous") reason)
  | _ -> Windtrap.fail "an ambiguous mapping must be refused, never resolved"
;;

let test_reconciliation_outcome_reports_what_it_restored () =
  let restored =
    Sol_cli_ownership_reconciliation.Recover
      { address = "google_sql_database_instance.postgres"
      ; resource_class = "Cloud SQL instance"
      ; found = "qual-1-postgres"
      ; import_identity = "qual-1-postgres"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome [ restored ] in
  List.iter
    (fun expected ->
       Windtrap.equal
         Windtrap.bool
         ~msg:expected
         true
         (matches_regex (Str.regexp_string expected) text))
    [ "Found Cloud SQL instance qual-1-postgres."
    ; "Restored Terraform ownership:"
    ; "  google_sql_database_instance.postgres"
    ; "Infrastructure ownership is reconciled."
    ]
;;

let test_reconciliation_outcome_says_no_changes () =
  let text = Sol_cli_ownership_reconciliation.outcome [] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a reconciled target reports no changes"
    true
    (matches_regex (Str.regexp_string "No changes.") text)
;;

let test_reconciliation_outcome_refuses_rather_than_claiming () =
  let refused =
    Sol_cli_ownership_reconciliation.Cannot_recover
      { resource_class = "service-networking peering connection"
      ; found = "qual-1"
      ; reason = "a composite import identity Sol has not established"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome [ refused ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unreconcilable resource is named, with its reason"
    true
    (matches_regex (Str.regexp_string "is not reconciled") text);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the reason is the registry's"
    true
    (matches_regex (Str.regexp_string "composite import identity") text)
;;

let test_reconciliation_outcome_does_not_claim_a_dry_run_changed_anything () =
  let candidate =
    Sol_cli_ownership_reconciliation.Recover
      { address = "google_sql_database_instance.postgres"
      ; resource_class = "Cloud SQL instance"
      ; found = "qual-1-postgres"
      ; import_identity = "qual-1-postgres"
      }
  in
  let text = Sol_cli_ownership_reconciliation.outcome ~dry_run:true [ candidate ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a dry run says what it would do, not what it did"
    true
    (matches_regex (Str.regexp_string "Would restore Terraform ownership:") text);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and never claims the work happened"
    false
    (matches_regex (Str.regexp_string "Infrastructure ownership is reconciled.") text)
;;

let test_block_preparation_failure_blocks_destruction () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        block_failure
          "the target's destroy_retention is final-snapshot, so its declared retention \
           guarantee could not be established before destroying: snapshot refused")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_blocked { guarantee } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the retention guarantee is identified as the blocker"
       true
       (matches_regex (Str.regexp_string "destroy_retention is final-snapshot") guarantee)
   | _ -> Windtrap.fail "a Block_destroy preparation failure must block destruction");
  Windtrap.equal Windtrap.int ~msg:"the substrate was not destroyed" 0 calls.substrate;
  Windtrap.equal
    Windtrap.int
    ~msg:"a blocked destroy exits as a failure"
    exit_failure
    (exit_code outcome)
;;

let test_clean_destruction_is_clean () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Prepared (Prepared { retained = None }))
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded
       { preparation = Prepared { retained = None }; degradations = []; _ } -> ()
   | _ -> Windtrap.fail "a clean preparation and a clean destroy must be a clean success");
  Windtrap.equal Windtrap.int ~msg:"the substrate was destroyed" 1 calls.substrate;
  Windtrap.equal Windtrap.int ~msg:"clean success exits 0" exit_clean (exit_code outcome)
;;

let test_degradation_preserved_when_destroy_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ~destroy_substrate:(fun () -> Error "terraform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Substrate_destroy_failed message; degradations = [ degraded ]; _ } ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the destroy failure stands"
       "terraform destroy exited 1"
       message;
     Windtrap.equal
       Windtrap.string
       ~msg:"the preparation degradation is preserved separately"
       "preparation: guards not lowered"
       degraded
   | _ ->
     Windtrap.fail "a failed destroy must preserve the earlier preparation degradation");
  Windtrap.equal
    Windtrap.int
    ~msg:"a failed destroy exits as a failure"
    exit_failure
    (exit_code outcome)
;;

let test_unknown_state_is_not_absence_and_not_silent () =
  let deps, calls =
    fake_deps
      ~state:(Error "terraform show failed with exit 1")
      ~prepare:(fun ~state:_ -> continue_failure "the target's state could not be read")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { substrate = Substrate_unknown; degradations = [ _ ]; _ } -> ()
   | _ -> Windtrap.fail "UNKNOWN must remain UNKNOWN and be reported, never absence");
  Windtrap.equal
    Windtrap.int
    ~msg:"the preparation was attempted, not skipped as empty"
    1
    (List.length calls.prepare);
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate
;;

let test_refused_plan_is_a_continue_failure () =
  let applied = ref 0 in
  let policy =
    { Sol_cli_terraform_plan.phase = "guard-preparation"
    ; rules =
        [ { matches = [ Sol_cli_terraform_plan.Exact "google_container_cluster.main" ]
          ; allows = [ Sol_cli_terraform_plan.Update ]
          ; reason = ""
          }
        ]
    }
  in
  let refused_plan =
    {|{"resource_changes":[{"address":"google_container_cluster.main","type":"google_container_cluster","mode":"managed","change":{"actions":["create"]}}]}|}
  in
  let preparation =
    match
      Sol_cli_terraform_plan.guarded_apply
        ~policy
        ~plan:(fun () -> Ok "/tmp/plan")
        ~show_plan:(fun _ -> Ok refused_plan)
        ~apply_plan:(fun _ ->
          applied := !applied + 1;
          Ok ())
        ()
    with
    | Ok () -> Sol_cli_cloud_lifecycle.Nothing_to_prepare
    | Error failure ->
      continue_failure (Sol_cli_terraform_plan.apply_failure_to_string failure)
  in
  Windtrap.equal Windtrap.int ~msg:"the unsafe apply never ran" 0 !applied;
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> preparation)
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; _ } -> ()
   | _ -> Windtrap.fail "a refused plan must let destruction continue, not block it");
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate
;;

let test_substrate_destroy_failure () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~destroy_substrate:(fun () -> Error "terraform destroy exited 1")
      ()
  in
  let outcome = execute ~deps in
  match outcome with
  | Destroy_failed { failure = Substrate_destroy_failed _; _ } -> ()
  | _ -> Windtrap.fail "expected the substrate destroy failure"
;;

let test_absent_state_with_outputs_skips_teardown () =
  let deps, calls = fake_deps ~state:(Ok {|{}|}) ~outputs:Outputs_available () in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"exit code is success" 0 (exit_code outcome);
  Windtrap.equal
    Windtrap.int
    ~msg:"no reconciliation without a represented substrate"
    0
    calls.reconcile;
  Windtrap.equal
    Windtrap.int
    ~msg:"no platform teardown without a represented substrate"
    0
    calls.platform;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate
;;

let binding =
  Sol_cli_terraform_plan.Exact
    "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
;;

let guard_json =
  {|{"resource_changes":[{"address":"google_container_cluster.main","type":"google_container_cluster","mode":"managed","change":{"actions":["create"]}}]}|}
;;

let refused_apply plan_ref policy plan_json () =
  match
    Sol_cli_terraform_plan.guarded_apply
      ~policy
      ~plan:(fun () -> Ok "/tmp/plan")
      ~show_plan:(fun _ -> Ok plan_json)
      ~apply_plan:(fun _ ->
        plan_ref := !plan_ref + 1;
        Ok ())
      ()
  with
  | Ok () -> Ok ()
  | Error failure -> Error (Sol_cli_terraform_plan.apply_failure_to_string failure)
;;

let test_refused_reconciliation_never_applies () =
  let open Sol_cli_terraform_plan in
  let applied = ref 0 in
  let policy =
    { phase = "destroy-reconciliation"
    ; rules = [ { matches = [ binding ]; allows = [ Update ]; reason = "" } ]
    }
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~reconcile:(refused_apply applied policy guard_json)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal Windtrap.int ~msg:"the refused apply was never invoked" 0 !applied;
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; cleanup = Cleanup_succeeded; _ } -> ()
   | _ -> Windtrap.fail "a refused plan must degrade the destroy, never be executed");
  Windtrap.equal Windtrap.int ~msg:"removal was still attempted" 1 calls.remove;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy still ran" 1 calls.substrate
;;

let test_refused_removal_does_not_stop_the_substrate_destroy () =
  let open Sol_cli_terraform_plan in
  let applied = ref 0 in
  let policy =
    { phase = "bootstrap-access-removal"
    ; rules = [ { matches = [ binding ]; allows = [ Update ]; reason = "" } ]
    }
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~remove:(refused_apply applied policy guard_json)
      ()
  in
  let outcome = execute ~deps in
  Windtrap.equal
    Windtrap.int
    ~msg:"the refused cleanup apply was never invoked"
    0
    !applied;
  (match outcome with
   | Destroy_succeeded { cleanup = Cleanup_failed _; degradations; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the refused removal is still not reported as a successful cleanup"
       true
       (List.exists
          (fun m -> matches_regex (Str.regexp_string "elevated access") m)
          degradations)
   | _ -> Windtrap.fail "the refused removal must stay visible as a degradation");
  Windtrap.equal
    Windtrap.int
    ~msg:"and it does not immobilise the substrate: the destroy still ran"
    1
    calls.substrate
;;

let observation_with
      ?(state = Sol_cli_destroy_verification.State_absent)
      ?(sweep =
        Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] })
      ?(retention = Sol_cli_destroy_verification.Retention_not_required "fixture")
      ()
  =
  { Sol_cli_destroy_verification.state; sweep; retention }
;;

let test_degradation_with_verified_absence () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = [ _ ]; verification; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the observation is carried, and it is the verified one"
       true
       (verification = verified_observation)
   | _ ->
     Windtrap.fail "a degraded preparation with verified absence is a degraded success");
  Windtrap.equal
    Windtrap.int
    ~msg:"a degraded success exits 0 with a warning"
    exit_clean
    (exit_code outcome);
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy ran" 1 calls.substrate
;;

let test_verification_unknown_is_a_failure () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~state:(Sol_cli_destroy_verification.State_unreadable "permission denied")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Verification_failed message
       ; degradations = []
       ; verification = Some _
       ; _
       } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the failure says the postcondition was not established"
       true
       (matches_regex (Str.regexp_string "could not be established") message)
   | _ -> Windtrap.fail "an UNKNOWN observation must fail the destroy");
  Windtrap.equal
    Windtrap.int
    ~msg:"UNKNOWN is failure, not degraded success"
    exit_failure
    (exit_code outcome);
  Windtrap.equal
    Windtrap.int
    ~msg:"the destroy itself was still attempted"
    1
    calls.substrate
;;

let test_degradation_preserved_when_verification_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ -> continue_failure "guards not lowered")
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~sweep:
            (Sol_cli_destroy_verification.Sweep_ran
               { residues = [ "a load balancer remains" ]; indeterminate = [] })
          ~retention:(Retention_not_required "fixture")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed
       { failure = Verification_failed message
       ; degradations = [ degraded ]
       ; verification = Some _
       ; _
       } ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the preparation degradation is preserved"
       "preparation: guards not lowered"
       degraded;
     Windtrap.equal
       Windtrap.bool
       ~msg:"and the violation is what failed the run"
       true
       (matches_regex (Str.regexp_string "violated") message)
   | _ -> Windtrap.fail "a violation must fail the destroy and keep the degradation");
  Windtrap.equal Windtrap.int ~msg:"a violation exits 1" exit_failure (exit_code outcome)
;;

let test_missing_retention_fails () =
  let deps, _ =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ ->
        observation_with
          ~retention:
            (Retention_violated
               "final-snapshot NOT observed (destroy_retention = final-snapshot): the \
                target declared it keeps its final snapshot, and the provider explicitly \
                reports that snap-1 does not exist")
          ())
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_failed { failure = Verification_failed message; degradations = []; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the promised snapshot is named"
       true
       (matches_regex (Str.regexp_string "snap-1") message)
   | _ -> Windtrap.fail "a missing promised snapshot must fail the destroy");
  Windtrap.equal Windtrap.int ~msg:"it exits 1" exit_failure (exit_code outcome)
;;

let test_fully_clean_is_exit_0 () =
  let observed =
    observation_with
      ~retention:
        (Retention_required_and_observed
           "final snapshot snap-1 observed available (destroy_retention = final-snapshot)")
      ()
  in
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Prepared (Prepared { retained = None }))
      ~verify_destruction:(fun ~pre_destroy:_ ~preparation:_ -> observed)
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_succeeded { degradations = []; verification; _ } ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the evidence is carried"
       true
       (verification = observed)
   | _ -> Windtrap.fail "a fully clean destroy must be a clean success");
  Windtrap.equal Windtrap.int ~msg:"clean success exits 0" exit_clean (exit_code outcome);
  Windtrap.equal Windtrap.int ~msg:"the verification ran" 1 calls.verify
;;

let test_blocked_destroy_never_verifies () =
  let deps, calls =
    fake_deps
      ~state:(Ok (show_json_resources gcp_cluster))
      ~prepare:(fun ~state:_ ->
        Sol_cli_cloud_lifecycle.Preparation_failed
          { reason = "the target's retention guarantee could not be established"
          ; policy = Sol_cli_cloud_lifecycle.Block_destroy
          })
      ()
  in
  let outcome = execute ~deps in
  (match outcome with
   | Destroy_blocked _ -> ()
   | _ -> Windtrap.fail "a Block_destroy preparation must block");
  Windtrap.equal Windtrap.int ~msg:"verification never ran" 0 calls.verify;
  Windtrap.equal Windtrap.int ~msg:"the substrate destroy never ran" 0 calls.substrate
;;

let%test "inventory: empty state" = test_empty_state ()
let%test "inventory: missing values is empty" = test_missing_values_is_empty ()
let%test "inventory: represented identity" = test_represented_identity ()
let%test "inventory: null protection" = test_null_protection_is_not_an_error ()
let%test "inventory: child-module address" = test_child_module_address_preserved ()

let%test "inventory: same type, distinct instances" =
  test_same_type_instances_are_distinct ()
;;

let%test "inventory: unreadable is UNKNOWN" = test_unreadable_is_unknown ()
let%test "inventory: identifier is captured" = test_identifier_captured ()

let%test "execute: empty state without outputs" =
  test_empty_state_destroys_without_outputs ()
;;

let%test "execute: a provably absent substrate accounts for stale state" =
  test_a_provably_absent_substrate_accounts_for_stale_state ()
;;

let%test "execute: a failed reconciliation degrades and still destroys" =
  test_a_failed_reconciliation_degrades_and_still_destroys ()
;;

let%test "execute: no reconciliation is claimed when there is none" =
  test_no_reconciliation_is_claimed_when_there_is_none ()
;;

let%test "execute: a substrate the provider lost skips what must reach it" =
  test_a_substrate_the_provider_lost_skips_what_must_reach_it ()
;;

let%test "execute: a reconciled state that cannot be re-read degrades" =
  test_a_reconciled_state_that_cannot_be_reread_degrades ()
;;

let%test "execute: the cluster contents are classified" =
  test_the_cluster_contents_are_classified ()
;;

let%test "execute: half-built state" = test_half_built_state_is_destroyable ()
let%test "execute: partial outputs never refuse" = test_partial_outputs_never_refuse ()

let%test "execute: state read failure is not absence" =
  test_state_read_failure_is_not_absence ()
;;

let%test "execute: elevated access opened/removed" =
  test_elevated_access_opened_and_removed ()
;;

let%test "execute: no authority mechanism acquires nothing" =
  test_no_authority_mechanism_acquires_nothing ()
;;

let%test "execute: no authority mechanism still reports a failed teardown" =
  test_no_authority_mechanism_still_reports_a_failed_teardown ()
;;

let%test "execute: protected-operation failure still removes" =
  test_protected_operation_failure_still_removes ()
;;

let%test "execute: skipped teardown is a degradation" =
  test_skipped_teardown_is_a_degradation ()
;;

let%test "execute: platform failure is not a degradation" =
  test_platform_failure_is_not_a_degradation ()
;;

let%test "execute: skipped teardown + cleanup failure preserved" =
  test_skipped_teardown_and_cleanup_failure_are_both_preserved ()
;;

let%test "execute: cleanup failure does not decide absence" =
  test_cleanup_failure_does_not_decide_absence ()
;;

let%test "execute: cleanup failure preserved" =
  test_cleanup_failure_preserved_when_operation_fails ()
;;

let%test "execute: substrate destroy failure" = test_substrate_destroy_failure ()

let%test "execute: absent state with outputs" =
  test_absent_state_with_outputs_skips_teardown ()
;;

let%test "failure policy: continue failure destroys" =
  test_continue_preparation_failure_destroys ()
;;

let%test
    "failure policy: an unremovable elevated binding does not immobilise the substrate"
  =
  test_unremovable_elevated_access_does_not_immobilise_the_substrate ()
;;

let%test "failure policy: a destroy that cannot converge claims no absence (FND-0069)" =
  test_destroy_that_cannot_converge_claims_no_absence ()
;;

let%test "failure policy: residue the state does not own is not absence" =
  test_residue_the_state_does_not_own_is_not_absence ()
;;

let%test "failure policy: an inconclusive residue probe is an unknown" =
  test_inconclusive_residue_probe_is_unknown ()
;;

let%test "failure policy: an empty provider inventory permits the claim" =
  test_an_empty_inventory_permits_the_absence_claim ()
;;

let%test "failure policy: a present resource refuses the claim (FND-0070)" =
  test_a_present_resource_refuses_the_absence_claim ()
;;

let%test "failure policy: an unobservable class refuses the claim" =
  test_an_unobservable_class_refuses_the_absence_claim ()
;;

let%test "failure policy: a present resource outranks an unobservable class" =
  test_a_present_resource_outranks_an_unobservable_class ()
;;

let%test "failure policy: an external resource is not residue" =
  test_an_external_resource_is_not_residue ()
;;

let%test "failure policy: the report explains attribution" =
  test_the_report_explains_attribution ()
;;

let%test
    "failure policy: recovery maps a present resource to its Terraform address (FND-0070)"
  =
  test_recovery_maps_a_present_resource_to_its_address ()
;;

let%test "failure policy: recovery carries a check that could not run (BUG-085)" =
  test_recovery_carries_a_check_that_could_not_run ()
;;

let%test "failure policy: recovery reports present and unresolved together (BUG-085)" =
  test_recovery_reports_present_and_unresolved_together ()
;;

let%test
    "failure policy: recovery claims no changes only for a complete inventory (BUG-085)"
  =
  test_recovery_claims_no_changes_only_for_a_complete_inventory ()
;;

let%test "failure policy: recovery does not import what the state already owns" =
  test_recovery_refuses_a_resource_the_state_already_owns ()
;;

let%test "failure policy: recovery reports a class it has no address for" =
  test_recovery_refuses_a_class_it_cannot_map ()
;;

let%test "failure policy: recovery refuses an unmapped class" =
  test_recovery_refuses_an_unmapped_class ()
;;

let%test "failure policy: recovery refuses a class the registry calls unrecoverable" =
  test_recovery_refuses_a_class_the_registry_calls_unrecoverable ()
;;

let%test "failure policy: reconciliation reports what it restored (FND-0070)" =
  test_reconciliation_outcome_reports_what_it_restored ()
;;

let%test "failure policy: reconciliation says no changes when there are none" =
  test_reconciliation_outcome_says_no_changes ()
;;

let%test "failure policy: reconciliation refuses rather than claiming" =
  test_reconciliation_outcome_refuses_rather_than_claiming ()
;;

let%test "failure policy: a dry run never claims to have changed anything" =
  test_reconciliation_outcome_does_not_claim_a_dry_run_changed_anything ()
;;

let%test "failure policy: recovery refuses an ambiguous mapping" =
  test_recovery_refuses_an_ambiguous_match ()
;;

let%test "failure policy: block failure blocks destruction" =
  test_block_preparation_failure_blocks_destruction ()
;;

let%test "failure policy: clean destruction is clean" = test_clean_destruction_is_clean ()

let%test "failure policy: degradation preserved when destroy fails" =
  test_degradation_preserved_when_destroy_fails ()
;;

let%test "failure policy: UNKNOWN is not absence and not silent" =
  test_unknown_state_is_not_absence_and_not_silent ()
;;

let%test "failure policy: refused plan is a continue failure" =
  test_refused_plan_is_a_continue_failure ()
;;

let%test "plan assertion: refused reconciliation never applies" =
  test_refused_reconciliation_never_applies ()
;;

let%test "plan assertion: a refused removal does not stop the substrate destroy" =
  test_refused_removal_does_not_stop_the_substrate_destroy ()
;;

let%test "verification: degradation + verified absence exits 0" =
  test_degradation_with_verified_absence ()
;;

let%test "verification: verification UNKNOWN exits 1" =
  test_verification_unknown_is_a_failure ()
;;

let%test "verification: degradation preserved when verification fails" =
  test_degradation_preserved_when_verification_fails ()
;;

let%test "verification: an unreadable workload listing is an error" =
  test_an_unreadable_workload_listing_is_an_error ()
;;

let%test "verification: the workload selection reads the pod template" =
  test_the_workload_selection_reads_the_pod_template ()
;;

let%test "verification: a Rollout listing is read from its pod template" =
  test_a_rollout_listing_is_read_from_its_pod_template ()
;;

let%test "verification: the ownership label is read from the pod template, not the object"
  =
  test_the_label_is_read_from_the_template_not_the_object ()
;;

let%test "release: a workload is removed only on an exact recorded-UID match" =
  test_the_release_removes_only_proven_workloads ()
;;

let%test "verification: the workload read is scoped to the declared namespace" =
  test_the_workload_read_is_scoped_to_the_declared_namespace ()
;;

let%test "verification: only a controller-installed kind may read as absence" =
  test_only_a_controller_installed_kind_may_read_as_absence ()
;;

let%test "verification: a scope with no declared namespace reads nothing" =
  test_a_scope_with_no_declared_namespace_reads_nothing ()
;;

let%test "verification: an unserved kind is absence, not a failed read (INFRA-097)" =
  test_an_unserved_kind_is_absence_not_a_failed_read ()
;;

let%test "verification: a namespace that does not exist holds no workload" =
  test_a_namespace_that_does_not_exist_holds_no_workload ()
;;

let%test
    "verification: declared namespaces that do not exist make the release not applicable"
  =
  test_every_declared_namespace_absent_is_not_applicable ()
;;

let%test
    "verification: a target that declares no namespace has no workload to release from"
  =
  test_a_target_with_no_declared_namespace_is_not_applicable ()
;;

let%test "verification: an absent namespace does not hide a namespace that exists" =
  test_an_absent_namespace_does_not_hide_a_present_one ()
;;

let%test
    "verification: a partial deployment is released, not read as a namespace that is gone"
  =
  test_a_partial_deployment_is_released_not_read_as_absent ()
;;

let%test "verification: an existence read that cannot be established keeps the refusal" =
  test_an_unestablishable_namespace_existence_is_unestablished ()
;;

let%test "verification: one observation decides one namespace" =
  test_one_observation_decides_one_namespace ()
;;

let%test
    "verification: a view that cannot be established refuses rather than falling back"
  =
  test_a_view_that_cannot_be_established_refuses_rather_than_falling_back ()
;;

let%test "verification: absence and a successful inspection are different facts" =
  test_absence_and_a_successful_inspection_are_different_facts ()
;;

let%test "verification: an unreachable cluster keeps the documented carve-out" =
  test_an_unreachable_cluster_probe_is_the_carve_out ()
;;

let%test "verification: an absent namespace never masks an unreadable one" =
  test_an_absent_namespace_never_masks_an_unreadable_one ()
;;

let%test "verification: a live cluster that refuses a read is unestablished" =
  test_a_live_cluster_that_refuses_a_read_is_unestablished ()
;;

let%test "verification: a listing that cannot be decoded is unestablished" =
  test_a_listing_that_cannot_be_decoded_is_unestablished ()
;;

let%test "verification: an unreachable cluster is not a failed release" =
  test_an_unreachable_cluster_is_not_a_failed_release ()
;;

let%test "verification: a cluster that answered and then went away is unestablished" =
  test_a_cluster_that_answered_then_went_away_is_unestablished ()
;;

let%test "verification: the removal names the workloads and waits" =
  test_the_removal_names_the_workloads_and_waits ()
;;

let%test "verification: workloads are released before the substrate is destroyed" =
  test_the_workloads_are_released_before_the_substrate_is_destroyed ()
;;

let%test "verification: a target with no substrate has no release to run" =
  test_a_target_with_no_substrate_has_no_release_to_run ()
;;

let%test
    "verification: an unreadable state listing refuses before anything is destroyed \
     (BUG-094)"
  =
  test_an_unreadable_state_listing_refuses_before_anything_is_destroyed ()
;;

let%test "verification: a confirmed absent listing keeps the degraded destroy policy" =
  test_a_confirmed_absent_listing_keeps_the_degraded_destroy_policy ()
;;

let%test "verification: an unreadable state observation is not the refusal" =
  test_an_unreadable_state_observation_is_not_the_refusal ()
;;

let%test "verification: an unestablished release stops before the substrate (DEC-059)" =
  test_an_unestablished_release_stops_before_the_substrate ()
;;

let%test "verification: --accept-unreleased destroys with the release unestablished" =
  test_the_override_destroys_with_the_release_unestablished ()
;;

let%test "verification: a release that does not apply is recorded and teardown continues" =
  test_a_release_that_does_not_apply_is_recorded_and_the_teardown_continues ()
;;

let%test "verification: missing retention fails" = test_missing_retention_fails ()
let%test "verification: fully clean exits 0" = test_fully_clean_is_exit_0 ()

let%test "verification: blocked destroy never verifies" =
  test_blocked_destroy_never_verifies ()
;;

let test_rds_identity_is_the_counted_address () =
  let rds address =
    show_json_resources
      (Printf.sprintf
         {|{"address":"%s","type":"aws_db_instance","values":{"deletion_protection":true,"skip_final_snapshot":false,"final_snapshot_identifier":null}}|}
         address)
  in
  let state_with_counted = inventory_of_show_json (rds "aws_db_instance.postgres[0]") in
  (match Sol_cli_aws_destruction.rds_of_state state_with_counted with
   | Ok (Some (true, None, Some false)) -> ()
   | Ok _ ->
     Windtrap.fail "a state that represents the counted database must expose its guard"
   | Error message ->
     Windtrap.failf
       "a state that represents the counted database must be readable: %s"
       message);
  let state_without_database =
    inventory_of_show_json
      (show_json_resources
         {|{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{"name":"lifecycle-test"}}|})
  in
  (match Sol_cli_aws_destruction.rds_of_state state_without_database with
   | Ok None -> ()
   | Ok (Some _) -> Windtrap.fail "a target with no database has nothing to prepare"
   | Error message ->
     Windtrap.failf "a target with no database must not be an error: %s" message);
  let state_with_unindexed = inventory_of_show_json (rds "aws_db_instance.postgres") in
  match Sol_cli_aws_destruction.rds_of_state state_with_unindexed with
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"a database at an unexpected address is diagnosed, not reported absent"
      true
      (Sol_cli_string.contains ~needle:"aws_db_instance.postgres[0]" message)
  | Ok _ ->
    Windtrap.fail
      "a malformed database identity must not grant a false absence or retention verdict"
;;

let%test "verification: RDS identity uses the counted Terraform address (BUG-209)" =
  test_rds_identity_is_the_counted_address ()
;;

let gcp_cluster_with_guard guard =
  Printf.sprintf
    {|{"address":"google_container_cluster.main","type":"google_container_cluster","values":{"name":"c","deletion_protection":%s}}|}
    (string_of_bool guard)
;;

let gcp_database ~address ~guard =
  Printf.sprintf
    {|{"address":%S,"type":"google_sql_database_instance","values":{"deletion_protection":%s}}|}
    address
    (string_of_bool guard)
;;

let verify_gcp_state resources =
  Sol_cli_gcp_destruction.verify_gcp_preparation_state
    (inventory_of_show_json (show_json_resources (String.concat "," resources)))
;;

let%test "verification: GCP preparation reads the counted Cloud SQL address" =
  let database address guard =
    verify_gcp_state [ gcp_cluster_with_guard false; gcp_database ~address ~guard ]
  in
  (match database "google_sql_database_instance.postgres[0]" true with
   | Error message ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the counted database's guard is verified"
       true
       (Sol_cli_string.contains ~needle:"still enabled" message)
   | Ok () -> Windtrap.fail "a counted database with protection enabled was accepted");
  (match database "google_sql_database_instance.postgres[0]" false with
   | Ok () -> ()
   | Error message -> Windtrap.failf "a disabled counted guard was refused: %s" message);
  match database "google_sql_database_instance.postgres" false with
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"an unexpected bare address is diagnosed instead of skipped"
      true
      (Sol_cli_string.contains ~needle:"not the expected address" message)
  | Ok () -> Windtrap.fail "a bare database address was accepted as the counted identity"
;;

let%test "verification: a count=0 Cloud SQL instance has no guard to lower" =
  match verify_gcp_state [ gcp_cluster_with_guard false ] with
  | Ok () -> ()
  | Error message -> Windtrap.failf "a target with no database was refused: %s" message
;;

let%test "preparation: a count=0 Cloud SQL instance is not targeted" =
  let guarded =
    [ "google_sql_database_instance.postgres[0]"; "google_container_cluster.main" ]
  in
  let desired ~represented ~create_database =
    Sol_cli_gcp_destruction.gcp_desired_guards ~represented ~guarded ~create_database
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the absent database is not a desired guard"
    [ "google_container_cluster.main" ]
    (desired ~represented:[] ~create_database:(Some "false"));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "a represented database is still guarded even if the current declaration says \
       count=0"
    guarded
    (desired
       ~represented:[ "google_sql_database_instance.postgres[0]" ]
       ~create_database:(Some "false"));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the default count keeps the database guard"
    guarded
    (desired ~represented:[] ~create_database:None)
;;
