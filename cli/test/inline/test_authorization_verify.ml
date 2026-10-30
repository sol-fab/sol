let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let target ?(fields = []) provider =
  { Sol_cli_config.name = "dev/aws/us-east-1"
  ; env = "dev"
  ; provider
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = None
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_traces_url = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields = [ Sol_cli_provider.to_string provider, fields ]
  ; secret_authorities = []
  }
;;

let workload ?(unit = "payments-api") ?(namespace = "payments") secrets =
  { Sol_cli_provider_capabilities.unit; namespace; secrets }
;;

let aws_run ~decision argv =
  if List.mem "get-caller-identity" argv
  then Ok "123456789012\n"
  else if List.mem "simulate-principal-policy" argv
  then Ok (Printf.sprintf {|["%s"]|} decision)
  else Error ("unexpected aws command: " ^ String.concat " " argv)
;;

let gcp_run ~members argv =
  if List.mem "get-iam-policy" argv
  then
    Ok
      (Printf.sprintf
         {|{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":[%s]}]}|}
         members)
  else Error ("unexpected gcloud command: " ^ String.concat " " argv)
;;

let test_aws_effective_grant_passes () =
  match
    Sol_cli_provider_capabilities.aws_effective_access
      ~run:(aws_run ~decision:"allowed")
      (target Sol_cli_provider.Aws)
      [ workload [ "stripe" ] ]
  with
  | Ok () -> ()
  | Error message -> Windtrap.fail message
;;

let test_aws_ineffective_grant_refuses_at_plan_time () =
  match
    Sol_cli_provider_capabilities.aws_effective_access
      ~run:(aws_run ~decision:"implicitDeny")
      (target Sol_cli_provider.Aws)
      [ workload [ "stripe" ] ]
  with
  | Ok () -> Windtrap.fail "an ineffective grant passed verification"
  | Error message ->
    check_bool
      "names the unit"
      true
      (Sol_cli_string.contains ~needle:"payments-api" message);
    check_bool
      "names the grant"
      true
      (Sol_cli_string.contains ~needle:"secret/stripe" message);
    check_bool
      "names the reconciliation to run"
      true
      (Sol_cli_string.contains ~needle:"sol grants apply dev/aws/us-east-1" message)
;;

let test_aws_no_declaration_observes_nothing () =
  let run argv =
    Windtrap.fail ("a unit with no grant was observed: " ^ String.concat " " argv)
  in
  check_bool
    "no declared grant means no cloud observation"
    true
    (Result.is_ok
       (Sol_cli_provider_capabilities.aws_effective_access
          ~run
          (target Sol_cli_provider.Aws)
          [ workload [] ]))
;;

let test_aws_unobservable_call_fails_closed () =
  let run _ =
    Error "AccessDenied: not authorized to perform iam:SimulatePrincipalPolicy"
  in
  match
    Sol_cli_provider_capabilities.aws_effective_access
      ~run
      (target Sol_cli_provider.Aws)
      [ workload [ "stripe" ] ]
  with
  | Ok () -> Windtrap.fail "an unobservable check was treated as effective"
  | Error message ->
    check_bool
      "the reason is reported"
      true
      (Sol_cli_string.contains ~needle:"AccessDenied" message)
;;

let test_gcp_effective_grant_passes () =
  let target = target ~fields:[ "project_id", "my-project" ] Sol_cli_provider.Gcp in
  let member = {|"serviceAccount:my-project.svc.id.goog[payments/payments-api]"|} in
  match
    Sol_cli_provider_capabilities.gcp_effective_access
      ~run:(gcp_run ~members:member)
      target
      [ workload [ "stripe" ] ]
  with
  | Ok () -> ()
  | Error message -> Windtrap.fail message
;;

let test_gcp_ineffective_grant_refuses () =
  let target = target ~fields:[ "project_id", "my-project" ] Sol_cli_provider.Gcp in
  match
    Sol_cli_provider_capabilities.gcp_effective_access
      ~run:(gcp_run ~members:{|"serviceAccount:someone-else"|})
      target
      [ workload [ "stripe" ] ]
  with
  | Ok () -> Windtrap.fail "an ineffective GCP grant passed verification"
  | Error message ->
    check_bool
      "names the grant"
      true
      (Sol_cli_string.contains ~needle:"secret/stripe" message);
    check_bool
      "names the reconciliation"
      true
      (Sol_cli_string.contains ~needle:"sol grants apply" message)
;;

let test_unit_name_is_the_kubernetes_identity () =
  let service =
    { Sol_cli_manifest.domain = "payments"
    ; name = "charge_svc"
    ; primitive = Sol_cli_manifest.Svc
    ; dir = "charge_svc"
    }
  in
  match Sol_cli_authorization_reconcile.unit_name service with
  | Error message -> Windtrap.fail message
  | Ok unit -> check_string "sanitized to the ServiceAccount name" "charge-svc" unit
;;

let test_workloads_group_secret_grants_by_unit () =
  let grants =
    [ { Sol_cli_authorization.unit = "payments-api"
      ; capability = "secret"
      ; resource = "stripe"
      }
    ; { Sol_cli_authorization.unit = "payments-api"
      ; capability = "secret"
      ; resource = "legacy"
      }
    ; { Sol_cli_authorization.unit = "checkout-api"
      ; capability = "secret"
      ; resource = "stripe"
      }
    ]
  in
  let namespace_of = function
    | "payments-api" -> Some "payments"
    | "checkout-api" -> Some "checkout"
    | _ -> None
  in
  match Sol_cli_authorization_reconcile.workloads ~grants ~namespace_of with
  | Error message -> Windtrap.fail message
  | Ok workloads ->
    check_bool "one workload per unit" true (List.length workloads = 2);
    let payments =
      List.find
        (fun w -> String.equal w.Sol_cli_provider_capabilities.unit "payments-api")
        workloads
    in
    check_string "namespace" "payments" payments.namespace;
    check_bool
      "every secret of the unit"
      true
      (List.equal String.equal [ "stripe"; "legacy" ] payments.secrets)
;;

let test_observation_is_read_only () =
  let seen = ref [] in
  let run argv =
    seen := argv :: !seen;
    aws_run ~decision:"allowed" argv
  in
  ignore
    (Sol_cli_provider_capabilities.aws_effective_access
       ~run
       (target Sol_cli_provider.Aws)
       [ workload [ "stripe" ] ]);
  let mutating =
    [ "create-role"
    ; "delete-role"
    ; "put-role-policy"
    ; "delete-role-policy"
    ; "attach-role-policy"
    ; "detach-role-policy"
    ; "create-policy"
    ; "pass-role"
    ]
  in
  check_bool
    "no verification call mutates IAM"
    false
    (List.exists
       (fun argv -> List.exists (fun verb -> List.mem verb argv) mutating)
       !seen);
  check_bool
    "the AWS simulation mechanism is used"
    true
    (List.exists (fun argv -> List.mem "simulate-principal-policy" argv) !seen)
;;

let%test "verify: an effective AWS grant passes" = test_aws_effective_grant_passes ()

let%test
    "verify: an ineffective AWS grant is refused at plan time with the reconciliation"
  =
  test_aws_ineffective_grant_refuses_at_plan_time ()
;;

let%test "verify: a unit with no declared grant triggers no cloud observation" =
  test_aws_no_declaration_observes_nothing ()
;;

let%test "verify: an unobservable check fails closed" =
  test_aws_unobservable_call_fails_closed ()
;;

let%test "verify: an effective GCP grant passes" = test_gcp_effective_grant_passes ()

let%test "verify: an ineffective GCP grant is refused" =
  test_gcp_ineffective_grant_refuses ()
;;

let%test "verify: a unit identity is the Kubernetes ServiceAccount name" =
  test_unit_name_is_the_kubernetes_identity ()
;;

let%test "verify: declared grants are grouped by unit for observation" =
  test_workloads_group_secret_grants_by_unit ()
;;

let%test "verify: the observation path never mutates IAM" =
  test_observation_is_read_only ()
;;
