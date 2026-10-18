open Sol_cli_destroy_verification

let gcp_absence_message = Sol_cli_gcloud.says_not_found
let classify_final_snapshot = Sol_cli_aws_destruction.classify_final_snapshot
let classify_instance_snapshots = Sol_cli_aws_destruction.classify_instance_snapshots
let answered ?(stdout = "") status stderr = Answered { status; stdout; stderr }

let observation
      ?(state = State_absent)
      ?(sweep = Sweep_ran { residues = []; indeterminate = [] })
      ?(retention = Retention_not_required "this fixture declares no retention")
      ()
  =
  { state; sweep; retention }
;;

let test_state_empty () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"an empty read is absent"
    true
    (state_evidence (Ok []) = State_absent)
;;

let test_state_residue () =
  let state = state_evidence (Ok [ "google_container_cluster.main" ]) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a represented address is residue"
    true
    (match state with
     | State_residue [ "google_container_cluster.main" ] -> true
     | _ -> false);
  let verdict = classify (observation ~state ()) in
  Windtrap.equal Windtrap.int ~msg:"it is a violation" 1 (List.length verdict.violations);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and it names the address that remains"
    true
    (Sol_cli_string.contains
       ~needle:"google_container_cluster.main"
       (List.hd verdict.violations))
;;

let test_state_unreadable () =
  let verdict =
    classify (observation ~state:(state_evidence (Error "terraform show exited 1")) ())
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"no absence is inferred"
    []
    verdict.violations;
  Windtrap.equal Windtrap.int ~msg:"it is an unknown" 1 (List.length verdict.unknowns);
  Windtrap.equal Windtrap.bool ~msg:"not verified" false (is_verified verdict)
;;

let test_combined_verified () =
  let verdict = classify (observation ()) in
  Windtrap.equal Windtrap.bool ~msg:"verified" true (is_verified verdict);
  Windtrap.equal
    Windtrap.string
    ~msg:"and says so"
    "the destruction postcondition is established"
    (verdict_message verdict)
;;

let test_sweep () =
  let verdict =
    classify
      (observation
         ~sweep:
           (Sweep_ran { residues = [ "AWS EBS volumes remain" ]; indeterminate = [] })
         ())
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"a residue is a violation"
    1
    (List.length verdict.violations);
  let verdict =
    classify
      (observation
         ~sweep:
           (Sweep_ran
              { residues = []; indeterminate = [ "the peering could not be checked" ] })
         ())
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"an inconclusive check is not a violation"
    []
    verdict.violations;
  Windtrap.equal
    Windtrap.bool
    ~msg:"an inconclusive required observation cannot be verified"
    false
    (is_verified verdict);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the verdict preserves the inconclusive observation"
    [ "the peering could not be checked" ]
    verdict.unknowns;
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "a residue with an empty state still fails: the empty state speaks only for what \
       Terraform manages"
    false
    (is_verified
       (classify
          (observation
             ~state:State_absent
             ~sweep:
               (Sweep_ran { residues = [ "a load balancer remains" ]; indeterminate = [] })
             ())))
;;

let test_sweep_not_run_is_not_absence () =
  let verdict = classify (observation ~sweep:Sweep_not_run ()) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a sweep that did not run does not establish destruction"
    false
    (is_verified verdict);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the verdict names the missing inventory"
    [ "the residue inventory did not run" ]
    verdict.unknowns
;;

let test_gcp_not_found_subject_must_match () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"a not-found naming our project is absence"
    true
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/captured-project/x");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a not-found naming another project is not"
    false
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: code=404 Not found: projects/other-project/x");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a not-found naming no project has no subject to contradict"
    true
    (gcp_absence_message
       ~project:"captured-project"
       "ERROR: NOT_FOUND: Resource was not found");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a permission error is not absence"
    false
    (gcp_absence_message ~project:"captured-project" "ERROR: PERMISSION_DENIED")
;;

let final_snapshot stdout = answered ~stdout 0 ""
let declared = Sol_cli_cloud_lifecycle.Retain_final_snapshot

let test_retention_final_snapshot_observed () =
  match
    classify_final_snapshot
      ~declared
      ~snapshot_id:"snap-1"
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"available"}]}|})
  with
  | Sol_cli_aws_destruction.Settled (Retention_required_and_observed evidence) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the observation names the identifier and the state"
      true
      (Sol_cli_string.contains ~needle:"snap-1" evidence
       && Sol_cli_string.contains ~needle:"available" evidence)
  | Sol_cli_aws_destruction.Settled _ ->
    Windtrap.fail "an available snapshot is a met retention guarantee"
  | Sol_cli_aws_destruction.Pending message ->
    Windtrap.failf "an available snapshot is not pending: %s" message
;;

let test_retention_final_snapshot_missing () =
  let lookup =
    answered
      254
      "An error occurred (DBSnapshotNotFound) when calling the DescribeDBSnapshots \
       operation"
  in
  (match classify_final_snapshot ~declared ~snapshot_id:"snap-1" lookup with
   | Sol_cli_aws_destruction.Settled (Retention_violated reason) ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the failure names the identifier and the declaration"
       true
       (Sol_cli_string.contains ~needle:"snap-1" reason
        && Sol_cli_string.contains ~needle:"final-snapshot" reason)
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Windtrap.fail "a missing promised snapshot must fail");
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-other","SnapshotType":"manual","Status":"available"}]}|})
   with
   | Sol_cli_aws_destruction.Settled (Retention_violated _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Windtrap.fail "an answer about another snapshot must not establish this one");
  match
    classify_final_snapshot
      ~declared
      ~snapshot_id:"snap-1"
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"failed"}]}|})
  with
  | Sol_cli_aws_destruction.Settled (Retention_violated _) -> ()
  | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
    Windtrap.fail "a failed snapshot must not read as retained"
;;

let test_retention_final_snapshot_unknown () =
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (Unavailable "aws CLI missing")
   with
   | Sol_cli_aws_destruction.Settled (Retention_unknown _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Windtrap.fail "an unavailable provider is UNKNOWN, not success");
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (answered 1 "ERROR: request timed out")
   with
   | Sol_cli_aws_destruction.Settled (Retention_unknown _) -> ()
   | Sol_cli_aws_destruction.Settled _ | Sol_cli_aws_destruction.Pending _ ->
     Windtrap.fail "a timeout is UNKNOWN, not success");
  (match
     classify_final_snapshot
       ~declared
       ~snapshot_id:"snap-1"
       (final_snapshot
          {|{"DBSnapshots":[{"DBSnapshotIdentifier":"snap-1","SnapshotType":"manual","Status":"creating"}]}|})
   with
   | Sol_cli_aws_destruction.Pending message ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the pending report says what it is waiting for"
       true
       (Sol_cli_string.contains ~needle:"creating" message)
   | Sol_cli_aws_destruction.Settled _ ->
     Windtrap.fail "a snapshot still being created is not a met guarantee");
  let verdict =
    classify (observation ~retention:(Retention_unknown "the snapshot query failed") ())
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"retention UNKNOWN is not verified"
    false
    (is_verified verdict)
;;

let test_retention_none_observed () =
  (match classify_instance_snapshots (final_snapshot {|{"DBSnapshots":[]}|}) with
   | Retention_required_and_observed evidence ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the observation says what was checked"
       true
       (Sol_cli_string.contains ~needle:"none observed" evidence)
   | retention ->
     Windtrap.failf "no residue must be observed, got %s" (retention_to_string retention));
  match
    classify_instance_snapshots
      (answered 254 "An error occurred (DBInstanceNotFound) when calling the operation")
  with
  | Retention_required_and_observed _ -> ()
  | retention ->
    Windtrap.failf
      "a gone instance retains nothing, got %s"
      (retention_to_string retention)
;;

let test_retention_none_residual () =
  match
    classify_instance_snapshots
      (final_snapshot
         {|{"DBSnapshots":[{"DBSnapshotIdentifier":"leaked-snap","SnapshotType":"manual","Status":"available"},{"DBSnapshotIdentifier":"leaked-auto","SnapshotType":"automated","Status":"available"}]}|})
  with
  | Retention_violated reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the failure names the residue and how many"
      true
      (Sol_cli_string.contains ~needle:"leaked-snap" reason
       && Sol_cli_string.contains ~needle:"leaked-auto" reason
       && Sol_cli_string.contains ~needle:"2 snapshot" reason)
  | retention ->
    Windtrap.failf "residual snapshots must fail, got %s" (retention_to_string retention)
;;

let test_retention_none_unknown () =
  (match classify_instance_snapshots (Unavailable "aws CLI missing") with
   | Retention_unknown msg ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the unknown says what could not be observed"
       true
       (Sol_cli_string.contains ~needle:"no-residue" msg)
   | retention ->
     Windtrap.failf
       "an unavailable provider is UNKNOWN, got %s"
       (retention_to_string retention));
  match classify_instance_snapshots (answered 1 "ERROR: throttled") with
  | Retention_unknown _ -> ()
  | retention ->
    Windtrap.failf "a failed query is UNKNOWN, got %s" (retention_to_string retention)
;;

let test_report_is_diagnostic () =
  let obs =
    observation
      ~state:(state_evidence (Ok [ "google_container_cluster.main" ]))
      ~sweep:
        (Sweep_ran
           { residues = [ "the service-networking peering survived the destroy: p1" ]
           ; indeterminate = [ "the EBS volumes could not be checked" ]
           })
      ~retention:
        (Retention_violated "final-snapshot NOT observed: the snapshot does not exist")
      ()
  in
  let report = report obs in
  List.iter
    (fun (label, needle) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:label
         true
         (Sol_cli_string.contains ~needle report))
    [ "the state postcondition", "STILL REPRESENTS google_container_cluster.main"
    ; "the residue", "the service-networking peering survived the destroy"
    ; "the inconclusive check", "the EBS volumes could not be checked"
    ; "the retention violation", "final-snapshot NOT observed"
    ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"an empty state names Terraform's authority (DEC-045)"
    true
    (Sol_cli_string.contains
       ~needle:"DEC-045"
       (Sol_cli_destroy_verification.report (observation ())));
  let verdict = classify obs in
  Windtrap.equal Windtrap.bool ~msg:"not verified" false (is_verified verdict);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the verdict message states the violation"
    true
    (Sol_cli_string.contains ~needle:"violated" (verdict_message verdict))
;;

let%test "state: empty read is absence" = test_state_empty ()
let%test "state: residue is a violation" = test_state_residue ()
let%test "state: unreadable is UNKNOWN" = test_state_unreadable ()
let%test "combined: clean is verified" = test_combined_verified ()
let%test "combined: residue and inconclusive checks" = test_sweep ()

let%test "combined: a sweep that did not run is not absence" =
  test_sweep_not_run_is_not_absence ()
;;

let%test "combined: GCP not-found subject" = test_gcp_not_found_subject_must_match ()
let%test "retention: final snapshot observed" = test_retention_final_snapshot_observed ()
let%test "retention: final snapshot missing" = test_retention_final_snapshot_missing ()
let%test "retention: final snapshot unknown" = test_retention_final_snapshot_unknown ()
let%test "retention: retain-nothing observed" = test_retention_none_observed ()
let%test "retention: retain-nothing residual" = test_retention_none_residual ()
let%test "retention: retain-nothing unknown" = test_retention_none_unknown ()
let%test "report: the report is diagnostic" = test_report_is_diagnostic ()
