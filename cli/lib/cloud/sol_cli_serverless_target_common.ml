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
  else Error "target-scoped serverless dispatch does not yet support service dependencies"
;;

let require_http_callers (target : Sol_cli_config.target) =
  if callers target = []
  then
    Error "target must declare serverless_callers for incoming application authentication"
  else Ok ()
;;
