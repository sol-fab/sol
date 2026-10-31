open Sol_cli_target_report

let provider () =
  match Sol_cli_provider.of_string "aws" with
  | Some provider -> provider
  | None -> Windtrap.fail "aws should be a known provider"
;;

let target ?(kube_context = Some "prod-us-east-1") ?kubeconfig () : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = provider ()
  ; region = "us-east-1"
  ; registry = Some "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  ; base_domain = Some "acme.com"
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context
  ; kubeconfig
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_logs_url = None
  ; observability_logs_username = None
  ; observability_logs_password_env = None
  ; observability_metrics_url = None
  ; observability_metrics_username = None
  ; observability_metrics_password_env = None
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
  ; provider_fields = []
  ; secret_authorities = []
  }
;;

let value_of rows label = List.assoc_opt label rows

let all_text rows =
  rows |> List.concat_map (fun (label, value) -> [ label; value ]) |> String.concat " "
;;

let test_not_configured_points_at_the_field () =
  let message = Sol_cli_target_report.describe ~verbose:false Not_configured in
  assert (Sol_cli_string.contains ~needle:"kube_context" message);
  assert (Sol_cli_string.contains ~needle:"deploy_kubeconfig_command" message)
;;

let test_misconfigured_is_not_absence () =
  let reason =
    "this target resolves to k3d-sol-local, Sol's own cluster, which is a reserved \
     execution mode rather than a target: use `sol local <command>` for it, and point \
     this target at a cluster you own"
  in
  let quiet =
    Sol_cli_target_report.describe
      ~verbose:false
      (Misconfigured ("k3d-sol-local", reason))
  in
  assert (Sol_cli_string.contains ~needle:"reserved execution mode" quiet);
  assert (Sol_cli_string.contains ~needle:"<context>" quiet);
  assert (not (Sol_cli_string.contains ~needle:"k3d-sol-local" quiet));
  assert (not (Sol_cli_string.contains ~needle:"names no kube_context" quiet));
  let loud =
    Sol_cli_target_report.describe ~verbose:true (Misconfigured ("k3d-sol-local", reason))
  in
  assert (Sol_cli_string.contains ~needle:"k3d-sol-local" loud)
;;

let test_configured_is_not_checked_and_hides_the_context () =
  let message =
    Sol_cli_target_report.describe ~verbose:false (Configured "prod-us-east-1")
  in
  assert (Sol_cli_string.contains ~needle:"not checked" message);
  assert (Sol_cli_string.contains ~needle:"--check" message);
  assert (not (Sol_cli_string.contains ~needle:"prod-us-east-1" message))
;;

let test_verbose_shows_the_context () =
  let rows =
    Sol_cli_target_report.rows
      ~verbose:true
      (target ~kubeconfig:".sol/kubeconfigs/prod.kubeconfig" ())
      (Reachable "prod-us-east-1")
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"raw context available when asked for"
    (Some "prod-us-east-1")
    (value_of rows "kube context");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"kubeconfig available when asked for"
    (Some ".sol/kubeconfigs/prod.kubeconfig")
    (value_of rows "kubeconfig")
;;

let test_default_summary_never_names_the_context () =
  let statuses =
    [ Not_configured
    ; Misconfigured ("prod-us-east-1", "this target resolves to prod-us-east-1 somehow")
    ; Configured "prod-us-east-1"
    ; Reachable "prod-us-east-1"
    ; Unreachable ("prod-us-east-1", "connection refused")
    ; Unreadable ("prod-us-east-1", "error: forbidden")
    ]
  in
  statuses
  |> List.iter (fun status ->
    let text = all_text (Sol_cli_target_report.rows ~verbose:false (target ()) status) in
    assert (not (Sol_cli_string.contains ~needle:"prod-us-east-1" text)))
;;

let test_rows_describe_the_target_not_a_cluster () =
  let rows = Sol_cli_target_report.rows ~verbose:false (target ()) (Configured "c") in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"region"
    (Some "us-east-1")
    (value_of rows "region");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"cluster"
    (Some "acme-prod")
    (value_of rows "cluster");
  Windtrap.equal
    Windtrap.bool
    ~msg:"provider present"
    true
    (Option.is_some (value_of rows "provider"));
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no target path by default"
    None
    (value_of rows "target");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no env by default"
    None
    (value_of rows "env")
;;

let test_unreachable_carries_the_reason () =
  let message =
    Sol_cli_target_report.describe
      ~verbose:true
      (Unreachable ("prod-us-east-1", "connection refused"))
  in
  assert (Sol_cli_string.contains ~needle:"connection refused" message);
  let quiet =
    Sol_cli_target_report.describe
      ~verbose:false
      (Unreachable ("prod-us-east-1", "connection refused"))
  in
  assert (Sol_cli_string.contains ~needle:"connection refused" quiet);
  assert (not (Sol_cli_string.contains ~needle:"prod-us-east-1" quiet))
;;

let test_json_matches_rows () =
  let rows = Sol_cli_target_report.rows ~verbose:false (target ()) (Configured "c") in
  let json = Sol_cli_target_report.to_json ~verbose:false (target ()) (Configured "c") in
  let from_json =
    match json with
    | `Assoc fields ->
      fields
      |> List.map (fun (key, value) ->
        match value with
        | `String value -> key, value
        | _ -> Windtrap.fail "expected string values")
    | _ -> Windtrap.fail "expected an object"
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"same rows"
    rows
    from_json
;;

let test_the_live_state_rows_follow_readiness () =
  let rows =
    Sol_cli_target_report.rows
      ~platform:"Ready"
      ~cloud:"Healthy"
      ~drift:"None — Terraform's recorded state matches the provider's observed reality"
      ~last_operation:"unavailable — no record"
      ~verbose:false
      (target ())
      (Reachable "c")
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"cloud"
    (Some "Healthy")
    (value_of rows "cloud");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"drift"
    (Some "None — Terraform's recorded state matches the provider's observed reality")
    (value_of rows "drift");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"last operation"
    (Some "unavailable — no record")
    (value_of rows "last operation");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the live state rows keep their order"
    [ "platform"; "cloud"; "drift"; "last operation" ]
    (List.filter
       (fun label -> List.mem label [ "platform"; "cloud"; "drift"; "last operation" ])
       (List.map fst rows))
;;

let test_the_offline_summary_omits_the_checked_rows () =
  let rows = Sol_cli_target_report.rows ~verbose:false (target ()) (Configured "c") in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no cloud row"
    None
    (value_of rows "cloud");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"no drift row"
    None
    (value_of rows "drift");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the last-operation row needs no check and is always reported"
    (Some Sol_cli_target_report.last_operation_unavailable)
    (value_of rows "last operation")
;;

let test_last_operation_is_unavailable_not_none () =
  let message = Sol_cli_target_report.last_operation_unavailable in
  assert (Sol_cli_string.contains ~needle:"unavailable" message);
  assert (Sol_cli_string.contains ~needle:"ADR 0003" message);
  assert (not (String.equal (String.trim message) "none"))
;;

let test_json_carries_the_live_state_fields () =
  let json =
    Sol_cli_target_report.to_json
      ~cloud:"Healthy"
      ~drift:
        "Detected — Terraform's recorded state differs from the provider's observed \
         reality"
      ~last_operation:Sol_cli_target_report.last_operation_unavailable
      ~verbose:false
      (target ())
      (Configured "c")
  in
  match json with
  | `Assoc fields ->
    let value name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Some value
      | _ -> None
    in
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"cloud"
      (Some "Healthy")
      (value "cloud");
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"drift"
      (Some
         "Detected — Terraform's recorded state differs from the provider's observed \
          reality")
      (value "drift");
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"last operation"
      (Some Sol_cli_target_report.last_operation_unavailable)
      (value "last operation")
  | _ -> Windtrap.fail "expected an object"
;;

let%test "target_report: not configured points at the field" =
  test_not_configured_points_at_the_field ()
;;

let%test "target_report: a misconfigured destination is not absence" =
  test_misconfigured_is_not_absence ()
;;

let%test "target_report: configured is not checked and hides the context" =
  test_configured_is_not_checked_and_hides_the_context ()
;;

let%test "target_report: the reason is filtered too" =
  (fun () ->
     let reason = "error: context \"prod-us-east-1\" does not exist" in
     let quiet =
       Sol_cli_target_report.describe
         ~verbose:false
         (Unreachable ("prod-us-east-1", reason))
     in
     assert (Sol_cli_string.contains ~needle:"does not exist" quiet);
     assert (not (Sol_cli_string.contains ~needle:"prod-us-east-1" quiet));
     assert (Sol_cli_string.contains ~needle:"<context>" quiet);
     let loud =
       Sol_cli_target_report.describe
         ~verbose:true
         (Unreachable ("prod-us-east-1", reason))
     in
     assert (Sol_cli_string.contains ~needle:"prod-us-east-1" loud))
    ()
;;

let%test "target_report: verbose shows the context" = test_verbose_shows_the_context ()

let%test "target_report: default summary never names the context" =
  test_default_summary_never_names_the_context ()
;;

let%test "target_report: rows describe the target" =
  test_rows_describe_the_target_not_a_cluster ()
;;

let%test "target_report: unreachable carries the reason" =
  test_unreachable_carries_the_reason ()
;;

let%test "target_report: an unreadable probe says Sol cannot tell" =
  (fun () ->
     let quiet =
       Sol_cli_target_report.describe
         ~verbose:false
         (Unreadable ("prod-us-east-1", "error: forbidden"))
     in
     assert (Sol_cli_string.contains ~needle:"error: forbidden" quiet);
     assert (not (Sol_cli_string.contains ~needle:"prod-us-east-1" quiet));
     assert (Sol_cli_string.contains ~needle:"cannot tell" quiet);
     let loud =
       Sol_cli_target_report.describe
         ~verbose:true
         (Unreadable ("prod-us-east-1", "error: forbidden"))
     in
     assert (Sol_cli_string.contains ~needle:"prod-us-east-1" loud))
    ()
;;

let%test "target_report: json matches rows" = test_json_matches_rows ()

let%test "target_report: the live state rows follow readiness" =
  test_the_live_state_rows_follow_readiness ()
;;

let%test "target_report: the offline summary omits the checked rows" =
  test_the_offline_summary_omits_the_checked_rows ()
;;

let%test "target_report: last operation is unavailable, not none" =
  test_last_operation_is_unavailable_not_none ()
;;

let%test "target_report: json carries the live state fields" =
  test_json_carries_the_live_state_fields ()
;;
