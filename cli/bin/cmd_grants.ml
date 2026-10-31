open Cmdliner
open Result.Syntax

type action =
  | Plan
  | Apply

let refuse message = Error (Sol_cli_exit.error message)

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

let target_vars ~strict target =
  Sol_cli_terraform_vars.of_target
    ~strict
    ~workspace:(Sol_cli_workspace.current_name ())
    target
  |> Result.map (fun (vars, config) -> Sol_cli_terraform.kv_args vars, config)
  |> Sol_cli_exit.of_msg
;;

let config_vars (config : Sol_cli_config.t) =
  Sol_cli_terraform_vars.of_config ~workspace:(Sol_cli_workspace.current_name ()) config
  |> Result.map (fun vars -> Sol_cli_terraform.kv_args vars, config)
  |> Sol_cli_exit.of_msg
;;

let resolve_var_file ~flag ~target =
  let cwd = Sys.getcwd () in
  let workspace_root = Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd in
  Sol_cli_terraform_vars.var_file ~cwd ~workspace_root ~flag ~target
;;

let namespace_of_workspace ~workspace model =
  Sol_cli_workspace_model.workloads model
  |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
    let open Result.Syntax in
    let* unit = Sol_cli_authorization_reconcile.unit_name workload.service in
    Sol_cli_deployment_plan.namespace_name
      ~workspace
      ~domain:workload.service.Sol_cli_manifest.domain
    |> Result.map (fun namespace -> unit, namespace))
  |> Result.map (fun pairs -> fun unit -> List.assoc_opt unit pairs)
;;

let authorization_vars = Sol_cli_authorization_stage.root_vars

let observe_deployed ~destination ~target_cfg ~namespaces =
  let destination =
    match destination with
    | Some destination -> Ok destination
    | None -> Sol_cli_config.destination_of_target target_cfg
  in
  match destination with
  | Error reason ->
    Sol_cli_authorization.Unobservable
      ("the target's cluster could not be addressed: " ^ reason)
  | Ok destination ->
    let ctx = Sol_cli_kube_destination.context_of_destination destination in
    (match
       Sol_cli_kubectl.get_raw
         ~ctx
         ~args:[ "get"; "deployments"; "--all-namespaces"; "-o"; "json" ]
     with
     | Error error ->
       Sol_cli_authorization.Unobservable
         ("the deployed workloads could not be read: "
          ^ Sol_cli_process.error_to_string error)
     | Ok output ->
       (match
          Sol_cli_authorization_reconcile.deployed_of_listing_json
            ~namespaces
            output.Sol_cli_process.stdout
        with
        | Ok grants -> Sol_cli_authorization.Deployed grants
        | Error reason -> Sol_cli_authorization.Unobservable reason))
;;

let report_plan ~target lines =
  Sol_cli_report.app "\nAuthorization plan for %s (target-wide, no scope):" target;
  if lines = []
  then Sol_cli_report.app "  (no change)"
  else List.iter (fun line -> Sol_cli_report.app "  %s" line) lines
;;

let run ?config ?destination ~action ~target ~var_file ~vars () =
  let* () = check_terraform () in
  let* assets = resolve_assets () in
  let* config_vars, resolved_config =
    match config with
    | Some config -> config_vars config
    | None -> target_vars ~strict:(action = Apply) target
  in
  let target_cfg = resolved_config.Sol_cli_config.target in
  let provider = target_cfg.Sol_cli_config.provider in
  let* identity =
    Sol_cli_authorization_identity.of_target target_cfg |> Sol_cli_exit.of_msg
  in
  let* env = Sol_cli_authorization_identity.environment identity |> Sol_cli_exit.of_msg in
  let* model = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  let workspace = Sol_cli_workspace.current_name () in
  let* namespace_of = namespace_of_workspace ~workspace model |> Sol_cli_exit.of_msg in
  let* desired =
    Sol_cli_authorization_reconcile.desired ~binding_config:resolved_config model
    |> Sol_cli_exit.of_msg
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
  let* backend =
    Sol_cli_cloud_lifecycle.authorization_backend target_cfg |> Sol_cli_exit.of_msg
  in
  let* root_vars = authorization_vars target_cfg |> Sol_cli_exit.of_msg in
  let auth_dir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let run_log = Sol_cli_run_log.create ~prefix:"cloud-grants" () in
  let* _ =
    Sol_cli_terraform_workdir.materialize
      ~assets
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
    |> Sol_cli_exit.of_msg
  in
  let* _ =
    Sol_cli_terraform.init ~env ~chdir:auth_dir ~backend_config:backend ()
    |> Sol_cli_exit.of_error Sol_cli_process.error_to_string
  in
  let* current =
    match Sol_cli_terraform.output_json ~env ~chdir:auth_dir () with
    | Ok output ->
      Sol_cli_authorization_reconcile.current_of_output_json output.Sol_cli_process.stdout
      |> Sol_cli_exit.of_msg
    | Error error ->
      refuse
        (Printf.sprintf
           "could not read the authorization root's outputs, so the grants it has \
            already established are unknown: %s\n\
           \  An authorization plan is never computed from an unreadable state: a grant \
            that is established but not observed would not be revoked, and the run would \
            report a reconciliation it did not perform."
           (Sol_cli_process.error_to_string error))
  in
  let namespaces =
    Sol_cli_workspace_model.workloads model
    |> List.filter_map (fun (workload : Sol_cli_workspace_model.workload) ->
      match Sol_cli_authorization_reconcile.unit_name workload.service with
      | Ok unit -> namespace_of unit
      | Error _ -> None)
  in
  let deployed = observe_deployed ~destination ~target_cfg ~namespaces in
  let plan = Sol_cli_authorization.compute ~desired ~current ~deployed in
  report_plan ~target (Sol_cli_authorization.render plan);
  (match plan.Sol_cli_authorization.notes with
   | [] -> ()
   | notes ->
     List.iter
       (fun note -> Sol_cli_run_log.append_phase_log run_log ~phase:"grant-notes" note)
       notes);
  Sol_cli_report.app
    "  reconciler identity: %s"
    (Sol_cli_authorization_identity.describe identity);
  let* terraform_grants =
    Sol_cli_authorization_reconcile.terraform_grants ~grants:plan.keep ~namespace_of
    |> Sol_cli_exit.of_msg
  in
  let grant_var = Sol_cli_authorization_reconcile.terraform_var terraform_grants in
  let all_vars = Sol_cli_terraform.kv_args (root_vars @ [ grant_var ]) @ vars in
  match action with
  | Plan ->
    let* _ =
      Sol_cli_terraform.plan
        ~env
        ~scope:Sol_cli_terraform.whole_root
        ~chdir:auth_dir
        ~var_files:(Option.to_list var_file)
        ~vars:all_vars
        ()
      |> Sol_cli_exit.of_error Sol_cli_process.error_to_string
    in
    Sol_cli_report.app
      "\nDone. Re-run with 'sol grants apply %s' to change workload authorization."
      target;
    Ok ()
  | Apply ->
    let* _ =
      Sol_cli_terraform.apply
        ~env
        ~scope:Sol_cli_terraform.whole_root
        ~chdir:auth_dir
        ~var_files:(Option.to_list var_file)
        ~vars:all_vars
        ()
      |> Sol_cli_exit.of_error Sol_cli_process.error_to_string
    in
    Sol_cli_report.app "\nDone. Workload authorization is reconciled.";
    Ok ()
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

let var_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "var" ]
        ~docv:"KEY=VALUE"
        ~doc:"Terraform variable. Can be passed multiple times.")
;;

let target_arg =
  Sol_cli_target_arg.positional
    ~doc:"Deployment target path: <env>/<provider>/<region>. Never inferred."
;;

let plan_cmd =
  let doc =
    "Plan the target-wide workload authorization reconciliation: workload identities and \
     cloud grants derived from the whole workspace."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Workload cloud authorization is a lifecycle of its own (DEC-062). It runs as \
         the fenced reconciler identity declared by the target, never as the deploy \
         identity, and it reconciles the whole target: there is no unit or domain scope, \
         because a partial reconcile would revoke every unselected unit's grants."
    ; `P
        "Sol computes the safe grant set before Terraform sees anything: a grant is \
         revoked only when the declarations no longer require it AND no deployed \
         workload still uses it. When the deployed state cannot be observed, nothing is \
         revoked. Only that safe set becomes the root's generated input."
    ; `P
        "The plan names the unit, the capability and the resource, so a reviewer can see \
         a production credential being granted."
    ; `S "EXIT STATUS"
    ; `P "0 -- the plan was produced."
    ; `P "1 -- the plan was refused, named on stderr."
    ]
  in
  Cmd.v
    (Cmd.info "plan" ~doc ~man)
    Term.(
      const (fun target var_file vars ->
        Sol_cli_exit.exit_on (run ~action:Plan ~target ~var_file ~vars ()))
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let apply_cmd =
  let doc =
    "Reconcile the target-wide workload authorization: create, keep and revoke workload \
     identities and cloud grants."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Runs the authorization root as the target's declared fenced reconciler \
         identity. The fence itself is created by `sol deploy`; the reconciler cannot \
         create or alter it."
    ; `P "See 'sol grants plan' for how the safe grant set is computed."
    ; `S "EXIT STATUS"
    ; `P "0 -- the reconciliation was applied."
    ; `P "1 -- the reconciliation was refused or failed, named on stderr."
    ]
  in
  Cmd.v
    (Cmd.info "apply" ~doc ~man)
    Term.(
      const (fun target var_file vars ->
        Sol_cli_exit.exit_on (run ~action:Apply ~target ~var_file ~vars ()))
      $ target_arg
      $ var_file_arg
      $ var_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "grants" ~doc:"Reconcile workload cloud authorization (DEC-062)")
    [ plan_cmd; apply_cmd ]
;;
