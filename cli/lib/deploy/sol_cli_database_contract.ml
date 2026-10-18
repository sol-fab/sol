open Result.Syntax
module P = Sol_cli_deployment_plan
module R = Sol_cli_database_setup_render
module M = Sol_cli_manifest_cluster_env

let string s = `String s
let strings xs = `List (List.map string xs)
let fields xs = `Assoc xs

let option fn = function
  | None -> `Null
  | Some value -> fn value
;;

module Data = Sol_cli_database_contract_data

let canonical = Data.canonical
let seal = Data.seal

type definition =
  { revision : string
  ; digest : string
  ; document : Yojson.Safe.t
  }

type projection = Projection of Yojson.Safe.t

let definition_json d = d.document
let projection_json (Projection json) = json
let revision d = d.revision
let digest d = d.digest

let definition ~revision =
  if
    String.length revision <> 40
    || not
         (String.for_all
            (function
              | '0' .. '9' | 'a' .. 'f' -> true
              | _ -> false)
            revision)
  then Error "product revision must be a full lowercase Git revision"
  else
    let* document =
      seal
        (fields
           [ "schema", `Int 1
           ; "product_revision", string revision
           ; "ca", fields [ "key", string M.db_ca_file_name; "file", string M.db_ca_file ]
           ; ( "credentials"
             , fields
                 [ "key", string R.postgres_url_key
                 ; "dml_class", string R.dml_class
                 ; "ddl_class", string R.ddl_class
                 ] )
           ; ( "rendering"
             , fields
                 [ "ca_volume_name", string M.db_ca_volume
                 ; "volume_identity", string "internal_linkage"
                 ; "migration_container", string M.migration_container_name
                 ] )
           ])
    in
    let* digest =
      Sol_cli_json.require
        ~what:"product declaration"
        [ "digest" ]
        Sol_cli_json.string
        document
    in
    Ok { revision; digest; document }
;;

let read_definition document =
  let* canonical_document = canonical document in
  match canonical_document with
  | `Assoc [ ("declaration", `Assoc payload); ("digest", `String _) ] ->
    (match List.assoc_opt "product_revision" payload with
     | Some (`String revision) ->
       let* expected = definition ~revision in
       let* expected_json = canonical expected.document in
       if canonical_document = expected_json
       then Ok expected
       else Error "unsupported or inconsistent product declaration"
     | _ -> Error "missing product revision")
  | _ -> Error "missing product declaration/digest"
;;

let reference ~namespace ~name =
  fields [ "namespace", string namespace; "name", string name ]
;;

let ca ~namespace ~target =
  fields
    [ "configmap", reference ~namespace ~name:(R.ca_configmap_name target)
    ; "key", string M.db_ca_file_name
    ; "file", string M.db_ca_file
    ]
;;

let project ~definition ~requested_target ~config ~(facts : Sol_cli_workspace_model.t) =
  let* () =
    match
      List.find_opt
        (fun (issue : Sol_cli_workspace_model.declaration_issue) ->
           issue.severity = `Error)
        (Sol_cli_workspace_model.declaration_issues
           ~scan:(Sol_cli_workspace_model.scan_of facts)
           (Sol_cli_config.services config))
    with
    | Some issue -> Error (issue.path ^ ": " ^ issue.message)
    | None -> Ok ()
  in
  let* () =
    match
      List.find_opt
        (fun (workload : Sol_cli_workspace_model.workload) ->
           (not workload.has_dockerfile)
           && not (Sol_cli_config.is_omitted_service config ~name:workload.service.name))
        (Sol_cli_workspace_model.workloads facts)
    with
    | Some workload ->
      Error ("cannot declare complete target: no Dockerfile for " ^ workload.service.name)
    | None -> Ok ()
  in
  let inventory = Sol_cli_workspace_model.services facts in
  let* selection = Sol_cli_deploy_selection.select ~image_refs:[] inventory in
  let* deployed =
    Sol_cli_deploy_selection.apply_target ~target:config.target.name ~config selection
  in
  let workspace = Sol_cli_workspace.workspace_name ~root:facts.root in
  let* plan =
    Sol_cli_deploy_selection.declaration_plan
      { workspace
      ; registry = "declaration.invalid"
      ; sha = "declaration-only"
      ; emit_to = None
      ; config
      ; facts
      ; inventory
      ; image_refs = []
      ; requested_scope = "workspace"
      ; services = deployed.services
      }
    |> Result.map_error (function
      | Sol_cli_deploy_selection.Refused message -> message
      | Preflight (profile, findings) -> Sol_cli_profile_preflight.report profile findings)
  in
  let selection = plan.Sol_cli_deployment_plan.database in
  let id = Sol_cli_database_setup_run.identity ~workspace ~config ~database:selection in
  let binding = Sol_cli_resource_binding.postgres_resource selection in
  let provisioned = Sol_cli_resource_binding.postgres_is_managed selection in
  let database =
    option
      (fun resource ->
         let namespace = R.database_namespace id in
         fields
           [ "resource", string resource
           ; "ownership", string (if provisioned then "sol" else "external")
           ; ( "credential_authority"
             , if provisioned
               then reference ~namespace ~name:(R.authority_name id.target)
               else `Null )
           ; ( "administrative_references"
             , if provisioned
               then `List [ reference ~namespace ~name:(R.secret_name id.target) ]
               else `List [] )
           ; ( "migration"
             , fields
                 [ "context", string "database_migration"
                 ; "namespace", string namespace
                 ; "resource", string "Job"
                 ; "container", string M.migration_container_name
                 ; "job_identity", string "requires_execution_receipt"
                 ; "credential", reference ~namespace ~name:(R.ddl_creds_name id.target)
                 ; ("ca", if provisioned then ca ~namespace ~target:id.target else `Null)
                 ] )
           ])
      binding
  in
  let workload (s : P.service_spec) =
    let subject = s.domain ^ "/" ^ s.source_name in
    let* database =
      match Sol_cli_resource_binding.postgres_use_target s.database, binding with
      | None, _ -> Ok `Null
      | Some _, Some binding -> Ok (string binding)
      | Some _, None -> Error "consumer has no resolved target database"
    in
    let namespace = P.namespace_to_string s.namespace
    and name = P.k8s_name_to_string s.k8s_name in
    Ok
      ( subject
      , fields
          [ "subject", string subject
          ; "resource", string (P.resource_of_spec s)
          ; "namespace", string namespace
          ; "name", string name
          ; "declared_uses", strings s.uses
          ; "database", database
          ; ( "consuming_containers"
            , if Option.is_some (Sol_cli_resource_binding.postgres_use_target s.database)
              then strings [ M.workload_container_name name ]
              else strings [] )
          ; ( "credential"
            , option
                (fun target -> reference ~namespace ~name:(R.dml_creds_name target))
                (Sol_cli_resource_binding.postgres_use_target s.database) )
          ; ( "ca"
            , option
                (fun target -> ca ~namespace ~target)
                (Sol_cli_resource_binding.postgres_use_ca_target s.database) )
          ] )
  in
  let* workloads = Sol_cli_result.map_list workload plan.services in
  let workloads =
    workloads |> List.sort (fun (a, _) (b, _) -> String.compare a b) |> List.map snd
  in
  let* document =
    seal
      (fields
         [ "schema", `Int 1
         ; "product_revision", string definition.revision
         ; "definition_digest", string definition.digest
         ; "workspace", string workspace
         ; "target", string config.target.name
         ; "requested_target", string requested_target
         ; "database", database
         ; "workloads", `List workloads
         ])
  in
  let* _ = Data.read_specimen document in
  Ok (Projection document)
;;
