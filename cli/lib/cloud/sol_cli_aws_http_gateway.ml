open Result.Syntax

(** AWS API Gateway HTTP API lifecycle for the target's shared public HTTP API.

    This is a gateway, not another function endpoint: each public HTTP function is
    an [AWS_PROXY] integration behind one route on one HTTP API. The Lambda
    Function URL is deliberately not created; the API Gateway endpoint is the
    function's only public HTTP address. Internal HTTP functions are refused by
    the target dispatcher because an HTTP API endpoint is public. *)

type route = Sol_cli_http_route.t

type endpoint =
  { name : string
  ; url : string
  }

type runner = string list -> (Sol_cli_serverless_runner.output, string) result

let tag = "api-gateway-experiment"
let stage = "$default"

let aws ~profile ~region args =
  [ "aws"; "--region"; region; "--output"; "json" ]
  @ (match profile with
     | None -> []
     | Some profile -> [ "--profile"; profile ])
  @ args
;;

let run_json run ~profile ~region args =
  match run (aws ~profile ~region args) with
  | Error message -> Error message
  | Ok output ->
    Sol_cli_json.decode
      ~what:("aws " ^ String.concat " " args)
      (output : Sol_cli_serverless_runner.output).stdout
;;

let string_field json name =
  Sol_cli_json.string (Sol_cli_json.field [ name ] json)
  |> Option.to_result ~none:(Printf.sprintf "provider response has no %s" name)
;;

let trim value = String.trim value

let owns ~(target : Sol_cli_config.target) tags =
  List.assoc_opt "sol-owned" tags = Some tag
  && List.assoc_opt "sol-workspace" tags
     = Some (Sol_cli_aws_lambda_common.workspace_label ())
  && List.assoc_opt "sol-target" tags = Some target.name
;;

let api_tags ~(target : Sol_cli_config.target) =
  [ "sol-owned", tag
  ; "sol-workspace", Sol_cli_aws_lambda_common.workspace_label ()
  ; "sol-target", target.name
  ]
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> String.concat ","
;;

let find_api run ~profile ~region ~name =
  let* json = run_json run ~profile ~region [ "apigatewayv2"; "get-apis" ] in
  match Sol_cli_json.list (Sol_cli_json.field [ "Items" ] json) with
  | None -> Error "API Gateway get-apis response has no Items array"
  | Some items ->
    Ok
      (List.find_opt
         (fun item ->
            match Sol_cli_json.string (Sol_cli_json.field [ "Name" ] item) with
            | Some candidate -> String.equal candidate name
            | None -> false)
         items)
;;

let api_tags_of run ~profile ~region ~api_id =
  let* json =
    run_json
      run
      ~profile
      ~region
      [ "apigatewayv2"
      ; "get-tags"
      ; "--resource-arn"
      ; Printf.sprintf "arn:aws:apigateway:%s::/apis/%s" region api_id
      ]
  in
  match Sol_cli_json.assoc (Sol_cli_json.field [ "tags" ] json) with
  | None -> Ok []
  | Some fields ->
    Ok
      (List.filter_map
         (fun (key, value) ->
            Option.map (fun value -> key, value) (Sol_cli_json.string value))
         fields)
;;

let verify_owned run ~profile ~region ~(target : Sol_cli_config.target) ~api_id =
  let* tags = api_tags_of run ~profile ~region ~api_id in
  if owns ~target tags
  then Ok ()
  else
    Error
      (Printf.sprintf
         "API Gateway API %s exists without this workspace's ownership tags"
         api_id)
;;

let ensure_api run ~profile ~region ~(target : Sol_cli_config.target) ~name =
  let* existing = find_api run ~profile ~region ~name in
  match existing with
  | Some item ->
    let* api_id = string_field item "ApiId" in
    let* () = verify_owned run ~profile ~region ~target ~api_id in
    let* url = string_field item "ApiEndpoint" in
    Ok (api_id, url)
  | None ->
    let* json =
      run_json
        run
        ~profile
        ~region
        [ "apigatewayv2"
        ; "create-api"
        ; "--name"
        ; name
        ; "--protocol-type"
        ; "HTTP"
        ; "--tags"
        ; api_tags ~target
        ]
    in
    let* api_id = string_field json "ApiId" in
    let* url = string_field json "ApiEndpoint" in
    Ok (api_id, url)
;;

let ensure_stage run ~profile ~region ~api_id =
  let* json =
    run_json run ~profile ~region [ "apigatewayv2"; "get-stages"; "--api-id"; api_id ]
  in
  let stages =
    match Sol_cli_json.list (Sol_cli_json.field [ "Items" ] json) with
    | None -> []
    | Some items ->
      List.filter_map
        (fun item -> Sol_cli_json.string (Sol_cli_json.field [ "StageName" ] item))
        items
  in
  if List.mem stage stages
  then Ok ()
  else
    run_json
      run
      ~profile
      ~region
      [ "apigatewayv2"
      ; "create-stage"
      ; "--api-id"
      ; api_id
      ; "--stage-name"
      ; stage
      ; "--auto-deploy"
      ]
    |> Result.map (fun _ -> ())
;;

let lambda_arn run ~profile ~region ~function_name =
  let* json =
    run_json
      run
      ~profile
      ~region
      [ "lambda"
      ; "get-function"
      ; "--function-name"
      ; function_name
      ; "--query"
      ; "Configuration.FunctionArn"
      ]
  in
  match Sol_cli_json.string json with
  | Some arn when String.trim arn <> "" -> Ok (trim arn)
  | _ -> Error (Printf.sprintf "Lambda function %s has no ARN" function_name)
;;

let integration_uri ~region ~alias_arn =
  Printf.sprintf
    "arn:aws:apigateway:%s:lambda:path/2015-03-31/functions/%s/invocations"
    region
    alias_arn
;;

let list_items run ~profile ~region ~api_id ~operation =
  let* json =
    run_json run ~profile ~region [ "apigatewayv2"; operation; "--api-id"; api_id ]
  in
  match Sol_cli_json.list (Sol_cli_json.field [ "Items" ] json) with
  | None -> Error (Printf.sprintf "API Gateway %s response has no Items array" operation)
  | Some items -> Ok items
;;

let ensure_integration run ~profile ~region ~api_id ~function_name =
  let* arn = lambda_arn run ~profile ~region ~function_name in
  let alias_arn = arn ^ ":live" in
  let uri = integration_uri ~region ~alias_arn in
  let* integrations =
    list_items run ~profile ~region ~api_id ~operation:"get-integrations"
  in
  let existing =
    List.find_opt
      (fun item ->
         match Sol_cli_json.string (Sol_cli_json.field [ "IntegrationUri" ] item) with
         | Some candidate -> String.equal candidate uri
         | None -> false)
      integrations
  in
  match existing with
  | Some item ->
    let* integration_id = string_field item "IntegrationId" in
    Ok integration_id
  | None ->
    let* json =
      run_json
        run
        ~profile
        ~region
        [ "apigatewayv2"
        ; "create-integration"
        ; "--api-id"
        ; api_id
        ; "--integration-type"
        ; "AWS_PROXY"
        ; "--integration-uri"
        ; alias_arn
        ; "--payload-format-version"
        ; "2.0"
        ]
    in
    string_field json "IntegrationId"
;;

let route_key (route : route) = "ANY " ^ route.path

let ensure_route run ~profile ~region ~api_id ~integration_id route =
  let* routes = list_items run ~profile ~region ~api_id ~operation:"get-routes" in
  let key = route_key route in
  let target = "integrations/" ^ integration_id in
  match
    List.find_opt
      (fun item ->
         match Sol_cli_json.string (Sol_cli_json.field [ "RouteKey" ] item) with
         | Some candidate -> String.equal candidate key
         | None -> false)
      routes
  with
  | Some item ->
    let* route_id = string_field item "RouteId" in
    let* () =
      run_json
        run
        ~profile
        ~region
        [ "apigatewayv2"
        ; "update-route"
        ; "--api-id"
        ; api_id
        ; "--route-id"
        ; route_id
        ; "--route-key"
        ; key
        ; "--target"
        ; target
        ]
      |> Result.map (fun _ -> ())
    in
    Ok ()
  | None ->
    run_json
      run
      ~profile
      ~region
      [ "apigatewayv2"
      ; "create-route"
      ; "--api-id"
      ; api_id
      ; "--route-key"
      ; key
      ; "--target"
      ; target
      ]
    |> Result.map (fun _ -> ())
;;

let permission_id (route : route) =
  "sol-gw-"
  ^ Sol_cli_kubernetes_name.sanitize_label_value (route.service ^ "-" ^ route.path)
;;

let ensure_permission run ~profile ~region ~api_id ~function_name ~account ~route =
  let statement_id = permission_id route in
  let source_arn =
    Printf.sprintf "arn:aws:execute-api:%s:%s:%s/*/ANY%s" region account api_id route.path
  in
  let remove =
    [ "lambda"
    ; "remove-permission"
    ; "--function-name"
    ; function_name
    ; "--statement-id"
    ; statement_id
    ]
  in
  let _ =
    match run (aws ~profile ~region remove) with
    | Ok _ -> ()
    | Error _ -> ()
  in
  run_json
    run
    ~profile
    ~region
    [ "lambda"
    ; "add-permission"
    ; "--function-name"
    ; function_name
    ; "--statement-id"
    ; statement_id
    ; "--action"
    ; "lambda:InvokeFunction"
    ; "--principal"
    ; "apigateway.amazonaws.com"
    ; "--source-arn"
    ; source_arn
    ]
  |> Result.map (fun _ -> ())
;;

let cleanup_integrations run ~profile ~region ~api_id =
  let* integrations =
    list_items run ~profile ~region ~api_id ~operation:"get-integrations"
  in
  let* referenced =
    list_items run ~profile ~region ~api_id ~operation:"get-routes"
    |> Result.map (fun routes ->
      List.filter_map
        (fun item ->
           match Sol_cli_json.string (Sol_cli_json.field [ "Target" ] item) with
           | Some target when String.starts_with ~prefix:"integrations/" target ->
             Some
               (String.sub
                  target
                  (String.length "integrations/")
                  (String.length target - String.length "integrations/"))
           | _ -> None)
        routes)
    |> Result.map (fun ids -> List.sort_uniq String.compare ids)
  in
  Sol_cli_result.map_list
    (fun item ->
       let* integration_id = string_field item "IntegrationId" in
       if List.mem integration_id referenced
       then Ok ()
       else
         run_json
           run
           ~profile
           ~region
           [ "apigatewayv2"
           ; "delete-integration"
           ; "--api-id"
           ; api_id
           ; "--integration-id"
           ; integration_id
           ]
         |> Result.map (fun _ -> ()))
    integrations
  |> Result.map ignore
;;

let ensure_route_for run ~profile ~region ~api_id (route : route) =
  let* integration_id =
    ensure_integration run ~profile ~region ~api_id ~function_name:route.backend
  in
  let* () = ensure_route run ~profile ~region ~api_id ~integration_id route in
  let* arn = lambda_arn run ~profile ~region ~function_name:route.backend in
  let account =
    match String.split_on_char ':' arn with
    | _arn :: _partition :: _service :: _region :: account :: _ -> account
    | _ -> ""
  in
  if account = ""
  then Error "could not derive the AWS account from the Lambda ARN"
  else
    ensure_permission
      run
      ~profile
      ~region
      ~api_id
      ~function_name:route.backend
      ~account
      ~route
;;

let delete_stale_routes run ~profile ~region ~api_id routes =
  let desired = List.map route_key routes |> List.sort_uniq String.compare in
  let* existing = list_items run ~profile ~region ~api_id ~operation:"get-routes" in
  let* () =
    Sol_cli_result.map_list
      (fun item ->
         let* key = string_field item "RouteKey" in
         if List.mem key desired || not (String.starts_with ~prefix:"ANY " key)
         then Ok ()
         else
           let* route_id = string_field item "RouteId" in
           run_json
             run
             ~profile
             ~region
             [ "apigatewayv2"
             ; "delete-route"
             ; "--api-id"
             ; api_id
             ; "--route-id"
             ; route_id
             ]
           |> Result.map (fun _ -> ()))
      existing
    |> Result.map ignore
  in
  cleanup_integrations run ~profile ~region ~api_id
;;

let delete_api run ~profile ~region ~api_id =
  run_json run ~profile ~region [ "apigatewayv2"; "delete-api"; "--api-id"; api_id ]
  |> Result.map (fun _ -> ())
;;

let delete_gateway run ~profile ~region ~target ~name =
  let* existing = find_api run ~profile ~region ~name in
  match existing with
  | None -> Ok None
  | Some item ->
    let* api_id = string_field item "ApiId" in
    let* () = verify_owned run ~profile ~region ~target ~api_id in
    let* () = delete_api run ~profile ~region ~api_id in
    let* gone = find_api run ~profile ~region ~name in
    (match gone with
     | None -> Ok None
     | Some _ -> Error "API Gateway API remains after delete")
;;

let reconcile run ~profile ~region ~(target : Sol_cli_config.target) ~name routes =
  let* () = Sol_cli_http_route.validate_routes routes in
  if routes = []
  then delete_gateway run ~profile ~region ~target ~name
  else
    let* api_id, url = ensure_api run ~profile ~region ~target ~name in
    let* () = ensure_stage run ~profile ~region ~api_id in
    let* () =
      Sol_cli_result.map_list
        (fun (route : route) -> ensure_route_for run ~profile ~region ~api_id route)
        routes
      |> Result.map ignore
    in
    let* () = delete_stale_routes run ~profile ~region ~api_id routes in
    Ok (Some { name; url = Sol_cli_aws_lambda_common.trim_url url })
;;

let restore_route run ~profile ~region ~target ~name (route : route) =
  let* api_id, url = ensure_api run ~profile ~region ~target ~name in
  let* () = ensure_stage run ~profile ~region ~api_id in
  let* integrations =
    list_items run ~profile ~region ~api_id ~operation:"get-integrations"
  in
  let function_marker = ":function:" ^ route.backend ^ ":live" in
  let* old_integrations =
    integrations
    |> Sol_cli_result.map_list (fun item ->
      let* integration_id = string_field item "IntegrationId" in
      let* uri = string_field item "IntegrationUri" in
      if Sol_cli_string.contains ~needle:function_marker uri
      then Ok (Some integration_id)
      else Ok None)
    |> Result.map (List.filter_map Fun.id)
  in
  let old_targets = List.map (fun id -> "integrations/" ^ id) old_integrations in
  let* routes = list_items run ~profile ~region ~api_id ~operation:"get-routes" in
  let desired = route_key route in
  let* () =
    Sol_cli_result.map_list
      (fun item ->
         let* key = string_field item "RouteKey" in
         let* item_target = string_field item "Target" in
         if List.mem item_target old_targets && not (String.equal key desired)
         then
           let* route_id = string_field item "RouteId" in
           run_json
             run
             ~profile
             ~region
             [ "apigatewayv2"
             ; "delete-route"
             ; "--api-id"
             ; api_id
             ; "--route-id"
             ; route_id
             ]
           |> Result.map (fun _ -> ())
         else Ok ())
      routes
    |> Result.map ignore
  in
  let* () = ensure_route_for run ~profile ~region ~api_id route in
  Ok (Some { name; url = Sol_cli_aws_lambda_common.trim_url url })
;;

let remove_route run ~profile ~region ~target ~name ~path =
  let* existing = find_api run ~profile ~region ~name in
  match existing with
  | None -> Ok None
  | Some item ->
    let* api_id = string_field item "ApiId" in
    let* () = verify_owned run ~profile ~region ~target ~api_id in
    let* routes = list_items run ~profile ~region ~api_id ~operation:"get-routes" in
    let key = "ANY " ^ path in
    let* () =
      match
        List.find_opt
          (fun item ->
             match Sol_cli_json.string (Sol_cli_json.field [ "RouteKey" ] item) with
             | Some candidate -> String.equal candidate key
             | None -> false)
          routes
      with
      | None -> Ok ()
      | Some item ->
        let* route_id = string_field item "RouteId" in
        run_json
          run
          ~profile
          ~region
          [ "apigatewayv2"; "delete-route"; "--api-id"; api_id; "--route-id"; route_id ]
        |> Result.map (fun _ -> ())
    in
    let* routes = list_items run ~profile ~region ~api_id ~operation:"get-routes" in
    if routes = []
    then delete_gateway run ~profile ~region ~target ~name
    else
      let* () = cleanup_integrations run ~profile ~region ~api_id in
      Ok None
;;
