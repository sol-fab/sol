type terraform_grant =
  { unit : string
  ; capability : string
  ; resource : string
  ; namespace : string
  }

let secret_grant ~unit ~key =
  { Sol_cli_authorization.unit
  ; capability = Sol_cli_grant.secret_capability
  ; resource = key
  }
;;

(* A secret key becomes the resource suffix of an IAM ARN. AWS treats `*` and `?` as
   wildcards and `/` as a path separator, so a declaration such as `secrets = ["*"]`
   would grant every environment secret rather than the unit's own. The full secret-key
   grammar is checked by `sol check`; this is the narrower IAM-resource safety boundary
   every grant path must enforce. *)
let validate_secret_resource key =
  let invalid =
    if String.equal key ""
    then Some "secret key must not be empty"
    else if String.exists (fun c -> c = '*' || c = '?' || c = '/') key
    then Some "secret key must not contain *, ?, or / in an authorization grant"
    else None
  in
  match invalid with
  | None -> Ok ()
  | Some message -> Error message
;;

let unit_name (service : Sol_cli_manifest.service) =
  Sol_cli_kubernetes_name.k8s_name_of_source service.name
  |> Result.map Sol_cli_kubernetes_name.k8s_name_to_string
  |> Result.map_error (fun message ->
    Printf.sprintf
      "service %s has no addressable Kubernetes identity: %s"
      service.name
      message)
;;

let desired workspace =
  Sol_cli_workspace_model.workloads workspace
  |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
    match workload.config with
    | Error parse_error ->
      Error
        (Printf.sprintf
           "cannot read %s's declarations (%s), so its grants cannot be computed; an \
            authorization plan is never built from an incomplete workspace"
           workload.service.Sol_cli_manifest.name
           (Sol_cli_toml.parse_error_to_string parse_error))
    | Ok config ->
      (match unit_name workload.service with
       | Error message -> Error message
       | Ok unit ->
         (match
            Sol_cli_result.map_list
              (fun key ->
                 validate_secret_resource key
                 |> Result.map (fun () -> key)
                 |> Result.map_error (fun message ->
                   Printf.sprintf "unit %s declares %S: %s" unit key message))
              config.Sol_cli_toml.secret_keys
          with
          | Error message -> Error message
          | Ok keys -> Ok (List.map (fun key -> secret_grant ~unit ~key) keys))))
  |> Result.map List.concat
;;

let terraform_grants ~grants ~namespace_of =
  grants
  |> Sol_cli_result.map_list (fun (grant : Sol_cli_authorization.grant) ->
    match namespace_of grant.unit with
    | Some namespace ->
      Ok
        { unit = grant.unit
        ; capability = grant.capability
        ; resource = grant.resource
        ; namespace
        }
    | None ->
      Error
        (Printf.sprintf
           "unit %s has no Kubernetes namespace in this workspace, so its identity \
            cannot be addressed"
           grant.unit))
;;

let workloads ~grants ~namespace_of =
  let open Result.Syntax in
  let* mapped = terraform_grants ~grants ~namespace_of in
  let units = List.sort_uniq String.compare (List.map (fun grant -> grant.unit) mapped) in
  Ok
    (units
     |> List.filter_map (fun unit ->
       match List.find_opt (fun grant -> String.equal grant.unit unit) mapped with
       | None -> None
       | Some first ->
         let secrets =
           mapped
           |> List.filter (fun grant ->
             String.equal grant.unit unit
             && String.equal grant.capability Sol_cli_grant.secret_capability)
           |> List.map (fun grant -> grant.resource)
         in
         Some { Sol_cli_provider_capabilities.unit; namespace = first.namespace; secrets })
    )
;;

let terraform_var grants =
  let object_ grant =
    `Assoc
      [ "unit", `String grant.unit
      ; "capability", `String grant.capability
      ; "resource", `String grant.resource
      ; "namespace", `String grant.namespace
      ]
  in
  "grants", Yojson.Safe.to_string (`List (List.map object_ grants))
;;

let grant_of_json json =
  let open Result.Syntax in
  let field key =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String value) -> Ok value
       | Some _ -> Error (Printf.sprintf "an established grant's %s is not a string" key)
       | None -> Error (Printf.sprintf "an established grant has no %s" key))
    | _ -> Error "an established grant is not an object"
  in
  let* unit = field "unit" in
  let* capability = field "capability" in
  let* resource = field "resource" in
  Ok { Sol_cli_authorization.unit; capability; resource }
;;

let current_of_output_json output =
  match Yojson.Safe.from_string output with
  | `Assoc outputs ->
    (match List.assoc_opt "established_grants" outputs with
     | None -> Ok []
     | Some (`Assoc entry) ->
       (match List.assoc_opt "value" entry with
        | None -> Ok []
        | Some (`List items) -> Sol_cli_result.map_list grant_of_json items
        | Some `Null -> Ok []
        | Some _ ->
          Error "the authorization root's established_grants output is not a list")
     | Some _ ->
       Error "the authorization root's established_grants output is not an object")
  | _ -> Error "terraform output is not a JSON object"
  | exception Yojson.Json_error message ->
    Error ("the authorization root's outputs are not JSON: " ^ message)
;;

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

let metadata_field item key =
  match item with
  | `Assoc fields ->
    (match List.assoc_opt "metadata" fields with
     | Some (`Assoc metadata) -> string_field key metadata
     | Some _ | None -> None)
  | _ -> None
;;

let annotation_of_item item =
  match item with
  | `Assoc fields ->
    (match List.assoc_opt "spec" fields with
     | Some (`Assoc spec) ->
       (match List.assoc_opt "template" spec with
        | Some (`Assoc template) ->
          (match List.assoc_opt "metadata" template with
           | Some (`Assoc metadata) ->
             (match List.assoc_opt "annotations" metadata with
              | Some (`Assoc annotations) ->
                string_field Sol_cli_grant.annotation_key annotations
              | Some _ | None -> None)
           | Some _ | None -> None)
        | Some _ | None -> None)
     | Some _ | None -> None)
  | _ -> None
;;

let grants_of_annotation ~unit value =
  let open Result.Syntax in
  let* tags = Sol_cli_grant.decode_tags value in
  Ok
    (List.map
       (fun tag ->
          { Sol_cli_authorization.unit
          ; capability = Sol_cli_grant.capability_of_tag tag
          ; resource = Sol_cli_grant.resource_of_tag tag
          })
       tags)
;;

let deployed_of_listing_json ~namespaces output =
  let open Result.Syntax in
  let items =
    match Yojson.Safe.from_string output with
    | `Assoc fields ->
      (match List.assoc_opt "items" fields with
       | Some (`List items) -> Ok items
       | Some _ -> Error "the Kubernetes listing has no items array"
       | None -> Error "the Kubernetes listing has no items field")
    | `List items -> Ok items
    | _ -> Error "the Kubernetes listing is not an object"
    | exception Yojson.Json_error message ->
      Error ("the Kubernetes listing is not JSON: " ^ message)
  in
  let* items = items in
  let in_scope item =
    match metadata_field item "namespace" with
    | None -> namespaces = []
    | Some namespace -> namespaces = [] || List.mem namespace namespaces
  in
  items
  |> List.filter in_scope
  |> Sol_cli_result.map_list (fun item ->
    let unit =
      match
        match item with
        | `Assoc fields ->
          (match List.assoc_opt "metadata" fields with
           | Some (`Assoc metadata) ->
             (match List.assoc_opt "labels" metadata with
              | Some (`Assoc labels) -> string_field "app" labels
              | Some _ | None -> None)
           | Some _ | None -> None)
        | _ -> None
      with
      | Some unit -> unit
      | None -> Option.value (metadata_field item "name") ~default:""
    in
    match annotation_of_item item with
    | None -> Ok []
    | Some value -> grants_of_annotation ~unit value)
  |> Result.map List.concat
;;
