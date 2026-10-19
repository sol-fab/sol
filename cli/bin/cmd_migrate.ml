open Cmdliner
open Result.Syntax

let cluster_pg_exists ~ctx () =
  Result.is_ok
    (Sol_cli_kubectl.get
       ~ctx
       ~resource:"svc"
       ~name:Sol_cli_local_platform.postgres_service
       ~namespace:Sol_cli_local_platform.postgres_namespace
       ~output:"name")
;;

let get_postgres_url ~ctx () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | Some u -> Ok u
  | None ->
    if cluster_pg_exists ~ctx ()
    then Sol_cli_local_platform.postgres_cluster_url ~ctx ()
    else
      Error
        "POSTGRES_URL not set and no cluster postgres found.\n\
        \  Run 'sol local deploy' to establish the local cluster, then retry."
;;

let pg_error_to_string ~url error =
  Sol_cli_redaction.connection_error ~url (Pg_error.to_string error)
;;

let with_pool url f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error e -> Error ("cannot connect to database: " ^ pg_error_to_string ~url e)
      | Ok pool -> f ~fs:env#fs pool))
;;

let print_pending_sql ~url ~fs pool ~table dir =
  let* pending =
    Migration.pending ~table ~fs pool ~dir |> Result.map_error (pg_error_to_string ~url)
  in
  (match pending with
   | [] -> Printf.printf "(no pending migrations in %s)\n" dir
   | pending ->
     pending
     |> List.iter (fun (_, _, path) ->
       let content = In_channel.with_open_text path In_channel.input_all in
       Printf.printf "-- %s\n%s\n\n" (Filename.basename path) content));
  Ok ()
;;

let run_apply_local ~ctx dir table =
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    Printf.printf "Applying migrations from %s...\n%!" dir;
    let* () =
      Migration.apply ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url)
    in
    Printf.printf "Done.\n";
    Ok ())
;;

let report_job_logs ~ctx (job : Sol_cli_migration_job.job) =
  Printf.printf "\n--- migration Job logs (%s) ---\n%!" job.job_name;
  (match Sol_cli_migration_job.logs ~ctx job with
   | Ok logs ->
     let redacted_logs =
       match Sol_cli_string.env "POSTGRES_URL" with
       | Some url -> Sol_cli_redaction.connection_error ~url logs
       | None -> logs
     in
     print_string redacted_logs
   | Error e -> Printf.eprintf "warning: could not fetch job logs: %s\n" e);
  Printf.printf "--- end logs ---\n\n%!"
;;

let report_job_outcome (outcome : Sol_cli_migration_job.outcome) =
  match outcome with
  | Timed_out s -> Printf.eprintf "error: migration Job did not complete within %.0fs\n" s
  | Unstartable { reason; detail } ->
    Printf.eprintf
      "error: migration Job cannot start: %s%s\n"
      reason
      (Option.fold detail ~none:"" ~some:(Printf.sprintf " (%s)"))
  | Succeeded | Failed -> ()
;;

let finish_job (outcome : Sol_cli_migration_job.outcome) =
  match outcome with
  | Succeeded ->
    Printf.printf "Done.\n";
    Ok ()
  | Failed | Unstartable _ | Timed_out _ ->
    Error "migration Job failed -- see logs above."
;;

let run_migration_job ~ctx ~namespace (job : Sol_cli_migration_job.job) =
  let* () =
    Sol_cli_migration_job.with_cleanup ~ctx job (fun () ->
      Printf.printf
        "Submitting migration Job %s in namespace %s...\n%!"
        job.job_name
        namespace;
      let outcome = Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:150 job in
      report_job_logs ~ctx job;
      report_job_outcome outcome;
      match outcome with
      | Succeeded -> Ok ()
      | Failed | Unstartable _ | Timed_out _ ->
        Error "migration Job failed -- see logs above.")
  in
  (* Do not print Done before cleanup has succeeded. *)
  finish_job Succeeded
;;

type target_migration =
  { workspace : string
  ; services : Sol_cli_manifest.service list
  ; database : Sol_cli_database_setup_render.database_identity
  ; selection : Sol_cli_resource_binding.postgres
  ; ddl_creds_name : string
  ; ca_configmap : string option
  ; target : string
  }

(* 2b: what the in-cluster migration paths need, computed once — the target's services and
   the class Secret the Job reads. The reader never branches on ownership; only the CA mount
   does, because an externally bound database publishes no Sol CA ConfigMap. *)
let in_cluster_context ~target_path =
  let workspace = Sol_cli_workspace.current_name () in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let* config =
    Sol_cli_config.load_for_target ~target:target_path
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let active =
    List.map (fun (s : Sol_cli_config.service) -> s.name) (Sol_cli_config.services config)
  in
  let services =
    Sol_cli_migration_job.services_of_target
      ~all:(Sol_cli_workspace_model.services facts)
      ~active
  in
  (* The database identity, resolved once here so the dry run, the apply and the migration Job
     all use the same namespace and the same target string (#1424). *)
  let* selection = Sol_cli_resource_binding.resolve_postgres config in
  let* () =
    match selection with
    | Sol_cli_resource_binding.No_postgres ->
      Error
        (Printf.sprintf
           "target %s declares no PostgreSQL resource; migrations require an explicit \
            database binding"
           config.target.name)
    | _ -> Ok ()
  in
  let database =
    Sol_cli_database_setup_run.identity ~workspace ~config ~database:selection
  in
  let target = database.Sol_cli_database_setup_render.target in
  let provisions_database = Sol_cli_resource_binding.postgres_is_managed selection in
  let ca_configmap =
    if provisions_database
    then Some (Sol_cli_database_setup_render.ca_configmap_name target)
    else None
  in
  Ok
    { workspace
    ; services
    ; database
    ; selection
    ; ddl_creds_name = Sol_cli_database_setup_render.ddl_creds_name target
    ; ca_configmap
    ; target = config.target.name
    }
;;

(* Explicit migrations resolve the current authority too. Only their DDL class
   is delivered; application credentials remain a deploy/rollback responsibility. *)
let prepare_migration_credentials ~ctx context =
  match context.selection with
  | Sol_cli_resource_binding.External_postgres binding ->
    let migration_namespace =
      Sol_cli_database_setup_render.database_namespace context.database
    in
    let* () =
      Sol_cli_substrate.ensure ~ctx ~namespaces:[ migration_namespace ] ~workloads:[]
    in
    let delivery =
      Sol_cli_database_setup_run.resource_delivery
        ~target:context.database.target
        ~resource:context.database.resource
        ~migration_namespace
        ~dml_namespaces:[]
        binding
    in
    Sol_cli_database_setup_run.run_external_credentials ~ctx delivery
  | _ -> Ok ()
;;

let print_pending_files ~dir applied files =
  match Sol_cli_migration.pending_files ~applied files with
  | [] -> Printf.printf "(no pending migrations in %s)\n" dir
  | pending ->
    List.iter
      (fun (fname, content) -> Printf.printf "-- %s\n%s\n\n" fname content)
      pending
;;

(* A dry run against a target reads the applied set with the same read-only in-cluster
   status Job the deploy gate uses, then prints the local files that Job reports pending. It
   never connects from the operator's machine, so it needs no credential in the operator's
   environment — the Job reads the target's DDL class Secret. *)
let run_dry_run_in_cluster ~ctx ~dir ~table ~target_path =
  let* context = in_cluster_context ~target_path in
  let { database; ddl_creds_name; ca_configmap; _ } = context in
  let* () = prepare_migration_credentials ~ctx context in
  let namespace = Sol_cli_database_setup_render.database_namespace database in
  let* applied =
    Sol_cli_migration_gate.read_applied
      ~ctx
      ~dir
      ~table
      ~namespace
      ~ddl_creds_name
      ?ca_configmap
      ()
  in
  let* files = Sol_cli_migration_gate.migration_files dir in
  print_pending_files ~dir applied files;
  Ok ()
;;

let run_apply_in_cluster ~ctx ~dir ~table ~target_path =
  let* context = in_cluster_context ~target_path in
  let { workspace; services; database; ddl_creds_name; ca_configmap; target; _ } =
    context
  in
  let namespace = Sol_cli_database_setup_render.database_namespace database in
  let* files = Sol_cli_migration_gate.migration_files dir in
  if files = []
  then (
    Printf.printf "(no migration files found in %s -- nothing to do)\n" dir;
    (* Report the skipped execution when (and only when) a launcher asked. The
       qualification policy decides whether a skipped execution can satisfy it;
       this command just tells the truth instead of leaving the observer to time
       out or infer a Job from a name. *)
    (match
       Sol_cli_migration_execution.notify_when_requested
         (No_execution "no migration files found")
     with
     | Ok () -> ()
     | Error message ->
       Sol_cli_report.warn
         "Migration execution capture is unestablished (%s); continuing normal behavior."
         message);
    Ok ())
  else
    let* () = prepare_migration_credentials ~ctx context in
    let* () = Sol_cli_substrate.ensure ~ctx ~namespaces:[ namespace ] ~workloads:[] in
    Sol_cli_migration_gate.reconcile_operator_bindings ~ctx ~workspace ~services;
    let* image = Sol_cli_migration_job.runner_image () in
    let* job =
      Sol_cli_migration_job.submit
        ~ctx
        ~namespace
        ~name_prefix:"sol-migrate"
        ~execution_target:target
        ~label:""
        ~image
        ~args:[ "migrate"; "apply"; "--dir"; "/migrations"; "--table"; table ]
        ~files
        ~ddl_creds_name
        ?ca_configmap
        ()
    in
    run_migration_job ~ctx ~namespace job
;;

let require_valid_migrations dir = Sol_cli_migration.required ~dir |> Result.map ignore

let status_rows (rows : Migration.status list) : Sol_cli_migration.status_row list =
  List.map
    (fun (s : Migration.status) ->
       { Sol_cli_migration.version = s.version
       ; name = s.name
       ; applied = s.applied_at <> None
       ; applied_at = s.applied_at
       ; recorded_checksum = s.checksum
       ; content_checksum = Some s.content_checksum
       })
    rows
;;

let read_local_status ~url dir table =
  with_pool url (fun ~fs pool ->
    Migration.status ~table pool ~dir ~fs |> Result.map_error (pg_error_to_string ~url))
;;

let run_status ~ctx ?(json = false) dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  let* statuses = read_local_status ~url dir table in
  let rows = status_rows statuses in
  let drifted = List.filter_map Sol_cli_migration.drift_of_row rows in
  if json
  then (
    print_endline (Sol_cli_migration.status_json ~table rows);
    Ok ())
  else (
    Printf.printf "%-6s  %-30s  %-8s  %s\n" "VER" "NAME" "DRIFT" "APPLIED AT";
    Printf.printf "%s\n" (String.make 72 '-');
    rows
    |> List.iter (fun (row : Sol_cli_migration.status_row) ->
      Printf.printf
        "%-6d  %-30s  %-8s  %s\n"
        row.version
        row.name
        (if Option.is_some (Sol_cli_migration.drift_of_row row) then "yes" else "-")
        (Option.value ~default:"(pending)" row.applied_at));
    if drifted = []
    then Ok ()
    else (
      Sol_cli_report.err
        "\nerror: %d applied migration(s) no longer match the file in this revision:"
        (List.length drifted);
      List.iter
        (fun d -> Sol_cli_report.err "  - %s" (Sol_cli_migration.drift_message d))
        drifted;
      Sol_cli_report.err
        "Restore each file to the content that was applied, or put the change in a new \
         migration and apply it. A deploy of this revision fails until they agree.";
      Error "an applied migration was edited after it was applied"))
;;

let run_rollback ~ctx dir table () =
  let* () = require_valid_migrations dir in
  let* url = get_postgres_url ~ctx () in
  with_pool url (fun ~fs pool ->
    let* () =
      Migration.rollback ~table pool ~dir ~fs
      |> Result.map_error (pg_error_to_string ~url)
    in
    Printf.printf "Rolled back.\n";
    Ok ())
;;

let run_apply ~ctx dir table dry_run target =
  let* () = require_valid_migrations dir in
  if dry_run
  then (
    match target with
    | None ->
      let* url = get_postgres_url ~ctx () in
      with_pool url (fun ~fs pool -> print_pending_sql ~url ~fs pool ~table dir)
    | Some path ->
      (* 2b: no operator-held POSTGRES_URL. A target's pending set is read by an in-cluster
         read-only status Job and compared with the local files. *)
      run_dry_run_in_cluster ~ctx ~dir ~table ~target_path:path)
  else (
    match target with
    | None -> run_apply_local ~ctx dir table
    | Some path -> run_apply_in_cluster ~ctx ~dir ~table ~target_path:path)
;;

let run_apply_term dir table dry_run target =
  Sol_cli_exit.exit_on
    (let* ctx =
       match target with
       | Some _ -> Cmd_destination.remote ~command:"migrate" target
       | None -> Ok Cmd_destination.local
     in
     run_apply ~ctx dir table dry_run target |> Sol_cli_exit.of_msg)
;;

let run_status_term dir table json =
  run_status ~ctx:Cmd_destination.local ~json dir table ()
  |> Sol_cli_exit.of_msg
  |> Sol_cli_exit.exit_on
;;

let run_rollback_term dir table =
  run_rollback ~ctx:Cmd_destination.local dir table ()
  |> Sol_cli_exit.of_msg
  |> Sol_cli_exit.exit_on
;;

let run_local_apply_term dir table dry_run =
  run_apply ~ctx:Cmd_destination.local dir table dry_run None
  |> Sol_cli_exit.of_msg
  |> Sol_cli_exit.exit_on
;;

let dir_arg =
  let explicit =
    Arg.(
      value
      & opt (some Sol_cli_args.text) None
      & info
          [ "dir" ]
          ~docv:"DIR"
          ~doc:
            "Directory containing migration SQL files (default: db/migrations at the \
             workspace root)")
  in
  Term.(
    const (fun dir ->
      Option.value dir ~default:(Sol_cli_workspace.migrations_dir ~dir:(Sys.getcwd ())))
    $ explicit)
;;

let table_override_conv =
  let parse table =
    match Sol_cli_migration.table_length_error ~table with
    | Some message -> Error message
    | None ->
      (match Cmdliner.Arg.conv_parser Sol_cli_args.text table with
       | Error (`Msg message) -> Error message
       | Ok table -> Ok table)
  in
  Cmdliner.Arg.conv' ~docv:"TABLE" (parse, Format.pp_print_string)
;;

let table_arg =
  let explicit =
    Arg.(
      value
      & opt (some table_override_conv) None
      & info
          [ "table" ]
          ~docv:"TABLE"
          ~doc:
            "Migration tracking table name (default: sol_<workspace>_schema_migrations, \
             which stays within PostgreSQL's 63-byte identifier limit; longer workspace \
             names get a truncated name plus a stable hash. Override with this flag to \
             share a table across workspaces)")
  in
  Term.(
    const (fun table ->
      Option.value
        table
        ~default:(Sol_cli_workspace.migrations_table ~dir:(Sys.getcwd ())))
    $ explicit)
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info
        [ "dry-run" ]
        ~doc:
          "Print pending migration SQL to stdout without applying. With a target, the \
           applied set is read by a read-only in-cluster status Job (the same one the \
           deploy gate uses) and compared with the local files; with no target, the \
           local dev cluster is read directly.")
;;

let target_arg =
  Sol_cli_target_arg.optional_positional
    ~doc:
      "Deployment target path: <env>/<provider>/<region>. When given, migrations run \
       from a one-shot Kubernetes Job inside the target's cluster instead of connecting \
       directly from this machine — required for any real deployment whose database \
       (e.g. RDS) isn't reachable from outside its network by design (FRIC-012). The Job \
       reads `<target>-ddl-creds`. A managed database requires a prior deploy to \
       establish its DDL credential and CA; an external binding synchronizes its current \
       DDL source before the Job runs. Omit for the local dev cluster, which remains \
       directly reachable via kubectl port-forward."
;;

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(const run_apply_term $ dir_arg $ table_arg $ dry_run_flag $ target_arg)
;;

let json_flag =
  Arg.(
    value
    & flag
    & info
        [ "json" ]
        ~doc:
          "Emit the status as JSON (the machine-readable form the deploy path's \
           read-only prerequisite check consumes)")
;;

let status_cmd =
  Cmd.v
    (Cmd.info
       "status"
       ~doc:
         "Show per-file applied/pending status, and drift in an applied migration whose \
          file changed")
    Term.(const run_status_term $ dir_arg $ table_arg $ json_flag)
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(const run_rollback_term $ dir_arg $ table_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info
       "migrate"
       ~doc:
         "Run database migrations. A target's Job reads the deploy-delivered \
          `<target>-ddl-creds`; the local dev cluster is reached by port-forward.")
    ~default:Term.(const run_apply_term $ dir_arg $ table_arg $ dry_run_flag $ target_arg)
    [ apply_cmd; status_cmd; rollback_cmd ]
;;

let local_cmd =
  Cmd.v
    (Cmd.info "migrate" ~doc:"Apply migrations against the local cluster's Postgres")
    Term.(const run_local_apply_term $ dir_arg $ table_arg $ dry_run_flag)
;;
