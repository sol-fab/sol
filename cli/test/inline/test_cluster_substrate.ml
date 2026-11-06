open Sol_cli_cluster_substrate

let test_standard_and_fresh_targets_are_accepted () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"standard is the profile's substrate"
    true
    (Result.is_ok (acceptable Standard));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a fresh target is what Sol provisions Standard into"
    true
    (Result.is_ok (acceptable Absent))
;;

let test_autopilot_is_refused_by_the_support_contract () =
  match acceptable Autopilot with
  | Ok () -> Windtrap.fail "Autopilot was accepted"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names Autopilot"
      true
      (Sol_cli_string.contains ~needle:"Autopilot" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"names GKE Standard as what to use"
      true
      (Sol_cli_string.contains ~needle:"GKE Standard" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"gives the profile's reason"
      true
      (Sol_cli_string.contains ~needle:"SYS_RESOURCE" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"and does not make one component the contract"
      false
      (Sol_cli_string.contains ~needle:"helm_release" message)
;;

let test_an_unreadable_cluster_is_never_absence () =
  (match acceptable (Unknown "the provider said nothing") with
   | Ok () -> Windtrap.fail "an unreadable cluster was accepted"
   | Error message ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the refusal says why it could not tell"
       true
       (Sol_cli_string.contains ~needle:"could not establish" message));
  Windtrap.equal
    Windtrap.bool
    ~msg:"and it is not read as a fresh target"
    false
    (Result.is_ok (acceptable (Unknown "timeout")))
;;

let test_absence_wording () =
  List.iter
    (fun wording ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "%S reads as absent" wording)
         true
         (Sol_cli_gcloud.says_not_found wording))
    [ "NOT_FOUND: Resource was not found"
    ; "ERROR: (gcloud.secrets.describe) NOT_FOUND: Secret        \
       [projects/819835583654/secrets/x] not found"
    ; "ERROR: (gcloud.container.clusters.describe) ResponseError: code=404, message=Not \
       found: projects/p/locations/r/clusters/c."
    ; "Could not fetch resource: - The resource 'x' was not found"
    ; "the cluster does not exist"
    ];
  List.iter
    (fun wording ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "%S is not absence" wording)
         false
         (Sol_cli_gcloud.says_not_found wording))
    [ "PERMISSION_DENIED: caller does not have permission"
    ; "ERROR: (gcloud.container.clusters.describe) Could not fetch resource:\n\
      \ - Required 'container.clusters.get' permission for \
       'projects/p/locations/r/clusters/c'."
    ; "Throttling: rate exceeded"
    ; "There was a problem refreshing your current auth tokens"
    ]
;;

let test_the_describe_field_is_read () =
  let check description json expected =
    match Sol_cli_gcp_cluster.autopilot_of_describe_json json with
    | Ok value -> Windtrap.equal Windtrap.bool ~msg:description expected value
    | Error message -> Windtrap.failf "%s: %s" description message
  in
  check "autopilot on" {|{"autopilot":{"enabled":true}}|} true;
  check "autopilot off" {|{"autopilot":{"enabled":false}}|} false;
  (* What GKE returns for a standard cluster: the field is present and empty. *)
  check "a standard cluster's empty autopilot object" {|{"autopilot":{}}|} false;
  (match Sol_cli_gcp_cluster.autopilot_of_describe_json {|{"name":"c"}|} with
   | Ok _ -> Windtrap.fail "a describe with no autopilot field was read as a mode"
   | Error _ -> ());
  (match
     Sol_cli_gcp_cluster.autopilot_of_describe_json {|{"autopilot":{"enabled":"yes"}}|}
   with
   | Ok _ -> Windtrap.fail "a non-boolean autopilot.enabled was read as a mode"
   | Error _ -> ());
  match Sol_cli_gcp_cluster.autopilot_of_describe_json "not json" with
  | Ok _ -> Windtrap.fail "an unparseable describe was read as a mode"
  | Error _ -> ()
;;

let%test "contract: standard and a fresh target are accepted" =
  test_standard_and_fresh_targets_are_accepted ()
;;

let%test "contract: Autopilot is refused by the support contract" =
  test_autopilot_is_refused_by_the_support_contract ()
;;

let%test "contract: an unreadable cluster is never absence" =
  test_an_unreadable_cluster_is_never_absence ()
;;

let%test "contract: the absence vocabulary" = test_absence_wording ()

let%test "observation: the describe field is read, and only when present" =
  test_the_describe_field_is_read ()
;;
