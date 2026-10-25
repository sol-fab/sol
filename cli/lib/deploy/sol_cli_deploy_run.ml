open Result.Syntax

type context =
  { execution : Sol_cli_execution.context
  ; sha : string
  ; registry : string
  ; facts : Sol_cli_workspace_model.t
  ; emit_plan_to : string option
  ; target_cfg : Sol_cli_config.target
  ; resolved_config : Sol_cli_config.t
  ; services : Sol_cli_manifest.service list
  ; inventory : Sol_cli_manifest.service list
  ; image_refs : (string * string) list
  ; target_name : string
  ; run_log : Sol_cli_run_log.t
  ; keep_releases : int
  }

let http_services ~ctx (results : Sol_cli_executor.result list) =
  let deployed = results |> List.map (fun r -> r.Sol_cli_executor.name) in
  let cluster_ip_services ns =
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    match
      Sol_cli_kubectl.get_raw
        ~ctx
        ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
    with
    | Ok r ->
      String.split_on_char ' ' r.stdout |> List.filter_map Sol_cli_string.non_blank
    | Error _ -> []
  in
  let serves_port_80 ns name =
    match
      Sol_cli_kubectl.get
        ~ctx
        ~resource:"svc"
        ~name
        ~namespace:ns
        ~output:"jsonpath={.spec.ports[?(@.port==80)].port}"
    with
    | Ok r -> Option.is_some (Sol_cli_string.non_blank r.stdout)
    | Error _ -> false
  in
  results
  |> List.map (fun r -> r.Sol_cli_executor.namespace)
  |> List.sort_uniq String.compare
  |> List.concat_map (fun ns ->
    cluster_ip_services ns
    |> List.filter (fun name -> List.mem name deployed && serves_port_80 ns name))
;;

let verify_image_refs_exist ~image_refs =
  match
    image_refs
    |> List.find_opt (fun (_, ref) -> not (Sol_cli_docker.manifest_exists ~image_ref:ref))
  with
  | None -> Ok ()
  | Some (service, ref) ->
    Error
      (Printf.sprintf
         "--image-ref for service %s was not found in its registry: %s\n\
         \  (docker manifest inspect failed; check the repository, digest and registry \
          credentials)\n\
         \  Nothing was applied."
         service
         ref)
;;

let run_plan_result ctx ~phase ~mode ?before_apply plan =
  Sol_cli_run_log.run_task ctx.run_log ~name:phase (fun () ->
    Sol_cli_factory.execute ctx.execution ~mode ?before_apply plan)
;;

type gate_failure =
  | Refused of string
  | Failed of string

(* **#1403: migration verification does not depend on the profile.** A profile answers which
   guarantees a target claims, not what the deploy does, so a profile-less target must still
   refuse to roll workloads against an unapplied schema. What decides is whether the workspace
   carries migrations at all — and that is decided before any cluster call, so a target with
   none performs no migration-specific Kubernetes work of any kind. *)
let migration_prerequisite ctx ~(plan : Sol_cli_deployment_plan.t) ~live =
  let dir =
    Filename.concat ctx.facts.Sol_cli_workspace_model.root Sol_cli_migration.default_dir
  in
  (* Whether there is anything to verify is decided **before any migration-specific cluster
     operation**: a target that carries no migrations returns here, so it reconciles no
     operator RoleBindings and reads no migration status. Asking the cluster first and
     discovering "nothing to verify" afterwards would still be cluster work. *)
  match Sol_cli_migration.required_if_present ~dir with
  | Ok [] -> Ok ()
  | Error _ when not live -> Ok ()
  | _ ->
    (* Reaching here offline means the directory is inspectable and names migrations, so the
       only honest answer is that this run did not verify them. *)
    if not live
    then (
      Sol_cli_report.app
        "Migrations: NOT verified -- a side-effect-free run creates no status Job. The \
         applied migration set is only checked against the live cluster by a real deploy \
         (before any workload moves).";
      Ok ())
    else (
      (* The lifecycle owner establishes the plan's namespaces and scoped RBAC once,
         in [substrate_prerequisite], before this gate. Migration verification must not
         re-enter that establishment: a second call would be duplicate lifecycle work
         and would let the two steps drift apart. *)
      (* 2b: the migration Job is a DDL consumer, so it reads `<target>-ddl-creds` — the class
       Secret the setup step (or ESO, for an externally bound database) writes. The reader
       never learns the ownership; the only ownership-shaped decision here is whether the
       target publishes a CA ConfigMap, which only Sol's setup step does. *)
      (* The identity comes from the *resolved config*, not from `ctx.target_name`: what the
         operator typed and what the environment file resolves to can differ, and two sanitized
         target strings would put this target's database operations in two namespaces (#1424).
         The class Secret names come from the identity's target for the same reason. *)
      let database =
        Sol_cli_database_setup_run.identity
          ~workspace:ctx.execution.workspace
          ~config:ctx.resolved_config
          ~database:plan.database
      in
      let target = database.Sol_cli_database_setup_render.target in
      let namespace = Sol_cli_database_setup_render.database_namespace database in
      let provisions_database =
        Sol_cli_resource_binding.postgres_is_managed plan.database
      in
      let ca_configmap =
        if provisions_database
        then Some (Sol_cli_database_setup_render.ca_configmap_name target)
        else None
      in
      let ddl_creds_name = Sol_cli_database_setup_render.ddl_creds_name target in
      Sol_cli_migration_gate.reconcile_operator_bindings
        ~ctx:ctx.execution.cluster
        ~workspace:ctx.execution.workspace
        ~services:ctx.inventory;
      match
        Sol_cli_migration_gate.verify
          ~ctx:ctx.execution.cluster
          ~workspace:ctx.execution.workspace
          ~dir
          ~namespace
          ~ddl_creds_name
          ?ca_configmap
          ()
      with
      | Sol_cli_migration_gate.No_migrations -> Ok ()
      | Sol_cli_migration_gate.Satisfied applied ->
        Sol_cli_report.app
          "Migrations: OK -- %d declared migration(s) present in schema_migrations"
          (List.length applied);
        Ok ()
      | Sol_cli_migration_gate.Unsatisfied missing ->
        Error
          (Failed
             (Printf.sprintf
                "\n\
                 error: the required migration set is not applied. Missing: %s\n\
                \  Migrations are workspace-wide, so this is the same set for every \
                 deploy. Run `sol migrate apply %s`, then deploy again."
                (String.concat ", " (List.map Sol_cli_migration.to_string missing))
                ctx.target_name))
      | Sol_cli_migration_gate.Drifted drifted ->
        Error
          (Failed
             (Printf.sprintf
                "\n\
                 error: an already-applied migration no longer matches the file this \
                 revision carries, so the applied schema record and the deployable \
                 revision disagree:\n\
                 %s\n\
                \  Restore each file to the content that was applied, or put the change \
                 in a new migration and apply it with `sol migrate apply %s`. Deploying \
                 while they disagree would record a boundary whose schema is one of the \
                 two, not both."
                (String.concat
                   "\n"
                   (List.map
                      (fun d -> "  - " ^ Sol_cli_migration.drift_message d)
                      drifted))
                ctx.target_name))
      | Sol_cli_migration_gate.Unavailable reason ->
        Error
          (Failed
             (Printf.sprintf
                "\n\
                 error: cannot verify the required migration state: %s\n\
                \  A deploy fails closed here rather than assume the schema is \
                 compatible: any target that carries migrations is verified. Migrations \
                 are workspace-wide -- a deploy does not select them -- so `sol migrate \
                 apply %s` checks the same required set this deploy did (it reports the \
                 applied set). Run it, then deploy again."
                reason
                ctx.target_name)))
;;

let substrate_prerequisite ctx ~plan ~live =
  let namespaces = Sol_cli_substrate.namespaces plan in
  if namespaces = []
  then Ok ()
  else if live
  then
    (* Only the units that declared the database this target provisions get the allowance.
       The plan already carries that answer in [database]'s published-CA target — the same field the renderer
       uses to mount the setup step's CA ConfigMap — so this gate does not resolve the
       bindings again. A unit that consumes no database, or one bound externally, is not
       widened, and no fact is required on its behalf. *)
    Sol_cli_substrate.ensure
      ~ctx:ctx.execution.cluster
      ~namespaces
      ~workloads:(Sol_cli_substrate.managed_database_workloads plan)
    |> Result.map_error (fun message -> Refused message)
  else
    Sol_cli_substrate.established ~ctx:ctx.execution.cluster ~namespaces
    |> Result.map_error (fun message -> Refused message)
;;

let deploy_events ~workspace ~(target_cfg : Sol_cli_config.target) ?release_id plan =
  let release_id =
    Option.value release_id ~default:plan.Sol_cli_deployment_plan.release_id
  in
  plan.Sol_cli_deployment_plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    { Sol_cli_deploy_event.workspace
    ; env = target_cfg.env
    ; domain = spec.domain
    ; service = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name
    ; primitive =
        Sol_cli_manifest.primitive_label
          (match spec.primitive with
           | Sol_cli_deployment_plan.Svc -> Sol_cli_manifest.Svc
           | Worker -> Sol_cli_manifest.Worker
           | Fn -> Sol_cli_manifest.Fn)
    ; release_id
    })
;;

let confirm_consumer_groups ~ctx ~workspace ~confirm_group_change plan =
  Sol_cli_deployment_state.check_removed_groups
    ~ctx
    ~workspace
    ~confirm_group_change
    ~next:
      (List.map
         Sol_cli_plan_ids.Consumer_group.to_string
         plan.Sol_cli_deployment_plan.consumer_groups)
;;

let read_previous_release_in ~cluster ~workspace =
  match Sol_cli_release_store.current ~ctx:cluster ~workspace with
  | Ok (Some release_id) -> Sol_cli_release_retention.Known release_id
  | Ok None -> Sol_cli_release_retention.None_yet
  | Error msg -> Sol_cli_release_retention.Unreadable msg
;;

let observe_contract_in ~cluster ~workspace plan =
  let* observed = Sol_cli_release_store.deployed_contract ~ctx:cluster ~workspace in
  Sol_cli_deployment_plan.with_observed_contract ~observed plan
  |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
;;

let observe_contract ctx plan =
  observe_contract_in
    ~cluster:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    plan
;;

let record_release_and_prune ~cluster ~workspace ~keep ~previous ~retained ~owned plan =
  match
    Sol_cli_release_store.record_plan
      ~ctx:cluster
      ~apply_mode:Sol_cli_release.Direct
      ~retained
      ~owned
      plan
  with
  | Error msg ->
    Error
      (Printf.sprintf
         "the release was applied but could not be recorded: %s\n\
         \  The workloads for this release may already be running; the release state was \
          not advanced, so `sol rollback` and release retention still describe the \
          previous release.\n\
         \  Fix the cause and deploy again -- nothing on the cluster needs undoing."
         msg)
  | Ok boundary_id ->
    (match
       Sol_cli_release_retention.with_retention
         ~ctx:cluster
         ~workspace
         ~keep
         ~current:boundary_id
         ~previous
     with
     | Pruned [] -> ()
     | Pruned pruned ->
       Sol_cli_report.app
         "Pruned %d release record(s) beyond the last %d."
         (List.length pruned)
         keep
     | Deferred reason -> Sol_cli_report.app "Retention: not run -- %s" reason
     | Failed msg -> Sol_cli_report.warn "warning: could not prune old releases: %s" msg);
    Ok ()
;;

let record_applied_state ~cluster ~workspace ~sha plan =
  Sol_cli_deployment_state.record_outcome
    ~ctx:cluster
    workspace
    (Sol_cli_deployment_state.Applied
       { namespace = "default"
       ; name = workspace
       ; image = sha
       ; consumer_groups =
           List.map
             Sol_cli_plan_ids.Consumer_group.to_string
             plan.Sol_cli_deployment_plan.consumer_groups
       })
;;

(* Whole-target reconciliation removes a workload the target no longer declares, but only
   while positive ownership evidence authorizes it: the live object's UID must equal the
   UID the superseded release recorded at apply (docs/architecture/ownership.md). Nothing
   is inferred from a declaration, a label or a name, and there is no cluster-wide
   pruning. The workload is the unit of ownership, so the auxiliaries it realizes are
   removed with it and a referenced PersistentVolumeClaim is never deleted (DEC-033).
   Read after the desired workloads are applied and before the new release is recorded, so
   the evidence is still the superseded release's.

   Incompleteness is an error, not a warning. The new release record would not carry the
   UID evidence of a workload it no longer declares, so advancing the boundary past a
   surplus object Sol owns but could not remove would discard the only evidence a later
   deploy could use to remove it. An unreadable record, an unobservable live set, a failed
   delete, or a surplus object whose live state could not be read therefore fails the
   deploy and leaves the superseded release authoritative, so the next deploy retries with
   the same evidence. A surplus object that is provably not Sol's (no recorded UID, a
   different live UID, or absent) is retained and reported, not a reconciliation failure:
   there is no recorded object left to authorize. An absent current release is the first
   deploy: there is no boundary to preserve, so only what is observed is reported. *)
(* Remove the ExternalSecret of a unit that no longer declares any external key, or whose
   workload is gone. The workload is applied first (this runs after apply), so deleting the
   ES cannot strand a live workload that still references it. Unobservable evidence fails
   the deploy for the same reason as a surplus workload: the next release record would drop
   the only UID that could authorize a later removal. *)
let prune_orphaned_external_secrets ~cluster ~plan ~evidence applied_but =
  match
    Sol_cli_rollback.prune_external_secrets
      ~ctx:cluster
      ~evidence
      ~declared:(Sol_cli_rollback.declared_external_secrets plan)
  with
  | Error message ->
    Error
      (Printf.sprintf
         "%s: orphaned ExternalSecret removal failed: %s"
         applied_but
         message)
  | Ok report ->
    List.iter
      (fun (t : Sol_cli_rollback.prune_target) ->
         Sol_cli_report.app
           "Removed %s %s/%s: this target no longer declares it."
           t.resource
           t.namespace
           t.name)
      report.removed_external_secrets;
    List.iter
      (fun ((t : Sol_cli_rollback.prune_target), reason) ->
         Sol_cli_report.warn
           "Retained %s %s/%s (%s): Sol removes an external Secret only while its live \
            UID equals the UID recorded at apply. Adopt or remove it by hand."
           t.resource
           t.namespace
           t.name
           (Sol_cli_rollback.unowned_reason_to_string reason))
      report.unowned_external_secrets;
    let unresolved =
      List.filter
        (fun (_, reason) ->
           match reason with
           | Sol_cli_rollback.Live_unobservable _ -> true
           | No_recorded_uid | Live_uid_differs | Live_absent -> false)
        report.unowned_external_secrets
    in
    (match unresolved with
     | [] -> Ok ()
     | objects ->
       Error
         (Printf.sprintf
            "%s: %d orphaned ExternalSecret(s) could not be observed, so Sol cannot know \
             whether the ones it recorded are still live: %s"
            applied_but
            (List.length objects)
            (String.concat
               ", "
               (List.map
                  (fun ((t : Sol_cli_rollback.prune_target), _) ->
                     Printf.sprintf "%s %s/%s" t.resource t.namespace t.name)
                  objects))))
;;

let remove_surplus_workloads (ctx : context) plan : (unit, string) result =
  let workspace = ctx.execution.workspace in
  let cluster = ctx.execution.cluster in
  let applied_but =
    "the workloads this target declares were applied, but the target was not fully \
     reconciled, so the release boundary was left unchanged; deploy again to retry"
  in
  match Sol_cli_release_store.recorded_evidence ~ctx:cluster ~workspace with
  | Error reason ->
    Error
      (Printf.sprintf
         "%s: the ownership evidence for this workspace could not be read (%s). Run `sol \
          plan %s` to review the live workload delta."
         applied_but
         reason
         ctx.target_name)
  | Ok evidence ->
    (match
       Sol_cli_rollback.live_workloads
         ~ctx:cluster
         ~workspace
         ~namespaces:
           (List.sort_uniq
              String.compare
              (Sol_cli_rollback.namespaces_of_plan plan
               @ Sol_cli_rollback.namespaces_of_evidence evidence))
     with
     | Error reason ->
       Error
         (Printf.sprintf
            "%s: the live workloads for this workspace could not be observed (%s). Run \
             `sol plan %s` to review the live workload delta."
            applied_but
            reason
            ctx.target_name)
     | Ok live ->
       let surplus =
         Sol_cli_rollback.unexpected_workloads
           ~expected:plan.Sol_cli_deployment_plan.services
           ~live
       in
       (match Sol_cli_rollback.prune_workloads ~ctx:cluster ~evidence ~live ~surplus with
        | Error message ->
          Error
            (Printf.sprintf "%s: surplus workload removal failed: %s" applied_but message)
        | Ok report ->
          List.iter
            (fun (t : Sol_cli_rollback.prune_target) ->
               Sol_cli_report.app
                 "Removed %s %s/%s: this target no longer declares it."
                 t.resource
                 t.namespace
                 t.name)
            report.removed;
          List.iter
            (fun (t : Sol_cli_rollback.prune_target) ->
               Sol_cli_report.app
                 "Retained %s %s/%s: storage lifetime is not this deploy's decision \
                  (DEC-033)."
                 t.resource
                 t.namespace
                 t.name)
            report.retained;
          let unresolved, resolved =
            List.partition
              (fun (u : Sol_cli_rollback.unowned_workload) ->
                 match u.reason with
                 | Sol_cli_rollback.Live_unobservable _ -> true
                 | No_recorded_uid | Live_uid_differs | Live_absent -> false)
              report.unowned
          in
          List.iter
            (fun (u : Sol_cli_rollback.unowned_workload) ->
               Sol_cli_report.warn
                 "Retained %s %s/%s (%s): Sol removes a workload only while its live UID \
                  equals the UID recorded at apply. Adopt or remove it by hand."
                 (Sol_cli_rollback.kind_resource u.identity.kind)
                 u.identity.namespace
                 u.identity.name
                 (Sol_cli_rollback.unowned_reason_to_string u.reason))
            resolved;
          (match prune_orphaned_external_secrets ~cluster ~plan ~evidence applied_but with
           | Error message -> Error message
           | Ok () ->
             (match unresolved with
              | [] -> Ok ()
              | objects ->
                Error
                  (Printf.sprintf
                     "%s: %d surplus object(s) could not be observed, so Sol cannot know \
                      whether the ones it recorded are still live: %s"
                     applied_but
                     (List.length objects)
                     (String.concat
                        ", "
                        (List.map
                           (fun (u : Sol_cli_rollback.unowned_workload) ->
                              Printf.sprintf
                                "%s %s/%s"
                                (Sol_cli_rollback.kind_resource u.identity.kind)
                                u.identity.namespace
                                u.identity.name)
                           objects)))))))
;;

(* Name every declared workload whose live object Sol does not own (a different UID, or no
   recorded UID). Apply still reconciles it — Kubernetes is authoritative for workload
   reconciliation; ownership governs removal — and the release written below records the
   live UID through capture_owned, so the mismatch is transient, not a standing hazard.
   The warning is how a user learns the name was occupied by something Sol did not apply.
   Read before apply, against the release being superseded. *)
let warn_not_owned_declared
      ~cluster
      ~(evidence : Sol_cli_release_id.owned_object list)
      (plan : Sol_cli_deployment_plan.t)
  =
  plan.Sol_cli_deployment_plan.services
  |> List.iter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    let id =
      { Sol_cli_workload_ownership.resource =
          Sol_cli_deployment_plan.resource_of_spec spec
      ; namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
      ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
      }
    in
    match Sol_cli_workload_ownership.observe ~ctx:cluster id with
    | Sol_cli_workload_ownership.Live_present live_uid ->
      let recorded = Sol_cli_workload_ownership.recorded_uid evidence id in
      if not (Sol_cli_workload_ownership.owns ~recorded ~live_uid)
      then
        Sol_cli_report.warn
          "%s %s/%s is live but not Sol-owned (%s); apply reconciles it and the new \
           release records the live UID"
          id.resource
          id.namespace
          id.name
          (match recorded with
           | Some recorded_uid ->
             Printf.sprintf
               "its live UID %s differs from the recorded UID %s"
               live_uid
               recorded_uid
           | None -> "Sol recorded no UID for it")
    | Sol_cli_workload_ownership.Live_absent
    | Sol_cli_workload_ownership.Live_unobservable _ -> ())
;;

let contract_reconciliation ctx (plan : Sol_cli_deployment_plan.t) =
  let workspace = ctx.facts.Sol_cli_workspace_model.root in
  if not (Sol_cli_contract.has_projection ~workspace)
  then Ok ()
  else
    Sol_cli_contract.reconciliation_images plan.Sol_cli_deployment_plan.services
    |> Sol_cli_result.map_list (fun (namespace, image, secret_name, consumer) ->
      Sol_cli_contract.reconcile_in_destination
        ~ctx:ctx.execution.cluster
        ~kafka:plan.Sol_cli_deployment_plan.kafka
        ~secret_name
        ~consumer
        ~namespace
        ~image)
    |> Result.map (fun _ -> ())
;;

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

let gate_message = function
  | Refused message -> message
  | Failed report -> report
;;

let run_gate ~on_refused gate =
  match gate with
  | Ok () -> Ok ()
  | Error failure ->
    on_refused failure;
    Error (gate_message failure)
;;

(* The shared deploy mutation/recording owner. Local `sol local deploy` and cloud/direct
   `sol deploy` both run this under their boundary lease, so the authoritative
   prior-contract read, presentation, prerequisite gates, group guard, retained
   state, execution and durable recording have one ordered owner. The
   environment-specific operations are supplied: how a plan is presented, which
   prerequisites a target needs, how it reconciles before applying, how it applies,
   how it reports success, and whether it publishes deploy events. None of them
   decides when it runs. *)
let run_lifecycle
      ~cluster
      ~workspace
      ~sha
      ~run_log
      ~keep_releases
      ~confirm_group_change
      ~present_plan
      ~gates
      ~database_setup
      ~kafka_delivery
      ~post_setup_gates
      ~before_apply
      ~apply
      ~report_success
      ~push_events
      plan
  =
  Sol_cli_boundary_lease.with_boundary_lease
    ~ctx:cluster
    ~workspace
    ~holder:Sol_cli_boundary_lease.Deploy
    ~ttl:Sol_cli_boundary_lease.default_ttl_s
    ~wait_s:0.
    (fun lease ->
       let* () = Sol_cli_boundary_lease.ensure_held lease in
       let* plan = observe_contract_in ~cluster ~workspace plan in
       let* () = present_plan plan in
       let* () = gates plan in
       (* The database setup step runs after the prerequisite gates — including the
          substrate it needs — and before the workloads, whose migration Jobs consume the
          DDL role it creates. Under the lease, because it mutates the target. *)
       let* () = database_setup () in
       (* The Kafka projection is written after the platform prerequisites create the
          chart-owned CA and before any consumer workload reads it. It is not part of the
          database step: a target may have either, both, or neither. *)
       let* () = kafka_delivery () in
       (* The migration verification runs *after* the setup, and this is the whole point of
          the phase: it verifies a schema the DDL role owns, and the reader switch has it read
          `<target>-ddl-creds` — which is exactly what the setup creates. Verifying before
          the setup would refuse a first deploy for a Secret that is about to exist, and
          would leave the operator with a remedy (`sol migrate apply`) whose own credential
          the setup has not yet written.

          The authority check stays in [gates], *before* the setup: it is read-only, and
          mutating before establishing authority is worse than after. *)
       let* () = post_setup_gates plan in
       record_plan run_log plan;
       let* () =
         confirm_consumer_groups ~ctx:cluster ~workspace ~confirm_group_change plan
       in
       let previous = read_previous_release_in ~cluster ~workspace in
       let* retained = Sol_cli_release_store.retained_for_plan ~ctx:cluster ~workspace in
       (* Unreadable evidence means no recorded UID, so nothing is treated as owned here;
          the warning below may then name a workload Sol actually applied. It reports the
          mismatch rather than guessing. *)
       let ownership_evidence =
         match Sol_cli_release_store.recorded_evidence ~ctx:cluster ~workspace with
         | Ok evidence -> evidence
         | Error _ -> []
       in
       warn_not_owned_declared ~cluster ~evidence:ownership_evidence plan;
       let boundary =
         Sol_cli_release.of_plan_with_boundary
           ~apply_mode:Sol_cli_release.Direct
           ~retained
           plan
       in
       let* release_id = Sol_cli_release_id.of_string boundary.release_id in
       let* () = before_apply plan in
       let applied = apply ~lease ~release_id plan in
       let completed =
         Result.bind applied (fun results ->
           Sol_cli_release.finish_deployment
             ~record_release:(fun () ->
               let* () = Sol_cli_boundary_lease.ensure_held lease in
               let owned = Sol_cli_rollback.capture_owned ~ctx:cluster plan in
               let* () =
                 record_release_and_prune
                   ~cluster
                   ~workspace
                   ~keep:keep_releases
                   ~previous
                   ~retained
                   ~owned
                   plan
               in
               record_applied_state ~cluster ~workspace ~sha plan)
             ~report_success:(fun () -> report_success plan results))
       in
       (match completed with
        | Ok _ -> push_events ~release_id plan
        | Error _ -> ());
       completed)
;;

(* Cloud/direct deploy's mutation owner: establish the destination's substrate, then
   run the shared lifecycle with the cloud operations. *)
let apply
      ctx
      ~present_plan
      ~effective_access
      ~on_substrate_refused
      ~push_events
      ~report_success
      ~confirm_group_change
      ?resolve_setup_image
      ?database_setup
      ?kafka_delivery
      plan
  =
  (* **Resolve deterministic prerequisites before the gate that creates infrastructure.** A
     missing or unpinnable setup image used to surface only when the setup step ran, after the
     substrate gate had already created the database. [resolve_setup_image] is the caller's
     policy for *which* image a provisioned database needs; the ordering is this function's, so
     no caller can run the substrate gate first, and the resolved value is what the setup step
     receives rather than something it looks up again. *)
  let* setup_image =
    match resolve_setup_image with
    | None -> Ok None
    | Some resolve -> resolve ()
  in
  let* () =
    run_gate
      ~on_refused:on_substrate_refused
      (substrate_prerequisite ctx ~plan ~live:true)
  in
  let database_setup =
    Option.value database_setup ~default:(fun ~setup_image:_ () -> Ok ())
  in
  let kafka_delivery = Option.value kafka_delivery ~default:(fun () -> Ok ()) in
  run_lifecycle
    ~cluster:ctx.execution.cluster
    ~workspace:ctx.execution.workspace
    ~sha:ctx.sha
    ~run_log:ctx.run_log
    ~keep_releases:ctx.keep_releases
    ~confirm_group_change
    ~present_plan
    ~gates:(fun _plan -> effective_access ())
    ~database_setup:(fun () -> database_setup ~setup_image ())
    ~kafka_delivery
    ~post_setup_gates:(fun plan ->
      run_gate ~on_refused:(fun _ -> ()) (migration_prerequisite ctx ~plan ~live:true))
    ~before_apply:(fun plan -> contract_reconciliation ctx plan)
    ~apply:(fun ~lease ~release_id:_ plan ->
      let* results =
        run_plan_result
          ctx
          ~phase:"apply"
          ~mode:Sol_cli_executor.Apply
          ~before_apply:(fun _ -> Sol_cli_boundary_lease.ensure_held lease)
          plan
      in
      (* Only once every declared workload is applied: remove the workloads this target
         no longer declares, while the live UID still matches the recorded evidence. A
         removal Sol cannot complete fails the deploy before the new release is recorded,
         so the superseded release stays authoritative and the next deploy can retry with
         the same evidence. *)
      let* () = Sol_cli_boundary_lease.ensure_held lease in
      let* () = remove_surplus_workloads ctx plan in
      Ok results)
    ~report_success
    ~push_events:(fun ~release_id plan ->
      push_events
        (deploy_events
           ~workspace:ctx.execution.workspace
           ~target_cfg:ctx.target_cfg
           ~release_id
           plan))
    plan
;;

(* The side-effect-free owner: prior-contract observation, presentation, the
   prerequisite gates, plan recording and execution in the requested mode. [Dry_run]
   validates the destination's substrate; [Emit_to] only writes artifacts and does not
   require the destination's substrate, so it deliberately skips that gate. *)
let run_offline ctx ~phase ~mode ~present_plan ~on_substrate_refused plan =
  let* plan = observe_contract ctx plan in
  let* () = present_plan plan in
  let* () =
    match mode with
    | Sol_cli_executor.Dry_run ->
      run_gate
        ~on_refused:on_substrate_refused
        (substrate_prerequisite ctx ~plan ~live:false)
    | Sol_cli_executor.Emit_to _ -> Ok ()
    | Sol_cli_executor.Apply ->
      Error "the offline lifecycle cannot apply; use the live apply owner"
  in
  let* () =
    run_gate ~on_refused:(fun _ -> ()) (migration_prerequisite ctx ~plan ~live:false)
  in
  record_plan ctx.run_log plan;
  run_plan_result ctx ~phase ~mode plan
;;
