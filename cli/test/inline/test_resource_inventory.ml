module I = Sol_cli_resource_inventory

let target provider =
  match Sol_cli_config.parse_target ("inventory/" ^ provider ^ "/us-east-1") with
  | Ok target -> target
  | Error error -> failwith (Sol_cli_config.error_to_string error)
;;

let resource
      ?(kind = "aws_db_instance")
      ?(name = Some "sol-postgres")
      ?role
      ?member
      ?secret_id
      ?email
      address
  =
  { Sol_cli_cloud_destroy.address
  ; kind
  ; name
  ; identifier = None
  ; deletion_protection = None
  ; final_snapshot_identifier = None
  ; skip_final_snapshot = None
  ; role
  ; member
  ; secret_id
  ; email
  ; url = None
  ; soft_delete_retention_seconds = None
  }
;;

let root ?(role = I.Cluster_root) ?(layer = I.Cloud) state =
  { I.role
  ; layer
  ; durable = false
  ; state
  ; last_operation = Sol_cli_supervised.No_previous
  ; errored_state = false
  }
;;

let present class_name found =
  Sol_cli_absence.Present
    { resource_class = class_name
    ; identity = class_name
    ; found
    ; attribution = Sol_cli_absence.Named_for_target "test"
    ; checked_with = "test"
    }
;;

let cloud ?(state = Sol_cli_cloud_destroy.State_empty) observations dispositions =
  ({ state; observations; dispositions; blockers = [] }
   : Sol_cli_cloud_wiring.cloud_collection)
;;

let collect ?(roots = []) ?cloud ?(state_only = false) target =
  I.collect target ~roots ~cloud ~state_only
;;

let%test "by-contract-only resources are reconciled" =
  let target = target "byo" in
  let state =
    Sol_cli_cloud_destroy.State_represented
      [ resource
          ~kind:"kubernetes_namespace"
          ~name:(Some "app")
          "kubernetes_namespace.app"
      ]
  in
  let inventory = collect target ~roots:[ root state ] ~cloud:(cloud [] []) in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"by-contract-only inventory should be reconciled"
    (Some "reconciled")
    (Some (I.verdict_to_string inventory.verdict));
  Windtrap.equal
    Windtrap.bool
    ~msg:"inventory completeness should be true"
    true
    inventory.coverage.inventory_complete;
  Windtrap.equal
    Windtrap.bool
    ~msg:"by-contract rows are not a verification gap"
    true
    inventory.coverage.verification_complete
;;

let%test "a recorded resource with no executable probe is incomplete" =
  let target = target "byo" in
  let state =
    Sol_cli_cloud_destroy.State_represented [ resource "aws_db_instance.postgres[0]" ]
  in
  let inventory = collect target ~roots:[ root state ] ~cloud:(cloud [] []) in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an unobserved recorded class must not claim reconciliation"
    (Some "incomplete")
    (Some (I.verdict_to_string inventory.verdict));
  Windtrap.equal
    Windtrap.bool
    ~msg:"verification completeness must be false"
    false
    inventory.coverage.verification_complete
;;

let%test "an observed but unrecorded resource is attention_required" =
  let target = target "byo" in
  let disposition =
    Sol_cli_ownership_reconciliation.Recover
      { address = "aws_db_instance.postgres[0]"
      ; resource_class = "RDS instance"
      ; found = "sol-postgres"
      ; import_identity = "sol-postgres"
      }
  in
  let inventory =
    collect
      target
      ~roots:[ root Sol_cli_cloud_destroy.State_empty ]
      ~cloud:(cloud [] [ disposition ])
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an unrecorded observed resource needs attention"
    (Some "attention_required")
    (Some (I.verdict_to_string inventory.verdict));
  let row = List.hd inventory.rows in
  Windtrap.equal
    Windtrap.string
    ~msg:"the observed resource remains unrecorded"
    "unrecorded"
    (I.status_to_string row.status);
  match row.recovery with
  | I.Recoverable { address; _ } ->
    Windtrap.equal Windtrap.string ~msg:"address" "aws_db_instance.postgres[0]" address
  | _ -> failwith "expected a recoverable disposition"
;;

let%test "an unreadable root is unknown, not empty" =
  let target = target "byo" in
  let inventory =
    collect
      target
      ~roots:[ root (Sol_cli_cloud_destroy.State_unreadable "terraform show exited 1") ]
      ~cloud:(cloud [] [])
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an unreadable root must not be reconciled"
    (Some "unknown")
    (Some (I.verdict_to_string inventory.verdict));
  Windtrap.equal
    Windtrap.bool
    ~msg:"inventory completeness must be false"
    false
    inventory.coverage.inventory_complete;
  Windtrap.equal
    Windtrap.int
    ~msg:"the unreadable root is reported"
    1
    (List.length inventory.unknowns)
;;

let%test "a cloud collection blocker is not reconciled" =
  let target = target "byo" in
  let blocked =
    ({ state = Sol_cli_cloud_destroy.State_empty
     ; observations = []
     ; dispositions = []
     ; blockers = [ Sol_cli_cloud_wiring.No_cluster_name ]
     }
     : Sol_cli_cloud_wiring.cloud_collection)
  in
  let inventory =
    collect target ~roots:[ root Sol_cli_cloud_destroy.State_empty ] ~cloud:blocked
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a missing cluster identity cannot reconcile"
    (Some "incomplete")
    (Some (I.verdict_to_string inventory.verdict));
  Windtrap.equal
    Windtrap.int
    ~msg:"the blocker is reported"
    1
    (List.length inventory.unknowns)
;;

let%test "state-only is unverified even when state is readable" =
  let target = target "byo" in
  let inventory =
    collect
      target
      ~roots:[ root Sol_cli_cloud_destroy.State_empty ]
      ~cloud:(cloud [] [])
      ~state_only:true
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"state-only cannot establish presence or absence"
    (Some "unverified")
    (Some (I.verdict_to_string inventory.verdict))
;;

let%test "authorization state resources map to observed classes" =
  let open Sol_cli_provider_registry in
  let aws_policy =
    resource
      ~kind:"aws_iam_policy"
      ~name:(Some "sol-prod-orders-boundary")
      "aws_iam_policy.scheduler_boundary[\"orders_svc\"]"
  in
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"scheduler boundary policy maps to the broadened authorization policy class"
    (Some ("authorization IAM policy", Some "sol-prod-orders-boundary"))
    (inventory_auth_class Sol_cli_provider.Aws aws_policy);
  let aws_role_policy =
    resource
      ~kind:"aws_iam_role_policy"
      ~name:(Some "sol-prod-orders-svc")
      ~role:"sol-prod-orders-svc"
      "aws_iam_role_policy.workload[\"orders_svc\"]"
  in
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"inline role policy has an exact role -> policy identity"
    (Some
       ("authorization inline policy", Some "sol-prod-orders-svc -> sol-prod-orders-svc"))
    (inventory_auth_class Sol_cli_provider.Aws aws_role_policy);
  let gcp_scheduler =
    resource
      ~kind:"google_service_account"
      ~name:None
      ~email:"sol-prod-sched-abc@example.iam.gserviceaccount.com"
      "google_service_account.scheduler[\"orders_svc\"]"
  in
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"scheduler service account maps to its observed class"
    (Some
       ( "authorization scheduler service account"
       , Some "sol-prod-sched-abc@example.iam.gserviceaccount.com" ))
    (inventory_auth_class Sol_cli_provider.Gcp gcp_scheduler);
  let gcp_secret =
    resource
      ~kind:"google_secret_manager_secret_iam_member"
      ~name:None
      ~secret_id:"projects/p/secrets/sol-prod-api-key"
      ~role:"roles/secretmanager.secretAccessor"
      ~member:"serviceAccount:sol-prod-rt@example.iam.gserviceaccount.com"
      "google_secret_manager_secret_iam_member.serverless[\"api\"]"
  in
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string (Windtrap.option Windtrap.string)))
    ~msg:"secret IAM member maps to the existing secret-binding observation"
    (Some
       ( "authorization secret IAM binding"
       , Some
           "sol-prod-api-key: roles/secretmanager.secretAccessor -> \
            serviceAccount:sol-prod-rt@example.iam.gserviceaccount.com" ))
    (inventory_auth_class Sol_cli_provider.Gcp gcp_secret)
;;

let%test "the new authorization probes are advertised" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS inline role policies have a probe"
    true
    (List.mem "authorization inline policy" (Sol_cli_aws_absence.observed_classes ()));
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP scheduler identities have a probe"
    true
    (List.mem
       "authorization scheduler service account"
       (Sol_cli_gcp_absence.observed_classes ()));
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP serverless identities have a probe"
    true
    (List.mem
       "authorization serverless service account"
       (Sol_cli_gcp_absence.observed_classes ()))
;;

let%test "json keeps status and recovery distinct" =
  let target = target "byo" in
  let disposition =
    Sol_cli_ownership_reconciliation.Recover
      { address = "aws_db_instance.postgres[0]"
      ; resource_class = "RDS instance"
      ; found = "sol-postgres"
      ; import_identity = "sol-postgres"
      }
  in
  let inventory =
    collect
      target
      ~roots:[ root Sol_cli_cloud_destroy.State_empty ]
      ~cloud:(cloud [] [ disposition ])
  in
  let json = I.to_json inventory in
  let resources =
    match Sol_cli_json.field [ "resources" ] json with
    | `List rows -> rows
    | _ -> failwith "resources is not a list"
  in
  let row = List.hd resources in
  Windtrap.equal
    Windtrap.string
    ~msg:"status is a string"
    "unrecorded"
    (match Sol_cli_json.field [ "status" ] row with
     | `String value -> value
     | _ -> "not a string");
  Windtrap.equal
    Windtrap.string
    ~msg:"recovery is separate from status"
    "recoverable"
    (match Sol_cli_json.field [ "recovery"; "disposition" ] row with
     | `String value -> value
     | _ -> "not a string");
  Windtrap.equal
    Windtrap.string
    ~msg:"an observed-only object is not recorded"
    "not_recorded"
    (match Sol_cli_json.field [ "record" ] row with
     | `String value -> value
     | _ -> "not a string")
;;
