open Result.Syntax

let projection_dir ~workspace = Filename.concat workspace "contract"
let entry_point ~workspace = Filename.concat (projection_dir ~workspace) "run"
let has_projection ~workspace = Sys.file_exists (entry_point ~workspace)

type mode =
  | Check
  | Apply
  | Projection

let mode_arg = function
  | Check -> "--check"
  | Apply -> "--apply"
  | Projection -> "--json"
;;

let run ~echo ~workspace ~registry_url ~scope ~mode =
  if not (has_projection ~workspace)
  then Ok None
  else (
    let cmd =
      Sol_cli_process.cmd
        ~cwd:workspace
        ~env:[ "SCHEMA_REGISTRY_URL", registry_url ]
        ~timeout_s:300.
        [ "sh"; "./contract/run"; mode_arg mode; "--scope"; scope ]
    in
    match Sol_cli_process.run ~echo cmd with
    | Ok out -> Ok (Some out.stdout)
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let report ~workspace ~registry_url ~scope ~mode =
  match run ~echo:true ~workspace ~registry_url ~scope ~mode with
  | Error msg -> Error msg
  | Ok None -> Ok ()
  | Ok (Some output) ->
    let trimmed = String.trim output in
    if trimmed <> "" then Sol_cli_report.app "%s" trimmed;
    Ok ()
;;

let print_declared_events events =
  List.iter
    (fun ((dir : string), (event : Sol_cli_toml.event_decl)) ->
       let key =
         match event.key_field with
         | None -> "(unkeyed)"
         | Some field -> field
       in
       Sol_cli_report.app
         "  - %s  %s  topic %s  partitions %d  key %s\n"
         dir
         event.name
         event.topic
         event.partitions
         key)
    events
;;

let plan_report ~workspace ~registry_url ~scope =
  (match Sol_cli_workspace_scan.discover_events ~root:workspace () with
   | Error error ->
     Sol_cli_report.warn
       "warning: could not read the declared contract: %s"
       (Sol_cli_toml.parse_error_to_string error)
   | Ok [] -> ()
   | Ok events ->
     Sol_cli_report.app "\nContract (declared):";
     print_declared_events events);
  (match Option.value registry_url ~default:"" with
   | "" ->
     Sol_cli_report.app
       "  registry: not observed (no SCHEMA_REGISTRY_URL; a private registry is only \
        reachable from the destination, and `sol deploy` reconciles it there)\n"
   | registry_url ->
     (match run ~echo:false ~workspace ~registry_url ~scope ~mode:Check with
      | Ok (Some output) ->
        String.split_on_char '\n' output
        |> List.iter (fun line ->
          let line = String.trim line in
          if line <> "" then Sol_cli_report.app "  %s" line)
      | Ok None -> ()
      | Error msg -> Sol_cli_report.app "  registry: not observed -- %s" msg));
  Ok ()
;;

let kafka_secret_name (spec : Sol_cli_deployment_plan.service_spec) =
  let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
  let keys = Sol_cli_manifest.kafka_required_secret_keys transport in
  List.find_map
    (fun key ->
       match List.assoc_opt key spec.secret_sources with
       | Some (Sol_cli_manifest.Target_kafka { secret }) -> Some secret
       | Some (External _) ->
         Some
           (Sol_cli_manifest.external_secret_name
              (Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name))
       | Some Sol_managed | None -> None)
    keys
;;

let reconciliation_images services =
  let seen = ref [] in
  List.filter_map
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       if List.mem spec.Sol_cli_deployment_plan.language !seen
       then None
       else (
         seen := spec.Sol_cli_deployment_plan.language :: !seen;
         let namespace =
           Sol_cli_deployment_plan.namespace_to_string
             spec.Sol_cli_deployment_plan.namespace
         in
         let candidates =
           List.filter
             (fun (candidate : Sol_cli_deployment_plan.service_spec) ->
                String.equal
                  (Sol_cli_deployment_plan.namespace_to_string
                     candidate.Sol_cli_deployment_plan.namespace)
                  namespace)
             services
         in
         let has_consumer =
           List.exists
             (fun (candidate : Sol_cli_deployment_plan.service_spec) ->
                candidate.Sol_cli_deployment_plan.consumes_kafka)
             candidates
         in
         (* The contract Job reconciles the workspace projection, so it needs the
            Kafka delivery of any consumer in this namespace — not merely the first
            unit that happens to share the language. A namespace with no consumer
            has no Kafka delivery to require. *)
         let kafka_secret =
           List.find_map
             (fun (candidate : Sol_cli_deployment_plan.service_spec) ->
                if candidate.Sol_cli_deployment_plan.consumes_kafka
                then kafka_secret_name candidate
                else None)
             candidates
         in
         Some (namespace, spec.Sol_cli_deployment_plan.image, kafka_secret, has_consumer)))
    services
;;

let reconcile_in_destination ~ctx ~kafka ~secret_name ~consumer ~namespace ~image =
  (* The Job consumes the same resolved selection and delivered Secret as workload
     rendering. It reads only the keys the transport requires, never every key in the
     Secret. A namespace with no consumer does not need a delivery at all. *)
  let kafka_config = Sol_cli_resource_binding.kafka_config kafka in
  let transport = Sol_cli_manifest.kafka_transport_of_config kafka_config in
  let* () =
    if not consumer
    then Ok ()
    else (
      match transport with
      | Sol_cli_manifest.Plaintext -> Ok ()
      | Sol_cli_manifest.Sasl_ssl ->
        (match secret_name with
         | None ->
           Error
             "the target's Kafka transport requires a delivered credential Secret, but \
              the plan resolved none"
         | Some secret_name ->
           Sol_cli_secret.verify_required_keys
             ~ctx
             ~namespace
             ~secret_name
             ~required_keys:(Sol_cli_manifest.kafka_required_secret_keys transport)
             ()))
  in
  match
    Sol_cli_migration_job.submit_doc
      ~ctx
      ~namespace
      ~name_prefix:"sol-contract"
      ~label:"contract"
      (fun ~name ->
         Sol_cli_manifest.contract_job_doc
           ~cluster_env:(kafka_config @ Sol_cli_manifest.telemetry_env)
           ~secret_name
           ~name
           ~namespace
           ~image
           ~command:[ "/usr/local/bin/contract" ]
           ~args:[ "--apply" ])
  with
  | Error e -> Error ("could not start the contract reconciliation Job: " ^ e)
  | Ok job ->
    (match Sol_cli_migration_job.wait ~ctx ~interval_s:2. ~attempts:150 job with
     | Succeeded ->
       let* () = Sol_cli_migration_job.cleanup ~ctx job in
       Sol_cli_report.app "Contract: reconciled in the destination with image %s." image;
       Ok ()
     | Failed ->
       Sol_cli_migration_job.evidence ~ctx job
       |> Option.iter (Sol_cli_report.err "\ncontract reconciliation Job evidence:\n%s");
       Error
         (Printf.sprintf
            "the contract reconciliation Job failed; it is kept for inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            job.job_name
            namespace)
     | Unstartable { reason; detail } ->
       Sol_cli_migration_job.evidence ~ctx job
       |> Option.iter (Sol_cli_report.err "\ncontract reconciliation Job evidence:\n%s");
       Error
         (Printf.sprintf
            "the contract reconciliation Job could not start (%s%s); it is kept for \
             inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            reason
            (match detail with
             | Some detail -> ": " ^ detail
             | None -> "")
            job.job_name
            namespace)
     | Timed_out seconds ->
       Error
         (Printf.sprintf
            "the contract reconciliation Job did not finish within %.0fs; it is kept for \
             inspection:\n\
            \  kubectl logs job/%s -n %s\n\
             No workload was rolled out."
            seconds
            job.job_name
            namespace))
;;
