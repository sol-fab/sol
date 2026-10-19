open Sol_cli_kafka_authority

let change ?(mode = "managed") address resource_type action
  : Sol_cli_terraform_plan.change
  =
  { address; resource_type; mode; action }
;;

let random action = change "random_password.kafka[0]" "random_password" action

let resources : authority_resources =
  { secret = "aws_secretsmanager_secret.kafka[0]"
  ; version = "aws_secretsmanager_secret_version.kafka[0]"
  }
;;

let authority action = change resources.secret "aws_secretsmanager_secret" action
let version action = change resources.version "aws_secretsmanager_secret_version" action

let refused = function
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "unsafe credential generation was permitted"
;;

let%test
    "Kafka generation requires its selected generator, and never rotates on \
     reconciliation"
  =
  let decide ?(managed = true) changes = generation ~resources ~managed changes in
  let reused changes =
    Windtrap.equal
      (Windtrap.result Windtrap.unit Windtrap.string)
      (Ok ())
      (Result.map ignore (decide changes))
  in
  reused [ random No_op; authority No_op; version No_op ];
  reused [ random No_op; authority Update; version No_op ];
  (* A retry after a partial first apply finishes the missing authority objects
     from the generator value already in state; it does not rotate. *)
  reused [ random No_op; authority Create; version Create ];
  reused [ random Create; authority Create; version Create ];
  Windtrap.equal
    (Windtrap.result Windtrap.unit Windtrap.string)
    (Ok ())
    (Result.map ignore (decide ~managed:false []));
  refused (decide []);
  List.iter
    (fun action -> refused (decide [ random action; authority No_op; version No_op ]))
    [ Update; Delete; Replace; Read; Unknown [ "unrecognized" ] ];
  List.iter
    (fun action -> refused (decide [ random No_op; authority action; version No_op ]))
    [ Delete; Replace; Read; Unknown [ "unrecognized" ] ];
  List.iter
    (fun action -> refused (decide [ random No_op; authority No_op; version action ]))
    [ Create; Update; Delete; Replace; Read; Unknown [ "unrecognized" ] ];
  refused (decide ~managed:false [ random No_op ]);
  refused (decide ~managed:false [ random Create ])
;;

let%test "Kafka authority deletion is a full-target teardown, not a deploy action" =
  let refused_as_teardown ?(managed = true) changes =
    match generation ~resources ~managed changes with
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the authority and directs to sol destroy"
        true
        (Sol_cli_string.contains ~needle:"credential authority" message
         && Sol_cli_string.contains ~needle:"sol destroy" message)
    | Ok _ -> Windtrap.fail "a destructive Kafka authority plan was accepted"
  in
  refused_as_teardown [ random Delete; authority Delete; version Delete ];
  refused_as_teardown [ random No_op; authority Delete; version No_op ];
  refused_as_teardown [ random No_op; authority Replace; version Replace ];
  (* Removing the Kafka resource from the target also plans deletion; it is the same
     explicit teardown, not an ordinary deploy. *)
  refused_as_teardown ~managed:false [ random Delete; authority Delete; version Delete ]
;;

let%test "Kafka addition to existing infrastructure still requires independent absence" =
  match
    generation
      ~resources
      ~managed:true
      [ random Create
      ; authority Create
      ; version Create
      ; change "aws_eks_cluster.main" "aws_eks_cluster" No_op
      ]
  with
  | Ok Initialize -> ()
  | _ -> Windtrap.fail "existing infrastructure alone does not prove a surviving broker"
;;

let%test "Kafka reuse requires independently observed provider authority" =
  (match check_reuse_authority Authority_current with
   | Ok () -> ()
   | Error message -> Windtrap.fail message);
  refused
    (check_reuse_authority
       (Authority_missing "the provider secret has no active version"));
  refused
    (check_reuse_authority
       (Authority_unobservable "AccessDeniedException: not authorized"))
;;

let absent resource_class =
  Sol_cli_absence.Absent
    { resource_class
    ; identity = "target"
    ; attribution = Within_target "fixture"
    ; checked_with = "provider"
    }
;;

let evidence =
  { broker = absent "broker"; storage = absent "storage"; authority = absent "authority" }
;;

let%test
    "Kafka initialization requires positive absence of each authority, cluster and \
     storage"
  =
  (match check_initial_absence evidence with
   | Ok () -> ()
   | Error e -> Windtrap.fail e);
  let states =
    [ Sol_cli_absence.Present
        { resource_class = "survivor"
        ; identity = "target"
        ; found = [ "id" ]
        ; attribution = Within_target "fixture"
        ; checked_with = "provider"
        }
    ; Unobservable
        { resource_class = "unreadable"
        ; reason = "PERMISSION_DENIED"
        ; checked_with = "provider"
        }
    ; Not_attributable { resource_class = "unattributed"; reason = "missing authority" }
    ; External { resource_class = "excluded"; identity = "id"; reason = "not absence" }
    ]
  in
  List.iter
    (fun state ->
       List.iter
         (fun evidence -> refused (check_initial_absence evidence))
         [ { evidence with broker = state }
         ; { evidence with storage = state }
         ; { evidence with authority = state }
         ])
    states
;;

let%test "Kafka broker projection creation cannot become implicit rotation or teardown" =
  let secret action =
    change
      "module.platform.kubernetes_secret_v1.redpanda_users[0]"
      "kubernetes_secret_v1"
      action
  in
  List.iter
    (fun action ->
       match
         Sol_cli_terraform_plan.violations broker_projection_policy [ secret action ]
       with
       | [] -> ()
       | _ -> Windtrap.fail "a missing or unchanged delivery Secret should be usable")
    [ Create; No_op ];
  List.iter
    (fun action ->
       match
         Sol_cli_terraform_plan.violations broker_projection_policy [ secret action ]
       with
       | [] ->
         Windtrap.fail
           "changing a broker projection requires an explicit recovery decision"
       | _ -> ())
    [ Update; Delete; Replace; Unknown [ "unsupported" ] ];
  match
    Sol_cli_terraform_plan.violations
      broker_projection_policy
      [ change "module.platform.helm_release.redpanda" "helm_release" Delete ]
  with
  | [] -> Windtrap.fail "credential delivery must not authorize broker destruction"
  | _ -> ()
;;

let%test "the final whole-platform plan preserves the broker credential projection" =
  let projection action =
    change
      "module.platform.kubernetes_secret_v1.redpanda_users[0]"
      "kubernetes_secret_v1"
      action
  in
  let ordinary = change "module.platform.helm_release.argocd" "helm_release" Update in
  (* The ordinary platform change is not collateral damage from this boundary. *)
  (match
     Sol_cli_terraform_plan.violations platform_policy [ ordinary; projection Create ]
   with
   | [] -> ()
   | _ -> Windtrap.fail "the final plan rejected an ordinary platform change");
  List.iter
    (fun action ->
       match
         Sol_cli_terraform_plan.violations platform_policy [ ordinary; projection action ]
       with
       | [] ->
         Windtrap.fail
           "the final whole-platform plan could change an existing broker credential"
       | _ -> ())
    [ Update; Delete; Replace; Unknown [ "unsupported" ] ]
;;

let%test
    "Kafka provisioning input cannot override the typed binding or its target authority"
  =
  let kafka = Sol_cli_resource_binding.Managed_kafka "events" in
  let input =
    match
      Sol_cli_resource_binding.kafka_native_connection ~cluster_name:"acme-prod" kafka
    with
    | Some (`Assoc fields) -> fields
    | _ -> Windtrap.fail "expected native metadata"
  in
  let plan value =
    Yojson.Safe.to_string
      (`Assoc [ "variables", `Assoc [ "kafka_connection", `Assoc [ "value", value ] ] ])
  in
  let check value =
    check_plan_inputs ~kafka ~cluster_name:(Some "acme-prod") (plan value)
  in
  (match check (`Assoc (List.rev input)) with
   | Ok () -> ()
   | Error message -> Windtrap.fail message);
  List.iter
    (fun (key, _) ->
       refused
         (check (`Assoc ((key, `String "another-target") :: List.remove_assoc key input))))
    input;
  refused (check `Null);
  refused (check_plan_inputs ~kafka ~cluster_name:(Some "acme-prod") "{}");
  refused (check_plan_inputs ~kafka:No_kafka ~cluster_name:None "{}");
  refused (check_plan_inputs ~kafka ~cluster_name:None (plan (`Assoc input)));
  let canary = "KAFKA_PLAN_INPUT_PASSWORD_CANARY" in
  (match check (`Assoc (("password", `String canary) :: input)) with
   | Ok () -> Windtrap.fail "extra credential input was accepted"
   | Error message ->
     Windtrap.equal Windtrap.bool false (Sol_cli_string.contains ~needle:canary message));
  match check_plan_inputs ~kafka:No_kafka ~cluster_name:None (plan `Null) with
  | Ok () -> ()
  | Error message -> Windtrap.fail message
;;

let%test "Kafka authority public projection cannot forward unknown confidential fields" =
  let canary = "DO_NOT_FORWARD_THIS_PASSWORD" in
  let output =
    Yojson.Safe.to_string
      (`Assoc
          [ ( "kafka_authority"
            , `Assoc
                [ ( "value"
                  , `Assoc
                      [ "resource", `String "events"
                      ; "reference", `String "public-resource-id"
                      ; "username", `String "sol"
                      ; "mechanism", `String "SCRAM-SHA-256"
                      ; "password", `String canary
                      ] )
                ] )
          ])
  in
  match reference_output output with
  | Ok (Some public) ->
    Windtrap.equal Windtrap.bool false (Sol_cli_string.contains ~needle:canary public);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      [ "mechanism"; "reference"; "resource"; "username" ]
      (Yojson.Safe.from_string public
       |> Yojson.Safe.Util.to_assoc
       |> List.map fst
       |> List.sort String.compare)
  | _ -> Windtrap.fail "reference-only output should be projectable"
;;
