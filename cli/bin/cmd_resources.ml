open Cmdliner
open Result.Syntax

let target_arg =
  Sol_cli_target_arg.positional ~doc:"Deployment target path: <env>/<provider>/<region>."
;;

let json_arg = Arg.(value & flag & info [ "json" ] ~doc:"Print the inventory as JSON.")

let state_only_arg =
  Arg.(
    value
    & flag
    & info
        [ "state-only" ]
        ~doc:
          "Read Terraform state and release records only; do not run independent \
           provider probes. This is not an offline mode: the state backend still needs \
           its credentials and network. It always reports `verdict: unverified` and \
           exits 1, because it cannot establish presence or absence.")
;;

let all_arg =
  Arg.(
    value
    & flag
    & info
        [ "all" ]
        ~doc:
          "Also show in-cluster, Terraform-internal, and absent class rows that the \
           default view summarizes.")
;;

let class_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "class" ]
        ~docv:"CLASS"
        ~doc:"Only show rows of this resource class. Repeatable.")
;;

let status_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "status" ]
        ~docv:"STATUS"
        ~doc:
          "Only show rows with this status (owned, recorded, missing, unrecorded, \
           external, in_cluster, synthetic, uid_mismatch, unknown). Repeatable.")
;;

let explain_arg =
  Arg.(
    value
    & flag
    & info
        [ "explain" ]
        ~doc:
          "Show the state address, observed identity, import identity, \
           observation/recovery disposition, and reason for each row.")
;;

let verbose_arg =
  Arg.(
    value
    & flag
    & info
        [ "verbose"; "v" ]
        ~doc:"Also show provider identities; equivalent to --explain.")
;;

let target_declared target =
  match Sol_cli_config.load_for_target ~target with
  | Error error ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "cannot load target %s: %s"
            target
            (Sol_cli_config.error_to_string error)))
  | Ok config ->
    if Sol_cli_config.target_declared config.Sol_cli_config.target
    then Ok config
    else
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "target %s is not declared (expected in %s)"
              target
              (Sol_cli_config.target_source config.Sol_cli_config.target)))
;;

let init_root ~echo ~assets ~run_log ~provider ~role ~backend reason =
  match
    Sol_cli_cloud_wiring.init_result ~echo ~assets run_log ~provider ~role backend
  with
  | Ok () -> Ok ()
  | Error message -> Error (reason ^ ": " ^ message)
;;

let read_or_unreadable ~role ~layer ~durable ~chdir ~backend = function
  | Ok () ->
    Sol_cli_resource_inventory.read_root
      ~role
      ~layer
      ~durable
      ~chdir
      ~backend_config:backend
  | Error reason ->
    Sol_cli_resource_inventory.unreadable_root
      ~role
      ~layer
      ~durable
      ~chdir
      ~backend_config:backend
      reason
;;

let run target json state_only all classes statuses explain verbose =
  if json then Sol_cli_report.install_terminal_stderr ();
  let* config = target_declared target in
  let target_cfg = config.Sol_cli_config.target in
  let provider = target_cfg.provider in
  let* () = Cmd_cloud_tf.require_cloud_root ~driver:provider in
  let* () = Cmd_cloud_tf.check_terraform () in
  let* assets = Cmd_cloud_tf.resolve_assets () in
  let* () =
    Sol_cli_cloud_wiring.credentials_result
      ~provider
      ~operation:"reading the resource inventory for"
      ~leaves_target_standing:true
    |> Sol_cli_exit.of_msg
  in
  let run_log = Sol_cli_run_log.create ~prefix:"resources" () in
  let* installation =
    match Sol_cli_installation.of_target target_cfg with
    | Error message -> Error (Sol_cli_exit.error message)
    | Ok configuration ->
      (match
         Sol_cli_provider_capabilities.installation_backend provider configuration
       with
       | Error message -> Error (Sol_cli_exit.error message)
       | Ok backend ->
         let chdir =
           Sol_cli_terraform_workdir.chdir
             ~provider
             ~role:Sol_cli_platform_assets.Bootstrap
             ~backend_config:backend
         in
         let initialized =
           init_root
             ~echo:(not json)
             ~assets
             ~run_log
             ~provider
             ~role:Sol_cli_platform_assets.Bootstrap
             ~backend
             "the installation state could not be initialized"
         in
         Ok
           (read_or_unreadable
              ~role:Sol_cli_resource_inventory.Installation_root
              ~layer:Sol_cli_resource_inventory.Installation
              ~durable:true
              ~chdir
              ~backend
              initialized))
  in
  let root_backend ~root =
    Sol_cli_cloud_lifecycle.backend_config target_cfg ~root |> Sol_cli_exit.of_msg
  in
  let* cloud_backend = root_backend ~root:`Cloud in
  let* platform_backend = root_backend ~root:`Platform in
  let* authorization_backend = root_backend ~root:`Authorization in
  let cloud_chdir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      ~backend_config:cloud_backend
  in
  let platform_chdir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Platform
      ~backend_config:platform_backend
  in
  let authorization_chdir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:authorization_backend
  in
  let cloud_init =
    init_root
      ~echo:(not json)
      ~assets
      ~run_log
      ~provider
      ~role:Sol_cli_platform_assets.Cluster
      ~backend:cloud_backend
      "the cloud state could not be initialized"
  in
  let platform_init =
    init_root
      ~echo:(not json)
      ~assets
      ~run_log
      ~provider
      ~role:Sol_cli_platform_assets.Platform
      ~backend:platform_backend
      "the platform state could not be initialized"
  in
  let authorization_init =
    init_root
      ~echo:(not json)
      ~assets
      ~run_log
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend:authorization_backend
      "the authorization state could not be initialized"
  in
  let platform =
    read_or_unreadable
      ~role:Sol_cli_resource_inventory.Platform_root
      ~layer:Sol_cli_resource_inventory.Platform
      ~durable:false
      ~chdir:platform_chdir
      ~backend:platform_backend
      platform_init
  in
  let authorization =
    read_or_unreadable
      ~role:Sol_cli_resource_inventory.Authorization_root
      ~layer:Sol_cli_resource_inventory.Authorization
      ~durable:false
      ~chdir:authorization_chdir
      ~backend:authorization_backend
      authorization_init
  in
  let authorization_identities =
    if state_only
    then None
    else (
      match authorization.state with
      | Sol_cli_cloud_destroy.State_unreadable _ -> None
      | Sol_cli_cloud_destroy.State_empty | Sol_cli_cloud_destroy.State_represented _ ->
        Some
          (Sol_cli_provider_registry.authorization_state_identities
             provider
             ~target:target_cfg
             authorization.state))
  in
  let cloud =
    match cloud_init with
    | Error reason ->
      ({ state = Sol_cli_cloud_destroy.State_unreadable reason
       ; observations = []
       ; dispositions = []
       ; blockers = [ Sol_cli_cloud_wiring.State_unreadable reason ]
       }
       : Sol_cli_cloud_wiring.cloud_collection)
    | Ok () ->
      Sol_cli_cloud_wiring.collect_cloud
        ~provider
        ~target_cfg
        ~cluster_name:target_cfg.cluster_name
        ~infra_dir:cloud_chdir
        ~observe:(not state_only)
        ?authorization_identities
        ()
  in
  let cloud_root =
    Sol_cli_resource_inventory.root_of_state
      ~role:Sol_cli_resource_inventory.Cluster_root
      ~layer:Sol_cli_resource_inventory.Cloud
      ~durable:false
      ~chdir:cloud_chdir
      ~backend_config:cloud_backend
      cloud.state
  in
  let roots = [ installation; cloud_root; platform; authorization ] in
  let inventory =
    Sol_cli_resource_inventory.collect target_cfg ~roots ~cloud:(Some cloud) ~state_only
    |> Sol_cli_resource_inventory.filter_inventory ~all ~classes ~statuses
  in
  if json
  then
    print_endline
      (Yojson.Safe.pretty_to_string (Sol_cli_resource_inventory.to_json inventory))
  else
    print_string
      (Sol_cli_resource_inventory.render
         ~all
         ~classes
         ~statuses
         ~explain:(explain || verbose)
         inventory);
  match inventory.verdict with
  | Sol_cli_resource_inventory.Reconciled -> Ok ()
  | Sol_cli_resource_inventory.Incomplete
  | Sol_cli_resource_inventory.Attention_required
  | Sol_cli_resource_inventory.Unknown_verdict
  | Sol_cli_resource_inventory.Unverified -> Error (Sol_cli_exit.reported ~code:1 ())
;;

let cmd =
  let doc =
    "Show the target's recorded and independently observed resources, their ownership \
     recovery disposition, and the inventory/verification verdict."
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Reads the target's installation, cloud, platform and authorization Terraform \
         states, observes the provider independently, and classifies every resource as \
         owned, recorded-but-unverified, missing, unrecorded, external, in-cluster, \
         synthetic, or unknown. It never imports, deletes, unlocks, or adopts: adoption \
         remains `sol target reconcile`."
    ; `P
        "`reconciled` requires both inventory completeness and verification \
         completeness. A recorded-but-unobserved class is `incomplete`, not a clean \
         result. A failed or unreadable observation is `unknown`, never absence. \
         `--state-only` is explicitly `unverified` and is not a presence/absence gate."
    ; `S "EXIT STATUS"
    ; `P
        "0 -- `reconciled`: inventory and verification are complete and no discrepancy \
         remains."
    ; `P
        "1 -- any other verdict (`incomplete`, `attention_required`, `unknown`, or \
         `unverified`). The JSON `verdict`, `coverage`, and `unknowns` distinguish them."
    ]
  in
  Cmd.v
    (Cmd.info "resources" ~doc ~man)
    Term.(
      const (fun target json state_only all classes statuses explain verbose ->
        Sol_cli_exit.exit_on
          (run target json state_only all classes statuses explain verbose))
      $ target_arg
      $ json_arg
      $ state_only_arg
      $ all_arg
      $ class_arg
      $ status_arg
      $ explain_arg
      $ verbose_arg)
;;
