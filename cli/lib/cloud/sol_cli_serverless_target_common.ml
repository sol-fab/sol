open Result.Syntax

let required_field (target : Sol_cli_config.target) ~provider name =
  match Sol_cli_config.provider_field target name with
  | Some value when String.trim value <> "" -> Ok value
  | _ ->
    Error
      (Printf.sprintf "target must declare %s.%s for serverless execution" provider name)
;;

let callers (target : Sol_cli_config.target) =
  match Sol_cli_config.provider_field target "serverless_callers" with
  | None | Some "" -> []
  | Some text ->
    String.split_on_char ',' text
    |> List.filter_map (fun entry ->
      match String.index_opt entry '=' with
      | None -> None
      | Some at ->
        let unit = String.sub entry 0 at |> String.trim in
        let subject =
          String.sub entry (at + 1) (String.length entry - at - 1) |> String.trim
        in
        if unit = "" || subject = "" then None else Some (subject, unit))
;;

let unit_of_service ~project (service : Sol_cli_manifest.service) =
  match String.split_on_char '/' service.dir |> List.rev with
  | name :: domain :: _ when name = service.name && domain <> "" && domain <> "." ->
    domain ^ "/" ^ service.name
  | _ -> project ^ "/" ^ service.name
;;

let services_by_backend (target : Sol_cli_config.target) services =
  match Sol_cli_config.execution_of_target target with
  | Sol_cli_config.Serverless -> services, []
  | Sol_cli_config.Kubernetes -> [], services
  | Sol_cli_config.Mixed ->
    ( List.filter
        (fun (service : Sol_cli_manifest.service) ->
           match service.primitive with
           | Sol_cli_manifest.Fn -> true
           | Svc | Worker -> false)
        services
    , List.filter
        (fun (service : Sol_cli_manifest.service) ->
           match service.primitive with
           | Sol_cli_manifest.Fn -> false
           | Svc | Worker -> true)
        services )
;;

let ensure_serverless (target : Sol_cli_config.target) =
  if Sol_cli_config.execution_of_target target = Sol_cli_config.Serverless
  then Ok ()
  else Error "target does not select execution: serverless"
;;

let declared_uses config (service : Sol_cli_manifest.service) =
  let* declared =
    Sol_cli_config.services config
    |> List.find_opt (fun (s : Sol_cli_config.service) -> s.name = service.name)
    |> Option.to_result ~none:"service is not declared in sol.yml"
  in
  if declared.uses = []
  then Ok ()
  else (
    let external_resource ref =
      match Sol_cli_resource_binding.resource_name_of_ref ref with
      | None -> false
      | Some name ->
        (match
           Sol_cli_config.resources config
           |> List.find_opt (fun (resource : Sol_cli_config.resource) ->
             String.equal resource.name name)
         with
         | Some { typ = Some ("queue" | "object_store"); binding = Some binding; _ }
           when binding.ownership = Sol_cli_config.Ownership_external -> true
         | _ -> false)
    in
    if List.for_all external_resource declared.uses
    then Ok ()
    else
      Error
        "target-scoped serverless dispatch supports only external queue/object-store \
         dependencies; other service dependencies are not implemented")
;;

let require_http_callers (target : Sol_cli_config.target) =
  if callers target = []
  then
    Error "target must declare serverless_callers for incoming application authentication"
  else Ok ()
;;
