open Cmdliner

let workspace_name = Sol_cli_workspace.current_name
let migrations_dir = "db/migrations"

open Result.Syntax

let ttl_s = Sol_cli_boundary_lease.default_ttl_s
let wait_s = Sol_cli_boundary_lease.rollback_wait_s

let apply_specs ~ensure_held ~ctx ~local ~release specs =
  let apply_spec (spec, identity) =
    let* () = ensure_held () in
    let* release_id_t =
      Sol_cli_release_id.of_string identity
      |> Result.map_error (fun message ->
        Printf.sprintf
          "release %s records an unreadable workload identity: %s"
          release.Sol_cli_release.release_id
          message)
    in
    let spec = if local then Sol_cli_executor.local_development_spec spec else spec in
    let* bundle =
      Sol_cli_deployment_render.render_spec
        ~workspace:release.Sol_cli_release.workspace
        ?env:release.environment
        ~release_id:release_id_t
        spec
    in
    let* () = Sol_cli_executor.apply_workload_phased ~ctx ~spec ~bundle () in
    (* The boundary lease TTL is 300s; heartbeat before the bounded rollout wait. *)
    let* () = ensure_held () in
    let* () = Sol_cli_executor.wait_for_workload_ready ~ctx ~spec in
    Printf.printf
      "  applied %s/%s\n%!"
      (Sol_cli_deployment_plan.namespace_to_string spec.namespace)
      (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name);
    Ok ()
  in
  specs |> Sol_cli_result.map_list apply_spec |> Result.map ignore
;;

(* The ExternalSecrets the release Sol is rolling back to declares: one per recorded
   workload that carries external remote refs. An ExternalSecret recorded by the release it
   is rolling back from but not declared here is an orphan to prune. Named [_of_release] to
   distinguish it from [Sol_cli_rollback.declared_external_secrets], which reads a plan. *)
let declared_external_secrets_of_release (release : Sol_cli_release.t) =
  release.workloads
  |> List.filter_map (fun (w : Sol_cli_release_id.recorded_workload) ->
    if w.spec.external_secret_refs = []
    then None
    else (
      match
        Sol_cli_deployment_plan.namespace_name
          ~workspace:release.workspace
          ~domain:w.spec.domain
      with
      | Error _ -> None
      | Ok namespace ->
        Some
          { Sol_cli_workload_ownership.resource = "externalsecret"
          ; namespace
          ; name = Sol_cli_manifest.external_secret_name w.spec.name
          }))
;;

let run_locked ~lease ~ctx ~local ?config ~workspace ~facts release_id
  : (unit, string) result
  =
  let* release = Sol_cli_release_store.get ~ctx ~workspace ~release_id in
  Printf.printf "Rolling back %s to release %s\n%!" workspace release.release_id;
  let current_migrations =
    Sol_cli_workspace_model.migration_files facts
    |> List.map Sol_cli_plan_ids.Migration_file.to_string
  in
  (* What the release Sol is rolling back from recorded at apply. A surplus workload may
     be removed only while its live UID matches this evidence; unreadable evidence
     retains, it does not guess (docs/architecture/ownership.md). *)
  let evidence =
    match Sol_cli_release_store.recorded_evidence ~ctx ~workspace with
    | Ok evidence -> evidence
    | Error message ->
      Sol_cli_report.warn
        "could not read the recorded UID evidence for this workspace (%s); any surplus \
         workload will be retained rather than removed"
        message;
      []
  in
  (* 2b: the migration boundary read is a DDL consumer, so against a target it reads the
     target's `<target>-ddl-creds` class Secret and mounts `<target>-db-ca` when Sol
     provisions that database. A local rollback has no target binding and keeps the
     workspace runtime Secret path. *)
  let ddl_creds_name, ca_configmap =
    match config with
    | None -> Sol_cli_manifest.runtime_secret_name, None
    | Some config ->
      let target =
        Sol_cli_kubernetes_name.sanitize_name config.Sol_cli_config.target.name
      in
      let provisions =
        match Sol_cli_resource_binding.resolve config with
        | Ok bindings -> Sol_cli_resource_binding.provisions bindings ~typ:"postgres"
        | Error _ -> false
      in
      ( Sol_cli_database_setup_render.ddl_creds_name target
      , if provisions
        then Some (Sol_cli_database_setup_render.ca_configmap_name target)
        else None )
  in
  let deps : Sol_cli_rollback.transaction_deps =
    { config
    ; ensure_held = (fun () -> Sol_cli_boundary_lease.ensure_held lease)
    ; applied_migrations =
        (fun () ->
          Sol_cli_migration_gate.read_applied
            ~ctx
            ~workspace
            ~dir:migrations_dir
            ~table:(Sol_cli_migration.table_name ~workspace)
            ~services:(Sol_cli_workspace_model.services facts)
            ~ddl_creds_name
            ?ca_configmap
            ())
    ; apply =
        apply_specs
          ~ensure_held:(fun () -> Sol_cli_boundary_lease.ensure_held lease)
          ~ctx
          ~local
          ~release
    ; live_workloads =
        (fun () -> Sol_cli_rollback.live_workloads ~ctx ~workspace:release.workspace)
    ; prune =
        (fun ~live ~surplus ->
          let* report = Sol_cli_rollback.prune_workloads ~ctx ~evidence ~live ~surplus in
          let* external_secrets =
            Sol_cli_rollback.prune_external_secrets
              ~ctx
              ~evidence
              ~declared:(declared_external_secrets_of_release release)
          in
          List.iter
            (fun (t : Sol_cli_rollback.prune_target) ->
               Sol_cli_report.app
                 "Removed %s %s/%s: this release no longer declares it."
                 t.resource
                 t.namespace
                 t.name)
            external_secrets.removed_external_secrets;
          List.iter
            (fun ((t : Sol_cli_rollback.prune_target), reason) ->
               Sol_cli_report.warn
                 "Retained %s %s/%s (%s): Sol removes an external Secret only while its \
                  live UID equals the UID recorded at apply. Adopt or remove it by hand."
                 t.resource
                 t.namespace
                 t.name
                 (Sol_cli_rollback.unowned_reason_to_string reason))
            external_secrets.unowned_external_secrets;
          Ok report)
    ; move_pointer = (fun () -> Sol_cli_release_store.move_pointer ~ctx release)
    ; verify_pointer = (fun () -> Sol_cli_rollback.verify_pointer ~ctx ~release)
    ; record_consumer_groups =
        (fun groups ->
          Sol_cli_deployment_state.record_consumer_groups ~ctx ~workspace groups)
    }
  in
  let* () = Sol_cli_rollback.execute ~release ~migrations_dir ~current_migrations ~deps in
  Printf.printf
    "Verified: workloads and pointer both name release %s.\n%!"
    release.release_id;
  Ok ()
;;

let run ~ctx ?(local = false) ?config release_id =
  let workspace = workspace_name () in
  Sol_cli_exit.of_msg
    (let* facts = Sol_cli_workspace_model.load_cwd () in
     Sol_cli_boundary_lease.with_boundary_lease
       ~ctx
       ~workspace
       ~holder:Sol_cli_boundary_lease.Rollback
       ~ttl:ttl_s
       ~wait_s
       (fun lease -> run_locked ~lease ~ctx ~local ?config ~workspace ~facts release_id))
;;

let release_id_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
    & info
        []
        ~docv:"RELEASE_ID"
        ~doc:"The release id to restore, e.g. r-1a2b3c4d5e6f7890.")
;;

let cmd =
  Cmd.v
    (Cmd.info
       "rollback"
       ~doc:
         "Restore a recorded release boundary. Refuses on a contracting migration since \
          that release, reconstructs and re-applies its workloads, moves the \
          current-release pointer, then verifies both independently.")
    Term.(
      const (fun release_id target ->
        let result =
          let* ctx = Cmd_destination.remote ~command:"rollback" target in
          (* 2b: the rollback's database delivery is derived from the target's **current**
             bindings, so load them here rather than reading ownership from the release. *)
          let* config =
            match target with
            | None ->
              Error (Sol_cli_exit.error "rollback requires a target to resolve bindings")
            | Some path ->
              Sol_cli_config.load_for_target ~target:path
              |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
          in
          run ~ctx ~config release_id
        in
        Sol_cli_exit.exit_on result)
      $ release_id_arg
      $ Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a recorded release boundary on the local cluster.")
    Term.(
      const (fun release_id ->
        Sol_cli_exit.exit_on (run ~ctx:Cmd_destination.local ~local:true release_id))
      $ release_id_arg)
;;
