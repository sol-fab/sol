let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let contains needle haystack = Sol_cli_string.contains ~needle haystack

let output json =
  { Sol_cli_serverless_runner.stdout = Yojson.Safe.to_string json; stderr = "" }
;;

let target provider =
  match Sol_cli_config.parse_target (Printf.sprintf "dev/%s/us-east-1" provider) with
  | Error error -> Windtrap.fail (Sol_cli_config.error_to_string error)
  | Ok target ->
    { target with
      Sol_cli_config.provider_fields =
        [ ( (match target.provider with
             | Sol_cli_provider.Aws -> "aws"
             | Sol_cli_provider.Gcp -> "gcp"
             | Sol_cli_provider.Byo -> "byo")
          , if target.provider = Sol_cli_provider.Gcp
            then [ "project_id", "example-project" ]
            else [] )
        ]
    }
;;

let aws_target = target "aws"
let gcp_target = target "gcp"

(* --- AWS fake ------------------------------------------------------------ *)

type aws_state =
  { mutable api : bool
  ; mutable integrations : (string * string) list
  ; mutable routes : (string * string * string) list
  ; mutable stage : bool
  }

let aws_state = { api = false; integrations = []; routes = []; stage = false }

let arg args flag =
  let rec go = function
    | [] -> None
    | [ _ ] -> None
    | flag' :: value :: rest ->
      if String.equal flag' flag then Some value else go (value :: rest)
  in
  go args
;;

let has args needle = List.exists (fun arg -> String.equal arg needle) args

let positional_after args word =
  let rec go = function
    | [] -> None
    | value :: rest ->
      if String.equal value word
      then (
        match rest with
        | next :: _ -> Some next
        | [] -> None)
      else go rest
  in
  go args
;;

let aws_run args : (Sol_cli_serverless_runner.output, string) result =
  let json value = Ok (output value) in
  if has args "get-apis"
  then
    json
      (`Assoc
          [ ( "Items"
            , if aws_state.api
              then
                `List
                  [ `Assoc
                      [ "ApiId", `String "api-1"
                      ; "Name", `String "dev-aws-us-east-1-http"
                      ; ( "ApiEndpoint"
                        , `String "https://api-1.execute-api.us-east-1.amazonaws.com/" )
                      ]
                  ]
              else `List [] )
          ])
  else if has args "get-tags"
  then
    json
      (`Assoc
          [ ( "tags"
            , `Assoc
                [ "sol-owned", `String "api-gateway-experiment"
                ; "sol-workspace", `String (Sol_cli_aws_lambda_common.workspace_label ())
                ; "sol-target", `String aws_target.name
                ] )
          ])
  else if has args "create-api"
  then (
    aws_state.api <- true;
    json
      (`Assoc
          [ "ApiId", `String "api-1"
          ; "ApiEndpoint", `String "https://api-1.execute-api.us-east-1.amazonaws.com/"
          ]))
  else if has args "get-stages"
  then
    json
      (`Assoc
          [ ( "Items"
            , if aws_state.stage
              then `List [ `Assoc [ "StageName", `String "$default" ] ]
              else `List [] )
          ])
  else if has args "create-stage"
  then (
    aws_state.stage <- true;
    json (`Assoc []))
  else if has args "get-integrations"
  then
    json
      (`Assoc
          [ ( "Items"
            , `List
                (List.mapi
                   (fun _index (id, uri) ->
                      `Assoc
                        [ "IntegrationId", `String id; "IntegrationUri", `String uri ])
                   aws_state.integrations) )
          ])
  else if has args "create-integration"
  then (
    match arg args "--integration-uri" with
    | None -> Error "missing integration uri"
    | Some uri ->
      let id = "int-" ^ string_of_int (List.length aws_state.integrations + 1) in
      aws_state.integrations <- (id, uri) :: aws_state.integrations;
      json (`Assoc [ "IntegrationId", `String id ]))
  else if has args "update-integration"
  then json (`Assoc [])
  else if has args "get-routes"
  then
    json
      (`Assoc
          [ ( "Items"
            , `List
                (List.mapi
                   (fun _index (key, target, id) ->
                      `Assoc
                        [ "RouteKey", `String key
                        ; "RouteId", `String id
                        ; "Target", `String target
                        ])
                   aws_state.routes) )
          ])
  else if has args "create-route"
  then (
    match arg args "--route-key", arg args "--target" with
    | Some key, Some target ->
      let id = "route-" ^ string_of_int (List.length aws_state.routes) in
      aws_state.routes <- (key, target, id) :: aws_state.routes;
      json (`Assoc [ "RouteId", `String id ])
    | _ -> Error "create-route missing arguments")
  else if has args "update-route"
  then json (`Assoc [])
  else if has args "delete-route"
  then (
    match arg args "--route-id" with
    | None -> Error "delete-route missing id"
    | Some id ->
      aws_state.routes
      <- List.filter
           (fun (_, _, candidate) -> not (String.equal candidate id))
           aws_state.routes;
      json (`Assoc []))
  else if has args "delete-integration"
  then (
    match arg args "--integration-id" with
    | None -> Error "delete-integration missing id"
    | Some id ->
      aws_state.integrations
      <- List.filter
           (fun (candidate, _) -> not (String.equal candidate id))
           aws_state.integrations;
      json (`Assoc []))
  else if has args "delete-api"
  then (
    aws_state.api <- false;
    aws_state.routes <- [];
    aws_state.integrations <- [];
    aws_state.stage <- false;
    json (`Assoc []))
  else if has args "get-function" && has args "--query"
  then (
    match arg args "--function-name" with
    | Some function_name ->
      json (`String ("arn:aws:lambda:us-east-1:123:function:" ^ function_name))
    | None -> Error "get-function missing --function-name")
  else if has args "add-permission" || has args "remove-permission"
  then json (`Assoc [])
  else Error ("unexpected aws command: " ^ String.concat " " args)
;;

let aws_route service path backend = { Sol_cli_http_route.service; path; backend }

let%test "route validation refuses duplicate paths" =
  match
    Sol_cli_http_route.validate_routes
      [ { Sol_cli_http_route.service = "a"; path = "/quote"; backend = "a" }
      ; { Sol_cli_http_route.service = "b"; path = "/quote"; backend = "b" }
      ]
  with
  | Ok () -> Windtrap.fail "accepted duplicate routes"
  | Error message ->
    check_bool "names the duplicate path" true (contains "same route" message)
;;

let%test "AWS gateway: two public routes compose on one API" =
  let routes =
    [ aws_route "quote_fn" "/quote" "quote-fn"
    ; aws_route "orders_fn" "/orders" "orders-fn"
    ]
  in
  match
    Sol_cli_aws_http_gateway.reconcile
      aws_run
      ~profile:None
      ~region:"us-east-1"
      ~target:aws_target
      ~name:"dev-aws-us-east-1-http"
      routes
  with
  | Error message -> Windtrap.fail message
  | Ok None -> Windtrap.fail "expected an endpoint"
  | Ok (Some endpoint) ->
    check_string
      "endpoint"
      "https://api-1.execute-api.us-east-1.amazonaws.com"
      endpoint.url;
    check_bool
      "quote route"
      true
      (List.exists (fun (key, _, _) -> String.equal key "ANY /quote") aws_state.routes);
    check_bool
      "orders route"
      true
      (List.exists (fun (key, _, _) -> String.equal key "ANY /orders") aws_state.routes);
    check_bool "stage" true aws_state.stage
;;

let%test "AWS gateway: removing one route leaves the other, then deletes the API" =
  let remaining = [ aws_route "quote_fn" "/quote" "quote-fn" ] in
  (match
     Sol_cli_aws_http_gateway.reconcile
       aws_run
       ~profile:None
       ~region:"us-east-1"
       ~target:aws_target
       ~name:"dev-aws-us-east-1-http"
       remaining
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  check_bool
    "orders route removed"
    false
    (List.exists (fun (key, _, _) -> String.equal key "ANY /orders") aws_state.routes);
  (match
     Sol_cli_aws_http_gateway.remove_route
       aws_run
       ~profile:None
       ~region:"us-east-1"
       ~target:aws_target
       ~name:"dev-aws-us-east-1-http"
       ~path:"/quote"
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  check_bool "api deleted" false aws_state.api
;;

let%test "AWS gateway: restore moves a function's route without touching others" =
  let first = aws_route "quote_fn" "/quote" "quote-fn" in
  (match
     Sol_cli_aws_http_gateway.reconcile
       aws_run
       ~profile:None
       ~region:"us-east-1"
       ~target:aws_target
       ~name:"dev-aws-us-east-1-http"
       [ first; aws_route "orders_fn" "/orders" "orders-fn" ]
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  (match
     Sol_cli_aws_http_gateway.restore_route
       aws_run
       ~profile:None
       ~region:"us-east-1"
       ~target:aws_target
       ~name:"dev-aws-us-east-1-http"
       { first with Sol_cli_http_route.path = "/v2/quote" }
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  check_bool
    ("old route removed: "
     ^ String.concat
         "; "
         (List.map
            (fun (key, target, id) -> key ^ "->" ^ target ^ "(" ^ id ^ ")")
            aws_state.routes))
    false
    (List.exists (fun (key, _, _) -> String.equal key "ANY /quote") aws_state.routes);
  check_bool
    "new route present"
    true
    (List.exists (fun (key, _, _) -> String.equal key "ANY /v2/quote") aws_state.routes);
  check_bool
    "unrelated route preserved"
    true
    (List.exists (fun (key, _, _) -> String.equal key "ANY /orders") aws_state.routes)
;;

let%test "AWS gateway: an API left by a failed deploy is removed" =
  aws_state.api <- true;
  aws_state.routes <- [];
  (match
     Sol_cli_aws_http_gateway.reconcile
       aws_run
       ~profile:None
       ~region:"us-east-1"
       ~target:aws_target
       ~name:"dev-aws-us-east-1-http"
       []
   with
   | Error message -> Windtrap.fail message
   | Ok None -> ()
   | Ok (Some _) -> Windtrap.fail "an empty route set returned an endpoint");
  check_bool "orphan API removed" false aws_state.api
;;

(* --- GCP fake ------------------------------------------------------------ *)

type gcp_state =
  { mutable api : bool
  ; mutable config : string option
  ; mutable spec : string option
  ; mutable gateway : bool
  }

let gcp_state = { api = false; config = None; spec = None; gateway = false }

let gcp_labels () =
  `Assoc
    [ "sol-owned", `String "api-gateway-experiment"
    ; "sol-workspace", `String (Sol_cli_aws_lambda_common.workspace_label ())
    ; "sol-target", `String (Sol_cli_kubernetes_name.sanitize_label_value gcp_target.name)
    ]
;;

let gcp_run args : (Sol_cli_serverless_runner.output, string) result =
  let json value = Ok (output value) in
  if has args "services" && has args "enable"
  then json (`Assoc [])
  else if has args "apis" && has args "describe"
  then
    if gcp_state.api
    then json (`Assoc [ "name", `String "example-api"; "labels", gcp_labels () ])
    else Error "NOT_FOUND"
  else if has args "apis" && has args "create"
  then (
    gcp_state.api <- true;
    json (`Assoc []))
  else if has args "api-configs" && has args "describe"
  then (
    let requested = positional_after args "describe" in
    match gcp_state.config, gcp_state.spec, requested with
    | Some config, Some spec, Some requested when String.equal config requested ->
      json
        (`Assoc
            [ ( "openapiDocuments"
              , `List
                  [ `Assoc
                      [ ( "document"
                        , `Assoc [ "contents", `String (Base64.encode_string spec) ] )
                      ]
                  ] )
            ; "name", `String config
            ])
    | _ -> Error "NOT_FOUND")
  else if has args "api-configs" && has args "create"
  then (
    match arg args "--openapi-spec" with
    | None -> Error "api-config create missing spec"
    | Some path ->
      let spec = In_channel.with_open_bin path In_channel.input_all in
      let config =
        match positional_after args "create" with
        | Some config -> config
        | None -> "cfg-test"
      in
      gcp_state.config <- Some config;
      gcp_state.spec <- Some spec;
      json (`Assoc []))
  else if has args "api-configs" && has args "list"
  then
    Ok
      { Sol_cli_serverless_runner.stdout =
          (match gcp_state.config with
           | Some config -> config ^ "\n"
           | None -> "")
      ; stderr = ""
      }
  else if has args "api-configs" && has args "delete"
  then (
    gcp_state.config <- None;
    gcp_state.spec <- None;
    json (`Assoc []))
  else if has args "gateways" && has args "describe"
  then
    if gcp_state.gateway
    then (
      match gcp_state.config with
      | None -> Error "NOT_FOUND"
      | Some config ->
        json
          (`Assoc
              [ "name", `String "dev-aws-us-east-1-http"
              ; "labels", gcp_labels ()
              ; ( "apiConfig"
                , `String
                    (Printf.sprintf
                       "projects/example-project/locations/global/apis/example-api/configs/%s"
                       config) )
              ; "defaultHostname", `String "gateway.example"
              ]))
    else Error "NOT_FOUND"
  else if has args "gateways" && (has args "create" || has args "update")
  then (
    gcp_state.gateway <- true;
    json (`Assoc []))
  else if has args "gateways" && has args "delete"
  then (
    gcp_state.gateway <- false;
    json (`Assoc []))
  else if has args "apis" && has args "delete"
  then (
    gcp_state.api <- false;
    json (`Assoc []))
  else Error ("unexpected gcloud command: " ^ String.concat " " args)
;;

let gcp_route service path =
  { Sol_cli_http_route.service; path; backend = "https://run.example/" ^ service }
;;

let%test "GCP gateway: an API left by a failed deploy is removed" =
  gcp_state.api <- true;
  gcp_state.config <- Some "cfg-orphan";
  gcp_state.spec
  <- Some {|{"swagger":"2.0","info":{"title":"x","version":"1"},"paths":{}}|};
  gcp_state.gateway <- false;
  (match
     Sol_cli_gcp_http_gateway.reconcile
       gcp_run
       ~project:"example-project"
       ~region:"us-central1"
       ~target:gcp_target
       ~name:"dev-gcp-us-central1-http"
       []
   with
   | Error message -> Windtrap.fail message
   | Ok None -> ()
   | Ok (Some _) -> Windtrap.fail "an empty route set returned an endpoint");
  check_bool "orphan API removed" false gcp_state.api
;;

let%test "GCP gateway: routes share one API Gateway endpoint" =
  let routes = [ gcp_route "quote_fn" "/quote"; gcp_route "orders_fn" "/orders" ] in
  match
    Sol_cli_gcp_http_gateway.reconcile
      gcp_run
      ~project:"example-project"
      ~region:"us-central1"
      ~target:gcp_target
      ~name:"dev-gcp-us-central1-http"
      routes
  with
  | Error message -> Windtrap.fail message
  | Ok None -> Windtrap.fail "expected an endpoint"
  | Ok (Some endpoint) ->
    check_string "endpoint" "https://gateway.example" endpoint.url;
    (match gcp_state.spec with
     | None -> Windtrap.fail "no spec"
     | Some spec ->
       check_bool "quote path" true (contains "\"/quote\"" spec);
       check_bool "orders path" true (contains "\"/orders\"" spec));
    check_bool "gateway and api" true (gcp_state.gateway && gcp_state.api)
;;

let%test "GCP gateway: removing the last route destroys the gateway and API" =
  (match
     Sol_cli_gcp_http_gateway.remove_route
       gcp_run
       ~project:"example-project"
       ~region:"us-central1"
       ~target:gcp_target
       ~name:"dev-gcp-us-central1-http"
       ~path:"/quote"
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  check_bool "gateway remains" true gcp_state.gateway;
  (match gcp_state.spec with
   | None ->
     Windtrap.fail
       (Printf.sprintf
          "no spec (gateway=%b api=%b config=%s)"
          gcp_state.gateway
          gcp_state.api
          (match gcp_state.config with
           | Some c -> c
           | None -> "none"))
   | Some spec -> check_bool "quote path removed" false (contains "\"/quote\"" spec));
  (match
     Sol_cli_gcp_http_gateway.remove_route
       gcp_run
       ~project:"example-project"
       ~region:"us-central1"
       ~target:gcp_target
       ~name:"dev-gcp-us-central1-http"
       ~path:"/orders"
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  check_bool "gateway deleted" false gcp_state.gateway;
  check_bool "api deleted" false gcp_state.api
;;

let%test "GCP gateway: restore moves a function's path and preserves others" =
  let quote = gcp_route "quote_fn" "/quote" in
  (match
     Sol_cli_gcp_http_gateway.reconcile
       gcp_run
       ~project:"example-project"
       ~region:"us-central1"
       ~target:gcp_target
       ~name:"dev-gcp-us-central1-http"
       [ quote; gcp_route "orders_fn" "/orders" ]
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  (match
     Sol_cli_gcp_http_gateway.restore_route
       gcp_run
       ~project:"example-project"
       ~region:"us-central1"
       ~target:gcp_target
       ~name:"dev-gcp-us-central1-http"
       { quote with Sol_cli_http_route.path = "/v2/quote" }
   with
   | Error message -> Windtrap.fail message
   | Ok _ -> ());
  match gcp_state.spec with
  | None -> Windtrap.fail "no spec"
  | Some spec ->
    check_bool "old path removed" false (contains "\"/quote\"" spec);
    check_bool "new path present" true (contains "\"/v2/quote\"" spec);
    check_bool "unrelated path preserved" true (contains "\"/orders\"" spec)
;;
