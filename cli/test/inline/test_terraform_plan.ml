open Sol_cli_terraform_plan

let plan_of changes =
  Printf.sprintf {|{"resource_changes":[%s]}|} (String.concat "," changes)
;;

let change ?(mode = "managed") address resource_type action =
  let action =
    Printf.sprintf "[%s]" (String.concat "," (List.map (Printf.sprintf "%S") action))
  in
  Printf.sprintf
    {|{"address":%S,"type":%S,"mode":%S,"change":{"actions":%s}}|}
    address
    resource_type
    mode
    action
;;

let create address kind = change address kind [ "create" ]
let update address kind = change address kind [ "update" ]
let delete address kind = change address kind [ "delete" ]
let replace address kind = change address kind [ "delete"; "create" ]
let no_op address kind = change address kind [ "no-op" ]
let data_read address kind = change ~mode:"data" address kind [ "read" ]
let authority = "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"

let authority_instances =
  [ authority; authority ^ "[0]"; authority ^ "[37]"; authority ^ "[\"key\"]" ]
;;

let not_the_authority =
  [ authority ^ "_suffix"
  ; authority ^ ".extra"
  ; "module.other." ^ authority
  ; "module.platform." ^ authority ^ "[0]"
  ; "kubernetes_cluster_role_binding.other_binding"
  ; "kubernetes_cluster_role_binding.other_binding[0]"
  ; "google_container_cluster.main[0]"
  ]
;;

let binding = Sol_cli_terraform_plan.Resource authority
let cluster = "google_container_cluster.main"
let sql = "google_sql_database_instance.postgres"
let network = "google_compute_network.main"

let allowlist policy json =
  match changes_of_plan_json json with
  | Error msg -> Windtrap.failf "the fixture plan could not be read: %s" msg
  | Ok changes -> List.length (violations policy changes) = 0
;;

let test_actions () =
  let check raw expected =
    let json = plan_of [ change "x.y" "z" raw ] in
    match changes_of_plan_json json with
    | Ok [ c ] ->
      Windtrap.equal
        Windtrap.string
        ~msg:("action of " ^ String.concat "," raw)
        expected
        (action_to_string c.action)
    | _ -> Windtrap.failf "could not classify %s" (String.concat "," raw)
  in
  check [ "no-op" ] "no-op";
  check [ "read" ] "read";
  check [ "create" ] "create";
  check [ "update" ] "update";
  check [ "delete" ] "delete";
  check [ "delete"; "create" ] "replace";
  check [ "create"; "delete" ] "replace";
  check [ "frobnicate" ] "unrecognised action [frobnicate]"
;;

let test_malformed_is_error () =
  List.iter
    (fun json ->
       match changes_of_plan_json json with
       | Error _ -> ()
       | Ok _ -> Windtrap.failf "expected an error for %s" json)
    [ "not json"
    ; {|{"values":{}}|}
    ; {|{"resource_changes":{}}|}
    ; {|{"resource_changes":[{"type":"z","mode":"managed","change":{"actions":["create"]}}]}|}
    ]
;;

let test_empty_and_read_only_are_allowed () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Windtrap.equal Windtrap.bool ~msg:"empty plan" true (allowlist policy (plan_of []));
  Windtrap.equal
    Windtrap.bool
    ~msg:"no-op anywhere"
    true
    (allowlist policy (plan_of [ no_op network network ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"data-source read"
    true
    (allowlist policy (plan_of [ data_read "data.x" "google_compute_network" ]))
;;

let test_whole_root_missing_cluster_create_is_refused () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"missing cluster create is refused"
    false
    (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
;;

let test_unrepresented_guarded_create_is_refused () =
  let policy = Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"configured-but-unrepresented guarded create is refused"
    false
    (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
;;

let test_unexpected_target_resource_create_is_refused () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"unexpected create is refused"
    false
    (allowlist policy (plan_of [ create network "google_compute_network" ]))
;;

let test_unexpected_replace_is_refused () =
  let policy = Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"replacement is refused"
    false
    (allowlist policy (plan_of [ replace cluster "google_container_cluster" ]))
;;

let test_bootstrap_create_is_allowed () =
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"bootstrap create is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ create
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]))
;;

let test_declared_authority_matches_every_instance () =
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  authority_instances
  |> List.iter (fun address ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "%s is the declared authority resource" address)
      true
      (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
;;

let test_declared_authority_matches_nothing_else () =
  let policy = Sol_cli_cloud_destroy.bootstrap_enable_policy ~bootstrap:[ binding ] in
  not_the_authority
  |> List.iter (fun address ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "%s is not the declared authority resource" address)
      false
      (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
;;

let test_attempt8_authority_create_is_accepted () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"index-qualified authority create is accepted"
    true
    (allowlist
       policy
       (plan_of [ create (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"index-qualified authority update is accepted"
    true
    (allowlist
       policy
       (plan_of [ update (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a for_each-keyed authority create is accepted"
    true
    (allowlist
       policy
       (plan_of [ create (authority ^ "[\"key\"]") "kubernetes_cluster_role_binding" ]))
;;

let test_attempt8_authority_create_is_refused_where_the_action_is_forbidden () =
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"removal may not create the authority it just removed"
    false
    (allowlist
       policy
       (plan_of [ create (authority ^ "[0]") "kubernetes_cluster_role_binding" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"removal may delete it"
    true
    (allowlist
       policy
       (plan_of [ delete (authority ^ "[0]") "kubernetes_cluster_role_binding" ]))
;;

let test_indexed_sibling_create_is_still_refused () =
  let policy =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ cluster ]
  in
  List.iter
    (fun address ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "an unrelated %s create is refused" address)
         false
         (allowlist policy (plan_of [ create address "kubernetes_cluster_role_binding" ])))
    [ "kubernetes_cluster_role_binding.other_binding[0]"
    ; "module.platform." ^ authority ^ "[0]"
    ]
;;

let test_guarded_update_is_allowed () =
  let policy =
    Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ cluster; sql ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"guarded update is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ update cluster "google_container_cluster"
          ; update sql "google_sql_database_instance"
          ]))
;;

let counted_guarded = "aws_db_instance.postgres"

let test_counted_guarded_update_is_allowed () =
  let preparation =
    Sol_cli_cloud_destroy.guard_preparation_policy ~addresses:[ counted_guarded ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the counted instance's guard-lowering update is in the preparation scope"
    true
    (allowlist
       preparation
       (plan_of [ update (counted_guarded ^ "[0]") "aws_db_instance" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"creating the counted instance is still refused during preparation"
    false
    (allowlist
       preparation
       (plan_of [ create (counted_guarded ^ "[0]") "aws_db_instance" ]));
  let reconciliation =
    Sol_cli_cloud_destroy.reconciliation_policy
      ~bootstrap:[ binding ]
      ~guarded:[ counted_guarded ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the counted instance's guard-lowering update is in the reconciliation scope"
    true
    (allowlist
       reconciliation
       (plan_of [ update (counted_guarded ^ "[0]") "aws_db_instance" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"destroying the counted instance during reconciliation is refused"
    false
    (allowlist
       reconciliation
       (plan_of [ delete (counted_guarded ^ "[0]") "aws_db_instance" ]))
;;

let test_removal_with_unexpected_create_is_refused () =
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"removal may not create target resources"
    false
    (allowlist
       policy
       (plan_of
          [ delete
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ; create cluster "google_container_cluster"
          ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"removal of the elevation is allowed"
    true
    (allowlist
       policy
       (plan_of
          [ delete
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"removal may not create the elevation it is closing"
    false
    (allowlist
       policy
       (plan_of
          [ create
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
          ]))
;;

let test_out_of_scope_delete_is_refused () =
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"out-of-scope delete is refused"
    false
    (allowlist policy (plan_of [ delete network "google_compute_network" ]))
;;

let test_attempt6_inventory_prunes_the_scope () =
  let inventory =
    {|{"values":{"root_module":{"resources":[{"address":"google_compute_network.main","type":"google_compute_network","values":{}}]}}}|}
  in
  match Sol_cli_cloud_destroy.inventory_of_show_json inventory with
  | Sol_cli_cloud_destroy.State_represented _ ->
    let eligible =
      Sol_cli_cloud_lifecycle.preparations_eligible
        ~state:
          (Sol_cli_cloud_destroy.addresses
             (Sol_cli_cloud_destroy.inventory_of_show_json inventory))
        ~desired:
          [ "google_container_cluster.main"; "google_sql_database_instance.postgres" ]
    in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"nothing guarded is eligible"
      []
      eligible;
    let policy =
      Sol_cli_cloud_destroy.reconciliation_policy ~bootstrap:[ binding ] ~guarded:eligible
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the missing cluster's create is refused"
      false
      (allowlist policy (plan_of [ create cluster "google_container_cluster" ]))
  | _ -> Windtrap.fail "expected a represented inventory"
;;

let test_unknown_action_is_refused () =
  let policy = Sol_cli_cloud_destroy.bootstrap_removal_policy ~bootstrap:[ binding ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unrecognised action is refused"
    false
    (allowlist
       policy
       (plan_of
          [ change
              "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"
              "kubernetes_cluster_role_binding"
              [ "frobnicate" ]
          ]))
;;

let guarded_apply_case ~plan_result ~plan_json =
  let applied = ref 0 in
  let policy =
    Sol_cli_terraform_plan.
      { phase = "test"
      ; rules = [ { matches = [ Exact cluster ]; allows = [ Update ]; reason = "" } ]
      }
  in
  let outcome =
    guarded_apply
      ~policy
      ~plan:(fun () -> plan_result)
      ~show_plan:(fun _ -> Ok plan_json)
      ~apply_plan:(fun _ ->
        applied := !applied + 1;
        Ok ())
      ()
  in
  outcome, !applied
;;

let test_guarded_apply_refusal_never_applies () =
  let outcome, applied =
    guarded_apply_case
      ~plan_result:(Ok "/tmp/plan")
      ~plan_json:(plan_of [ create cluster "google_container_cluster" ])
  in
  Windtrap.equal Windtrap.int ~msg:"the apply was never invoked" 0 applied;
  match outcome with
  | Error failure ->
    Windtrap.equal Windtrap.bool ~msg:"refused" true (was_refused failure)
  | Ok () -> Windtrap.fail "expected a refusal"
;;

let test_guarded_apply_malformed_never_applies () =
  let outcome, applied =
    guarded_apply_case ~plan_result:(Ok "/tmp/plan") ~plan_json:"not json"
  in
  Windtrap.equal Windtrap.int ~msg:"the apply was never invoked" 0 applied;
  match outcome with
  | Error (Plan_unreadable _) -> ()
  | _ -> Windtrap.fail "expected Plan_unreadable"
;;

let test_guarded_apply_plan_failure_never_applies () =
  let outcome, applied =
    guarded_apply_case ~plan_result:(Error "terraform exited 1") ~plan_json:(plan_of [])
  in
  Windtrap.equal Windtrap.int ~msg:"the apply was never invoked" 0 applied;
  match outcome with
  | Error (Plan_failed _) -> ()
  | _ -> Windtrap.fail "expected Plan_failed"
;;

let test_guarded_apply_permitted_applies_once () =
  let outcome, applied =
    guarded_apply_case
      ~plan_result:(Ok "/tmp/plan")
      ~plan_json:(plan_of [ update cluster "google_container_cluster" ])
  in
  Windtrap.equal Windtrap.int ~msg:"the apply ran once" 1 applied;
  match outcome with
  | Ok () -> ()
  | Error failure ->
    Windtrap.failf "expected success: %s" (apply_failure_to_string failure)
;;

let test_removed_of_type () =
  let changes =
    match
      changes_of_plan_json
        (plan_of
           [ delete {|aws_ecr_repository.services["old-svc"]|} "aws_ecr_repository"
           ; replace {|aws_ecr_repository.services["renamed"]|} "aws_ecr_repository"
           ; change
               {|aws_ecr_repository.services["create-first"]|}
               "aws_ecr_repository"
               [ "create"; "delete" ]
           ; update {|aws_ecr_repository.services["kept"]|} "aws_ecr_repository"
           ; create {|aws_ecr_repository.services["new-svc"]|} "aws_ecr_repository"
           ; delete "aws_ecr_lifecycle_policy.services" "aws_ecr_lifecycle_policy"
           ])
    with
    | Ok c -> c
    | Error e -> Windtrap.fail e
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"deletes and replaces of the type, nothing else"
    [ {|aws_ecr_repository.services["old-svc"]|}
    ; {|aws_ecr_repository.services["renamed"]|}
    ; {|aws_ecr_repository.services["create-first"]|}
    ]
    (removed_of_type ~resource_type:"aws_ecr_repository" changes)
;;

let secret = "s3cr3t-db-password-7f1c"

let plan_with_secret =
  Printf.sprintf
    {|{"variables":{"db_password":{"value":"%s"}},"resource_changes":[{"address":"aws_db_instance.main","type":"aws_db_instance","mode":"managed","change":{"actions":["delete"],"before":{"password":"%s"}}}]}|}
    secret
    secret
;;

let temp_dir () =
  let d = Filename.temp_file "sol-runlog-" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  d
;;

let rec files_under dir =
  Array.to_list (Sys.readdir dir)
  |> List.concat_map (fun f ->
    let p = Filename.concat dir f in
    if Sys.is_directory p then files_under p else [ p ])
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let test_show_and_record_never_logs_plan_json () =
  let base = temp_dir () in
  let run_log = Sol_cli_run_log.create ~base ~prefix:"sec008" () in
  (match
     Sol_cli_terraform_plan.show_and_record
       ~run_log
       ~phase:"destroy-show"
       ~show:(fun () -> Ok plan_with_secret)
   with
   | Error m -> Windtrap.failf "unexpected error: %s" m
   | Ok (json, changes) ->
     Windtrap.equal
       Windtrap.string
       ~msg:"the JSON is returned to the caller"
       plan_with_secret
       json;
     Windtrap.equal Windtrap.int ~msg:"one change" 1 (List.length changes));
  let files = files_under base in
  Windtrap.equal Windtrap.bool ~msg:"a phase log was written" true (files <> []);
  files
  |> List.iter (fun f ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "%s holds no secret" f)
      false
      (Sol_cli_string.contains ~needle:secret (read f));
    Windtrap.equal
      Windtrap.int
      ~msg:(Printf.sprintf "%s is 0600" f)
      0o600
      ((Unix.stat f).st_perm land 0o777));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the classified change is recorded"
    true
    (Sol_cli_string.contains
       ~needle:"delete aws_db_instance.main"
       (read (Sol_cli_run_log.phase_log_path run_log ~phase:"destroy-show")))
;;

let test_show_and_record_unreadable_plan_is_an_error () =
  let run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"sec008" () in
  Windtrap.equal
    Windtrap.bool
    ~msg:"malformed JSON refuses"
    true
    (Result.is_error
       (Sol_cli_terraform_plan.show_and_record
          ~run_log
          ~phase:"destroy-show"
          ~show:(fun () -> Ok "not json")));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a failed show refuses"
    true
    (Result.is_error
       (Sol_cli_terraform_plan.show_and_record
          ~run_log
          ~phase:"destroy-show"
          ~show:(fun () -> Error "terraform exited 1")))
;;

(* A run log the process cannot write is diagnostics for a plan that was read
   successfully; it must not turn the read into a failure. Replacing the run's
   directory with a regular file forces ENOTDIR, which no privilege bypasses. *)
let test_show_and_record_survives_a_failed_append () =
  let run_log = Sol_cli_run_log.create ~base:(temp_dir ()) ~prefix:"sec008" () in
  let dir = Sol_cli_run_log.dir run_log in
  ignore (Sol_cli_fs.remove_tree dir : (unit, string) result);
  Out_channel.with_open_text dir (fun oc -> output_string oc "not a directory");
  let result, reports =
    Sol_cli_report.collect (fun () ->
      Sol_cli_terraform_plan.show_and_record
        ~run_log
        ~phase:"destroy-show"
        ~show:(fun () -> Ok plan_with_secret))
  in
  (match result with
   | Error message ->
     Windtrap.failf "an unavailable run log must not fail the operation: %s" message
   | Ok (json, changes) ->
     Windtrap.equal Windtrap.string ~msg:"the JSON is returned" plan_with_secret json;
     Windtrap.equal Windtrap.int ~msg:"the changes are returned" 1 (List.length changes));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the unavailable log is reported"
    true
    (List.exists
       (fun (_, line) -> Sol_cli_string.contains ~needle:"run log unavailable" line)
       reports)
;;

let%test "classification: actions" = test_actions ()
let%test "classification: removed_of_type (INFRA-074)" = test_removed_of_type ()
let%test "classification: malformed is an error" = test_malformed_is_error ()

let%test "classification: empty and read-only are allowed" =
  test_empty_and_read_only_are_allowed ()
;;

let%test "classification: unknown action is refused" = test_unknown_action_is_refused ()

let%test "phase allowlists: whole-root missing cluster create is refused" =
  test_whole_root_missing_cluster_create_is_refused ()
;;

let%test "phase allowlists: unrepresented guarded create is refused" =
  test_unrepresented_guarded_create_is_refused ()
;;

let%test "phase allowlists: unexpected target create is refused" =
  test_unexpected_target_resource_create_is_refused ()
;;

let%test "phase allowlists: unexpected replace is refused" =
  test_unexpected_replace_is_refused ()
;;

let%test "phase allowlists: bootstrap create is allowed" =
  test_bootstrap_create_is_allowed ()
;;

let%test "phase allowlists: declared authority matches every instance" =
  test_declared_authority_matches_every_instance ()
;;

let%test "phase allowlists: declared authority matches nothing else" =
  test_declared_authority_matches_nothing_else ()
;;

let%test "phase allowlists: Attempt-8 authority create is accepted" =
  test_attempt8_authority_create_is_accepted ()
;;

let%test
    "phase allowlists: Attempt-8 authority create is refused where the action is \
     forbidden"
  =
  test_attempt8_authority_create_is_refused_where_the_action_is_forbidden ()
;;

let%test "phase allowlists: indexed sibling create is still refused" =
  test_indexed_sibling_create_is_still_refused ()
;;

let%test "phase allowlists: guarded update is allowed" = test_guarded_update_is_allowed ()

let%test "phase allowlists: a counted guarded instance is matched (BUG-209)" =
  test_counted_guarded_update_is_allowed ()
;;

let%test "phase allowlists: removal with unexpected create is refused" =
  test_removal_with_unexpected_create_is_refused ()
;;

let%test "phase allowlists: out-of-scope delete is refused" =
  test_out_of_scope_delete_is_refused ()
;;

let%test "phase allowlists: Attempt-6 inventory prunes the scope" =
  test_attempt6_inventory_prunes_the_scope ()
;;

let%test "guarded_apply: refusal never applies" =
  test_guarded_apply_refusal_never_applies ()
;;

let%test "guarded_apply: malformed never applies" =
  test_guarded_apply_malformed_never_applies ()
;;

let%test "guarded_apply: plan failure never applies" =
  test_guarded_apply_plan_failure_never_applies ()
;;

let%test "guarded_apply: permitted applies once" =
  test_guarded_apply_permitted_applies_once ()
;;

let%test "show_and_record (SEC-008): plan JSON never reaches the run log" =
  test_show_and_record_never_logs_plan_json ()
;;

let%test "show_and_record (SEC-008): unreadable plan is an error" =
  test_show_and_record_unreadable_plan_is_an_error ()
;;

let%test "show_and_record: an unavailable run log does not fail the read" =
  test_show_and_record_survives_a_failed_append ()
;;

let%test "invalid Terraform plan diagnostics do not echo sensitive JSON fragments" =
  match changes_of_plan_json "credentialCanaryDoNotDisclose is not JSON" with
  | Ok _ -> Windtrap.fail "malformed plan accepted"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      false
      (Sol_cli_string.contains ~needle:"credentialCanary" message)
;;
