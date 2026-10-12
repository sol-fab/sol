let available_target_paths = lazy (Sol_cli_workspace_model.load_cwd ())

let available_targets () =
  match Lazy.force available_target_paths with
  | Error reason ->
    "the workspace could not be read, so its targets are unknown: " ^ reason
  | Ok facts ->
    (match facts.Sol_cli_workspace_model.targets with
     | [] -> "no targets found: declare them in sol/environments.yml"
     | paths -> "available targets:\n  " ^ String.concat "\n  " paths)
;;

let not_shown message = Sol_cli_exit.failure (message ^ "\n\n" ^ available_targets ())

let first_line text =
  match String.split_on_char '\n' (String.trim text) with
  | line :: _ -> String.trim line
  | [] -> ""
;;

let kubernetes_status ~check (target : Sol_cli_config.target) =
  match Sol_cli_config.destination_of_target target with
  | Error reason ->
    let context = String.trim (Option.value target.kube_context ~default:"") in
    if Sol_cli_string.is_blank context
    then Sol_cli_target_report.Not_configured
    else Sol_cli_target_report.Misconfigured (context, reason)
  | Ok destination ->
    let context = destination.context in
    if not check
    then Sol_cli_target_report.Configured context
    else (
      let args = Sol_cli_kube_destination.kubectl_args destination @ [ "cluster-info" ] in
      match
        Sol_cli_kubectl.probe_result
          ~ctx:(Sol_cli_kube_destination.context_of_destination destination)
          ~args
      with
      | Ok (Sol_cli_kubectl.Succeeded _) -> Sol_cli_target_report.Reachable context
      | Ok (Sol_cli_kubectl.Failed failure) ->
        let reason = first_line (Sol_cli_process.failure_message failure) in
        (match Sol_cli_kubectl.classify (Sol_cli_process.Non_zero failure) with
         | Sol_cli_kubectl.Unreachable ->
           Sol_cli_target_report.Unreachable (context, reason)
         | Sol_cli_kubectl.Refused
         | Sol_cli_kubectl.Not_found
         | Sol_cli_kubectl.Already_exists
         | Sol_cli_kubectl.Conflict
         | Sol_cli_kubectl.No_resource_type
         | Sol_cli_kubectl.Other -> Sol_cli_target_report.Unreadable (context, reason))
      | Error message -> Sol_cli_target_report.Unreadable (context, message))
;;

let platform_status ~check ~verbose (target : Sol_cli_config.target) =
  if not check
  then None
  else (
    match Sol_cli_config.destination_of_target target with
    | Error reason ->
      Some
        (Printf.sprintf
           "Unknown — %s"
           (Sol_cli_target_report.redact_context
              ~verbose
              ~context:(Option.value target.kube_context ~default:"")
              reason))
    | Ok destination ->
      let prefix = Sol_cli_kube_destination.kubectl_args destination in
      let env = Sol_cli_kube_destination.environment destination in
      let run args =
        Sol_cli_cluster.process_output_result ~env (("kubectl" :: prefix) @ args)
      in
      let summary =
        Sol_cli_cloud_lifecycle.readiness ~provider:target.provider ~run
        |> Sol_cli_cloud_lifecycle.readiness_summary
      in
      Some
        (Sol_cli_target_report.redact_context
           ~verbose
           ~context:destination.context
           summary))
;;

let cloud_status (target : Sol_cli_config.target) =
  match Sol_cli_provider_capabilities.observe_installation target with
  | Ok (_, verdicts) -> Sol_cli_installation.health_summary verdicts
  | Error message -> "Unknown — the installation could not be resolved: " ^ message
;;

let drift_status (target : Sol_cli_config.target) =
  let drift =
    match Sol_cli_platform_assets.resolve () with
    | Error error ->
      Sol_cli_environment_stage.Unknown
        ("the platform's Terraform assets are not available: "
         ^ Sol_cli_platform_assets.error_to_string error)
    | Ok assets ->
      Sol_cli_environment_stage.drift
        ~assets
        ~target:target.name
        ~var_file:None
        ~vars:[]
        ()
  in
  Sol_cli_environment_stage.drift_to_string drift
;;

let substrate_status
      ~check
      ~verbose
      (target : Sol_cli_config.target)
      (status : Sol_cli_target_report.kubernetes_status)
  =
  if not check
  then None
  else (
    let reason context why = Sol_cli_target_report.redact_context ~verbose ~context why in
    let cluster =
      match status with
      | Sol_cli_target_report.Reachable _ -> `Reachable
      | Unreachable (context, why) -> `Unmet (reason context why)
      | Unreadable (context, why) -> `Unknown (reason context why)
      | Misconfigured (context, why) -> `Unmet (reason context why)
      | Not_configured -> `Unmet "the target declares no explicit Kubernetes destination"
      | Configured _ -> `Unknown "the cluster was not probed"
    in
    Some
      (Sol_cli_substrate_contract.lines
         { cluster; registry = target.registry; base_domain = target.base_domain }))
;;

(* Live state, so it is read only under --check: how an operator or a harness reaches
   this target's cluster, as the cloud root itself declares it. Absent outputs are not
   an error here — the report then says nothing about a handoff rather than guessing a
   context (DEC-020 keeps the context a mechanism, not the target's identity). *)
let deploy_handoff (target : Sol_cli_config.target) =
  match Sol_cli_cloud_lifecycle.cloud_target target with
  | Error _ -> None
  | Ok cloud_target ->
    let infra_dir =
      Sol_cli_terraform_workdir.chdir
        ~provider:target.provider
        ~role:Sol_cli_platform_assets.Cluster
        ~backend_config:(Sol_cli_cloud_lifecycle.cloud_backend cloud_target)
    in
    (match Sol_cli_terraform.output_json ~chdir:infra_dir () with
     | Error _ -> None
     | Ok output -> Sol_cli_target_report.deploy_handoff_of_outputs output.stdout)
;;

open Result.Syntax

let declared_target target =
  match Sol_cli_config.load_for_target ~target with
  | Error e -> Error (not_shown (Sol_cli_config.error_to_string e))
  | Ok { target = target_config; _ }
    when not (Sol_cli_config.target_declared target_config) ->
    Error
      (not_shown
         (Printf.sprintf
            "target %s is not declared (expected in %s)"
            target
            (Sol_cli_config.target_source target_config)))
  | Ok config -> Ok config.target
;;

let show target verbose json check =
  let* target =
    match target with
    | Some target -> Ok target
    | None -> Error (not_shown "sol target show needs a target — which one?")
  in
  let* target_config = declared_target target in
  let status = kubernetes_status ~check target_config in
  let platform = platform_status ~check ~verbose target_config in
  let cloud = if check then Some (cloud_status target_config) else None in
  let drift = if check then Some (drift_status target_config) else None in
  let handoff = if check then deploy_handoff target_config else None in
  let substrate = substrate_status ~check ~verbose target_config status in
  if json
  then
    print_endline
      (Yojson.Safe.to_string
         (Sol_cli_target_report.to_json
            ?platform
            ?cloud
            ?drift
            ?substrate
            ?deploy_handoff:handoff
            ~verbose
            target_config
            status))
  else
    Sol_cli_target_report.rows
      ?platform
      ?cloud
      ?drift
      ?substrate
      ?deploy_handoff:handoff
      ~verbose
      target_config
      status
    |> List.iter (fun (label, value) -> Printf.printf "%-14s %s\n" label value);
  Ok ()
;;

open Cmdliner

let target_arg =
  Sol_cli_target_arg.flag
    ~doc:
      "The target to show, as a path (e.g. `prod/aws/us-east-1`). Required: there is no \
       current target, and no default (DEC-016)."
;;

let verbose_arg =
  Arg.(
    value
    & flag
    & info
        [ "verbose"; "v" ]
        ~doc:
          "Also show where the target sits and the raw kube-context Sol will use. The \
           context is hidden by default because it is a mechanism, not the target's \
           identity (DEC-020).")
;;

let json_arg = Arg.(value & flag & info [ "json" ] ~doc:"Print the same fields as JSON.")

let check_arg =
  Arg.(
    value
    & flag
    & info
        [ "check" ]
        ~doc:
          "Report live state as well as identity: probe whether the cluster is reachable \
           and report the substrate contract (docs/reference/substrate.md) as \
           Established, Unmet or UNKNOWN per input, observe whether the provider's \
           installation is established, and read whether Terraform's recorded state has \
           drifted from observed reality. An input Sol cannot observe from the CLI is \
           UNKNOWN with its reason rather than reported as satisfied, and a refused or \
           unauthenticated probe is UNKNOWN rather than a missing prerequisite \
           (DEC-052). Off by default: the summary is also what you read while diagnosing \
           an unreachable cluster, so it must not block before printing. `last \
           operation` is reported either way: it needs no read because Sol keeps no \
           target-scoped record for it.")
;;

let show_cmd =
  let doc = "Show a deployment target" in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Prints a target as a target — provider, region, cluster, registry, base domain \
         — and says whether Sol can reach its cluster. Nothing is inferred: an unknown \
         or missing target fails closed and lists what exists."
    ; `P
        "Every live field names its authority rather than keeping state of its own. \
         `cloud` is the provider's own answer for the installation Sol manages — the \
         same observation `sol plan` reports, never a Sol-side record. `drift` is a \
         read-only, refresh-only Terraform plan, so it compares the recorded state with \
         observed reality without changing either. `last operation` has no target-scoped \
         authority to read, and ADR 0003 forbids adding one, so it is reported as \
         unavailable rather than as `none`."
    ; `P
        "With --check it also reports the self-hosted substrate contract \
         (docs/reference/substrate.md) input by input, in the same Established / Unmet / \
         UNKNOWN vocabulary as the durable prerequisites: an input Sol cannot observe \
         from the CLI is reported UNKNOWN with its reason rather than as satisfied, and \
         a refused or unauthenticated probe is UNKNOWN rather than a missing \
         prerequisite (DEC-052)."
    ]
  in
  Cmd.v
    (Cmd.info "show" ~doc ~man)
    Term.(
      const Sol_cli_exit.exit_on
      $ (const show $ target_arg $ verbose_arg $ json_arg $ check_arg))
;;

(* `reconcile` is the target's ownership audit: it compares Terraform's recorded
   attribution with independently observed provider reality, and adopts what it can
   attribute exactly. It is target-scoped, like `show`, so it lives here rather than
   under a removed `sol cloud` group. *)
let cmd =
  Cmd.group
    (Cmd.info "target" ~doc:"Inspect and reconcile deployment targets")
    [ show_cmd; Cmd_cloud_tf.reconcile_cmd ]
;;
