open Result.Syntax

type failure =
  | Terraform_failed of string
  | Refused of string

let failure_to_string = function
  | Terraform_failed message | Refused message -> message
;;

let of_apply_failure = function
  | Sol_cli_cloud_apply.Terraform_failed message -> Terraform_failed message
  | Sol_cli_cloud_apply.Refused message -> Refused message
;;

type drift =
  | In_sync
  | Detected
  | Unknown of string

let drift_to_string = function
  | In_sync -> "None — Terraform's recorded state matches the provider's observed reality"
  | Detected ->
    "Detected — Terraform's recorded state differs from the provider's observed reality; \
     `sol plan` shows the changes"
  | Unknown reason -> "Unknown — " ^ reason
;;

let drift_of_refresh = function
  | Ok _ -> In_sync
  | Error (Sol_cli_process.Non_zero { exit_code = 2; _ }) -> Detected
  | Error error -> Unknown (Sol_cli_process.error_to_string error)
;;

type environment =
  { cluster : Sol_cli_cluster.t option
  ; infra_dir : string
  }

type outcome =
  | Applied of environment
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
      }

let refused message = Error (Refused message)

let asset_root ~assets provider role =
  let dir = Sol_cli_platform_assets.cloud_root assets provider role in
  if Sys.file_exists dir
  then Ok dir
  else refused (Printf.sprintf "Terraform module not found: %s" dir)
;;

let resolve_var_file ~flag ~target =
  let cwd = Sys.getcwd () in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  Sol_cli_terraform_vars.var_file ~cwd ~workspace_root ~flag ~target
;;

let refuse_sensitive_vars ~infra_dir ~vars =
  let* sensitive =
    Sol_cli_sensitive_vars.declared ~root:infra_dir
    |> Result.map_error (fun message -> Refused message)
  in
  Sol_cli_sensitive_vars.refuse_on_command_line ~sensitive ~vars
  |> Result.map_error (fun message -> Refused message)
;;

let guard_previous_operation ~constructive ~accept_unresolved ~chdir ~backend_config =
  Sol_cli_state_guard.check ~constructive ~accept_unresolved ~chdir ~backend_config
  |> Result.map_error (fun message -> Refused message)
;;

let report_ownership_reconciliation
      ~provider
      ~target_cfg
      ~cluster_name
      ~infra_dir
      ~var_files
      ~vars
  =
  match
    Sol_cli_cloud_wiring.reconcile_ownership
      ~provider
      ~target_cfg
      ~cluster_name
      ~infra_dir
      ~var_files
      ~vars
      ~act:true
  with
  | Error message ->
    Sol_cli_report.warn
      "warning: ownership reconciliation could not complete -- %s"
      message
  | Ok reconciliation ->
    if reconciliation.restored <> []
    then
      Sol_cli_report.app
        "%s"
        (Sol_cli_ownership_reconciliation.outcome reconciliation.dispositions);
    let refused =
      List.filter
        (function
          | Sol_cli_ownership_reconciliation.Cannot_recover _
          | Sol_cli_ownership_reconciliation.Unmapped _ -> true
          | Sol_cli_ownership_reconciliation.Unresolved _ -> false
          | Sol_cli_ownership_reconciliation.Recover _
          | Sol_cli_ownership_reconciliation.Already_owned _
          | Sol_cli_ownership_reconciliation.By_contract _ -> false)
        reconciliation.dispositions
    in
    if refused <> []
    then
      Sol_cli_report.warn
        "warning: %d resource(s) the provider holds for this target cannot be attributed \
         to a Terraform address automatically; run 'sol target reconcile %s --explain' \
         to see what was checked."
        (List.length refused)
        target_cfg.Sol_cli_config.name
;;

let reconcile_ownership_at ~provider ~target_cfg ~infra_dir ~var_files ~vars =
  match target_cfg.Sol_cli_config.cluster_name with
  | Some cluster_name when not (Sol_cli_string.is_blank cluster_name) ->
    report_ownership_reconciliation
      ~provider
      ~target_cfg
      ~cluster_name
      ~infra_dir
      ~var_files
      ~vars
  | _ ->
    Sol_cli_report.warn
      "warning: ownership reconciliation is skipped: the target declares no cluster_name \
       to attribute provider resources by."
;;

let report_cleanup_evidence = function
  | Sol_cli_cloud_destroy.Cleanup_failed message ->
    Sol_cli_report.warn
      "warning: removing the bootstrap access failed (%s); the elevated access may still \
       be applied"
      message
  | Sol_cli_cloud_destroy.Cleanup_not_needed | Sol_cli_cloud_destroy.Cleanup_succeeded ->
    ()
;;

type prepared =
  { provider : Sol_cli_provider.t
  ; target_cfg : Sol_cli_config.target
  ; cloud_target : Sol_cli_cloud_lifecycle.cloud_target
  ; cloud_backend : string list
  ; platform_backend : string list
  ; infra_dir : string
  ; platform_dir : string
  ; inputs : Sol_cli_cloud_wiring.terraform_inputs
  }

let prepare_config ~strict ~assets ~config ~var_file ~vars () =
  let target_cfg = config.Sol_cli_config.target in
  let* () =
    if strict && not (Sol_cli_config.target_declared target_cfg)
    then
      refused
        (Printf.sprintf
           "target %S is not declared in %s -- terraform apply/destroy require an \
            explicit target, even an empty one, so a typo'd or unintended target can't \
            silently inherit sol.yml's shared defaults and mutate infrastructure anyway."
           target_cfg.name
           (Sol_cli_config.target_source target_cfg))
    else Ok ()
  in
  let* config_vars =
    Sol_cli_terraform_vars.of_config ~workspace:(Sol_cli_workspace.current_name ()) config
    |> Result.map_error (fun message -> Refused message)
  in
  let config_vars = Sol_cli_terraform.kv_args config_vars in
  let provider = target_cfg.Sol_cli_config.provider in
  let* () =
    Sol_cli_provider_capabilities.validate_target provider target_cfg
    |> Result.map_error (fun message -> Refused message)
  in
  let var_file =
    resolve_var_file ~flag:var_file ~target:target_cfg.Sol_cli_config.terraform_var_file
  in
  let vars =
    Sol_cli_config.vars_with_profile_precedence
      ~has_profile:(Option.is_some target_cfg.Sol_cli_config.profile)
      ~cli_vars:vars
      ~config_vars
  in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  let* platform_shape =
    Sol_cli_config.platform_shape config
    |> Result.map_error (fun message -> Refused message)
  in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target ~platform_shape target_cfg
    |> Result.map_error (fun message -> Refused message)
  in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
  Ok
    { provider
    ; target_cfg
    ; cloud_target
    ; cloud_backend
    ; platform_backend
    ; infra_dir =
        Sol_cli_terraform_workdir.chdir
          ~provider
          ~role:Sol_cli_platform_assets.Cluster
          ~backend_config:cloud_backend
    ; platform_dir =
        Sol_cli_terraform_workdir.chdir
          ~provider
          ~role:Sol_cli_platform_assets.Platform
          ~backend_config:platform_backend
    ; inputs = { Sol_cli_cloud_wiring.var_files = Option.to_list var_file; vars }
    }
;;

let prepare ~strict ~assets ~target ~var_file ~vars () =
  let* config =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error (fun error -> Refused (Sol_cli_config.error_to_string error))
  in
  prepare_config ~strict ~assets ~config ~var_file ~vars ()
;;

let report_starting { provider; _ } =
  Sol_cli_report.app
    "\nInitializing cloud infrastructure (%s)..."
    (Sol_cli_provider.to_string provider)
;;

let refresh_only_drift ~assets ~provider ~infra_dir ~cloud_backend ~var_files ~vars =
  match
    Sol_cli_terraform_workdir.materialize
      ~assets
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      ~backend_config:cloud_backend
  with
  | Error message -> Unknown message
  | Ok _ ->
    (match
       Sol_cli_terraform.init
         ~echo:false
         ~chdir:infra_dir
         ~backend_config:cloud_backend
         ()
     with
     | Error error -> Unknown (Sol_cli_process.error_to_string error)
     | Ok _ ->
       Sol_cli_terraform.plan_refresh_only ~chdir:infra_dir ~var_files ~vars ()
       |> drift_of_refresh)
;;

let drift ~assets ~target ~var_file ~vars () =
  match prepare ~strict:false ~assets ~target ~var_file ~vars () with
  | Error failure -> Unknown (failure_to_string failure)
  | Ok { provider; infra_dir; cloud_backend; inputs; _ } ->
    let { Sol_cli_cloud_wiring.var_files; vars } = inputs in
    refresh_only_drift ~assets ~provider ~infra_dir ~cloud_backend ~var_files ~vars
;;

let plan_prepared ~assets ~run_log prepared =
  let { provider; cloud_target; infra_dir; cloud_backend; inputs; _ } = prepared in
  report_starting prepared;
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let* () =
    Sol_cli_cloud_wiring.init
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      cloud_backend
    |> Result.map_error of_apply_failure
  in
  Sol_cli_cloud_wiring.plan ~assets ~run_log ~cloud_target ~inputs
  |> Result.map_error of_apply_failure
;;

let plan ~assets ~run_log ~target ~var_file ~vars () =
  let* prepared = prepare ~strict:false ~assets ~target ~var_file ~vars () in
  plan_prepared ~assets ~run_log prepared
;;

let plan_config ~assets ~run_log ~config ~var_file ~vars () =
  let* prepared = prepare_config ~strict:false ~assets ~config ~var_file ~vars () in
  plan_prepared ~assets ~run_log prepared
;;

let apply_config
      ?confirm_ecr_removal
      ?accept_unresolved
      ~assets
      ~run_log
      ~config
      ~var_file
      ~vars
      ()
  =
  let* prepared = prepare_config ~strict:true ~assets ~config ~var_file ~vars () in
  let { provider
      ; target_cfg
      ; cloud_target
      ; infra_dir
      ; platform_dir
      ; cloud_backend
      ; platform_backend
      ; inputs
      ; _
      }
    =
    prepared
  in
  report_starting prepared;
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"applying"
      ~leaves_target_standing:false
    |> Result.map_error (fun message -> Refused message)
  in
  let* () =
    guard_previous_operation
      ~constructive:true
      ~accept_unresolved:(Option.value accept_unresolved ~default:false)
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:true
      ~accept_unresolved:(Option.value accept_unresolved ~default:false)
      ~chdir:platform_dir
      ~backend_config:platform_backend
  in
  let* () =
    Sol_cli_cloud_wiring.init
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      cloud_backend
    |> Result.map_error of_apply_failure
  in
  let var_files = inputs.Sol_cli_cloud_wiring.var_files in
  let vars = inputs.Sol_cli_cloud_wiring.vars in
  reconcile_ownership_at ~provider ~target_cfg ~infra_dir ~var_files ~vars;
  let* deps =
    Sol_cli_cloud_wiring.apply_deps
      ~assets
      ~confirm_ecr_removal:(Option.value confirm_ecr_removal ~default:false)
      ~run_log
      ~cloud_target
      ~inputs
    |> Result.map_error of_apply_failure
  in
  match Sol_cli_cloud_apply.execute ~deps with
  | Sol_cli_cloud_apply.Applied ->
    let cluster =
      match
        Sol_cli_provider_registry.of_root provider ~target:target_cfg ~chdir:infra_dir
      with
      | Ok cluster -> cluster
      | Error failure ->
        Sol_cli_report.warn
          "warning: the apply completed but the environment could not be read back from \
           Terraform's outputs (%s), so this run cannot name the cluster it just \
           provisioned."
          (Sol_cli_provider_registry.resolution_failure_to_string failure);
        None
    in
    let* () =
      Sol_cli_authorization_stage.fence ~assets ~run_log ~target:target_cfg
      |> Result.map (fun outcome ->
        Sol_cli_report.app "  %s" (Sol_cli_authorization_stage.outcome_to_string outcome))
      |> Result.map_error (fun message -> Refused message)
    in
    Ok (Applied { cluster; infra_dir })
  | Sol_cli_cloud_apply.Apply_failed { failure; cleanup } ->
    report_cleanup_evidence cleanup;
    Sol_cli_report.warn
      "warning: the apply failed, so Terraform's error is not evidence about what the \
       provider holds. Observing the provider independently and reconciling what can be \
       attributed exactly:";
    reconcile_ownership_at ~provider ~target_cfg ~infra_dir ~var_files ~vars;
    Ok (Apply_failed { failure = of_apply_failure failure; cleanup })
;;

let apply
      ?confirm_ecr_removal
      ?accept_unresolved
      ~assets
      ~run_log
      ~target
      ~var_file
      ~vars
      ()
  =
  let* config =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error (fun error -> Refused (Sol_cli_config.error_to_string error))
  in
  apply_config
    ?confirm_ecr_removal
    ?accept_unresolved
    ~assets
    ~run_log
    ~config
    ~var_file
    ~vars
    ()
;;
