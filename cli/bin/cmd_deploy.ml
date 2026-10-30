open Cmdliner
open Sol_cli_manifest

let workspace_name = Sol_cli_workspace.current_name

open Result.Syntax

let print_service_urls names =
  names |> List.iter (Printf.printf "  →  http://localhost:8080  (%s)\n%!")
;;

let check_contract ~facts ~services =
  let findings = Sol_cli_check.run_services ~facts services in
  findings
  |> List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f));
  if Sol_cli_check.has_errors findings then Error (Sol_cli_exit.reported ()) else Ok ()
;;

let check_apply_environment ~facts ~services = check_contract ~facts ~services

let print_header ~workspace ~sha ?mode_line () =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  Option.iter (Printf.printf "%s\n") mode_line;
  Printf.printf "\n%!"
;;

let run_serverless
      ~(resolved_config : Sol_cli_config.t)
      ~(target_cfg : Sol_cli_config.target)
      ~(deployed : Sol_cli_deploy_selection.deployed)
      ~(selection : Sol_cli_deploy_selection.selection)
      ~run_log
  =
  let* service =
    match deployed.services with
    | [ service ] -> Ok service
    | [] ->
      Error (Sol_cli_exit.error "serverless deployment requires one -svc or -fn service")
    | _ ->
      Error
        (Sol_cli_exit.error
           "serverless deployment currently supports exactly one -svc or -fn service per \
            target")
  in
  let* () =
    match service.primitive with
    | Sol_cli_manifest.Worker ->
      Error
        (Sol_cli_exit.error
           "target-scoped serverless dispatch does not support -worker on GCP")
    | Sol_cli_manifest.Svc | Sol_cli_manifest.Fn -> Ok ()
  in
  let* project =
    match resolved_config.project with
    | Some project when String.trim project <> "" -> Ok project
    | _ -> Error (Sol_cli_exit.error "serverless deployment requires sol.yml project")
  in
  let* image =
    match List.assoc_opt service.name selection.Sol_cli_deploy_selection.image_refs with
    | Some image -> Ok image
    | None ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "serverless deployment requires --image-ref %s=REPO@sha256:DIGEST"
              service.name))
  in
  let record = Filename.concat (Sol_cli_run_log.dir run_log) "serverless-release.json" in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  let unit = Sol_cli_serverless_target_common.unit_of_service ~project service in
  let* facts =
    Sol_cli_workspace_model.load_cwd ()
    |> Result.map_error (fun message -> Sol_cli_exit.error message)
  in
  let* service_config =
    match
      Sol_cli_workspace_model.workloads facts
      |> List.find_opt (fun (workload : Sol_cli_workspace_model.workload) ->
        String.equal workload.service.Sol_cli_manifest.name service.name)
    with
    | None ->
      Error
        (Sol_cli_exit.error (Printf.sprintf "cannot find %s's declarations" service.name))
    | Some workload ->
      (match workload.config with
       | Ok config -> Ok config
       | Error parse_error ->
         Error
           (Sol_cli_exit.error
              (Printf.sprintf
                 "cannot read %s's declarations: %s"
                 service.name
                 (Sol_cli_toml.parse_error_to_string parse_error))))
  in
  let requirements =
    service_config.secret_keys |> List.map Sol_cli_grant.secret_requirement
  in
  let* runtime_service_account =
    Sol_cli_serverless_lifecycle.ensure_runtime_identity
      ~assets
      ~run_log
      ~target:target_cfg
      ~unit
      ~requirements
    |> Result.map_error Sol_cli_exit.error
  in
  let* release =
    Sol_cli_serverless_lifecycle.deploy
      ~target:target_cfg
      ~config:resolved_config
      ~project
      ~service
      ~image
      ~record
      ~runtime_service_account
    |> Result.map_error Sol_cli_exit.error
  in
  print_endline (Yojson.Safe.to_string release);
  Ok ()
;;

let build_plan
      ?(evaluation = Sol_cli_profile_preflight.All)
      (input : Sol_cli_deploy_selection.Target_plan_input.t)
  =
  let* plan =
    Sol_cli_deploy_selection.target_plan ~evaluation input
    |> Result.map_error (function
      | Sol_cli_deploy_selection.Refused message -> Sol_cli_exit.error message
      | Preflight (profile, findings) ->
        Sol_cli_exit.failure (Sol_cli_profile_preflight.report profile findings))
  in
  (* Only a caller that evaluated every guarantee can say the preflight passed here: the apply
     path evaluates the artifacts after it has reconciled the registry, and prints the pass
     then. *)
  (match evaluation with
   | Sol_cli_profile_preflight.All ->
     Sol_cli_deploy_selection.Target_plan.profile plan
     |> Option.iter (fun (claim : Sol_cli_deployment_plan.profile_claim) ->
       Printf.printf
         "Profile: %s (preflight passed)\n%!"
         (Sol_cli_profile.to_string claim.profile))
   | Structural | Artifacts -> ());
  Ok plan
;;

let print_plan_preflight_passed (plan : Sol_cli_deployment_plan.t) =
  match plan.Sol_cli_deployment_plan.profile with
  | Some (claim : Sol_cli_deployment_plan.profile_claim) ->
    Printf.printf
      "Profile: %s (preflight passed)\n%!"
      (Sol_cli_profile.to_string claim.profile)
  | None -> ()
;;

let project_trusted_workload_issuer target_cfg plan =
  if
    not
      (List.exists
         (fun (service : Sol_cli_deployment_plan.service_spec) ->
            service.primitive = Sol_cli_deployment_plan.Svc)
         plan.Sol_cli_deployment_plan.services)
  then Ok plan
  else (
    match
      (Sol_cli_provider_capabilities.capabilities_of target_cfg.Sol_cli_config.provider)
        .workload_identity_issuer
        target_cfg
    with
    | Error message ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "could not establish the target's trusted Kubernetes workload issuer: %s\n\
               deployments containing a svc require a target that establishes workload \
               identity"
              message))
    | Ok issuer ->
      Ok
        { plan with
          services =
            List.map
              (fun (service : Sol_cli_deployment_plan.service_spec) ->
                 match service.primitive with
                 | Svc ->
                   { service with
                     config =
                       ("SOL_TRUSTED_WORKLOAD_ISSUER", issuer)
                       :: List.remove_assoc "SOL_TRUSTED_WORKLOAD_ISSUER" service.config
                   }
                 | Worker | Fn -> service)
              plan.services
        })
;;

let planning_input_of_ctx (ctx : Sol_cli_deploy_run.context) ~emit_to
  : Sol_cli_deploy_selection.Target_plan_input.t
  =
  { workspace = ctx.execution.workspace
  ; registry = ctx.registry
  ; sha = ctx.sha
  ; emit_to
  ; config = ctx.resolved_config
  ; facts = ctx.facts
  ; inventory = ctx.inventory
  ; image_refs = ctx.image_refs
  ; services = ctx.services
  }
;;

let write_plan_if_requested ~emit_plan_to plan =
  match emit_plan_to with
  | None -> Ok ()
  | Some path ->
    let json_str = Yojson.Safe.pretty_to_string (Sol_cli_deployment_plan.to_json plan) in
    if path = "-"
    then (
      print_string json_str;
      print_char '\n';
      Ok ())
    else
      Sol_cli_fs.write_atomic path (json_str ^ "\n")
      |> Result.map (fun () -> Printf.printf "Plan written to %s\n%!" path)
      |> Sol_cli_exit.of_msg
;;

let to_manifest_primitive = function
  | Sol_cli_deployment_plan.Svc -> Svc
  | Sol_cli_deployment_plan.Worker -> Worker
  | Sol_cli_deployment_plan.Fn -> Fn
;;

let print_planned_services plan =
  plan.Sol_cli_deployment_plan.services
  |> List.iter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Printf.printf
      "[%s] %s/%s\n%!"
      (primitive_label (to_manifest_primitive spec.primitive))
      spec.domain
      spec.source_name)
;;

let print_contract_changes plan =
  match plan.Sol_cli_deployment_plan.contract_changes with
  | [] -> ()
  | changes ->
    Printf.printf "\nContract changes:\n%!";
    changes
    |> List.iter (fun change ->
      Printf.printf "  %s\n%!" (Sol_cli_deployment_plan.contract_change_to_string change))
;;

let run_failed msg = Sol_cli_exit.failure ("\nerror: " ^ msg)

let present_plan (ctx : Sol_cli_deploy_run.context) plan =
  (let* () = write_plan_if_requested ~emit_plan_to:ctx.emit_plan_to plan in
   print_planned_services plan;
   print_contract_changes plan;
   Ok ())
  |> Result.map_error (fun (failure : Sol_cli_exit.failure) -> failure.text)
;;

let print_guided lines = List.iter (fun line -> Printf.printf "%s\n%!" line) lines
let eprint_guided lines = List.iter (fun line -> Printf.eprintf "%s\n%!" line) lines

let setup_refusal_reason = function
  | Sol_cli_command_request.Deploy_apply -> "this run is not interactive"
  | Deploy_dry_run _ -> "this run is `--dry-run`, which changes nothing"
  | Deploy_emit_to _ -> "this run only writes manifests for another actor to apply"
;;

let allow_setup = function
  | Sol_cli_command_request.Deploy_apply -> true
  | Deploy_dry_run _ | Deploy_emit_to _ -> false
;;

let await_public_delegation ~configuration ~run ~seconds =
  Sol_cli_installation_stage.await_public_delegation
    ~configuration
    ~run
    ~seconds
    ~report:(fun line -> Printf.printf "%s\n%!" line)
    ~on_established:(fun () -> Ok ())
  |> Result.map_error Sol_cli_exit.error
;;

let print_identity_contracts ~target ~target_cfg ~configuration ~verdicts =
  Sol_cli_installation_stage.identity_contract_lines
    ~target
    ~provider:target_cfg.Sol_cli_config.provider
    ~configuration
    ~verdicts
  |> print_guided
;;

let set_up_installation ~target ~target_cfg ~configuration ~await_delegation =
  let provider = target_cfg.Sol_cli_config.provider in
  let run = Sol_cli_provider_capabilities.installation_observation ~provider in
  let* () = Cmd_cloud_tf.check_terraform () in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  Printf.printf "\nSetting up the installation for %s...\n%!" target;
  let* lines =
    Sol_cli_installation_stage.reconcile ~assets ~provider ~configuration ~run ()
    |> Sol_cli_exit.of_msg
  in
  print_guided (List.map (fun line -> "  " ^ line) lines);
  let* () = await_public_delegation ~configuration ~run ~seconds:await_delegation in
  match Sol_cli_provider_capabilities.observe_installation target_cfg with
  | Error message ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "the installation for %s can no longer be resolved: %s"
            target
            message))
  | Ok (_, verdicts) ->
    (match Sol_cli_installation_onboarding.state_of_verdicts verdicts with
     | Sol_cli_installation_onboarding.Present ->
       print_guided (Sol_cli_installation_onboarding.established_lines ~target);
       Ok ()
     | Sol_cli_installation_onboarding.Absent
     | Sol_cli_installation_onboarding.Partial
     | Sol_cli_installation_onboarding.Indeterminate ->
       eprint_guided
         (Sol_cli_installation_onboarding.still_unresolved_lines ~target verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       Error (Sol_cli_exit.reported ~code:1 ()))
;;

type installation_state =
  | Installation_established
  | Installation_reported

let installation_stage ~target ~target_cfg ~action ~await_delegation () =
  match Sol_cli_provider_capabilities.observe_installation target_cfg with
  | Error message ->
    eprint_guided
      (Sol_cli_installation_onboarding.undeclared_lines ~target ~reason:message);
    Ok Installation_reported
  | Ok (configuration, verdicts) ->
    let state = Sol_cli_installation_onboarding.state_of_verdicts verdicts in
    let can_set_up = allow_setup action && Sol_cli_confirm.interactive () in
    (match Sol_cli_installation_onboarding.decision ~interactive:can_set_up state with
     | Proceed -> Ok Installation_established
     | Report ->
       eprint_guided
         (Sol_cli_installation_onboarding.indeterminate_lines ~target verdicts);
       Ok Installation_reported
     | Refuse ->
       print_guided
         (Sol_cli_installation_onboarding.report_lines ~target ~configuration verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       eprint_guided
         (Sol_cli_installation_onboarding.refusal_lines
            ~target
            ~because:(setup_refusal_reason action)
            verdicts);
       Ok Installation_reported
     | Offer ->
       print_guided
         (Sol_cli_installation_onboarding.report_lines ~target ~configuration verdicts);
       print_identity_contracts ~target ~target_cfg ~configuration ~verdicts;
       if
         Sol_cli_confirm.ask
           ~question:(Printf.sprintf "Set up Sol for %s now?" target)
           ~default:true
           ~print:(fun text ->
             print_string text;
             flush stdout)
       then
         let* () =
           set_up_installation ~target ~target_cfg ~configuration ~await_delegation
         in
         Ok Installation_established
       else (
         eprint_guided
           (Sol_cli_installation_onboarding.refusal_lines
              ~target
              ~because:"you chose not to set it up"
              verdicts);
         Ok Installation_reported))
;;

let guide_installation ~target ~target_cfg ~action ~await_delegation =
  let* state = installation_stage ~target ~target_cfg ~action ~await_delegation () in
  (match state with
   | Installation_reported -> ()
   | Installation_established ->
     print_guided (Sol_cli_installation_onboarding.present_lines ~target));
  Ok ()
;;

let guide_installation_of_ctx ~ctx ~action ~await_delegation =
  guide_installation
    ~target:ctx.Sol_cli_deploy_run.target_name
    ~target_cfg:ctx.Sol_cli_deploy_run.target_cfg
    ~action
    ~await_delegation
;;

let destination_output_lines ~infra_dir =
  let wanted =
    [ "deploy_kubeconfig_command"
    ; "deploy_kube_context"
    ; "kubeconfig_command"
    ; "kube_context"
    ]
  in
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Error _ -> []
  | Ok output ->
    (match Sol_cli_terraform_outputs.displayable output.stdout with
     | Error _ -> []
     | Ok outputs ->
       outputs
       |> List.filter (fun (name, _) -> List.mem name wanted)
       |> List.map Sol_cli_terraform_outputs.line)
;;

let no_deploy_identity_lines ~target ~infra_dir =
  [ Printf.sprintf
      "The environment for %s is provisioned, but this run cannot reach its cluster as a \
       deploy identity:"
      target
  ; "  this provider declares no deploy identity, and Sol does not reach a cluster as the"
  ; "  provisioning identity it has just used (DEC-034)."
  ; ""
  ; "One action required — configure kubectl as the identity that deploys to this target,"
  ; "then name the context it writes as this target's kube_context:"
  ]
  @ List.map (fun line -> "  " ^ line) (destination_output_lines ~infra_dir)
  @ [ ""; Printf.sprintf "Then re-run `sol deploy %s`." target ]
;;

(** Resolve the destination, and carry the reconciled environment's root directory out with
    it: the database setup step reads the provisioning connection from that root's outputs. *)
let environment_destination ~target ~target_cfg ~cluster ~infra_dir =
  match cluster with
  | None ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "the environment for %s was reconciled, but Sol cannot read back the cluster \
             it created from Terraform's outputs, so this run cannot name the cluster it \
             would deploy to. Review it with `sol plan %s` and resolve the output error \
             before retrying."
            target
            target))
  | Some cluster ->
    (match cluster.Sol_cli_cluster.deploy_access () with
     | Ok (Some destination) -> Ok (destination, infra_dir)
     | Ok None ->
       (* The provider declares no deploy identity (GCP does not: DEC-034), so the deploy
          identity is the context the operator configured and named. "No deploy identity"
          means "do not fabricate one", not "there is none to use": without this the run
          would print the guidance and then, on the re-run it asks for, print it again. *)
       (match Sol_cli_config.destination_of_target target_cfg with
        | Ok destination -> Ok (destination, infra_dir)
        | Error _ ->
          eprint_guided (no_deploy_identity_lines ~target ~infra_dir);
          Error (Sol_cli_exit.reported ~code:1 ()))
     | Error message -> Error (Sol_cli_exit.error message))
;;

let environment_refusal_lines ~target ~because =
  [ Printf.sprintf
      "The environment for %s is not provisioned yet, and Sol will not create it in this \
       run: %s."
      target
      because
  ; ""
  ; "Sol does this for you on a run that changes things: reconcile the environment for \
     this"
  ; "target — network, cluster, database and platform — and establish this run's own \
     cluster"
  ; "access."
  ; ""
  ; "Run an interactive deploy to reconcile it:"
  ; Printf.sprintf "  sol deploy %s" target
  ; "Then name the context that deploy setup prints as this target's kube_context."
  ]
;;

let environment_stage ~target ~target_cfg ~run_log ~action ~accept_unresolved () =
  if not (allow_setup action)
  then (
    eprint_guided
      (environment_refusal_lines ~target ~because:(setup_refusal_reason action));
    Error (Sol_cli_exit.reported ~code:1 ()))
  else
    let* () = Cmd_cloud_tf.check_terraform () in
    let* assets = Cmd_cloud_tf.resolve_assets () in
    print_guided
      [ ""
      ; Printf.sprintf
          "Sol does this for you: reconcile the environment for %s — network, cluster, \
           database and platform — from the durable installation, and establish this \
           run's own cluster access."
          target
      ];
    match
      Sol_cli_environment_stage.apply
        ~accept_unresolved
        ~assets
        ~run_log
        ~target
        ~var_file:None
        ~vars:[]
        ()
    with
    | Ok (Sol_cli_environment_stage.Applied { cluster; infra_dir }) ->
      print_guided [ Printf.sprintf "The environment for %s is provisioned." target ];
      environment_destination ~target ~target_cfg ~cluster ~infra_dir
    | Ok (Sol_cli_environment_stage.Apply_failed { failure; _ }) ->
      Error
        (Sol_cli_exit.failure
           ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
    | Error failure ->
      Error
        (Sol_cli_exit.failure
           ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
;;

let first_run ~target ~target_cfg ~action ~await_delegation ~run_log ~accept_unresolved ()
  =
  print_guided
    [ ""
    ; Printf.sprintf
        "This target names no Kubernetes destination Sol can reach from here, so this is \
         the first run for %s:"
        target
    ];
  let* () =
    match installation_stage ~target ~target_cfg ~action ~await_delegation () with
    | Ok Installation_established ->
      print_guided (Sol_cli_installation_onboarding.observed_lines ~target);
      Ok ()
    | Ok Installation_reported -> Error (Sol_cli_exit.reported ~code:1 ())
    | Error exit -> Error exit
  in
  environment_stage ~target ~target_cfg ~run_log ~action ~accept_unresolved ()
;;

let reconcile_environment_for_deploy
      ~planning
      ~target
      ~run_log
      ~await_delegation
      ~confirm_ecr_removal
      ~accept_unresolved
      ()
  =
  let target_cfg = planning.Sol_cli_deploy_selection.Target_plan_input.config.target in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  let* installation =
    installation_stage
      ~target
      ~target_cfg
      ~action:Sol_cli_command_request.Deploy_apply
      ~await_delegation
      ()
  in
  let* () =
    match installation with
    | Installation_established ->
      print_guided (Sol_cli_installation_onboarding.observed_lines ~target);
      Ok ()
    | Installation_reported ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "the durable installation for %s could not be established with positive \
               evidence; target reconciliation stopped before changing the environment"
              target))
  in
  let* () = Cmd_cloud_tf.check_terraform () in
  (match target_cfg.Sol_cli_config.kube_context with
   | None ->
     print_guided
       [ "This target names no Kubernetes destination Sol can reach from here, so this \
          is "
         ^ "the first run for "
         ^ target
         ^ ":"
       ]
   | Some _ -> ());
  print_guided
    [ ""
    ; Printf.sprintf
        "Reconciling the whole target %s — infrastructure, platform and workloads."
        target
    ];
  match
    Sol_cli_environment_stage.apply_config
      ~confirm_ecr_removal
      ~accept_unresolved
      ~assets
      ~run_log
      ~config:planning.config
      ~var_file:None
      ~vars:[]
      ()
  with
  | Ok (Sol_cli_environment_stage.Applied { cluster; infra_dir }) ->
    print_guided [ Printf.sprintf "The environment for %s is reconciled." target ];
    environment_destination ~target ~target_cfg ~cluster ~infra_dir
  | Ok (Sol_cli_environment_stage.Apply_failed { failure; _ }) ->
    Error
      (Sol_cli_exit.failure ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
  | Error failure ->
    Error
      (Sol_cli_exit.failure ("\n" ^ Sol_cli_environment_stage.failure_to_string failure))
;;

(** The destination, whether this run established the environment, and — when it did — the
    root directory it reconciled.

    The root directory is [None] on every path that did not reconcile an environment: a
    target whose destination is already declared and reachable. There is no provisioning
    root to read there, which the database setup step treats as "nothing to reconcile",
    not as an absent database. *)
let destination_or_environment_stage
      ~planning
      ~target
      ~run_log
      ~action
      ~await_delegation
      ~confirm_ecr_removal
      ~accept_unresolved
      ()
  =
  let target_cfg =
    planning.Sol_cli_deploy_selection.Target_plan_input.config.Sol_cli_config.target
  in
  let declared_context =
    match target_cfg.Sol_cli_config.kube_context with
    | Some context -> not (Sol_cli_string.is_blank context)
    | None -> false
  in
  let first_run () =
    let* destination, infra_dir =
      first_run
        ~target
        ~target_cfg
        ~action
        ~await_delegation
        ~run_log
        ~accept_unresolved
        ()
    in
    Ok (destination, true, Some infra_dir)
  in
  if
    action = Sol_cli_command_request.Deploy_apply
    && Sol_cli_provider_capabilities.owns_root target_cfg.Sol_cli_config.provider
  then
    reconcile_environment_for_deploy
      ~planning
      ~target
      ~run_log
      ~await_delegation
      ~confirm_ecr_removal
      ~accept_unresolved
      ()
    |> Result.map (fun (destination, infra_dir) -> destination, true, Some infra_dir)
  else (
    match Sol_cli_config.destination_of_target target_cfg with
    | Ok destination when not (allow_setup action) -> Ok (destination, false, None)
    | Ok destination when Sol_cli_target_report.context_is_configured destination ->
      Ok (destination, false, None)
    | Ok _ -> first_run ()
    | Error message when declared_context -> Error (Sol_cli_exit.error message)
    | Error _ when allow_setup action -> first_run ()
    | Error message ->
      let* () = guide_installation ~target ~target_cfg ~action ~await_delegation in
      Error (Sol_cli_exit.error message))
;;

let push_deploy_events ~ctx ~target_cfg ~loki_push_url events =
  let backend =
    Option.bind
      target_cfg.Sol_cli_config.observability_backend
      Sol_cli_observability_backend.backend_of_string
    |> Option.value ~default:Sol_cli_observability_backend.Local
  in
  try Cmd_deploy_event.push_all ~ctx ~backend ~explicit_url:loki_push_url events with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    Printf.eprintf
      "warning: deploy-event log push failed: %s\n%!"
      (Printexc.to_string exn)
;;

let run_dry_run (ctx : Sol_cli_deploy_run.context) ~emit_to ~await_delegation =
  print_header ~workspace:ctx.execution.workspace ~sha:ctx.sha ~mode_line:"(dry-run)" ();
  let planning = planning_input_of_ctx ctx ~emit_to in
  let* plan = build_plan planning in
  let plan = Sol_cli_deploy_selection.Target_plan.to_deployment_plan plan in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  Sol_cli_deploy_run.run_offline
    ctx
    ~phase:"dry-run"
    ~mode:Sol_cli_executor.Dry_run
    ~present_plan:(present_plan ctx)
    ~on_substrate_refused:(fun _ ->
      guide_installation_of_ctx
        ~ctx
        ~action:(Sol_cli_command_request.Deploy_dry_run { emit_to })
        ~await_delegation
      |> ignore)
    plan
  |> Result.map (fun _ -> ())
  |> Result.map_error run_failed
;;

let run_emit (ctx : Sol_cli_deploy_run.context) ~dir =
  print_header
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~mode_line:(Printf.sprintf "emit-to: %s" dir)
    ();
  let planning = planning_input_of_ctx ctx ~emit_to:(Some dir) in
  let* plan = build_plan planning in
  let plan = Sol_cli_deploy_selection.Target_plan.to_deployment_plan plan in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  let* results =
    Sol_cli_deploy_run.run_offline
      ctx
      ~phase:"emit"
      ~mode:(Sol_cli_executor.Emit_to dir)
      ~present_plan:(present_plan ctx)
      ~on_substrate_refused:(fun _ -> ())
      plan
    |> Result.map_error run_failed
  in
  results
  |> List.iter (fun (r : Sol_cli_executor.result) ->
    let path = Filename.concat dir (Printf.sprintf "%s-%s.yaml" r.namespace r.name) in
    Printf.printf "  ✓  %s\n%!" path);
  Printf.printf "\nManifests written to %s/\n" dir;
  Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n";
  Ok ()
;;

let report_apply_success (ctx : Sol_cli_deploy_run.context) results =
  results
  |> List.iter (fun r ->
    Printf.printf "  ✓  namespace %s  image %s\n\n%!" r.Sol_cli_executor.namespace r.image);
  Printf.printf "\nDone. %d service(s) deployed.\n" (List.length ctx.services);
  print_service_urls (Sol_cli_deploy_run.http_services ~ctx:ctx.execution.cluster results);
  Printf.printf "Use Kubernetes tooling to inspect workload health after deployment.\n%!"
;;

let namespace_of_facts ~workspace (facts : Sol_cli_workspace_model.t) =
  Sol_cli_workspace_model.workloads facts
  |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
    let open Result.Syntax in
    let* unit = Sol_cli_authorization_reconcile.unit_name workload.service in
    Sol_cli_deployment_plan.namespace_name
      ~workspace
      ~domain:workload.service.Sol_cli_manifest.domain
    |> Result.map (fun namespace -> unit, namespace))
  |> Result.map (fun pairs -> fun unit -> List.assoc_opt unit pairs)
;;

let verify_effective_access
      (planning : Sol_cli_deploy_selection.Target_plan_input.t)
      ~target_cfg
  =
  let open Result.Syntax in
  let* grants = Sol_cli_authorization_reconcile.desired planning.facts in
  let* namespace_of = namespace_of_facts ~workspace:planning.workspace planning.facts in
  let* workloads = Sol_cli_authorization_reconcile.workloads ~grants ~namespace_of in
  (Sol_cli_provider_capabilities.capabilities_of target_cfg.Sol_cli_config.provider)
    .authorization_effective_access
    target_cfg
    workloads
;;

let check_effective_access
      (planning : Sol_cli_deploy_selection.Target_plan_input.t)
      ~target_cfg
  =
  verify_effective_access planning ~target_cfg
  |> Sol_cli_exit.of_msg
  |> Result.map_error (fun (failure : Sol_cli_exit.failure) -> failure.text)
;;

(** The refusal ADR 0007 condition 6 exists to make loud: a target that declares a
    Sol-provisioned database must take its master from the cluster root's output, never from
    an operator's environment. 2b deleted the env fallback the condition removes, so this is
    now the only source; the message stays explicit about what it replaced. *)
let database_master_unavailable ~target detail =
  Printf.sprintf
    "could not obtain the database master for target %s from the cluster output: %s.\n\
     ADR 0007 condition 6: a Sol-provisioned database's master is delivered from the \
     cluster root's `postgres_url` output, not from an operator's POSTGRES_URL \
     environment variable. Fix the output (or re-run the environment reconcile) and \
     retry; Sol does not fall back to POSTGRES_URL."
    target
    detail
;;

(** 2d: every consumer verifies the endpoint against this CA, so a null or unreadable one is
    a failure, not a fallback to an unverified connection. *)
let database_ca_unavailable ~target detail =
  Printf.sprintf
    "could not obtain the database CA for target %s from the cluster output: %s.\n\
     ADR 0007 condition 6 / 2d: a Sol-provisioned database's clients run the provider's \
     `sslmode`, which needs the trust anchor the cluster root publishes as \
     `postgres_ca_cert`. Fix the output (or re-run the environment reconcile) and retry; \
     Sol does not fall back to an unverified connection."
    target
    detail
;;

(** The 2c database setup step, run once per target between the deploy prerequisites and the
    workloads. It is a no-op unless the target provisions its own database:

    - no postgres resource, or one that is externally bound: nothing to do. An external
      database owns its own roles; Sol writing DDL/DML credentials for it would invent a
      contract the external authority never agreed to.
    - a Sol-provisioned postgres resource: the master must come from the cluster root's
      [postgres_url] output. A run that did not reconcile the environment, an unreadable
      output, and a null output are all failures — never a silent fallback.

    The credentials land in the two class Secrets ([Sol_cli_database_setup_render]): DDL in
    the migration namespace, DML in each namespace that consumes this resource. The master
    itself lives only in the Job's transient Secret, which the coordinator deletes. *)
let run_database_setup_step
      ~(planning : Sol_cli_deploy_selection.Target_plan_input.t)
      ~ctx
      ~infra_dir
      ~plan
      ~setup_image
  =
  let open Result.Syntax in
  (* [target.name] is the resolved target path ([<env>/<provider>/<region>]), which is not a
     Kubernetes name: the setup Job, its Secret and the output Secrets are named from a
     sanitized form. The path itself stays in the diagnostics. *)
  let target_path =
    planning.Sol_cli_deploy_selection.Target_plan_input.config.target.name
  in
  let selection = plan.Sol_cli_deployment_plan.database in
  let database =
    Sol_cli_database_setup_run.identity
      ~workspace:planning.workspace
      ~config:planning.config
      ~database:selection
  in
  let target = database.Sol_cli_database_setup_render.target in
  (* The namespace and the declaration belong to the target's database operations, so they are
     established only where a database is involved: a target that binds none gets neither, as
     before, and the migration gate ensures the namespace itself when it needs it. *)
  let migration_namespace = Sol_cli_database_setup_render.database_namespace database in
  let establish () =
    let* () =
      Sol_cli_substrate.ensure ~ctx ~namespaces:[ migration_namespace ] ~workloads:[]
    in
    (* The deploy declares the identity it resolved, so a verifier reads the location instead of
       reproducing the naming rule. Stable fields; see database_identity_report. *)
    Sol_cli_report.app
      "%s"
      (Sol_cli_database_setup_render.database_identity_report database);
    Ok ()
  in
  match selection with
  | Sol_cli_resource_binding.No_postgres
  | Sol_cli_resource_binding.External_postgres _
  | Sol_cli_resource_binding.Local_postgres _ ->
    (* No Sol-provisioned database: the target either binds its database externally — then
       the class Secrets are still delivered, by ESO, from the store the delivery names — or
       has no database and there is nothing to do. The delivery was resolved with the plan
       ([Sol_cli_deployment_plan.resource_delivery]), and the GitOps emit renders the same
       class ExternalSecrets from it. *)
    (match plan.Sol_cli_deployment_plan.resource_delivery with
     | None -> Ok ()
     | Some delivery ->
       let* () = establish () in
       Sol_cli_database_setup_run.run_external_credentials ~ctx delivery)
  | Sol_cli_resource_binding.Managed_postgres _ ->
    let* () = establish () in
    let provider =
      planning.Sol_cli_deploy_selection.Target_plan_input.config.target.provider
    in
    let* master_url, ca_cert =
      match infra_dir with
      | None ->
        Error
          (database_master_unavailable
             ~target:target_path
             "this run did not reconcile the environment, so there is no cluster root to \
              read")
      | Some infra_dir ->
        let* output =
          Sol_cli_terraform.output_json ~chdir:infra_dir ()
          |> Result.map_error (fun error ->
            database_master_unavailable
              ~target:target_path
              (Printf.sprintf
                 "reading the cluster output failed: %s"
                 (Sol_cli_process.error_to_string error)))
        in
        let* postgres_url =
          Sol_cli_provider_registry.postgres_url_of_outputs
            provider
            output.Sol_cli_process.stdout
          |> Result.map_error (fun failure ->
            database_master_unavailable
              ~target:target_path
              (Printf.sprintf
                 "parsing the cluster output failed: %s"
                 (Sol_cli_provider_registry.resolution_failure_to_string failure)))
        in
        let* master_url =
          match postgres_url with
          | Some url -> Ok url
          | None ->
            Error
              (database_master_unavailable
                 ~target:target_path
                 "the `postgres_url` output is null, so the provisioning configuration \
                  reports no database")
        in
        (* 2d: the CA is read and required alongside the master. Every consumer runs
           `sslmode=verify-full`, so a missing anchor is a failure to state, not a reason
           to connect unverified. *)
        let* ca_cert =
          Sol_cli_provider_registry.postgres_ca_cert_of_outputs
            provider
            output.Sol_cli_process.stdout
          |> Result.map_error (fun failure ->
            database_ca_unavailable
              ~target:target_path
              (Printf.sprintf
                 "parsing the cluster output failed: %s"
                 (Sol_cli_provider_registry.resolution_failure_to_string failure)))
        in
        let* ca_cert =
          match ca_cert with
          | Some cert -> Ok cert
          | None ->
            Error
              (database_ca_unavailable
                 ~target:target_path
                 "the `postgres_ca_cert` output is null, so there is no trust anchor to \
                  verify the database against")
        in
        Ok (master_url, ca_cert)
    in
    (* **#1427: the image was resolved before the substrate gate and is passed down.** [None]
       here would mean no image was required for a database this branch is setting up, which is
       a contradiction rather than a fallback: refuse instead of provisioning with nothing. *)
    let* image =
      match setup_image with
      | Some image -> Ok image
      | None ->
        Error
          "a Sol-provisioned database needs a database setup image, and none was \
           resolved before the infrastructure gate"
    in
    (* The mode is the provider's, not a constant here: the contract is authenticated server
       identity and each provider establishes it its own way. *)
    let* sslmode =
      Sol_cli_provider_registry.postgres_sslmode provider
      |> Result.map_error (fun failure ->
        database_master_unavailable
          ~target:target_path
          (Printf.sprintf
             "the provider's TLS mode could not be resolved: %s"
             (Sol_cli_provider_registry.resolution_failure_to_string failure)))
    in
    let master_url =
      Sol_cli_database_setup_url.with_tls
        ~sslmode
        ~ca_cert_path:Sol_cli_database_setup_render.ca_cert_path
        master_url
    in
    (* The passwords come from the target's authority, not from a fresh generation: an
       ordinary deploy re-applies what its consumers already hold, so Postgres and the class
       projections stay in agreement. Only a target with no recorded authority bootstraps,
       and then the values are generated once and persisted before the Job touches Postgres. *)
    let* operation, ddl_password, dml_password =
      Sol_cli_database_setup_run.resolve ~ctx ~namespace:migration_namespace ~target
    in
    let ddl_url = Sol_cli_database_setup_url.ddl ~password:ddl_password master_url in
    let dml_url = Sol_cli_database_setup_url.dml ~password:dml_password master_url in
    let declared = Sol_cli_config.declared_of_config planning.config in
    (* The consumers of *this binding*. `database` above is the name-safe identity used for the
       namespace and the object names; the routing predicate compares the resource key the units
       declared, so the binding — not the sanitized identity — is what it must be asked (#1481). *)
    let dml_namespaces =
      Sol_cli_database_setup_run.dml_namespaces
        ~declared:(Some declared)
        ~database:selection
        plan
    in
    let ddl_secret =
      Sol_cli_database_setup_render.output_secret_doc
        ~ns:migration_namespace
        ~name:(Sol_cli_database_setup_render.ddl_creds_name target)
        ~postgres_url:ddl_url
    in
    (* Every projection is checked before it is rendered: a class Secret may only be written
       where nothing exists or where what exists is Sol's. The check is here rather than in
       the coordinator because the names and namespaces are. *)
    let* () =
      Sol_cli_secret.assert_destination_is_sol
        ~ctx
        ~resource:"secret"
        ~namespace:migration_namespace
        ~name:(Sol_cli_database_setup_render.ddl_creds_name target)
    in
    let* () =
      List.fold_left
        (fun acc ns ->
           let* () = acc in
           Sol_cli_secret.assert_destination_is_sol
             ~ctx
             ~resource:"secret"
             ~namespace:ns
             ~name:(Sol_cli_database_setup_render.dml_creds_name target))
        (Ok ())
        dml_namespaces
    in
    let dml_secrets =
      List.map
        (fun ns ->
           Sol_cli_database_setup_render.output_secret_doc
             ~ns
             ~name:(Sol_cli_database_setup_render.dml_creds_name target)
             ~postgres_url:dml_url)
        dml_namespaces
    in
    Sol_cli_database_setup_run.run
      ~ctx
      ~namespace:migration_namespace
      ~ca_namespaces:(migration_namespace :: dml_namespaces)
      ~target
      ~master_url
      ~operation
      ~ddl_password
      ~dml_password
      ~ca_cert
      ~image
      ~output_secrets:(ddl_secret :: dml_secrets)
;;

let run_apply
      ~planning
      ~context_of
      ~target
      ~run_log
      ~confirm_group_change
      ~confirm_ecr_removal
      ~accept_unresolved
      ~loki_push_url
      ~await_delegation
      ()
  =
  print_header
    ~workspace:planning.Sol_cli_deploy_selection.Target_plan_input.workspace
    ~sha:planning.Sol_cli_deploy_selection.Target_plan_input.sha
    ();
  let* plan = build_plan ~evaluation:Sol_cli_profile_preflight.Structural planning in
  let plan = Sol_cli_deploy_selection.Target_plan.to_deployment_plan plan in
  let* () =
    check_apply_environment
      ~facts:planning.Sol_cli_deploy_selection.Target_plan_input.facts
      ~services:planning.Sol_cli_deploy_selection.Target_plan_input.services
  in
  let* () =
    Sol_cli_deploy_run.verify_image_refs_exist
      ~image_refs:planning.Sol_cli_deploy_selection.Target_plan_input.image_refs
    |> Sol_cli_exit.of_msg
  in
  let* setup_image =
    Sol_cli_database_setup_run.setup_image_preflight planning.config
    |> Sol_cli_exit.of_msg
  in
  (* **Immutable artifact availability.** Its evidence — a digest published into the target's
     registry — cannot exist before the target root has created that registry, so a target
     that already names one is checked here, before any mutation, and a target that does not
     is provisioned first and reported incomplete below. This is the last preflight step, and
     it is evaluated before the environment stage so a warm run still refuses before
     provisioning. Nothing here changes a workload: the entire workload stage runs only when
     this is established. *)
  let pending_artifacts =
    match
      Sol_cli_profile_preflight.check
        ~evaluation:Sol_cli_profile_preflight.Artifacts
        ~target:planning.Sol_cli_deploy_selection.Target_plan_input.config.target
        ~apply_mode:Sol_cli_release.Direct
        plan
    with
    | Ok () -> None
    | Error (profile, _findings) -> Some profile
  in
  let* destination, established, infra_dir =
    destination_or_environment_stage
      ~planning
      ~target
      ~run_log
      ~action:Sol_cli_command_request.Deploy_apply
      ~await_delegation
      ~confirm_ecr_removal
      ~accept_unresolved
      ()
  in
  let target_cfg = planning.Sol_cli_deploy_selection.Target_plan_input.config.target in
  let* () =
    match pending_artifacts with
    | None -> Ok ()
    | Some profile ->
      print_guided
        [ ""
        ; "Deployment incomplete."
        ; Sol_cli_profile_preflight.pending_artifacts_report ~target ~profile plan
        ];
      Error (Sol_cli_exit.reported ~code:1 ())
  in
  print_plan_preflight_passed plan;
  let authorization = Sol_cli_provider_capabilities.capabilities_of target_cfg.provider in
  let reconciler_declared =
    match
      Sol_cli_config.provider_field target_cfg authorization.authorization_trust_field
    with
    | Some principal -> not (Sol_cli_string.is_blank principal)
    | None -> false
  in
  let* () =
    if not reconciler_declared
    then Ok ()
    else
      Cmd_grants.run
        ~config:planning.config
        ~destination
        ~action:Cmd_grants.Apply
        ~target
        ~var_file:None
        ~vars:[]
        ()
      |> Result.map_error (fun (failure : Sol_cli_exit.failure) ->
        Sol_cli_exit.failure failure.text)
  in
  let ctx : Sol_cli_deploy_run.context = context_of ~destination in
  let* plan = project_trusted_workload_issuer ctx.target_cfg plan in
  let database_setup ~setup_image () =
    run_database_setup_step
      ~planning
      ~ctx:ctx.execution.cluster
      ~infra_dir
      ~plan
      ~setup_image
  in
  let kafka_delivery () =
    Sol_cli_kafka_delivery.run
      ~ctx:ctx.execution.cluster
      ~target:ctx.target_cfg
      ~kafka:plan.kafka
      ~services:plan.services
  in
  Sol_cli_deploy_run.apply
    ctx
    ~present_plan:(present_plan ctx)
    ~effective_access:(fun () ->
      check_effective_access planning ~target_cfg:ctx.target_cfg)
    ~on_substrate_refused:(fun _ ->
      if not established
      then
        guide_installation_of_ctx
          ~ctx
          ~action:Sol_cli_command_request.Deploy_apply
          ~await_delegation
        |> ignore)
    ~confirm_group_change
    ~resolve_setup_image:(fun () -> Ok setup_image)
    ~database_setup
    ~kafka_delivery
    ~push_events:
      (push_deploy_events
         ~ctx:ctx.execution.cluster
         ~target_cfg:ctx.target_cfg
         ~loki_push_url)
    ~report_success:(fun _plan results -> report_apply_success ctx results)
    plan
  |> Result.map_error run_failed
;;

let run (req : Sol_cli_command_request.deploy_request) =
  let workspace = workspace_name () in
  let sha = req.image_tag in
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  let inventory = Sol_cli_workspace_model.services facts in
  let* selection =
    Sol_cli_deploy_selection.select ~image_refs:req.image_refs inventory
    |> Sol_cli_exit.of_msg
  in
  let* resolved_config =
    Sol_cli_config.load_for_target ~target:req.target
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  let target_cfg = resolved_config.target in
  let* deployed =
    Sol_cli_deploy_selection.apply_target
      ~target:req.target
      ~config:resolved_config
      selection
    |> Sol_cli_exit.of_msg
  in
  List.iter print_endline deployed.notes;
  let { Sol_cli_deploy_selection.image_refs; _ } = selection in
  let services = deployed.services in
  let registry =
    match req.registry with
    | Some r -> r
    | None ->
      (match target_cfg.registry with
       | Some r -> r
       | None -> "")
  in
  let run_log = Sol_cli_run_log.create ~prefix:"deploy" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  (match Sol_cli_config.execution_of_target target_cfg with
   | Sol_cli_config.Serverless ->
     (match req.action with
      | Sol_cli_command_request.Deploy_apply ->
        Sol_cli_exit.exit_on
          (run_serverless ~resolved_config ~target_cfg ~deployed ~selection ~run_log);
        Stdlib.exit 0
      | Deploy_dry_run _ | Deploy_emit_to _ ->
        Sol_cli_exit.exit_on
          (Error
             (Sol_cli_exit.error
                "serverless target dispatch supports apply only; dry-run/emit are not \
                 implemented for this execution backend")))
   | Sol_cli_config.Kubernetes -> ());
  let emit_intent =
    match req.action with
    | Sol_cli_command_request.Deploy_dry_run { emit_to } -> emit_to
    | Sol_cli_command_request.Deploy_emit_to dir -> Some dir
    | Sol_cli_command_request.Deploy_apply -> None
  in
  let await_delegation = Option.value req.await_delegation ~default:300 in
  let planning : Sol_cli_deploy_selection.Target_plan_input.t =
    { workspace
    ; registry
    ; sha
    ; emit_to = emit_intent
    ; config = resolved_config
    ; facts
    ; inventory
    ; image_refs
    ; services
    }
  in
  let context_of ~destination : Sol_cli_deploy_run.context =
    { execution =
        Sol_cli_execution.context
          ~cluster:(Sol_cli_kube_destination.context_of_destination destination)
          ~workspace
          ~env:target_cfg.env
          ()
    ; sha
    ; registry
    ; facts
    ; emit_plan_to = req.emit_plan_to
    ; target_cfg
    ; resolved_config
    ; services
    ; inventory
    ; image_refs
    ; target_name = req.target
    ; run_log
    ; keep_releases = req.keep_releases
    }
  in
  match req.action with
  | Sol_cli_command_request.Deploy_apply ->
    run_apply
      ~planning
      ~context_of
      ~target:req.target
      ~run_log
      ~confirm_group_change:req.confirm_group_change
      ~confirm_ecr_removal:req.confirm_ecr_removal
      ~accept_unresolved:req.accept_unresolved
      ~loki_push_url:req.loki_push_url
      ~await_delegation
      ()
  | Deploy_dry_run { emit_to } ->
    let* destination, _, _ =
      destination_or_environment_stage
        ~planning
        ~target:req.target
        ~run_log
        ~action:(Sol_cli_command_request.Deploy_dry_run { emit_to })
        ~await_delegation
        ~confirm_ecr_removal:req.confirm_ecr_removal
        ~accept_unresolved:req.accept_unresolved
        ()
    in
    run_dry_run (context_of ~destination) ~emit_to ~await_delegation
  | Deploy_emit_to dir ->
    let* destination, _, _ =
      destination_or_environment_stage
        ~planning
        ~target:req.target
        ~run_log
        ~action:(Sol_cli_command_request.Deploy_emit_to dir)
        ~await_delegation
        ~confirm_ecr_removal:req.confirm_ecr_removal
        ~accept_unresolved:req.accept_unresolved
        ()
    in
    run_emit (context_of ~destination) ~dir
;;

let target_arg =
  Sol_cli_target_arg.positional
    ~doc:
      "Deployment target path: <env>/<provider>/<region>, e.g. dev/aws/us-east-1 — same \
       convention as 'sol plan'. Resolves sol.yml, then the environment and target in \
       sol/environments.yml, for registry/env defaults. Unlike 'sol local deploy' \
       (local-only, no target concept), this is required."
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info [ "dry-run" ] ~doc:"Print synthesized YAML to stdout without applying")
;;

let emit_to_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "emit-to" ]
        ~docv:"DIR"
        ~doc:
          "Write YAML files to DIR instead of applying (GitOps mode). One file per \
           service: <namespace>-<name>.yaml")
;;

let emit_plan_to_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "emit-plan-to" ]
        ~docv:"FILE"
        ~doc:
          "Write the deployment plan as JSON to FILE before executing. Use '-' to print \
           to stdout. Plan format is experimental.")
;;

let image_tag_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "image-tag" ]
        ~docv:"TAG"
        ~doc:
          "Image tag to deploy (default: short git SHA). In CI, pass the exact SHA built \
           by the preceding job.")
;;

let image_ref_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "image-ref" ]
        ~docv:"[SERVICE=]REPO@sha256:DIGEST"
        ~doc:
          "Deploy a pre-built immutable artifact instead of a mutable tag. Repeatable. A \
           <service>= prefix pins one service; a bare reference requires exactly one \
           selected service. Every reference must be a digest. A target that selects \
           production-single-region requires one for every deployed workload.")
;;

let registry_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "registry" ]
        ~docv:"URL"
        ~doc:
          "Container registry prefix, e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com. \
           Omit to fall back to the resolved target's own registry (its registry in \
           sol/environments.yml); required if neither is set.")
;;

let confirm_group_change_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-group-change" ]
        ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")
;;

let confirm_ecr_removal_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-ecr-removal" ]
        ~doc:
          "Confirm deleting ECR repositories whose workloads leave this target's \
           declared set")
;;

let loki_push_url_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "loki-push-url" ]
        ~docv:"URL"
        ~doc:
          "Loki push URL for this deploy's release-event log line (OBS-037), e.g. \
           https://logs-prod-000.grafana.net. When omitted: for the \
           'local'/'self_hosted_durable' observability backends, sol deploy probes the \
           cluster for an in-cluster Loki (svc/loki -n monitoring) and, if found, \
           port-forwards to it for the duration of the push; for 'external' there is no \
           in-cluster Loki and no configured push URL, so pass this flag to record the \
           event at all. A push failure never fails the deploy.")
;;

let keep_releases_arg =
  Arg.(
    value
    & opt int Sol_cli_release_retention.default_keep
    & info
        [ "keep-releases" ]
        ~docv:"N"
        ~doc:
          (Printf.sprintf
             "Keep the last N release records after a successful deploy (default %d). \
              The current and previous release are never pruned. Deployment-event \
              history is not affected."
             Sol_cli_release_retention.default_keep))
;;

let await_delegation_arg =
  Arg.(
    value
    & opt (some int) None
    & info
        [ "await-delegation" ]
        ~docv:"SECONDS"
        ~doc:
          "Bound the wait for the domain this target serves to answer with NS records \
           from a public resolver during the inline first-run setup, in five-second \
           checks. Omitted, that wait runs for up to 300 seconds; 0 disables it. The \
           exact records to add are printed either way, and an unqueryable resolver is \
           UNKNOWN rather than a silent success.")
;;

let man =
  [ `S Manpage.s_description
  ; `P
      "Like 'sol local deploy' without the build step: the images must already be in the \
       registry, addressed by --image-tag or by an immutable --image-ref."
  ; `P
      "The first run for an account is guided in place (DEC-057 §2): when this deploy \
       cannot reach the target's cluster, Sol observes the target's durable installation \
       at the provider — never inferring it from configuration — and reports what it \
       found. An installation that is not established is reported with the prerequisites \
       that are missing, the work Sol would do to set it up, and the one external action \
       the operator may have to take (today, the DNS delegation), and Sol offers to set \
       it up without a separate administrative command. An account that already has an \
       installation is deployed to without any one-time setup and without a prompt."
  ; `P
      "Every prerequisite is an observation: Established, Unmet (the provider answered \
       that it is not there) or UNKNOWN (Sol could not look). A refused or \
       unauthenticated provider answer is UNKNOWN, never treated as an absent \
       prerequisite, because a deploy identity is not required to be able to read the \
       durable resources; UNKNOWN is reported and never promoted to healthy (DEC-052)."
  ; `P
      "A run that is not interactive, or that changes nothing (--dry-run, --emit-to), \
       never prompts and never sets an installation up: it reports the same observation \
       and the command that establishes it, so a CI run fails with an explanation \
       instead of hanging or silently skipping the installation."
  ; `S "EXIT STATUS"
  ; `P
      "0 -- the deployment was applied (or emitted) and verified as the selected profile \
       requires."
  ; `P
      "1 -- the run failed: a prerequisite is unmet, unknown or was refused; a migration \
       is not applied; the deployment did not converge; or the operator declined (or was \
       not asked) to set an unestablished installation up. The reason is named on \
       stderr, and nothing is assumed healthy."
  ; `P "No other code is used by this command."
  ]
;;

let cmd =
  Cmd.v
    (Cmd.info
       "deploy"
       ~doc:
         "Reconcile a target's infrastructure, authorization and workloads, deploying \
          pre-built images. Like 'sol local deploy' but skips the build step — images \
          must already be in the registry. Takes a required TARGET positional \
          (<env>/<provider>/<region>, e.g. dev/aws/us-east-1), unlike 'sol local deploy' \
          whose positional is the optional service-path filter — 'sol local deploy' is \
          local-only and has no target to resolve. A first run against an uninstalled \
          account is guided in place rather than requiring a separate bootstrap command \
          first."
       ~man)
    Term.(
      const
        (fun
            target
             dry_run
             emit_to
             emit_plan_to
             image_tag
             raw_image_refs
             registry
             confirm_group_change
             confirm_ecr_removal
             accept_unresolved
             loki_push_url
             keep_releases
             await_delegation
           ->
           Sol_cli_exit.exit_on
             (let* req =
                Sol_cli_command_request.make_deploy_request
                  ~target
                  ~dry_run
                  ~emit_to
                  ~emit_plan_to
                  ~image_tag
                  ~image_refs:(List.map Sol_cli_image_ref.split_flag_value raw_image_refs)
                  ~registry
                  ~confirm_group_change
                  ~confirm_ecr_removal
                  ~loki_push_url
                  ~keep_releases
                  ~await_delegation
                  ~git_sha:Sol_cli_command_request.git_sha
                  ~accept_unresolved
                |> Sol_cli_exit.of_msg
              in
              run req))
      $ target_arg
      $ dry_run_flag
      $ emit_to_arg
      $ emit_plan_to_arg
      $ image_tag_arg
      $ image_ref_arg
      $ registry_arg
      $ confirm_group_change_flag
      $ confirm_ecr_removal_flag
      $ Cmd_cloud_tf.accept_unresolved_flag
      $ loki_push_url_arg
      $ keep_releases_arg
      $ await_delegation_arg)
;;
