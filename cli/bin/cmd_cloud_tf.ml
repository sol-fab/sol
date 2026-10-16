open Cmdliner
open Result.Syntax

let print_outputs infra_dir =
  match
    Sol_cli_terraform.output_json ~chdir:infra_dir ()
    |> Result.map (fun r -> r.Sol_cli_process.stdout)
  with
  | Error e ->
    Printf.printf
      "  (could not retrieve terraform outputs: %s)\n%!"
      (Sol_cli_process.error_to_string e)
  | Ok json ->
    (match Sol_cli_terraform_outputs.displayable json with
     | Ok outputs ->
       outputs
       |> List.iter (fun output -> print_endline (Sol_cli_terraform_outputs.line output))
     | Error reason -> Printf.printf "  (could not read terraform outputs: %s)\n%!" reason)
;;

let refuse message = Error (Sol_cli_exit.error message)

let provider_of_target_path target =
  match String.split_on_char '/' target with
  | [ _env; provider; _region ] ->
    (match Sol_cli_provider.of_string provider with
     | Some provider -> Ok provider
     | None ->
       refuse (Printf.sprintf "unsupported provider %S in target %S." provider target))
  | _ -> refuse "target must look like <env>/<provider>/<region>."
;;

let check_terraform () =
  if Sol_cli_terraform.which_check ()
  then Ok ()
  else
    refuse
      (Printf.sprintf
         "%S not found in PATH.\n  Install: %s"
         "terraform"
         "https://developer.hashicorp.com/terraform/install")
;;

let resolve_assets () =
  Sol_cli_platform_assets.resolve ()
  |> Sol_cli_exit.of_error Sol_cli_platform_assets.error_to_string
;;

let asset_root ~assets provider role =
  let dir = Sol_cli_platform_assets.cloud_root assets provider role in
  if Sys.file_exists dir then Ok dir else refuse ("Terraform module not found: " ^ dir)
;;

let require_cloud_root ~driver =
  match (Sol_cli_provider_capabilities.capabilities_of driver).root_status with
  | Sol_cli_provider_capabilities.Root_present -> Ok ()
  | Sol_cli_provider_capabilities.Root_not_applicable ->
    refuse
      (Printf.sprintf
         "the %s driver owns no cloud Terraform root: it is bring-your-own \
          infrastructure, so Sol has no provider lifecycle to plan, apply or destroy. \
          `sol deploy` consumes the cluster; it does not manage the substrate (DEC-051)."
         (Sol_cli_provider.to_string driver))
  | Sol_cli_provider_capabilities.Root_not_implemented ->
    refuse
      (Printf.sprintf
         "the %s driver is registered but has no cloud Terraform root yet, so there is \
          nothing for Sol to plan, apply or destroy."
         (Sol_cli_provider.to_string driver))
;;

type action =
  | Plan
  | Apply

let action_of_flags plan apply =
  match plan, apply with
  | true, false -> `Ok Plan
  | false, true -> `Ok Apply
  | false, false -> `Ok Plan
  | true, true -> `Error (false, "--plan and --apply are mutually exclusive")
;;

let resolve_var_file ~flag ~target =
  let cwd = Sys.getcwd () in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  Sol_cli_terraform_vars.var_file ~cwd ~workspace_root ~flag ~target
;;

let target_vars ~strict target =
  Sol_cli_terraform_vars.of_target
    ~strict
    ~workspace:(Sol_cli_workspace.current_name ())
    target
  |> Result.map (fun (vars, config) -> Sol_cli_terraform.kv_args vars, config)
  |> Sol_cli_exit.of_msg
;;

let guard_previous_operation ~constructive ~accept_unresolved ~chdir ~backend_config =
  Sol_cli_state_guard.check ~constructive ~accept_unresolved ~chdir ~backend_config
  |> Sol_cli_exit.of_msg
;;

let refuse_sensitive_vars ~infra_dir ~vars =
  match
    Result.bind (Sol_cli_sensitive_vars.declared ~root:infra_dir) (fun sensitive ->
      Sol_cli_sensitive_vars.refuse_on_command_line ~sensitive ~vars)
  with
  | Ok () -> Ok ()
  | Error msg -> Error (Sol_cli_exit.failure ("\nerror: " ^ msg))
;;

let report_cleanup_evidence = function
  | Sol_cli_cloud_destroy.Cleanup_failed message ->
    Printf.eprintf
      "warning: removing the bootstrap access failed (%s); the elevated access may still \
       be applied\n\
       %!"
      message
  | Sol_cli_cloud_destroy.Cleanup_not_needed | Sol_cli_cloud_destroy.Cleanup_succeeded ->
    ()
;;

let report_verification observation =
  Printf.printf "%s%!" (Sol_cli_destroy_verification.report observation)
;;

let workdir provider role ~backend_config =
  Sol_cli_terraform_workdir.chdir ~provider ~role ~backend_config
;;

let reconcile_ownership_at ~provider ~target_cfg ~infra_dir ~var_files ~vars =
  Sol_cli_environment_stage.reconcile_ownership_at
    ~provider
    ~target_cfg
    ~infra_dir
    ~var_files
    ~vars
;;

let exit_of_environment_failure = function
  | Sol_cli_environment_stage.Terraform_failed message ->
    Sol_cli_exit.failure ("\n" ^ message)
  | Sol_cli_environment_stage.Refused message -> Sol_cli_exit.error message
;;

let cloud_init
      ?(confirm_ecr_removal = false)
      ?(accept_unresolved = false)
      ~target
      ~var_file
      ~vars
      ~action
      ()
  =
  let* provider = provider_of_target_path target in
  let* () = require_cloud_root ~driver:provider in
  let* () = check_terraform () in
  let* assets = resolve_assets () in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-apply" () in
  match action with
  | Plan ->
    (match Sol_cli_environment_stage.plan ~assets ~run_log ~target ~var_file ~vars () with
     | Error failure -> Error (exit_of_environment_failure failure)
     | Ok () ->
       Printf.printf "\nDone. Re-run with 'sol deploy' to reconcile the target.\n%!";
       Ok ())
  | Apply ->
    (match
       Sol_cli_environment_stage.apply
         ~confirm_ecr_removal
         ~accept_unresolved
         ~assets
         ~run_log
         ~target
         ~var_file
         ~vars
         ()
     with
     | Ok (Sol_cli_environment_stage.Applied { infra_dir; _ }) ->
       Printf.printf "\nProvisioned endpoints:\n%!";
       print_outputs infra_dir;
       Printf.printf "\nDone.\n%!";
       Ok ()
     | Ok (Sol_cli_environment_stage.Apply_failed { failure; _ }) ->
       Error (exit_of_environment_failure failure)
     | Error failure -> Error (exit_of_environment_failure failure))
;;

let report_degradations = function
  | [] -> ()
  | degradations ->
    degradations
    |> List.iter (fun message ->
      Printf.eprintf
        "warning: a preparation degraded and destruction continued -- %s\n%!"
        message)
;;

let declared_workload_namespaces () =
  match Sol_cli_workspace_model.load_cwd () with
  | Error message ->
    Sol_cli_report.warn
      "warning: the workspace's declared services could not be read (%s), so the \
       workloads it deployed cannot be released by namespace before the substrate is \
       destroyed"
      message;
    []
  | Ok facts ->
    let workspace = Sol_cli_workspace.current_name () in
    Sol_cli_workspace_model.services facts
    |> List.filter_map (fun (service : Sol_cli_manifest.service) ->
      match Sol_cli_deployment_plan.namespace_name ~workspace ~domain:service.domain with
      | Ok namespace -> Some namespace
      | Error message ->
        Sol_cli_report.warn "warning: %s" message;
        None)
    |> List.sort_uniq String.compare
;;

(* Destroy consumes the target intent its caller already resolved
   (`Sol_cli_config.load_for_target`, the same resolution `sol plan` and `sol deploy`
   read), so the provider and the Terraform variables come from the one typed target
   rather than being re-derived from the target string here. Every destruction safety
   policy below is unchanged. *)
let cloud_destroy ~target ~resolved_config ~var_file ~vars ~action ~accept_unreleased () =
  let target_cfg = resolved_config.Sol_cli_config.target in
  let provider = target_cfg.Sol_cli_config.provider in
  let* () = require_cloud_root ~driver:provider in
  let* () = check_terraform () in
  let pname = Sol_cli_provider.to_string provider in
  let* assets = resolve_assets () in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-destroy" () in
  let* () =
    if action = Apply && not (Sol_cli_config.target_declared target_cfg)
    then
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "target %S is not declared in %s -- terraform apply/destroy require an \
               explicit target, even an empty one, so a typo'd or unintended target \
               can't silently inherit sol.yml's shared defaults and mutate \
               infrastructure anyway."
              target
              (Sol_cli_config.target_source target_cfg)))
    else Ok ()
  in
  let* config_vars =
    Sol_cli_terraform_vars.of_config
      ~workspace:(Sol_cli_workspace.current_name ())
      resolved_config
    |> Result.map Sol_cli_terraform.kv_args
    |> Sol_cli_exit.of_msg
  in
  let var_file = resolve_var_file ~flag:var_file ~target:target_cfg.terraform_var_file in
  let vars = config_vars @ vars in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  let* retention =
    match target_cfg.destroy_retention with
    | None -> Ok Sol_cli_cloud_lifecycle.default_destroy_retention
    | Some raw ->
      Sol_cli_cloud_lifecycle.destroy_retention_of_string raw |> Sol_cli_exit.of_msg
  in
  let* platform_shape =
    Sol_cli_config.platform_shape resolved_config |> Sol_cli_exit.of_msg
  in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target ~platform_shape target_cfg |> Sol_cli_exit.of_msg
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let infra_dir =
    workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
  let platform_dir =
    workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:platform_dir
      ~backend_config:platform_backend
  in
  let var_files = Option.to_list var_file in
  let inputs : Sol_cli_cloud_wiring.terraform_inputs = { var_files; vars } in
  let destruction =
    Sol_cli_cloud_wiring.destruction
      ~run_log
      ~provider
      ~target_cfg
      ~infra_dir
      ~var_files
      ~vars
  in
  let* () =
    if action = Apply
    then (
      let* () =
        Sol_cli_cloud_wiring.init_result
          ~assets
          run_log
          ~provider
          ~role:Sol_cli_platform_assets.Cluster
          cloud_backend
        |> Sol_cli_exit.of_msg
      in
      reconcile_ownership_at ~provider ~target_cfg ~infra_dir ~var_files ~vars;
      Ok ())
    else Ok ()
  in
  Printf.printf "\nDestroying cloud infrastructure (%s)...\n%!" pname;
  match action with
  | Plan ->
    let* () =
      Sol_cli_cloud_wiring.destroy_preview ~assets ~run_log ~cloud_target ~inputs
      |> Sol_cli_exit.of_msg
    in
    Printf.printf "\nDone. Re-run with --apply to destroy cloud resources.\n%!";
    Ok ()
  | Apply ->
    let workload_namespaces = declared_workload_namespaces () in
    (* The UID evidence the workspace recorded at apply. Workloads it cannot match are
       retained, not removed (docs/architecture/ownership.md). *)
    let recorded_evidence =
      match Sol_cli_config.destination_of_target target_cfg with
      | Error _ -> []
      | Ok destination ->
        let ctx = Sol_cli_kube_destination.context_of_destination destination in
        (match
           Sol_cli_release_store.recorded_evidence
             ~ctx
             ~workspace:(Sol_cli_workspace.current_name ())
         with
         | Ok evidence -> evidence
         | Error message ->
           Sol_cli_report.warn
             "could not read the recorded UID evidence for this workspace (%s); \
              workloads Sol cannot prove it owns will be retained"
             message;
           [])
    in
    let deps =
      Sol_cli_cloud_wiring.destroy_deps
        ~assets
        ~run_log
        ~cloud_target
        ~inputs
        ~retention
        ~workload_namespaces
        ~accept_unreleased
        ~recorded_evidence
        ~destruction
    in
    let outcome = Sol_cli_cloud_destroy.execute ~deps in
    (match outcome with
     | Sol_cli_cloud_destroy.Destroy_succeeded { degradations; cleanup; verification; _ }
       ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       report_verification verification;
       Printf.printf "\n%s\n%!" (Sol_cli_cloud_destroy.completion_message outcome)
     | Sol_cli_cloud_destroy.Destroy_blocked { guarantee } ->
       Printf.eprintf
         "error: destruction is blocked -- proceeding would violate a destruction-time \
          guarantee this target declared: %s\n\
          %!"
         guarantee
     | Sol_cli_cloud_destroy.Destroy_failed
         { failure = _; degradations; cleanup; verification } ->
       report_cleanup_evidence cleanup;
       report_degradations degradations;
       verification |> Option.iter report_verification;
       Printf.eprintf "error: %s\n%!" (Sol_cli_cloud_destroy.completion_message outcome));
    (match Sol_cli_cloud_destroy.exit_code outcome with
     | 0 ->
       (match Sol_cli_authorization_stage.destroy ~assets ~run_log ~target:target_cfg with
        | Ok outcome ->
          Printf.printf "%s\\n%!" (Sol_cli_authorization_stage.outcome_to_string outcome)
        | Error message ->
          Printf.eprintf
            "warning: the environment was destroyed but the authorization reconciler \
             identity and its fence were not (%s); remove them explicitly before the \
             durable installation is retired.\\n%!"
            message);
       Ok ()
     | code -> Error (Sol_cli_exit.reported ~code ()))
;;

let var_file_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "var-file" ]
        ~docv:"PATH"
        ~doc:"Path to a Terraform .tfvars file. Passed as -var-file to terraform.")
;;

let target_arg =
  Sol_cli_target_arg.positional ~doc:"Deployment target path: <env>/<provider>/<region>."
;;

let var_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "var" ]
        ~docv:"KEY=VALUE"
        ~doc:"Terraform variable. Can be passed multiple times.")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info
        [ "dry-run" ]
        ~doc:
          "Report what reconciliation would do without adopting anything. Reconciliation \
           adopts nothing it cannot attribute exactly, so running it without this flag \
           is safe.")
;;

let explain_flag =
  Arg.(
    value
    & flag
    & info
        [ "explain" ]
        ~doc:
          "Show everything the provider inventory checked, with the rule that makes each \
           finding this target's, and the disposition of every resource found.")
;;

let cloud_reconcile ~target ~var_file ~vars ~dry_run ~explain () =
  let* provider = provider_of_target_path target in
  let* () = require_cloud_root ~driver:provider in
  let* () = check_terraform () in
  let* assets = resolve_assets () in
  let* cluster_assets = asset_root ~assets provider Sol_cli_platform_assets.Cluster in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-reconcile" () in
  let* config_vars, config = target_vars ~strict:true target in
  let target_cfg = config.Sol_cli_config.target in
  let var_file = resolve_var_file ~flag:var_file ~target:target_cfg.terraform_var_file in
  let vars = config_vars @ vars in
  let* () = refuse_sensitive_vars ~infra_dir:cluster_assets ~vars in
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"reconciling infrastructure ownership for"
      ~leaves_target_standing:true
    |> Sol_cli_exit.of_msg
  in
  let* platform_shape = Sol_cli_config.platform_shape config |> Sol_cli_exit.of_msg in
  let* cloud_target =
    Sol_cli_cloud_lifecycle.cloud_target ~platform_shape target_cfg |> Sol_cli_exit.of_msg
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let infra_dir =
    workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  in
  let* () =
    guard_previous_operation
      ~constructive:false
      ~accept_unresolved:false
      ~chdir:infra_dir
      ~backend_config:cloud_backend
  in
  let* () =
    Sol_cli_cloud_wiring.init_result
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      cloud_backend
    |> Sol_cli_exit.of_msg
  in
  let* cluster_name =
    match target_cfg.cluster_name with
    | Some name when not (Sol_cli_string.is_blank name) -> Ok name
    | _ ->
      Error
        (Sol_cli_exit.error
           "reconciliation needs the target's cluster_name: both the provider inventory \
            and the identity registry address resources by it, so without it nothing can \
            be attributed or mapped")
  in
  let var_files = Option.to_list var_file in
  let* reconciliation =
    Sol_cli_cloud_wiring.reconcile_ownership
      ~provider
      ~target_cfg
      ~cluster_name
      ~infra_dir
      ~var_files
      ~vars
      ~act:(not dry_run)
    |> Sol_cli_exit.of_msg
  in
  if explain
  then (
    Printf.printf "%s%!" (Sol_cli_absence.report reconciliation.observations);
    Printf.printf
      "%s%!"
      (Sol_cli_ownership_reconciliation.report reconciliation.dispositions);
    Printf.printf
      "  %s\n\n%!"
      (Sol_cli_ownership_reconciliation.summary reconciliation.dispositions));
  Printf.printf
    "%s%!"
    (Sol_cli_ownership_reconciliation.outcome ~dry_run reconciliation.dispositions);
  let outstanding =
    Sol_cli_ownership_reconciliation.unreconciled reconciliation.dispositions
    |> List.filter (function
      | Sol_cli_ownership_reconciliation.Recover candidate ->
        not
          (List.exists
             (fun (restored : Sol_cli_ownership_reconciliation.candidate) ->
                restored.address = candidate.address)
             reconciliation.restored)
      | Sol_cli_ownership_reconciliation.Cannot_recover _
      | Sol_cli_ownership_reconciliation.Unmapped _ -> true
      | Sol_cli_ownership_reconciliation.Unresolved _ -> true
      | Sol_cli_ownership_reconciliation.Already_owned _
      | Sol_cli_ownership_reconciliation.By_contract _ -> false)
  in
  if outstanding = []
  then Ok ()
  else (
    Printf.eprintf
      "error: %d resource(s) attributable to this target remain outside Terraform \
       ownership, and Sol will not guess at them:\n\
       %!"
      (List.length outstanding);
    Printf.eprintf "%s%!" (Sol_cli_ownership_reconciliation.report outstanding);
    Error (Sol_cli_exit.reported ~code:1 ()))
;;

let reconcile_cmd =
  let doc =
    "Compare Terraform ownership with independently observed provider reality, and \
     repair discrepancies that can be attributed exactly."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Terraform is the mutation and convergence authority for directly managed \
         infrastructure; the provider is the reality authority. When an apply fails \
         after the provider created something, the state may not represent it, and a \
         state-driven destroy then cannot remove it. This command observes the provider \
         independently, maps each resource it finds to a Terraform address through the \
         identity registry, and adopts it so the ordinary lifecycle can act on it."
    ; `P
        "It refuses to guess. A resource whose class has no registry entry, whose class \
         the registry marks as not recoverable (a composite provider identity, a \
         module's internals, a name that depends on the workspace layout), or whose name \
         matches more than one address, is reported and left alone. Resources that are \
         external or durable by contract, and resources a controller created on behalf \
         of something Terraform owns, are reported as their owner's business rather than \
         adopted."
    ; `P
        "Adoption is idempotent: a resource Terraform already owns is reported as such \
         and nothing changes. Lifecycle operations reconcile automatically before an \
         apply and before a destroy, so an operator does not have to know that a failed \
         apply left the state behind reality."
    ; `P
        "Adoption evaluates the whole configuration, so the target's Terraform variables \
         must be resolvable exactly as an apply needs them, including any the operator \
         supplies through the environment (TF_VAR_*). Sol never takes a secret on the \
         command line."
    ; `P
        "--await-delegation waits for the public delegation: the domain this target \
         serves must answer with NS records before the command reports success, each \
         attempt is printed so the wait is visible, and an unqueryable resolver is \
         UNKNOWN rather than a silent success (DEC-052)."
    ; `S "EXIT STATUS"
    ; `P
        "0 -- reconciled: every resource the provider holds for this target is either \
         owned already, not this target's to reconcile, or adopted by this run."
    ; `P
        "1 -- something remains that Sol cannot safely reconcile, or an adoption failed. \
         The reason is named on stderr, and nothing is guessed."
    ]
  in
  Cmd.v
    (Cmd.info "reconcile" ~doc ~man)
    Term.(
      const (fun target var_file vars dry_run explain ->
        Sol_cli_exit.exit_on
          (cloud_reconcile ~target ~var_file ~vars ~dry_run ~explain ()))
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ dry_run_flag
      $ explain_flag)
;;

let installation_observation ~provider =
  Sol_cli_provider_capabilities.installation_observation ~provider
;;

let declared_target target =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> refuse (Sol_cli_config.error_to_string e)
  | Ok { target = target_config; _ } when Sol_cli_config.target_declared target_config ->
    Ok target_config
  | Ok config ->
    refuse
      (Printf.sprintf
         "target %s is not declared (expected in %s)"
         target
         (Sol_cli_config.target_source config.target))
;;

let cloud_bootstrap ~target ~reconcile ~await_delegation () =
  let* target_cfg = declared_target target in
  let* () = require_cloud_root ~driver:target_cfg.provider in
  let run = installation_observation ~provider:target_cfg.provider in
  let* configuration = Sol_cli_installation.of_target target_cfg |> Sol_cli_exit.of_msg in
  let* () =
    if reconcile
    then (
      let* () = check_terraform () in
      let* assets = resolve_assets () in
      let* lines =
        Sol_cli_installation_stage.reconcile
          ~assets
          ~provider:target_cfg.provider
          ~configuration
          ~run
          ()
        |> Sol_cli_exit.of_msg
      in
      List.iter (fun line -> Printf.printf "  %s\n%!" line) lines;
      Ok ())
    else Ok ()
  in
  let verdicts =
    Sol_cli_provider_capabilities.installation_probes target_cfg.provider configuration
    |> Sol_cli_installation.observe ~run
  in
  Printf.printf
    "\n\
     Installation (%s) -- the durable prerequisites that outlive every environment:\n\n\
     %!"
    (Sol_cli_cloud_lifecycle.phase_to_string Sol_cli_cloud_lifecycle.Cloud_bootstrap);
  Printf.printf "  resolved configuration\n%!";
  Sol_cli_installation.resolved_configuration_to_lines configuration
  |> List.iter print_endline;
  Printf.printf "\n%s\n%!" (Sol_cli_installation.summary verdicts);
  Sol_cli_installation_stage.identity_contract_lines
    ~target
    ~provider:target_cfg.provider
    ~configuration
    ~verdicts
  |> List.iter print_endline;
  let* () =
    Sol_cli_installation_stage.await_public_delegation
      ~configuration
      ~run
      ~seconds:await_delegation
      ~report:(fun line -> Printf.printf "%s\n%!" line)
      ~on_established:(fun () ->
        Printf.printf "\n  public delegation           Established\n%!";
        Ok ())
    |> Result.map_error Sol_cli_exit.error
  in
  let* () = Sol_cli_installation.all_established verdicts |> Sol_cli_exit.of_msg in
  Printf.printf
    "\n\
     The installation is established. Environments can be created and destroyed against \
     it;\n\
     `sol destroy` removes an environment, never this.\n\
     %!";
  Ok ()
;;

let bootstrap_await_delegation_flag =
  Arg.(
    value
    & opt int 0
    & info
        [ "await-delegation" ]
        ~docv:"SECONDS"
        ~doc:
          "Wait up to SECONDS (in five-second checks) for the domain this target serves \
           to answer with NS records from a public resolver, reporting each attempt, and \
           exit non-zero when the delegation is still not visible. 0, the default, does \
           not wait: the single-shot public-delegation verdict already appears above.")
;;

let bootstrap_apply_flag =
  Arg.(
    value
    & flag
    & info
        [ "apply" ]
        ~doc:
          "Reconcile the durable root, then report. Reconciliation plans the root, \
           refuses a plan that would replace or destroy a durable resource, and applies \
           what is left.")
;;

let bootstrap_cmd =
  let doc =
    "Report whether a target's durable installation is established, and what is missing."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "The installation is the durable account-level layer that outlives every \
         environment: the Terraform state backend and its locking, the provisioning / \
         cluster-access / deploy / operator identities, and the delegated DNS zone when \
         Sol owns one (DEC-057). Every prerequisite is *observed* at the provider, never \
         inferred from configuration, and reports Established, Unmet or UNKNOWN. A \
         prerequisite Sol cannot observe is UNKNOWN, never healthy (DEC-052)."
    ; `P
        "Without --apply this is read-only: it reports what the provider holds so a \
         missing prerequisite is named before anything is created."
    ; `P
        "With --apply the durable root is reconciled: planned, inspected, and applied \
         only when the plan neither replaces nor destroys a durable resource. A root \
         already at its declared state applies nothing, so a second run is a no-op. The \
         state backend is the one prerequisite whose presence is checked first, because \
         a root cannot create the backend that stores its own state."
    ; `S "EXIT STATUS"
    ; `P "0 -- every prerequisite was observed Established."
    ; `P
        "1 -- a prerequisite is Unmet or UNKNOWN, or reconciliation was refused. The \
         verdict and the reason are printed, and nothing is assumed healthy."
    ; `P "No other code is used by this command."
    ]
  in
  Cmd.v
    (Cmd.info "bootstrap" ~doc ~man)
    Term.(
      const (fun target reconcile await_delegation ->
        Sol_cli_exit.exit_on (cloud_bootstrap ~target ~reconcile ~await_delegation ()))
      $ target_arg
      $ bootstrap_apply_flag
      $ bootstrap_await_delegation_flag)
;;

let plan_flag =
  Arg.(
    value
    & flag
    & info
        [ "plan" ]
        ~doc:"Run terraform plan only. No infrastructure is changed. This is the default.")
;;

let apply_flag =
  Arg.(
    value
    & flag
    & info
        [ "apply" ]
        ~doc:"Run terraform apply/destroy and change billable cloud resources.")
;;

let action_term = Term.(ret (const action_of_flags $ plan_flag $ apply_flag))

let confirm_ecr_removal_flag =
  Arg.(
    value
    & flag
    & info
        [ Sol_cli_cloud_wiring.confirm_guarded_removal_flag ]
        ~doc:
          "Allow an apply whose plan deletes a resource the provider declares guarded \
           (AWS: ECR repositories, and every image in them). Without it such an apply is \
           refused before anything changes.")
;;

let accept_unresolved_flag =
  Arg.(
    value
    & flag
    & info
        [ "accept-unresolved" ]
        ~doc:
          "Proceed although the previous Terraform operation against this state ended \
           unresolved (Terraform was killed before finishing its own shutdown, or left \
           errored.tfstate). Use it only after reconciling: inspecting the provider and \
           the state, and importing, removing or pushing what diverged. Without it such \
           an apply is refused before anything changes.")
;;

let accept_unreleased_flag =
  Arg.(
    value
    & flag
    & info
        [ Sol_cli_cloud_destroy.accept_unreleased_flag ]
        ~doc:
          "Destroy even though the application workloads this target deployed could not \
           be established as released. A supported destroy releases those workloads and \
           waits for their pods before it destroys the substrate, so a provider is never \
           asked to drop durable application state while the workloads that own it may \
           still be running. A declared namespace that does not exist is not an \
           unestablished release: no workload can be running without its namespace, so \
           that case does not need this flag. Without this flag a destroy stops before \
           the substrate and destroys nothing.")
;;

let plan_cmd =
  Cmd.v
    (Cmd.info "plan" ~doc:"Preview cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars ->
        Sol_cli_exit.exit_on (cloud_init ~target ~var_file ~vars ~action:Plan ()))
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply cloud infrastructure changes for a target.")
    Term.(
      const (fun target var_file vars confirm_ecr_removal accept_unresolved ->
        Sol_cli_exit.exit_on
          (cloud_init
             ~confirm_ecr_removal
             ~accept_unresolved
             ~target
             ~var_file
             ~vars
             ~action:Apply
             ()))
      $ target_arg
      $ var_file_arg
      $ var_arg
      $ confirm_ecr_removal_flag
      $ accept_unresolved_flag)
;;

(* The public target destroy command moved to `cmd_destroy.ml` as the top-level
   `sol destroy <target>`; its flags (`action_term`, `accept_unreleased_flag`) and the
   executor (`cloud_destroy`) stay here and are referenced from there. *)
