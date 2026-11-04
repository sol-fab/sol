open Result.Syntax

(** GCP API Gateway lifecycle for the target's shared public HTTP API.

    Public HTTP functions remain independent Cloud Run services; this adapter owns
    the one API Gateway API, API config, and gateway that route a shared host to
    them. Internal HTTP functions are deliberately outside this gateway: their
    Cloud Run ingress and workload-identity check stay private. *)

type route = Sol_cli_http_route.t

type endpoint =
  { name : string
  ; url : string
  }

type runner = string list -> (Sol_cli_serverless_runner.output, string) result

let tag = "api-gateway-experiment"

let contains value needle =
  let value = String.lowercase_ascii value
  and needle = String.lowercase_ascii needle in
  let rec at index =
    if index + String.length needle > String.length value
    then false
    else if String.sub value index (String.length needle) = needle
    then true
    else at (index + 1)
  in
  at 0
;;

let absent message = contains message "not found" || contains message "not_found"

let run_json run args =
  match run args with
  | Error message -> Error message
  | Ok output ->
    Sol_cli_json.decode
      ~what:("gcloud " ^ String.concat " " args)
      (output : Sol_cli_serverless_runner.output).stdout
;;

let string_field json name =
  Sol_cli_json.string (Sol_cli_json.field [ name ] json)
  |> Option.to_result ~none:(Printf.sprintf "provider response has no %s" name)
;;

let project (target : Sol_cli_config.target) =
  match Sol_cli_config.provider_field target "project_id" with
  | Some project when String.trim project <> "" -> Ok (String.trim project)
  | _ -> Error "target must declare gcp.project_id for a shared HTTP API"
;;

let labels ~(target : Sol_cli_config.target) =
  [ "sol-owned", tag
  ; "sol-workspace", Sol_cli_aws_lambda_common.workspace_label ()
  ; "sol-target", Sol_cli_kubernetes_name.sanitize_label_value target.name
  ]
;;

let labels_arg ~target =
  labels ~target |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat ","
;;

let owns ~(target : Sol_cli_config.target) json =
  match Sol_cli_json.assoc (Sol_cli_json.field [ "labels" ] json) with
  | None -> false
  | Some fields ->
    let value key =
      match List.assoc_opt key fields with
      | Some value -> Sol_cli_json.string value
      | None -> None
    in
    value "sol-owned" = Some tag
    && value "sol-workspace" = Some (Sol_cli_aws_lambda_common.workspace_label ())
    && value "sol-target"
       = Some (Sol_cli_kubernetes_name.sanitize_label_value target.name)
;;

let describe_gateway run ~project ~region ~name =
  match
    run_json
      run
      [ "gcloud"
      ; "api-gateway"
      ; "gateways"
      ; "describe"
      ; name
      ; "--location"
      ; region
      ; "--project"
      ; project
      ; "--format=json"
      ]
  with
  | Ok json -> Ok (Some json)
  | Error message when absent message -> Ok None
  | Error message -> Error message
;;

let describe_api run ~project ~name =
  match
    run_json
      run
      [ "gcloud"
      ; "api-gateway"
      ; "apis"
      ; "describe"
      ; name
      ; "--project"
      ; project
      ; "--format=json"
      ]
  with
  | Ok json -> Ok (Some json)
  | Error message when absent message -> Ok None
  | Error message -> Error message
;;

let config_parts json =
  let* resource =
    let* value = string_field json "apiConfig" in
    Ok value
  in
  match String.split_on_char '/' resource |> List.rev with
  | config :: "configs" :: api :: "apis" :: _ -> Ok (api, config)
  | _ -> Error (Printf.sprintf "cannot parse API config resource %S" resource)
;;

let ensure_api run ~project ~target ~name =
  let* existing = describe_api run ~project ~name in
  match existing with
  | Some json ->
    if owns ~target json
    then Ok ()
    else Error (Printf.sprintf "API Gateway API %s lacks this workspace's labels" name)
  | None ->
    run
      [ "gcloud"
      ; "api-gateway"
      ; "apis"
      ; "create"
      ; name
      ; "--project"
      ; project
      ; "--labels"
      ; labels_arg ~target
      ; "--quiet"
      ]
    |> Result.map (fun _ -> ())
;;

let config_exists run ~project ~api ~config =
  match
    run_json
      run
      [ "gcloud"
      ; "api-gateway"
      ; "api-configs"
      ; "describe"
      ; config
      ; "--api"
      ; api
      ; "--project"
      ; project
      ; "--format=json"
      ]
  with
  | Ok _ -> Ok true
  | Error message when absent message -> Ok false
  | Error message -> Error message
;;

let create_config run ~project ~target ~api ~config ~spec =
  Sol_cli_fs.with_temp_file ~prefix:"sol-api-gateway-" ~suffix:".json" spec (fun path ->
    run
      [ "gcloud"
      ; "api-gateway"
      ; "api-configs"
      ; "create"
      ; config
      ; "--api"
      ; api
      ; "--openapi-spec"
      ; path
      ; "--project"
      ; project
      ; "--labels"
      ; labels_arg ~target
      ; "--quiet"
      ]
    |> Result.map (fun _ -> ()))
  |> Result.map_error (fun message -> "could not write API config: " ^ message)
  |> Result.join
;;

let default_hostname json =
  match Sol_cli_json.string (Sol_cli_json.field [ "defaultHostname" ] json) with
  | Some hostname when String.trim hostname <> "" -> Ok (String.trim hostname)
  | _ -> Error "API Gateway describe has no defaultHostname"
;;

let prune_configs run ~project ~api ~keep =
  match
    run
      [ "gcloud"
      ; "api-gateway"
      ; "api-configs"
      ; "list"
      ; "--api"
      ; api
      ; "--project"
      ; project
      ; "--format=value(name)"
      ]
  with
  | Error message ->
    Sol_cli_report.warn "could not list API Gateway configs for pruning: %s" message;
    ()
  | Ok output ->
    let names =
      String.split_on_char '\n' (output : Sol_cli_serverless_runner.output).stdout
      |> List.map String.trim
      |> List.filter (fun value -> value <> "")
    in
    List.iter
      (fun resource ->
         let name = List.hd (List.rev (String.split_on_char '/' resource)) in
         if String.equal name keep
         then ()
         else (
           match
             run
               [ "gcloud"
               ; "api-gateway"
               ; "api-configs"
               ; "delete"
               ; name
               ; "--api"
               ; api
               ; "--project"
               ; project
               ; "--quiet"
               ]
           with
           | Ok _ -> ()
           | Error message ->
             Sol_cli_report.warn
               "could not delete superseded API Gateway config %s: %s"
               name
               message))
      names
;;

let ensure_gateway run ~project ~region ~target ~name ~api ~config =
  match describe_gateway run ~project ~region ~name with
  | Error message -> Error message
  | Ok None ->
    run
      [ "gcloud"
      ; "api-gateway"
      ; "gateways"
      ; "create"
      ; name
      ; "--api"
      ; api
      ; "--api-config"
      ; config
      ; "--location"
      ; region
      ; "--project"
      ; project
      ; "--labels"
      ; labels_arg ~target
      ; "--quiet"
      ]
    |> Result.map (fun _ -> ())
  | Ok (Some json) ->
    if owns ~target json
    then
      run
        [ "gcloud"
        ; "api-gateway"
        ; "gateways"
        ; "update"
        ; name
        ; "--api"
        ; api
        ; "--api-config"
        ; config
        ; "--location"
        ; region
        ; "--project"
        ; project
        ; "--labels"
        ; labels_arg ~target
        ; "--quiet"
        ]
      |> Result.map (fun _ -> ())
    else
      Error
        (Printf.sprintf
           "API Gateway %s exists without this workspace's ownership labels"
           name)
;;

let publish_spec run ~project ~region ~target ~name ~spec =
  let api = Sol_cli_kubernetes_name.sanitize_name (name ^ "-api") in
  (* API Gateway is delivered by project services that a fresh project does not
     enable. Enabling is idempotent and shared; destruction deliberately leaves
     them enabled because other gateways may use them. *)
  let* () =
    run
      [ "gcloud"
      ; "services"
      ; "enable"
      ; "apigateway.googleapis.com"
      ; "servicecontrol.googleapis.com"
      ; "servicemanagement.googleapis.com"
      ; "--project"
      ; project
      ; "--quiet"
      ]
    |> Result.map (fun _ -> ())
  in
  let* () = ensure_api run ~project ~target ~name:api in
  let digest = Digest.to_hex (Digest.string spec) in
  let config = "cfg-" ^ String.sub digest 0 12 in
  let* exists = config_exists run ~project ~api ~config in
  let* () =
    if exists then Ok () else create_config run ~project ~target ~api ~config ~spec
  in
  let* () = ensure_gateway run ~project ~region ~target ~name ~api ~config in
  let* json =
    run_json
      run
      [ "gcloud"
      ; "api-gateway"
      ; "gateways"
      ; "describe"
      ; name
      ; "--location"
      ; region
      ; "--project"
      ; project
      ; "--format=json"
      ]
  in
  let* () =
    if owns ~target json then Ok () else Error "API Gateway lost its ownership labels"
  in
  let* hostname = default_hostname json in
  prune_configs run ~project ~api ~keep:config;
  Ok (Some { name; url = "https://" ^ hostname })
;;

let methods = [ "get"; "post"; "put"; "patch"; "delete" ]

let operations_for ~backend =
  let backend =
    `Assoc
      [ "address", `String backend; "path_translation", `String "APPEND_PATH_TO_ADDRESS" ]
  in
  methods
  |> List.map (fun method_ ->
    ( method_
    , `Assoc
        [ "x-google-backend", backend
        ; "responses", `Assoc [ "200", `Assoc [ "description", `String "OK" ] ]
        ] ))
  |> fun operations -> `Assoc operations
;;

let backend_of_operations = function
  | `Assoc operations ->
    List.find_map
      (fun (_, operation) ->
         match
           Sol_cli_json.string
             (Sol_cli_json.field [ "x-google-backend"; "address" ] operation)
         with
         | Some address -> Some address
         | None -> None)
      operations
  | _ -> None
;;

let spec_json ~name routes =
  let paths =
    List.map
      (fun (route : route) -> route.path, operations_for ~backend:route.backend)
      routes
  in
  `Assoc
    [ "swagger", `String "2.0"
    ; "info", `Assoc [ "title", `String name; "version", `String "1" ]
    ; "paths", `Assoc paths
    ]
  |> Yojson.Safe.to_string
;;

let render_delete run ~project ~region ~target ~name ~api =
  let* existing = describe_gateway run ~project ~region ~name in
  let* () =
    match existing with
    | None -> Ok ()
    | Some json ->
      let* () =
        if owns ~target json
        then Ok ()
        else Error "API Gateway lacks this workspace's ownership labels"
      in
      run
        [ "gcloud"
        ; "api-gateway"
        ; "gateways"
        ; "delete"
        ; name
        ; "--location"
        ; region
        ; "--project"
        ; project
        ; "--quiet"
        ]
      |> Result.map (fun _ -> ())
  in
  prune_configs run ~project ~api ~keep:"";
  let* api_json = describe_api run ~project ~name:api in
  let* () =
    match api_json with
    | None -> Ok ()
    | Some json ->
      let* () =
        if owns ~target json
        then Ok ()
        else Error "API Gateway API lacks this workspace's ownership labels"
      in
      run
        [ "gcloud"
        ; "api-gateway"
        ; "apis"
        ; "delete"
        ; api
        ; "--project"
        ; project
        ; "--quiet"
        ]
      |> Result.map (fun _ -> ())
  in
  let* gone = describe_gateway run ~project ~region ~name in
  match gone with
  | None -> Ok ()
  | Some _ -> Error "API Gateway remains after delete"
;;

let delete_orphan_api run ~project ~target ~api =
  let* existing = describe_api run ~project ~name:api in
  match existing with
  | None -> Ok ()
  | Some json ->
    let* () =
      if owns ~target json
      then Ok ()
      else Error "API Gateway API lacks this workspace's ownership labels"
    in
    prune_configs run ~project ~api ~keep:"";
    run
      [ "gcloud"; "api-gateway"; "apis"; "delete"; api; "--project"; project; "--quiet" ]
    |> Result.map (fun _ -> ())
;;

let reconcile run ~project ~region ~target ~name routes =
  let* () = Sol_cli_http_route.validate_routes routes in
  if routes = []
  then
    let* existing = describe_gateway run ~project ~region ~name in
    match existing with
    | None ->
      let* () =
        delete_orphan_api
          run
          ~project
          ~target
          ~api:(Sol_cli_kubernetes_name.sanitize_name (name ^ "-api"))
      in
      Ok None
    | Some json ->
      let* api, _config = config_parts json in
      let* () = render_delete run ~project ~region ~target ~name ~api in
      Ok None
  else publish_spec run ~project ~region ~target ~name ~spec:(spec_json ~name routes)
;;

let config_spec run ~project ~api ~config =
  let* json =
    run_json
      run
      [ "gcloud"
      ; "api-gateway"
      ; "api-configs"
      ; "describe"
      ; config
      ; "--api"
      ; api
      ; "--project"
      ; project
      ; "--view=FULL"
      ; "--format=json"
      ]
  in
  let* documents =
    Sol_cli_json.list (Sol_cli_json.field [ "openapiDocuments" ] json)
    |> Option.to_result ~none:"API config has no openapiDocuments"
  in
  match documents with
  | [] -> Error "API config has an empty openapiDocuments list"
  | document :: _ ->
    let* contents =
      Sol_cli_json.string (Sol_cli_json.field [ "document"; "contents" ] document)
      |> Option.to_result ~none:"API config document has no contents"
    in
    (match Base64.decode contents with
     | Error (`Msg message) -> Error ("API config document: " ^ message)
     | Ok decoded -> Ok decoded)
;;

let restore_route run ~project ~region ~target ~name (route : route) =
  let* existing = describe_gateway run ~project ~region ~name in
  match existing with
  | None ->
    publish_spec run ~project ~region ~target ~name ~spec:(spec_json ~name [ route ])
  | Some json ->
    let* () =
      if owns ~target json
      then Ok ()
      else Error "API Gateway lacks this workspace's ownership labels"
    in
    let* api, config = config_parts json in
    let* spec = config_spec run ~project ~api ~config in
    let* spec_json =
      Sol_cli_json.decode ~what:"API config document" spec
      |> Result.map_error (fun message -> "API config document: " ^ message)
    in
    let paths =
      match Sol_cli_json.field [ "paths" ] spec_json with
      | `Assoc paths -> paths
      | _ -> []
    in
    let paths =
      List.filter
        (fun (path, operations) ->
           not
             (String.equal path route.path
              || backend_of_operations operations = Some route.backend))
        paths
    in
    let paths = (route.path, operations_for ~backend:route.backend) :: paths in
    let spec =
      match spec_json with
      | `Assoc fields ->
        `Assoc
          (("paths", `Assoc paths) :: List.filter (fun (key, _) -> key <> "paths") fields)
      | other -> other
    in
    publish_spec run ~project ~region ~target ~name ~spec:(Yojson.Safe.to_string spec)
;;

let remove_route run ~project ~region ~target ~name ~path =
  let* existing = describe_gateway run ~project ~region ~name in
  match existing with
  | None ->
    let* () =
      delete_orphan_api
        run
        ~project
        ~target
        ~api:(Sol_cli_kubernetes_name.sanitize_name (name ^ "-api"))
    in
    Ok None
  | Some json ->
    let* () =
      if owns ~target json
      then Ok ()
      else Error "API Gateway lacks this workspace's ownership labels"
    in
    let* api, config = config_parts json in
    let* spec = config_spec run ~project ~api ~config in
    let* spec_json =
      Sol_cli_json.decode ~what:"API config document" spec
      |> Result.map_error (fun message -> "API config document: " ^ message)
    in
    let paths =
      match Sol_cli_json.field [ "paths" ] spec_json with
      | `Assoc paths -> paths
      | _ -> []
    in
    let paths =
      List.filter (fun (candidate, _) -> not (String.equal candidate path)) paths
    in
    if paths = []
    then
      render_delete run ~project ~region ~target ~name ~api |> Result.map (fun () -> None)
    else (
      let spec =
        match spec_json with
        | `Assoc fields ->
          `Assoc
            (("paths", `Assoc paths)
             :: List.filter (fun (key, _) -> key <> "paths") fields)
        | other -> other
      in
      publish_spec run ~project ~region ~target ~name ~spec:(Yojson.Safe.to_string spec))
;;
