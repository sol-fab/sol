open Result.Syntax

type terraform_inputs =
  { var_files : string list
  ; vars : string list
  }

let terraform_outcome = Sol_cli_terraform_steps.terraform_outcome
let apply_asserted = Sol_cli_terraform_steps.apply_asserted
let capabilities = Sol_cli_provider_capabilities.capabilities_of
let workspace_name = Sol_cli_workspace.current_name

let post_destroy_state ~infra_dir =
  let observed_state =
    match Sol_cli_terraform.show_json ~chdir:infra_dir () with
    | Ok result ->
      (match Sol_cli_cloud_destroy.inventory_of_show_json result.stdout with
       | Sol_cli_cloud_destroy.State_empty -> Ok []
       | Sol_cli_cloud_destroy.State_represented _ as state ->
         Ok (Sol_cli_cloud_destroy.addresses state)
       | Sol_cli_cloud_destroy.State_unreadable reason -> Error reason)
    | Error (Sol_cli_process.Non_zero result) ->
      Error (Printf.sprintf "terraform show exited %d" result.exit_code)
    | Error error ->
      Error ("terraform show could not be run: " ^ Sol_cli_process.error_to_string error)
  in
  Sol_cli_destroy_verification.state_evidence observed_state
;;

let verification_observation
      ~(destruction : Sol_cli_destruction.t)
      ~infra_dir
      ~cluster
      ~retention
      ~pre_destroy
      ~preparation
  =
  let open Sol_cli_destroy_verification in
  let state = post_destroy_state ~infra_dir in
  let observations = destruction.residue ~pre_destroy ~cluster in
  Sol_cli_report.app "%s" (Sol_cli_absence.report observations);
  let sweep = Sol_cli_absence.to_sweep observations in
  { state; sweep; retention = destruction.retention ~retention ~pre_destroy ~preparation }
;;

let workdir provider role ~backend_config =
  Sol_cli_terraform_workdir.chdir ~provider ~role ~backend_config
;;

type terraform_layout =
  { provider : Sol_cli_provider.t
  ; pname : string
  ; infra_dir : string
  ; platform_dir : string
  ; cloud_backend : string list
  ; platform_backend : string list
  }

let terraform_layout ~(cloud_target : Sol_cli_cloud_lifecycle.cloud_target) =
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let provider = target_cfg.Sol_cli_config.provider in
  let cloud_backend = Sol_cli_cloud_lifecycle.cloud_backend cloud_target in
  let platform_backend = Sol_cli_cloud_lifecycle.platform_backend cloud_target in
  { provider
  ; pname = Sol_cli_provider.to_string provider
  ; infra_dir =
      workdir provider Sol_cli_platform_assets.Cluster ~backend_config:cloud_backend
  ; platform_dir =
      workdir provider Sol_cli_platform_assets.Platform ~backend_config:platform_backend
  ; cloud_backend
  ; platform_backend
  }
;;

let materialize_workdir ~assets provider role ~backend_config =
  Sol_cli_terraform_workdir.materialize ~assets ~provider ~role ~backend_config
  |> Result.map ignore
;;

let terraform_init run_log infra_dir backend_config =
  Sol_cli_run_log.run_phase run_log ~name:"terraform-init" (fun () ->
    Sol_cli_terraform.init ~chdir:infra_dir ~backend_config ())
;;

let init ~assets run_log ~provider ~role backend_config =
  match materialize_workdir ~assets provider role ~backend_config with
  | Error message -> Error (Sol_cli_cloud_apply.Refused message)
  | Ok () ->
    terraform_init run_log (workdir provider role ~backend_config) backend_config
    |> terraform_outcome
    |> Result.map_error (fun message -> Sol_cli_cloud_apply.Terraform_failed message)
;;

let failure_message = function
  | Sol_cli_cloud_apply.Terraform_failed message | Sol_cli_cloud_apply.Refused message ->
    message
;;

let init_result ~assets run_log ~provider ~role backend_config =
  init ~assets run_log ~provider ~role backend_config |> Result.map_error failure_message
;;

let cluster_of ~(target_cfg : Sol_cli_config.target) provider infra_dir =
  Sol_cli_provider_registry.of_root provider ~target:target_cfg ~chdir:infra_dir
;;

let process_ok = Sol_cli_cluster.process_ok
let process_output_result = Sol_cli_cluster.process_output_result

let platform_vars_of_result
      ?(context = Sol_cli_cloud_lifecycle.Install)
      ~cloud_target
      ~cluster
      ()
  : (string list, string) result
  =
  let* inputs = Sol_cli_cloud_lifecycle.platform_inputs cloud_target cluster in
  Sol_cli_cloud_lifecycle.platform_terraform_vars ~context inputs
;;

let with_cluster_access (cluster : Sol_cli_cluster.t) ~refused f =
  match cluster.with_access (fun ~env -> Ok (f env)) with
  | Ok result -> result
  | Error message -> Error (refused message)
;;

let with_cluster_access_result
      (cluster : Sol_cli_cluster.t)
      (f : env:(string * string) list -> (unit, string) result)
  : (unit, string) result
  =
  cluster.with_access f
;;

let credentials_result ~provider ~operation ~leaves_target_standing
  : (unit, string) result
  =
  Sol_cli_provider_registry.credentials provider ~operation ~leaves_target_standing
;;

let cloud_ready_expectation provider = (capabilities provider).cloud_ready_expectation

let crds_established env =
  process_ok
    ~env
    [ "kubectl"
    ; "wait"
    ; "--for=condition=Established"
    ; "crd/certificates.cert-manager.io"
    ; "crd/clusterissuers.cert-manager.io"
    ; "--timeout=5s"
    ]
;;

let provisioner_rbac_established env =
  Sol_cli_cloud_lifecycle.provisioner_authorization_established ~can_i:(fun args ->
    process_ok ~env ([ "kubectl"; "auth"; "can-i" ] @ args))
;;

let install_window_open env =
  Sol_cli_cloud_lifecycle.install_window_open ~can_i:(fun args ->
    process_ok ~env ([ "kubectl"; "auth"; "can-i" ] @ args))
;;

let platform_prerequisite_targets =
  let address = Sol_cli_cloud_lifecycle.platform_address in
  Sol_cli_terraform.targets
    (address "kubernetes_namespace.cert_manager")
    (List.map
       address
       [ "kubernetes_namespace.ingress_nginx"
       ; "kubernetes_namespace.argocd"
       ; "kubernetes_namespace.redpanda"
       ; "kubernetes_namespace.monitoring"
       ; "kubernetes_cluster_role.platform_provisioner_namespaced"
       ; "kubernetes_role_binding.platform_provisioner"
       ; "kubernetes_cluster_role.platform_provisioner_cluster"
       ; "kubernetes_cluster_role_binding.platform_provisioner_cluster"
       ; "helm_release.cert_manager"
       ])
;;

let guarded_addresses_of provider state =
  Sol_cli_cloud_lifecycle.preparations_eligible
    ~state:(Sol_cli_cloud_destroy.addresses state)
    ~desired:(capabilities provider).guarded_addresses
;;

let destroy_policy_vars ~provider ~phase ~retention ~prepared =
  match prepared with
  | Sol_cli_cloud_destroy.Nothing_prepared -> []
  | Sol_cli_cloud_destroy.Prepared { retained } ->
    Sol_cli_cloud_lifecycle.policy_vars
      ~provider
      ~phase
      ~destroy_snapshot_id:(Option.value retained ~default:"")
      ~retention
;;

type reconciliation =
  { observations : Sol_cli_absence.observation list
  ; dispositions : Sol_cli_ownership_reconciliation.disposition list
  ; restored : Sol_cli_ownership_reconciliation.candidate list
  }

let adopt
      ~infra_dir
      ~var_files
      ~vars
      (candidate : Sol_cli_ownership_reconciliation.candidate)
  =
  match
    Sol_cli_terraform.import_
      ~chdir:infra_dir
      ~var_files
      ~vars
      ~address:candidate.address
      ~import_identity:candidate.import_identity
      ()
  with
  | Error error ->
    Error
      (Printf.sprintf
         "%s could not be adopted as %s: %s"
         candidate.found
         candidate.address
         (Sol_cli_process.error_to_string error))
  | Ok _ ->
    (match Sol_cli_terraform.show_json ~chdir:infra_dir () with
     | Error error ->
       Error
         (Printf.sprintf
            "adopted %s, but the state could not be re-read: %s"
            candidate.address
            (Sol_cli_process.error_to_string error))
     | Ok result ->
       let after = Sol_cli_cloud_destroy.inventory_of_show_json result.stdout in
       let owned =
         Sol_cli_cloud_destroy.resources after
         |> List.find_opt (fun (resource : Sol_cli_cloud_destroy.resource) ->
           resource.address = candidate.address)
       in
       (match owned with
        | None ->
          Error
            (Printf.sprintf
               "the adoption of %s reported success, but the state does not represent it"
               candidate.address)
        | Some resource ->
          let observed = Option.value resource.identifier ~default:"" in
          let agrees =
            Sol_cli_string.is_blank observed
            || Sol_cli_string.contains ~needle:observed candidate.import_identity
            || Sol_cli_string.contains ~needle:candidate.import_identity observed
          in
          if agrees
          then Ok ()
          else
            Error
              (Printf.sprintf
                 "the state now holds %s with provider id %s, which is not the identity \
                  %s that                   was adopted"
                 candidate.address
                 observed
                 candidate.import_identity)))
;;

let reconcile_ownership
      ~provider
      ~(target_cfg : Sol_cli_config.target)
      ~cluster_name
      ~infra_dir
      ~var_files
      ~vars
      ~act
  =
  let state =
    match Sol_cli_terraform.show_json ~chdir:infra_dir () with
    | Ok result -> Sol_cli_cloud_destroy.inventory_of_show_json result.stdout
    | Error (Sol_cli_process.Non_zero result) ->
      Sol_cli_cloud_destroy.State_unreadable
        (Printf.sprintf "terraform show exited %d" result.exit_code)
    | Error error ->
      Sol_cli_cloud_destroy.State_unreadable
        ("terraform show could not be run: " ^ Sol_cli_process.error_to_string error)
  in
  match state with
  | Sol_cli_cloud_destroy.State_unreadable reason ->
    Error
      (Printf.sprintf
         "refusing to reconcile: the Terraform state could not be read (%s), so Sol \
          cannot tell which provider resources this target already owns. An unreadable \
          state is not an empty one -- nothing is imported while ownership is unknown"
         reason)
  | Sol_cli_cloud_destroy.State_empty | Sol_cli_cloud_destroy.State_represented _ ->
    let observations =
      Sol_cli_provider_registry.observations provider target_cfg ~cluster_name
    in
    let dispositions =
      Sol_cli_ownership_reconciliation.dispositions
        ~entries:(Sol_cli_provider_registry.resource_identity provider ~cluster_name)
        ~state_addresses:(Sol_cli_cloud_destroy.addresses state)
        observations
    in
    let candidates =
      List.filter_map Sol_cli_ownership_reconciliation.candidate dispositions
    in
    if not act
    then Ok { observations; dispositions; restored = [] }
    else
      List.fold_left
        (fun acc (candidate : Sol_cli_ownership_reconciliation.candidate) ->
           match acc with
           | Error _ as error -> error
           | Ok reconciliation ->
             (match adopt ~infra_dir ~var_files ~vars candidate with
              | Error _ as error -> error
              | Ok () ->
                Ok
                  { reconciliation with
                    restored = reconciliation.restored @ [ candidate ]
                  }))
        (Ok { observations; dispositions; restored = [] })
        candidates
;;

let bootstrap_access_vars ~enabled =
  [ ("provisioner_bootstrap_admin", if enabled then "true" else "false") ]
;;

let terraform_failure r =
  terraform_outcome r
  |> Result.map_error (fun message -> Sol_cli_cloud_apply.Terraform_failed message)
;;

let with_cluster_access_apply cluster f =
  with_cluster_access cluster ~refused:(fun m -> Sol_cli_cloud_apply.Refused m) f
;;

let await_platform_readiness ~provider ~deadline_s ~env =
  let sample () =
    Sol_cli_cloud_lifecycle.readiness ~provider ~run:(fun args ->
      process_output_result ~env ("kubectl" :: args))
  in
  let unestablished_count checks =
    List.length
      (checks
       |> List.filter (fun (_, state) ->
         match state with
         | Sol_cli_cloud_lifecycle.Established -> false
         | Sol_cli_cloud_lifecycle.Unmet _ | Sol_cli_cloud_lifecycle.Unobservable _ ->
           true))
  in
  let poll_s = 15. in
  let deadline = Unix.gettimeofday () +. deadline_s in
  let waiting_since = Unix.gettimeofday () in
  let rec await () =
    let checks = sample () in
    let unestablished = unestablished_count checks in
    if unestablished = 0 || Unix.gettimeofday () >= deadline
    then checks
    else (
      Sol_cli_report.app
        "  awaiting platform readiness: %d check(s) not established, %.0fs elapsed"
        unestablished
        (Unix.gettimeofday () -. waiting_since);
      Unix.sleepf poll_s;
      await ())
  in
  await ()
;;

let confirm_guarded_removal_flag = "confirm-ecr-removal"

let required_platform_credentials ~assets ~platform_vars =
  match Sol_cli_cloud_lifecycle.profile_of_platform_vars platform_vars with
  | None -> Ok []
  | Some platform_profile ->
    (match Yojson.Safe.from_file (Sol_cli_platform_assets.components_json assets) with
     | json ->
       Ok
         (Sol_cli_cloud_lifecycle.platform_credentials_of_components
            ~platform_profile
            json)
     | exception _ ->
       Error
         "the platform's operator-supplied credential prerequisites could not be read \
          from platform/shared/components.json, so Sol cannot check them before the \
          platform install")
;;

(* How the target's deploy identity reaches its cluster. The cloud root publishes
   this, and the operator's prerequisite step needs it at exactly the moment the
   install stops for it — so the refusal can print it instead of leaving the
   operator to find a context. Absent outputs are not an error here: the refusal
   then says only what it knows. *)
let deploy_kubeconfig_handoff ~infra_dir =
  match Sol_cli_terraform.output_json ~chdir:infra_dir () with
  | Error _ -> None
  | Ok output ->
    let field name =
      match Sol_cli_terraform_outputs.raw output.stdout ~name with
      | Ok (Some value) when not (Sol_cli_string.is_blank value) ->
        Some (String.trim value)
      | _ -> None
    in
    (match field "deploy_kubeconfig_command", field "deploy_kube_context" with
     | Some command, Some context -> Some (command, context)
     | _ -> None)
;;

let verify_platform_prerequisites ~assets ~env ~platform_vars ~deploy_handoff =
  let open Result.Syntax in
  let* required =
    required_platform_credentials ~assets ~platform_vars
    |> Result.map_error (fun message -> Sol_cli_cloud_apply.Refused message)
  in
  let investigate (credential : Sol_cli_cloud_lifecycle.platform_credential) =
    let argv =
      [ "kubectl"
      ; "get"
      ; "secret"
      ; credential.secret
      ; "-n"
      ; credential.namespace
      ; "-o"
      ; "name"
      ]
    in
    match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
    | Ok _ -> Sol_cli_cloud_lifecycle.Credential_present
    | Error (Sol_cli_process.Non_zero { exit_code; stdout; stderr }) ->
      Sol_cli_cloud_lifecycle.credential_presence
        ~exit_code
        ~output:(stderr ^ " " ^ stdout)
    | Error error ->
      Sol_cli_cloud_lifecycle.Credential_unverifiable
        (Sol_cli_process.error_to_string error)
  in
  List.fold_left
    (fun accumulated (credential : Sol_cli_cloud_lifecycle.platform_credential) ->
       let* () = accumulated in
       match investigate credential with
       | Sol_cli_cloud_lifecycle.Credential_present -> Ok ()
       | Sol_cli_cloud_lifecycle.Credential_absent ->
         Error
           (Sol_cli_cloud_apply.Refused
              (Sol_cli_cloud_lifecycle.missing_platform_credential_message
                 ?deploy_handoff
                 credential))
       | Sol_cli_cloud_lifecycle.Credential_unverifiable reason ->
         Error
           (Sol_cli_cloud_apply.Refused
              (Sol_cli_cloud_lifecycle.unverifiable_platform_credential_message
                 credential
                 reason)))
    (Ok ())
    required
;;

let apply_deps
      ~assets
      ~confirm_ecr_removal
      ~run_log
      ~cloud_target
      ~(inputs : terraform_inputs)
  =
  let* deadline_s =
    Sol_cli_duration.env_seconds ~name:"SOL_PLATFORM_READINESS_TIMEOUT_S" ~default:900.
    |> Result.map_error (fun message -> Sol_cli_cloud_apply.Refused message)
  in
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let { provider; pname; infra_dir; platform_dir; platform_backend; _ } =
    terraform_layout ~cloud_target
  in
  let { var_files; vars } = inputs in
  let plan_file = Filename.temp_file "sol-cloud-apply-" ".tfplan" in
  let discard_plan () =
    List.iter Sol_cli_fs.remove_reporting [ plan_file; plan_file ^ ".args" ]
  in
  at_exit discard_plan;
  let platform_apply ~name ~scope env platform_vars =
    terraform_failure
      (Sol_cli_run_log.run_phase run_log ~name (fun () ->
         Sol_cli_terraform.apply
           ~env
           ~scope
           ~chdir:platform_dir
           ~var_files:[]
           ~vars:platform_vars
           ()))
  in
  Ok
    { Sol_cli_cloud_apply.substrate_exists =
        (fun () ->
          cluster_of ~target_cfg provider infra_dir
          |> Result.map Option.is_some
          |> Result.map_error Sol_cli_provider_registry.resolution_failure_to_string)
    ; plan =
        (fun () ->
          let* () =
            terraform_failure
              (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
                 Sol_cli_terraform.plan_saved
                   ~scope:Sol_cli_terraform.whole_root
                   ~chdir:infra_dir
                   ~var_files
                   ~vars:
                     (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true)
                      @ vars)
                   ~out:plan_file
                   ()))
          in
          match
            Sol_cli_terraform.show_saved_plan
              ~run_log
              ~phase:"terraform-plan-show"
              ~chdir:infra_dir
              ~plan_file
              ()
          with
          | Ok (_, changes) -> Ok changes
          | Error message ->
            Error
              (Sol_cli_cloud_apply.Refused ("could not read the cloud plan: " ^ message)))
    ; guarded_removals = (capabilities provider).guarded_removals
    ; confirm_guarded_removal = confirm_ecr_removal
    ; confirmation_flag = "--" ^ confirm_guarded_removal_flag
    ; apply_plan =
        (fun () ->
          terraform_failure
            (Sol_cli_run_log.run_phase run_log ~name:"terraform-apply" (fun () ->
               Sol_cli_terraform.apply_saved ~chdir:infra_dir ~plan_file ())))
    ; discard_plan
    ; outputs =
        (fun () ->
          cluster_of ~target_cfg provider infra_dir
          |> Result.map_error Sol_cli_provider_registry.resolution_failure_to_string)
    ; open_window =
        (fun cluster ->
          match cluster.bootstrap_window with
          | Verified window ->
            let* () = window.gate () in
            Result.map Option.some (window.observe ())
          | No_role_declared | Closed_by_platform_root -> Ok None)
    ; platform_vars = (fun cluster -> platform_vars_of_result ~cloud_target ~cluster ())
    ; substrate_supported =
        (fun () ->
          match
            (Sol_cli_provider_capabilities.capabilities_of provider).cluster_substrate
          with
          | None -> Ok ()
          | Some observe ->
            (match cluster_of ~target_cfg provider infra_dir with
             | Ok None -> Ok ()
             | Ok (Some cluster) ->
               let outputs_json =
                 match Sol_cli_terraform.output_json ~chdir:infra_dir () with
                 | Ok result -> result.Sol_cli_process.stdout
                 | Error _ -> ""
               in
               (match
                  Result.bind
                    (observe
                       ~outputs_json
                       ~region:target_cfg.region
                       ~cluster_name:cluster.Sol_cli_cluster.name)
                    Sol_cli_cluster_substrate.acceptable
                with
                | Ok () -> Ok ()
                | Error message -> Error (Sol_cli_cloud_apply.Refused message))
             | Error _ -> Ok ()))
    ; observe_disk_quota =
        (fun _ ->
          match (Sol_cli_provider_capabilities.capabilities_of provider).disk_quota with
          | None -> Ok None
          | Some observe ->
            (match Sol_cli_terraform.output_json ~chdir:infra_dir () with
             | Error _ ->
               Error
                 "could not read the cloud root's outputs to scope the disk-quota \
                  observation"
             | Ok outputs ->
               Result.map
                 Option.some
                 (observe ~outputs_json:outputs.stdout ~region:target_cfg.region)))
    ; cloud_ready =
        (fun cluster ->
          if cluster.ready ()
          then Ok ()
          else
            Error
              (Printf.sprintf
                 "%s cloud substrate is not Ready: %s"
                 pname
                 (cloud_ready_expectation provider)))
    ; with_cluster_access = with_cluster_access_apply
    ; platform_init =
        (fun () ->
          match
            materialize_workdir
              ~assets
              provider
              Sol_cli_platform_assets.Platform
              ~backend_config:platform_backend
          with
          | Error message -> Error (Sol_cli_cloud_apply.Refused message)
          | Ok () ->
            terraform_failure (terraform_init run_log platform_dir platform_backend))
    ; platform_installed = crds_established
    ; apply_prerequisites =
        platform_apply
          ~name:"platform-prerequisites-apply"
          ~scope:platform_prerequisite_targets
    ; await_crds =
        (fun env ->
          process_ok
            ~env
            [ "kubectl"
            ; "wait"
            ; "--for=condition=Established"
            ; "crd/certificates.cert-manager.io"
            ; "crd/clusterissuers.cert-manager.io"
            ; "--timeout=180s"
            ])
    ; verify_platform_prerequisites =
        (fun env platform_vars ->
          verify_platform_prerequisites
            ~assets
            ~env
            ~platform_vars
            ~deploy_handoff:(deploy_kubeconfig_handoff ~infra_dir))
    ; apply_platform =
        platform_apply ~name:"platform-apply" ~scope:Sol_cli_terraform.whole_root
    ; await_readiness = (fun env -> await_platform_readiness ~provider ~deadline_s ~env)
    ; remove_bootstrap_access =
        (fun () ->
          terraform_failure
            (Sol_cli_run_log.run_phase
               run_log
               ~name:"provisioner-bootstrap-access-remove"
               (fun () ->
                  Sol_cli_terraform.apply
                    ~scope:Sol_cli_terraform.whole_root
                    ~chdir:infra_dir
                    ~var_files
                    ~vars:
                      (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false)
                       @ vars)
                    ())))
    ; verify_deescalation =
        (fun cluster _control ->
          match cluster.bootstrap_window with
          | Verified window ->
            (match window.deescalated () with
             | Ok () ->
               (match window.successor () with
                | Ok () ->
                  Sol_cli_report.app "  de-escalation verified as %s" window.principal;
                  Ok ()
                | Error verdict ->
                  Error ("de-escalation could not be established: " ^ verdict))
             | Error verdict ->
               Error ("de-escalation could not be established: " ^ verdict))
          | No_role_declared ->
            Sol_cli_report.app
              "  no provisioner role declared: no bootstrap elevation to verify";
            Ok ()
          | Closed_by_platform_root -> Ok ())
    ; provisioner_effective = provisioner_rbac_established
    ; report = (fun line -> Sol_cli_report.app "%s" line)
    }
;;

let plan ~assets ~run_log ~cloud_target ~(inputs : terraform_inputs) =
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let { provider; infra_dir; platform_dir; platform_backend; _ } =
    terraform_layout ~cloud_target
  in
  let { var_files; vars } = inputs in
  let refused r = Result.map_error (fun m -> Sol_cli_cloud_apply.Refused m) r in
  let* () =
    terraform_failure
      (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan" (fun () ->
         Sol_cli_terraform.plan
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:infra_dir
           ~var_files
           ~vars
           ()))
  in
  let report_phase name = function
    | Sol_cli_cloud_lifecycle.Plannable -> Sol_cli_report.app "\n%s\n  PLANNED" name
    | Sol_cli_cloud_lifecycle.Deferred reason ->
      Sol_cli_report.app "\n%s\n  DEFERRED — %s" name reason
  in
  match cluster_of ~target_cfg provider infra_dir with
  | Ok None ->
    report_phase
      "Platform prerequisites"
      (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
    report_phase
      "Platform substrate"
      (Sol_cli_cloud_lifecycle.Deferred "requires cloud substrate to exist");
    Ok ()
  | Error failure ->
    Error
      (Sol_cli_cloud_apply.Refused
         (Sol_cli_provider_registry.resolution_failure_to_string failure))
  | Ok (Some cluster) ->
    let* platform_vars = platform_vars_of_result ~cloud_target ~cluster () |> refused in
    with_cluster_access
      cluster
      ~refused:(fun m -> Sol_cli_cloud_apply.Refused m)
      (fun env ->
         let* () =
           if process_ok ~env [ "kubectl"; "auth"; "can-i"; "--list" ]
           then Ok ()
           else
             Error
               (Sol_cli_cloud_apply.Refused
                  "could not authenticate to the cluster as the platform provisioner; \
                   refusing to report an unavailable cluster credential as a deferred \
                   phase")
         in
         let install_window_open = install_window_open env in
         let rbac_established = provisioner_rbac_established env in
         let crds_established =
           (rbac_established || install_window_open) && crds_established env
         in
         let prerequisites, substrate =
           Sol_cli_cloud_lifecycle.platform_plan_phases
             ~cluster_exists:true
             ~rbac_established
             ~install_window_open
             ~crds_established
         in
         let* () =
           match prerequisites with
           | Sol_cli_cloud_lifecycle.Plannable ->
             let* () =
               init
                 ~assets
                 run_log
                 ~provider
                 ~role:Sol_cli_platform_assets.Platform
                 platform_backend
             in
             terraform_failure
               (Sol_cli_run_log.run_phase
                  run_log
                  ~name:"platform-prerequisites-plan"
                  (fun () ->
                     Sol_cli_terraform.plan
                       ~env
                       ~scope:platform_prerequisite_targets
                       ~chdir:platform_dir
                       ~var_files:[]
                       ~vars:platform_vars
                       ()))
           | Sol_cli_cloud_lifecycle.Deferred _ -> Ok ()
         in
         let* () =
           match substrate with
           | Sol_cli_cloud_lifecycle.Plannable ->
             terraform_failure
               (Sol_cli_run_log.run_phase run_log ~name:"platform-plan" (fun () ->
                  Sol_cli_terraform.plan
                    ~env
                    ~scope:Sol_cli_terraform.whole_root
                    ~chdir:platform_dir
                    ~var_files:[]
                    ~vars:platform_vars
                    ()))
           | Sol_cli_cloud_lifecycle.Deferred _ -> Ok ()
         in
         report_phase "Platform prerequisites" prerequisites;
         report_phase "Platform substrate" substrate;
         Ok ())
;;

let destroy_preview ~assets ~run_log ~cloud_target ~(inputs : terraform_inputs)
  : (unit, string) result
  =
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let { provider; infra_dir; platform_dir; platform_backend; _ } =
    terraform_layout ~cloud_target
  in
  let { var_files; vars } = inputs in
  let* () =
    match cluster_of ~target_cfg provider infra_dir with
    | Ok (Some cluster) ->
      let* platform_vars =
        platform_vars_of_result
          ~context:Sol_cli_cloud_lifecycle.Destruction
          ~cloud_target
          ~cluster
          ()
      in
      with_cluster_access_result cluster (fun ~env ->
        let* () =
          init_result
            ~assets
            run_log
            ~provider
            ~role:Sol_cli_platform_assets.Platform
            platform_backend
        in
        terraform_outcome
          (Sol_cli_run_log.run_phase run_log ~name:"platform-plan-destroy" (fun () ->
             Sol_cli_terraform.plan_destroy
               ~env
               ~chdir:platform_dir
               ~var_files:[]
               ~vars:platform_vars
               ())))
    | Ok None ->
      Sol_cli_report.app
        "  Platform destroy DEFERRED — no install outputs are published, so the platform \
         teardown cannot be wired.";
      Ok ()
    | Error failure ->
      Sol_cli_report.app
        "  Platform destroy DEFERRED — install outputs are unavailable (%s), so the \
         platform teardown cannot be wired."
        (Sol_cli_provider_registry.resolution_failure_to_string failure);
      Ok ()
  in
  terraform_outcome
    (Sol_cli_run_log.run_phase run_log ~name:"terraform-plan-destroy" (fun () ->
       Sol_cli_terraform.plan_destroy ~chdir:infra_dir ~var_files ~vars ()))
;;

let destruction
      ~run_log
      ~provider
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~var_files
      ~vars
  =
  Sol_cli_provider_registry.destruction
    provider
    { Sol_cli_destruction.run_log
    ; infra_dir
    ; var_files
    ; vars
    ; target = target_cfg
    ; resolved_var = (fun key -> Sol_cli_terraform_vars.resolved key ~var_files ~vars)
    }
;;

let forget_addresses ~run_log ~phase ~chdir addresses =
  List.fold_left
    (fun acc address ->
       let* forgotten = acc in
       Sol_cli_report.app "    forgetting %s" address;
       let* () =
         Sol_cli_run_log.run_phase run_log ~name:phase (fun () ->
           Sol_cli_terraform.state_rm ~chdir ~address ())
         |> terraform_outcome
         |> Result.map_error (fun message ->
           Printf.sprintf
             "%s could not be forgotten in state, so it still represents an object the \
              provider does not have: %s"
             address
             message)
       in
       Ok (address :: forgotten))
    (Ok [])
    addresses
  |> Result.map List.rev
;;

let platform_state_reconciliation
      ~assets
      ~run_log
      ~provider
      ~platform_dir
      ~platform_backend
  =
  let open Sol_cli_cloud_destroy in
  let* () =
    init_result
      ~assets
      run_log
      ~provider
      ~role:Sol_cli_platform_assets.Platform
      platform_backend
  in
  match Sol_cli_terraform.show_json ~chdir:platform_dir () with
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Printf.sprintf
         "the platform root's state could not be read, so what it still represents is \
          unknown (terraform show exited %d)"
         result.exit_code)
  | Error error ->
    Error
      ("the platform root's state could not be read, so what it still represents is \
        unknown: "
       ^ Sol_cli_process.error_to_string error)
  | Ok result ->
    (match inventory_of_show_json result.stdout with
     | State_unreadable reason -> Error reason
     | State_empty -> Ok []
     | State_represented resources ->
       Sol_cli_report.app
         "  the platform root's state represents %d resource(s), and the cluster that \
          carried every one of them is provably absent, so none of them can exist"
         (List.length resources);
       forget_addresses
         ~run_log
         ~phase:"platform-destroy-forget-absent-substrate"
         ~chdir:platform_dir
         (List.map (fun (resource : resource) -> resource.address) resources))
;;

let enters_the_cluster ~provider (resource : Sol_cli_cloud_destroy.resource) =
  List.exists
    (fun prefix -> String.starts_with ~prefix resource.Sol_cli_cloud_destroy.address)
    (Sol_cli_provider_registry.substrate_addresses provider)
  || Sol_cli_cloud_destroy.in_cluster_kind resource.Sol_cli_cloud_destroy.kind
;;

let provable_absence_reconciliation
      ~assets
      ~run_log
      ~provider
      ~(target_cfg : Sol_cli_config.target)
      ~infra_dir
      ~platform_dir
      ~platform_backend
      ~var_files
      ~vars
      ~state
  =
  let open Sol_cli_cloud_destroy in
  let stale = List.filter (enters_the_cluster ~provider) (resources state) in
  match stale, substrate_presence state with
  | [], Substrate_present | [], Substrate_unknown -> Ok Nothing_to_reconcile
  | stale, _ ->
    (match Sol_cli_terraform_vars.resolved "cluster_name" ~var_files ~vars with
     | None ->
       Sol_cli_report.warn
         "warning: this target's cloud root still represents a substrate, or resources \
          that live inside one, whose existence the provider was never asked about: its \
          cluster name is neither declared nor resolved, so nothing was forgotten (a \
          state entry is only forgotten on a positively established absence).";
       Ok Nothing_to_reconcile
     | Some cluster_name ->
       (match
          Sol_cli_provider_registry.substrate_absence provider target_cfg ~cluster_name
        with
        | Sol_cli_absence.Absent _ as observation ->
          let evidence = Sol_cli_absence.summary observation in
          Sol_cli_report.app
            "  the substrate's absence is positively established at the provider: %s"
            evidence;
          if stale <> []
          then
            Sol_cli_report.app
              "  this target's cloud state still represents %d resource(s) that live \
               inside the cluster, which cannot exist once the cluster does not"
              (List.length stale);
          let* forgotten_cloud =
            forget_addresses
              ~run_log
              ~phase:"destroy-forget-absent-substrate"
              ~chdir:infra_dir
              (List.map (fun (resource : resource) -> resource.address) stale)
          in
          let* forgotten_platform =
            platform_state_reconciliation
              ~assets
              ~run_log
              ~provider
              ~platform_dir
              ~platform_backend
          in
          (match forgotten_cloud @ forgotten_platform with
           | [] -> Ok Nothing_to_reconcile
           | forgotten -> Ok (Reconciled { evidence; forgotten }))
        | observation ->
          Sol_cli_report.warn
            "warning: the state a provably absent substrate leaves behind was not \
             reconciled: the substrate's absence could not be established at the \
             provider, and only a positively established absence permits forgetting what \
             state represents (%s)."
            (Sol_cli_absence.summary observation);
          Ok Nothing_to_reconcile))
;;

let destroy_deps
      ~assets
      ~run_log
      ~cloud_target
      ~(inputs : terraform_inputs)
      ~retention
      ~workload_namespaces
      ~accept_unreleased
      ~(recorded_evidence : Sol_cli_release_id.owned_object list)
      ~(destruction : Sol_cli_destruction.t)
  : Sol_cli_cloud_destroy.deps
  =
  let target_cfg = Sol_cli_cloud_lifecycle.target cloud_target in
  let { provider; infra_dir; platform_dir; cloud_backend; platform_backend; _ } =
    terraform_layout ~cloud_target
  in
  let { var_files; vars } = inputs in
  let state_ref = ref Sol_cli_cloud_destroy.State_empty in
  let prepared_ref = ref Sol_cli_cloud_destroy.Nothing_prepared in
  let cluster_ref = ref None in
  let observed_window = ref None in
  let destroy_phase () =
    let substrate = Sol_cli_cloud_destroy.substrate_presence !state_ref in
    let cloud_exists = substrate <> Sol_cli_cloud_destroy.Substrate_absent in
    Sol_cli_cloud_lifecycle.enter_destruction
      ~from:
        (Sol_cli_cloud_lifecycle.observed_phase ~cloud_exists ~platform_installed:true)
  in
  let destroy_apply_vars () =
    vars
    @ Sol_cli_terraform.kv_args
        (destroy_policy_vars
           ~provider
           ~phase:(destroy_phase ())
           ~retention
           ~prepared:!prepared_ref)
  in
  let prepare_cluster_name () =
    match !cluster_ref with
    | Some (cluster : Sol_cli_cluster.t) -> cluster.name
    | None ->
      (match Sol_cli_terraform_vars.resolved "cluster_name" ~var_files ~vars with
       | Some name -> name
       | None -> workspace_name ())
  in
  let destroy_platform_result ~cluster () : (unit, string) result =
    let* platform_vars =
      platform_vars_of_result
        ~context:Sol_cli_cloud_lifecycle.Destruction
        ~cloud_target
        ~cluster
        ()
    in
    with_cluster_access_result cluster (fun ~env ->
      let* () =
        init_result
          ~assets
          run_log
          ~provider
          ~role:Sol_cli_platform_assets.Platform
          platform_backend
      in
      Sol_cli_platform_teardown.destroy
        ~run_log
        ~env
        ~chdir:platform_dir
        ~vars:platform_vars)
  in
  let release_workloads_result () : Sol_cli_workload_scope.release =
    let open Sol_cli_workload_scope in
    match Sol_cli_config.destination_of_target target_cfg with
    | Error message ->
      Workloads_not_releasable
        (Printf.sprintf
           "the target's cluster could not be addressed, so there is no cluster to \
            release from (%s)"
           message)
    | Ok destination ->
      let ctx = Sol_cli_kube_destination.context_of_destination destination in
      let workspace = workspace_name () in
      let run args =
        Sol_cli_kubectl.run ~ctx args
        |> Result.map (fun (listing : Sol_cli_process.output) -> listing.stdout)
      in
      (* Namespace existence is established under the cluster-access identity -- the lifecycle
         authority that already manages the platform (DEC-034) -- and never under the deploy
         identity, whose namespaced authority begins only where it has deployed. Before an
         absence is trusted, the view must be shown to see namespaces at all: a view that were
         filtered (an identity scoped to particular namespaces) would answer NotFound for a
         namespace that exists, and a look-up that cannot be trusted must never become a
         deletion decision. An authority that cannot be shown is unestablished, which keeps
         the refusal. Every read is bounded, so a hung kubectl is unestablished and never
         absence (sol-fab/sol#1491). *)
      let namespace_view_authority = ref None in
      let authority_probe (cluster : Sol_cli_cluster.t) =
        match !namespace_view_authority with
        | Some answer -> answer
        | None ->
          let answer =
            cluster.with_access (fun ~env ->
              match
                Sol_cli_process.run
                  (Sol_cli_process.cmd
                     ~env
                     ~timeout_s:60.
                     ("kubectl" :: namespace_exists_args ~namespace:"kube-system"))
              with
              | Ok _ -> Ok ()
              | Error error -> Error (Sol_cli_process.error_to_string error))
          in
          namespace_view_authority := Some answer;
          answer
      in
      let namespace_probe namespace =
        match !cluster_ref with
        | None ->
          Namespace_unestablished
            "the cluster this target provisioned is not recorded, so whether its \
             namespaces exist cannot be established"
        | Some cluster ->
          (match authority_probe cluster with
           | Error message ->
             Namespace_unobservable
               (Printf.sprintf
                  "the cluster-access identity's view of namespaces could not be \
                   established (%s)"
                  message)
           | Ok () ->
             (match
                cluster.with_access (fun ~env ->
                  match
                    Sol_cli_process.run
                      (Sol_cli_process.cmd
                         ~env
                         ~timeout_s:60.
                         ("kubectl" :: namespace_exists_args ~namespace))
                  with
                  | Ok _ -> Ok Namespace_exists
                  | Error error ->
                    let reason = Sol_cli_process.error_to_string error in
                    (match Sol_cli_kubectl.classify error with
                     | Sol_cli_kubectl.Not_found -> Ok Namespace_absent
                     | Sol_cli_kubectl.Unreachable -> Ok (Namespace_unreachable reason)
                     | _ -> Ok (Namespace_unestablished reason)))
              with
              | Ok probe -> probe
              | Error message -> Namespace_unestablished message))
      in
      release_workloads
        ~run
        ~namespace_probe
        ~delete:(fun ~namespace ~names ->
          Sol_cli_kubectl.run ~ctx (delete_args ~namespace ~names ~timeout_seconds:300)
          |> Result.map ignore)
        ~wait:(fun ~namespace ->
          Sol_cli_kubectl.run ~ctx (wait_args ~namespace ~workspace ~timeout_seconds:300)
          |> Result.map ignore)
        ~evidence:recorded_evidence
        ~namespaces:workload_namespaces
        ~workspace
  in
  let deps : Sol_cli_cloud_destroy.deps =
    { require_credentials =
        (fun () ->
          credentials_result
            ~provider
            ~operation:"destroying"
            ~leaves_target_standing:true)
    ; terraform_init =
        (fun () ->
          init_result
            ~assets
            run_log
            ~provider
            ~role:Sol_cli_platform_assets.Cluster
            cloud_backend)
    ; observe_state =
        (fun () ->
          match Sol_cli_terraform.show_json ~chdir:infra_dir () with
          | Ok result ->
            state_ref := Sol_cli_cloud_destroy.inventory_of_show_json result.stdout;
            Ok result.stdout
          | Error (Sol_cli_process.Non_zero result) ->
            Error
              (Printf.sprintf
                 "terraform show failed with exit %d%s"
                 result.exit_code
                 (let detail = String.trim result.stderr in
                  if detail = "" then "" else ": " ^ detail))
          | Error error ->
            Error
              ("could not read terraform state: " ^ Sol_cli_process.error_to_string error))
    ; reconcile_provable_absence =
        (fun () ->
          provable_absence_reconciliation
            ~assets
            ~run_log
            ~provider
            ~target_cfg
            ~infra_dir
            ~platform_dir
            ~platform_backend
            ~var_files
            ~vars
            ~state:!state_ref)
    ; cloud_outputs =
        (fun () ->
          match cluster_of ~target_cfg provider infra_dir with
          | Ok (Some cluster) ->
            cluster_ref := Some cluster;
            Sol_cli_cloud_destroy.Outputs_available
          | Ok None ->
            Sol_cli_cloud_destroy.Outputs_unavailable "no install outputs are published"
          | Error (Sol_cli_provider_registry.State_unreadable reason) ->
            Sol_cli_cloud_destroy.Outputs_unreadable reason
          | Error failure ->
            Sol_cli_cloud_destroy.Outputs_unavailable
              (Sol_cli_provider_registry.resolution_failure_to_string failure))
    ; prepare =
        (fun ~state ->
          let outcome =
            destruction.prepare ~retention ~cluster_name:(prepare_cluster_name ()) ~state
          in
          (match outcome with
           | Sol_cli_cloud_lifecycle.Prepared preparation -> prepared_ref := preparation
           | Sol_cli_cloud_lifecycle.Nothing_to_prepare
           | Sol_cli_cloud_lifecycle.Preparation_failed _ -> ());
          outcome)
    ; authority =
        (match (capabilities provider).authority with
         | Sol_cli_provider_capabilities.No_authority_required ->
           Sol_cli_cloud_destroy.No_authority_required
         | Sol_cli_provider_capabilities.Mechanism
             { matchers; scope = bootstrap_scope; reconciliation_scope } ->
           Sol_cli_cloud_destroy.Mechanism
             { reconcile_and_enable =
                 (fun () ->
                   let guarded = guarded_addresses_of provider !state_ref in
                   apply_asserted
                     ~run_log
                     ~phase_name:"destroy-reconciliation-apply"
                     ~policy:
                       (Sol_cli_cloud_destroy.reconciliation_policy
                          ~bootstrap:matchers
                          ~guarded)
                     ~scope:(reconciliation_scope guarded)
                     ~chdir:infra_dir
                     ~var_files
                     ~vars:
                       (Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:true)
                        @ destroy_apply_vars ())
                     ())
             ; remove_elevated_access =
                 (fun () ->
                   apply_asserted
                     ~run_log
                     ~phase_name:"provisioner-bootstrap-access-remove"
                     ~policy:
                       (Sol_cli_cloud_destroy.bootstrap_removal_policy
                          ~bootstrap:matchers)
                     ~scope:bootstrap_scope
                     ~chdir:infra_dir
                     ~var_files
                     ~vars:
                       (vars
                        @ Sol_cli_terraform.kv_args (bootstrap_access_vars ~enabled:false)
                       )
                     ())
             })
    ; destroy_platform =
        (fun () ->
          match !cluster_ref with
          | Some cluster -> destroy_platform_result ~cluster ()
          | None ->
            Error "the platform teardown requires install outputs, which are unavailable")
    ; observe_window_before =
        (fun () ->
          match !cluster_ref with
          | Some { Sol_cli_cluster.bootstrap_window = Verified window; _ } ->
            let* () = window.observe () in
            observed_window := Some window;
            Ok ()
          | Some { bootstrap_window = No_role_declared; _ } ->
            Sol_cli_report.app
              "  no provisioner role declared: no bootstrap elevation to verify";
            Ok ()
          | Some { bootstrap_window = Closed_by_platform_root; _ } -> Ok ()
          | None ->
            Sol_cli_report.app
              "  bootstrap window: not observed (no install outputs to reach the cluster \
               with)";
            Ok ())
    ; verify_window_after =
        (fun () ->
          match !observed_window with
          | None -> Ok ()
          | Some window ->
            (match window.deescalated () with
             | Ok () -> Ok ()
             | Error verdict ->
               Error
                 (Printf.sprintf
                    "the bootstrap access was removed but its effective removal could \
                     not be verified (%s). Proceeding: destroying the substrate removes \
                     the access with it, and teardown is not blocked by a probe that can \
                     fail (ADR 0003 invariant 6)."
                    verdict)))
    ; release_workloads = release_workloads_result
    ; accept_unreleased
    ; destroy_substrate =
        (fun () ->
          destruction.before_substrate_destroy ();
          terraform_outcome
            (Sol_cli_run_log.run_phase run_log ~name:"terraform-destroy" (fun () ->
               Sol_cli_terraform.destroy
                 ~chdir:infra_dir
                 ~var_files
                 ~vars:(destroy_apply_vars ())
                 ())))
    ; verify_destruction =
        (fun ~pre_destroy ~preparation ->
          verification_observation
            ~destruction
            ~infra_dir
            ~cluster:!cluster_ref
            ~retention
            ~pre_destroy
            ~preparation)
    ; report = (fun message -> Sol_cli_report.app "%s" message)
    ; warn = (fun message -> Sol_cli_report.warn "%s" message)
    }
  in
  deps
;;
