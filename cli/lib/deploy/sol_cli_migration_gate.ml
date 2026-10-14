open Result.Syntax

let configmap_byte_limit = 1024 * 1024

let refuse_oversized_configmap files =
  let total =
    List.fold_left (fun bytes (_, content) -> bytes + String.length content) 0 files
  in
  if total > configmap_byte_limit
  then
    Error
      (Printf.sprintf
         "the migration files total %d bytes, which exceeds the %d-byte (1 MiB) \
          ConfigMap that carries them into the migration Job; split them across \
          releases, or keep an oversized migration out of db/migrations"
         total
         configmap_byte_limit)
  else Ok files
;;

let migration_files dir =
  let ext = ".sql" in
  match Sys.readdir dir with
  | exception Sys_error msg -> Error ("cannot read migrations dir: " ^ msg)
  | arr ->
    let read fname =
      let content =
        In_channel.with_open_text (Filename.concat dir fname) In_channel.input_all
      in
      if String.contains content '\000'
      then
        Error
          (Printf.sprintf
             "migration %s contains a NUL character, which a ConfigMap cannot carry"
             fname)
      else Ok (fname, content)
    in
    let* files =
      Array.to_list arr
      |> List.filter (fun f -> Filename.check_suffix f ext)
      |> List.sort String.compare
      |> List.fold_left
           (fun acc fname ->
              let* files = acc in
              let* file = read fname in
              Ok (file :: files))
           (Ok [])
    in
    refuse_oversized_configmap (List.rev files)
;;

let reconcile_operator_bindings ~ctx ~workspace ~services =
  Sol_cli_substrate.reconcile_operator_bindings ~ctx ~workspace ~services
  |> Result.iter_error (fun msg ->
    Sol_cli_report.warn
      "warning: could not establish the operator's diagnostic RoleBindings: %s\n\
       The operator identity will not be able to read this workspace's workloads."
      msg)
;;

type verification =
  | No_migrations
  | Satisfied of int list
  | Unsatisfied of Sol_cli_migration.prerequisite list
  | Drifted of Sol_cli_migration.drift list
  | Unavailable of string

let read_status ~ctx ~dir ~table ~database ~ddl_creds_name ?ca_configmap () =
  (* The migration namespace comes from the database identity -- the target and its resource --
     never from a service list (#1424). *)
  let namespace = Sol_cli_database_setup_render.database_namespace database in
  let* () =
    Sol_cli_substrate.ensure
      ~ctx
      ~namespaces:[ namespace ]
      ~workloads:[]
      ~manages_database:false
  in
  let* image = Sol_cli_migration_job.runner_image () in
  let* files = migration_files dir in
  let* job =
    Sol_cli_migration_job.submit
      ~ctx
      ~namespace
      ~name_prefix:"sol-migrate-status"
      ~label:"status "
      ~image
      ~args:[ "migrate"; "status"; "--json"; "--dir"; "/migrations"; "--table"; table ]
      ~files
      ~ddl_creds_name
      ?ca_configmap
      ()
  in
  let result =
    match Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:60 job with
    | Unstartable { reason; detail } ->
      Error
        (Printf.sprintf
           "migration-status Job cannot start: %s%s"
           reason
           (Option.fold detail ~none:"" ~some:(Printf.sprintf " (%s)")))
    | Timed_out s ->
      Error (Printf.sprintf "migration-status Job did not complete within %.0fs" s)
    | Failed -> Error "migration-status Job failed -- see the Job logs"
    | Succeeded ->
      (match Sol_cli_migration_job.logs ~ctx job with
       | Error e -> Error ("could not read migration-status Job logs: " ^ e)
       | Ok logs ->
         let text = String.trim logs in
         let text =
           match String.index_opt text '{', String.rindex_opt text '}' with
           | Some i, Some j when j > i -> String.sub text i (j - i + 1)
           | _ -> text
         in
         Sol_cli_migration.parse_status_json text)
  in
  (match result with
   | Ok _ -> Sol_cli_migration_job.cleanup ~ctx job
   | Error _ ->
     Sol_cli_migration_job.evidence ~ctx job
     |> Option.iter (Sol_cli_report.err "\nmigration-status Job evidence:\n%s");
     let cleanup_hint =
       match job.configmap_name with
       | Some configmap ->
         Printf.sprintf
           "kubectl delete job/%s configmap/%s -n %s"
           job.job_name
           configmap
           namespace
       | None -> Printf.sprintf "kubectl delete job/%s -n %s" job.job_name namespace
     in
     Sol_cli_report.err
       "\nThe failing Job is kept for inspection:\n  kubectl logs job/%s -n %s\n  %s"
       job.job_name
       namespace
       cleanup_hint);
  result
;;

let read_applied ~ctx ~dir ~table ~database ~ddl_creds_name ?ca_configmap () =
  read_status ~ctx ~dir ~table ~database ~ddl_creds_name ?ca_configmap ()
  |> Result.map (fun (status : Sol_cli_migration.applied_status) -> status.applied)
;;

let verify ~ctx ~workspace ~dir ~database ~ddl_creds_name ?ca_configmap () =
  match Sol_cli_migration.required_if_present ~dir with
  | Error e -> Unavailable e
  | Ok [] -> No_migrations
  | Ok required ->
    let table = Sol_cli_migration.table_name ~workspace in
    (match read_status ~ctx ~dir ~table ~database ~ddl_creds_name ?ca_configmap () with
     | Error e -> Unavailable e
     | Ok status ->
       (match status.drifted with
        | _ :: _ as drifted -> Drifted drifted
        | [] ->
          (match Sol_cli_migration.unsatisfied ~required ~applied:status.applied with
           | [] -> Satisfied status.applied
           | missing -> Unsatisfied missing)))
;;
